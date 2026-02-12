package httpmux

import (
	"log"
	"net"
	"sync"
	"sync/atomic"
)

type pendingConn struct {
	streamID uint32
	target   string
	conn     net.Conn
}

var globalPending = make(chan pendingConn, 8192)

type tcpLink struct {
	c net.Conn
}

var (
	serverLinksMu sync.Mutex
	serverLinks   = map[uint32]*tcpLink{}
)

var nextStreamID uint32 = 2 // server uses even IDs

func (s *Server) StartReverseTCP(bindAddr, targetAddr string) {
	ln, err := net.Listen("tcp", bindAddr)
	if err != nil {
		log.Printf("reverse listen failed %s: %v", bindAddr, err)
		return
	}
	log.Printf("reverse tcp listening on %s -> %s", bindAddr, targetAddr)

	for {
		c, err := ln.Accept()
		if err != nil {
			log.Printf("accept err: %v", err)
			continue
		}
		go s.handleInboundTCP(c, targetAddr)
	}
}

func (s *Server) handleInboundTCP(c net.Conn, target string) {
	id := atomic.AddUint32(&nextStreamID, 2)
	globalPending <- pendingConn{
		streamID: id,
		target:   target,
		conn:     c,
	}
}
