package httpmux

import (
	"log"
	"net"
	"sync"
	"sync/atomic"
)

type tcpLink struct {
	c net.Conn
}

var (
	serverLinksMu sync.Mutex
	serverLinks   = map[uint32]*tcpLink{}
	nextStreamID uint32 = 2
)

func (s *Server) StartReverseTCP(bindAddr, targetAddr string) {
	ln, err := net.Listen("tcp", bindAddr)
	if err != nil {
		log.Printf("❌ Reverse listen failed %s: %v", bindAddr, err)
		return
	}
	log.Printf("🔗 Reverse TCP Listening: %s -> Client -> %s", bindAddr, targetAddr)

	for {
		c, err := ln.Accept()
		if err != nil { continue }
		go s.handleInboundTCP(c, targetAddr)
	}
}

func (s *Server) handleInboundTCP(c net.Conn, target string) {
	// ✅ فیکس: دریافت سشن فعال فعلی (دیگر Global نیست)
	sess := s.getActiveSession()
	if sess == nil {
		c.Close()
		return
	}

	id := atomic.AddUint32(&nextStreamID, 2)
	
	serverLinksMu.Lock()
	serverLinks[id] = &tcpLink{c: c}
	serverLinksMu.Unlock()

	select {
	case sess.Outgoing <- &Frame{
		StreamID: id,
		Type:     FrameOpen,
		Length:   uint32(len(target)),
		Payload:  []byte(target),
	}:
	default:
		c.Close()
	}
}