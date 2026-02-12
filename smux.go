package httpmux

import (
	"errors"
	"sync"
	"time"
)

type SMUXConfig struct {
	KeepAlive  time.Duration
	MaxStreams int
	MaxFrame   int
}

type SMUX struct {
	cfg       SMUXConfig
	nextID    uint32
	isClient  bool

	streams  map[uint32]*Stream
	streamMu sync.Mutex

	tr   FrameTransport

	die     chan struct{}
	closeMu sync.Mutex
	closed  bool
}

func NewSMUX(tr FrameTransport, cfg SMUXConfig, isClient bool) *SMUX {
	m := &SMUX{
		cfg:      cfg,
		isClient: isClient,
		streams:  make(map[uint32]*Stream),
		tr:       tr,
		die:      make(chan struct{}),
	}

	// client = odd, server = even
	if isClient {
		m.nextID = 1
	} else {
		m.nextID = 2
	}

	_ = tr.Start()
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
	if m.cfg.MaxStreams > 0 && len(m.streams) >= m.cfg.MaxStreams {
		return nil, errors.New("max streams reached")
	}

	id := m.nextID
	m.nextID += 2

	str := NewStream(id, m)
	m.streams[id] = str
	return str, nil
}

func (m *SMUX) sendFrame(fr *Frame) error {
	return m.tr.Send(fr)
}

func (m *SMUX) readLoop() {
	for {
		select {
		case <-m.die:
			return
		default:
		}

		fr, err := m.tr.Recv()
		if err != nil {
			m.Close()
			return
		}
		if fr == nil {
			continue
		}
		m.handleFrame(fr)
	}
}

func (m *SMUX) handleFrame(fr *Frame) {
	if fr.Type == FramePing {
		_ = m.sendFrame(&Frame{StreamID: 0, Type: FramePong})
		return
	}
	if fr.Type == FramePong {
		return
	}

	m.streamMu.Lock()
	str := m.streams[fr.StreamID]
	m.streamMu.Unlock()
	if str == nil {
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
	if m.cfg.KeepAlive <= 0 {
		return
	}
	t := time.NewTicker(m.cfg.KeepAlive)
	defer t.Stop()

	for {
		select {
		case <-t.C:
			_ = m.sendFrame(&Frame{StreamID: 0, Type: FramePing})
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

	m.streamMu.Lock()
	for _, s := range m.streams {
		s.shutdown()
	}
	m.streamMu.Unlock()

	_ = m.tr.Close()
	m.closeMu.Unlock()
}
