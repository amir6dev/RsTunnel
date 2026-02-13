package httpmux

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"sync"
	"sync/atomic"
	"time"
)

type FrameTransport interface {
	Start() error
	Close() error
	Send(fr *Frame) error
	Recv() (*Frame, error)
}

type HTTPConn struct {
	Client    *http.Client
	Mimic     *MimicConfig
	Obfs      *ObfsConfig
	PSK       string
	SessionID string
	ServerURL string

	// Path-level behaviors
	RetryInterval time.Duration
	Aggressive    bool
	nextTryNS     int64
}

func (hc *HTTPConn) canTry(now time.Time) bool {
	nt := atomic.LoadInt64(&hc.nextTryNS)
	return nt == 0 || now.UnixNano() >= nt
}

func (hc *HTTPConn) markFail(now time.Time) {
	ri := hc.RetryInterval
	if ri <= 0 {
		ri = 3 * time.Second
	}
	if hc.Aggressive {
		if ri > 500*time.Millisecond {
			ri = 500 * time.Millisecond
		}
	}
	atomic.StoreInt64(&hc.nextTryNS, now.Add(ri).UnixNano())
}

func (hc *HTTPConn) markOK() {
	atomic.StoreInt64(&hc.nextTryNS, 0)
}

func (hc *HTTPConn) RoundTrip(payload []byte) ([]byte, error) {
	if hc.Client == nil {
		hc.Client = &http.Client{Timeout: 25 * time.Second}
	}

	// Encrypt -> Obfs
	enc, err := EncryptPSK(payload, hc.PSK)
	if err != nil {
		return nil, err
	}
	enc = ApplyObfuscation(enc, hc.Obfs)
	ApplyDelay(hc.Obfs)

	body := bytes.NewReader(enc)
	req, err := http.NewRequest("POST", hc.ServerURL, body)
	if err != nil {
		return nil, err
	}

	if hc.Mimic != nil {
		if hc.Mimic.FakeDomain != "" {
			req.Host = hc.Mimic.FakeDomain
		}
		if hc.Mimic.Chunked {
			req.ContentLength = -1
		}
	}
	ApplyMimicHeaders(req, hc.Mimic, hc.SessionID)

	resp, err := hc.Client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if hc.Mimic != nil && hc.Mimic.SessionCookie {
		for _, c := range resp.Cookies() {
			if c == nil {
				continue
			}
			if c.Name == "session" && c.Value != "" {
				hc.SessionID = c.Value
				break
			}
		}
	}

	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	// Deobfs -> Decrypt
	b = StripObfuscation(b, hc.Obfs)
	plain, err := DecryptPSK(b, hc.PSK)
	if err != nil {
		return nil, err
	}
	return plain, nil
}

type HTTPMuxConfig struct {
	FlushInterval time.Duration
	MaxBatch      int
	IdlePoll      time.Duration
}

type HTTPMuxTransport struct {
	conns []*HTTPConn
	cfg   HTTPMuxConfig

	out chan *Frame
	in  chan *Frame

	die chan struct{}
	wg  sync.WaitGroup

	rr uint32
	
	// Semaphore to limit concurrent inflight requests (Backpressure)
	sem chan struct{}
}

func NewHTTPMuxTransport(conns []*HTTPConn, cfg HTTPMuxConfig) *HTTPMuxTransport {
	if cfg.FlushInterval <= 0 {
		cfg.FlushInterval = 20 * time.Millisecond // Faster flush for responsiveness
	}
	if cfg.MaxBatch <= 0 {
		cfg.MaxBatch = 128 // Increased batch size
	}
	if cfg.IdlePoll <= 0 {
		cfg.IdlePoll = 250 * time.Millisecond
	}
	
	// Limit concurrency to roughly 2x the number of connections per path
	// This ensures we use all connections but don't explode memory if net is slow.
	concurrencyLimit := len(conns) * 4 
	if concurrencyLimit < 4 {
		concurrencyLimit = 4
	}

	return &HTTPMuxTransport{
		conns: conns,
		cfg:   cfg,
		out:   make(chan *Frame, 8192), // Larger buffer
		in:    make(chan *Frame, 8192),
		die:   make(chan struct{}),
		sem:   make(chan struct{}, concurrencyLimit),
	}
}

func (t *HTTPMuxTransport) Start() error {
	if len(t.conns) == 0 {
		return errors.New("no conns")
	}
	t.wg.Add(1)
	go t.loop()
	return nil
}

func (t *HTTPMuxTransport) Close() error {
	select {
	case <-t.die:
	default:
		close(t.die)
	}
	t.wg.Wait()
	return nil
}

func (t *HTTPMuxTransport) Send(fr *Frame) error {
	select {
	case t.out <- fr:
		return nil
	case <-t.die:
		return io.EOF
	}
}

func (t *HTTPMuxTransport) Recv() (*Frame, error) {
	select {
	case fr := <-t.in:
		return fr, nil
	case <-t.die:
		return nil, io.EOF
	}
}

func (t *HTTPMuxTransport) pickConn() *HTTPConn {
	i := atomic.AddUint32(&t.rr, 1)
	return t.conns[int(i)%len(t.conns)]
}

func (t *HTTPMuxTransport) loop() {
	defer t.wg.Done()

	flushTick := time.NewTicker(t.cfg.FlushInterval)
	defer flushTick.Stop()

	var batch []*Frame

	// Helper to execute a round-trip asynchronously
	doRequest := func(payload []byte) {
		defer func() { <-t.sem }() // Release semaphore token

		// Try to find a healthy connection
		var conn *HTTPConn
		now := time.Now()
		
		// Simple retry logic for picking a connection
		for i := 0; i < len(t.conns); i++ {
			c := t.pickConn()
			if c.canTry(now) {
				conn = c
				break
			}
		}
		// If all are cooling down, just pick one anyway to avoid stalling
		if conn == nil {
			conn = t.pickConn()
		}

		resp, err := conn.RoundTrip(payload)
		if err != nil {
			conn.markFail(now)
			return
		}
		conn.markOK()

		if len(resp) == 0 {
			return
		}

		// Process response frames
		r := bytes.NewReader(resp)
		for {
			fr, err := ReadFrame(r)
			if err != nil {
				break
			}
			select {
			case t.in <- fr:
			case <-t.die:
				return
			}
		}
	}

	flush := func() {
		if len(batch) == 0 {
			// Idle poll (heartbeat/poll) logic
			// Only poll if we have capacity in semaphore
			select {
			case t.sem <- struct{}{}:
				go doRequest(nil)
			default:
				// If busy, skip idle polling
			}
			return
		}

		// Serialize batch
		var buf bytes.Buffer
		for _, fr := range batch {
			_ = WriteFrame(&buf, fr)
		}
		// Clear batch slice but keep capacity
		batch = batch[:0]

		// Acquire semaphore token (Backpressure: wait if too many requests inflight)
		select {
		case t.sem <- struct{}{}:
			// Launch request in background
			payload := make([]byte, buf.Len())
			copy(payload, buf.Bytes()) // Copy buffer because buf is reused
			go doRequest(payload)
		case <-t.die:
			return
		}
	}

	for {
		select {
		case <-t.die:
			return

		case fr := <-t.out:
			batch = append(batch, fr)
			if len(batch) >= t.cfg.MaxBatch {
				flush()
			}

		case <-flushTick.C:
			flush()
		}
	}
}