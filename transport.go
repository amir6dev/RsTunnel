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

	// Path-level behaviors (Dagger-like)
	RetryInterval time.Duration // per-path retry interval
	Aggressive    bool          // aggressive_pool
	nextTryNS     int64         // unix nano; internal cooldown timestamp
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
	// aggressive pool retries faster
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
	// Dagger-style Host spoofing (connect to real host, send fake Host header)
	if hc.Mimic != nil {
		if hc.Mimic.FakeDomain != "" {
			req.Host = hc.Mimic.FakeDomain
		}
		// If Chunked is enabled, force chunked transfer encoding (hide body size)
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

	// Capture Dagger-style session cookie for subsequent requests.
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
}

func NewHTTPMuxTransport(conns []*HTTPConn, cfg HTTPMuxConfig) *HTTPMuxTransport {
	if cfg.FlushInterval <= 0 {
		cfg.FlushInterval = 30 * time.Millisecond
	}
	if cfg.MaxBatch <= 0 {
		cfg.MaxBatch = 64
	}
	if cfg.IdlePoll <= 0 {
		cfg.IdlePoll = 250 * time.Millisecond
	}
	return &HTTPMuxTransport{
		conns: conns,
		cfg:   cfg,
		out:   make(chan *Frame, 4096),
		in:    make(chan *Frame, 4096),
		die:   make(chan struct{}),
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

	flush := func() {
		// request payload
		var buf bytes.Buffer
		for _, fr := range batch {
			_ = WriteFrame(&buf, fr)
		}
		batch = batch[:0]

		// idle poll: اگر چیزی برای ارسال نبود هم گهگاهی poll کن
		if buf.Len() == 0 {
			time.Sleep(t.cfg.IdlePoll)
		}

		// Try multiple conns (multi-path) before sleeping.
		now := time.Now()
		var (
			resp []byte
			err  error
		)
		tried := 0
		for tried < len(t.conns) {
			conn := t.pickConn()
			tried++
			if conn != nil && !conn.canTry(now) {
				continue
			}
			resp, err = conn.RoundTrip(buf.Bytes())
			if err != nil {
				if conn != nil {
					conn.markFail(now)
				}
				continue
			}
			if conn != nil {
				conn.markOK()
			}
			break
		}
		if err != nil {
			// All conns failed; small sleep to avoid tight loop.
			time.Sleep(250 * time.Millisecond)
			return
		}
		if len(resp) == 0 {
			return
		}

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
