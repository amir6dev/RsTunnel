package httpmux

import (
	"errors"
	"io"
	"sync"
)

type Stream struct {
	ID       uint32
	in       chan []byte
	out      chan []byte
	closed   bool
	mux      *SMUX
	writeMtx sync.Mutex
}

func NewStream(id uint32, mux *SMUX) *Stream {
	return &Stream{
		ID:  id,
		in:  make(chan []byte, 64),
		out: make(chan []byte, 64),
		mux: mux,
	}
}

func (s *Stream) Read(p []byte) (int, error) {
	data, ok := <-s.in
	if !ok {
		return 0, io.EOF
	}

	n := copy(p, data)
	return n, nil
}

func (s *Stream) Write(p []byte) (int, error) {
	s.writeMtx.Lock()
	defer s.writeMtx.Unlock()

	if s.closed {
		return 0, errors.New("stream closed")
	}

	fr := &Frame{
		StreamID: s.ID,
		Type:     FrameData,
		Length:   uint32(len(p)),
		Payload:  p,
	}

	return len(p), s.mux.sendFrame(fr)
}

func (s *Stream) Close() error {
	if s.closed {
		return nil
	}
	s.closed = true

	fr := &Frame{
		StreamID: s.ID,
		Type:     FrameClose,
		Length:   0,
	}
	return s.mux.sendFrame(fr)
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
