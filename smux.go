package httpmux

import (
	"errors"
	"io"
	"sync"
	"time"
)

type SMUXConfig struct {
	KeepAlive     time.Duration
	MaxStreams    int
	MaxFrame      int
	ReadTimeout   time.Duration
	WriteTimeout  time.Duration
}

type SMUX struct {
	cfg      SMUXConfig
	nextID   uint32
	streams  map[uint32]*Stream
	streamMu sync.Mutex

	wio   io.Writer
	rio   io.Reader
	wlock sync.Mutex

	die     chan struct{}
	closeMu sync.Mutex
	closed  bool
}

func NewSMUX(r io.Reader, w io.Writer, cfg SMUXConfig) *SMUX {
	m := &SMUX{
		cfg:     cfg,
		nextID:  1,
		streams: make(map[uint32]*Stream),
		rio:     r,
		wio:     w,
		die:     make(chan struct{}),
	}

	go m.readLoop()
	go m.keepaliveLoop()

	return m
}

func (m *SMUX) OpenStream() (*Stream, error) {
	m.streamMu.Lock()
	defer m.streamMu.Unlock()

	if m.closed {
		return nil, errors.New("mux closed")
	}

	id := m.nextID
	m.nextID += 2 // client uses odd, server uses even

	str := NewStream(id, m)
	m.streams[id] = str
	return str, nil
}

func (m *SMUX) sendFrame(fr *Frame) error {
	m.wlock.Lock()
	defer m.wlock.Unlock()

	return WriteFrame(m.wio, fr)
}

func (m *SMUX) readLoop() {
	for {
		select {
		case <-m.die:
			return
		default:
		}

		fr, err := ReadFrame(m.rio)
		if err != nil {
			m.Close()
			return
		}

		m.handleFrame(fr)
	}
}

func (m *SMUX) handleFrame(fr *Frame) {
	if fr.Type == FramePing {
		// return pong
		m.sendFrame(&Frame{
			StreamID: 0,
			Type:     FramePong,
			Length:   0,
		})
		return
	}

	if fr.Type == FramePong {
		return
	}

	m.streamMu.Lock()
	str, exists := m.streams[fr.StreamID]
	m.streamMu.Unlock()

	if !exists {
		return
	}

	switch fr.Type {
	case FrameData:
		str.push(fr.Payload)

	case FrameClose:
		str.shutdown()
	}
}

func (m *SMUX) keepaliveLoop() {
	t := time.NewTicker(m.cfg.KeepAlive)
	defer t.Stop()

	for {
		select {
		case <-t.C:
			m.sendFrame(&Frame{
				StreamID: 0,
				Type:     FramePing,
				Length:   0,
			})
		case <-m.die:
			return
		}
	}
}

func (m *SMUX) Close() {
	m.closeMu.Lock()
	if m.closed {
		m.closeMu.Unlock()
		return
	}
	m.closed = true
	close(m.die)

	for _, s := range m.streams {
		s.shutdown()
	}
	m.closeMu.Unlock()
}
