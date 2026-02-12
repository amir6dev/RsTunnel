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

type HTTPConn struct {
	Client    *http.Client
	Mimic     *MimicConfig
	Obfs      *ObfsConfig
	SessionID string
	ServerURL string
}

func (hc *HTTPConn) RoundTrip(payload []byte) ([]byte, error) {
	if hc.Client == nil {
		hc.Client = &http.Client{Timeout: 25 * time.Second}
	}
	payload = ApplyObfuscation(payload, hc.Obfs)
	ApplyDelay(hc.Obfs)

	req, err := http.NewRequest("POST", hc.ServerURL, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	ApplyMimicHeaders(req, hc.Mimic, hc.SessionID)

	resp, err := hc.Client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	return StripObfuscation(b, hc.Obfs), nil
}

type HTTPMuxConfig struct {
	FlushInterval time.Duration // هر چند وقت یک بار اگر فریم هست flush کن
	MaxBatch      int           // چند فریم در هر درخواست
	IdlePoll      time.Duration // اگر چیزی برای ارسال نبود، هر چند وقت یکبار poll کن (long-poll ساده)
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
		cfg.IdlePoll = 300 * time.Millisecond
	}
	return &HTTPMuxTransport{
		conns: conns,
		cfg:   cfg,
		out:   make(chan *Frame, 2048),
		in:    make(chan *Frame, 2048),
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
		// already closed
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
		if len(batch) == 0 {
			// idle poll: یک درخواست خالی برای گرفتن فریم‌های pending
			time.Sleep(t.cfg.IdlePoll)
		}

		var buf bytes.Buffer
		for _, fr := range batch {
			_ = WriteFrame(&buf, fr)
		}
		batch = batch[:0]

		conn := t.pickConn()
		resp, err := conn.RoundTrip(buf.Bytes())
		if err != nil {
			// backoff کوچک
			time.Sleep(200 * time.Millisecond)
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
