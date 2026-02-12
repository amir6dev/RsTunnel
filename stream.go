package httpmux

import (
	"bytes"
	"errors"
	"io"
	"sync"
)

type Stream struct {
	ID  uint32
	in  chan []byte

	closed   bool
	mux      *SMUX
	writeMtx sync.Mutex

	// برای اینکه اگر payload بزرگ‌تر از p بود گم نشه
	rbuf bytes.Buffer
	rmu  sync.Mutex
}

func NewStream(id uint32, mux *SMUX) *Stream {
	return &Stream{
		ID: id,
		in: make(chan []byte, 64),
		mux: mux,
	}
}

func (s *Stream) Read(p []byte) (int, error) {
	s.rmu.Lock()
	defer s.rmu.Unlock()

	if s.rbuf.Len() > 0 {
		return s.rbuf.Read(p)
	}

	data, ok := <-s.in
	if !ok {
		return 0, io.EOF
	}
	_, _ = s.rbuf.Write(data)
	return s.rbuf.Read(p)
}

func (s *Stream) Write(p []byte) (int, error) {
	s.writeMtx.Lock()
	defer s.writeMtx.Unlock()

	if s.closed {
		return 0, errors.New("stream closed")
	}
	if s.mux == nil {
		return 0, errors.New("no mux attached")
	}

	max := s.mux.cfg.MaxFrame
	if max <= 0 {
		max = 2048
	}

	// chunking
	sent := 0
	for sent < len(p) {
		end := sent + max
		if end > len(p) {
			end = len(p)
		}
		chunk := p[sent:end]

		fr := &Frame{
			StreamID: s.ID,
			Type:     FrameData,
			Length:   uint32(len(chunk)),
			Payload:  chunk,
		}
		if err := s.mux.sendFrame(fr); err != nil {
			return sent, err
		}
		sent = end
	}

	return len(p), nil
}

func (s *Stream) Close() error {
	if s.closed {
		return nil
	}
	s.closed = true
	if s.mux == nil {
		return nil
	}
	return s.mux.sendFrame(&Frame{StreamID: s.ID, Type: FrameClose})
}

// internal receive from mux
func (s *Stream) push(data []byte) {
	if !s.closed {
		s.in <- data
	}
}

func (s *Stream) shutdown() {
	if !s.closed {
		s.closed = true
		close(s.in)
	}
}
