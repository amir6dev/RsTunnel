package httpmux

import (
	"log"
	"net"
	"sync"
)

type ClientReverse struct {
	tr FrameTransport

	mu    sync.Mutex
	links map[uint32]net.Conn
}

func NewClientReverse(tr FrameTransport) *ClientReverse {
	return &ClientReverse{
		tr:    tr,
		links: make(map[uint32]net.Conn),
	}
}

func (cr *ClientReverse) Run() {
	for {
		fr, err := cr.tr.Recv()
		if err != nil {
			return
		}
		switch fr.Type {
		case FrameOpen:
			target := string(fr.Payload)
			go cr.open(fr.StreamID, target)

		case FrameData:
			cr.mu.Lock()
			c := cr.links[fr.StreamID]
			cr.mu.Unlock()
			if c != nil {
				_, _ = c.Write(fr.Payload)
			}

		case FrameClose:
			cr.mu.Lock()
			c := cr.links[fr.StreamID]
			delete(cr.links, fr.StreamID)
			cr.mu.Unlock()
			if c != nil {
				_ = c.Close()
			}

		case FramePing:
			_ = cr.tr.Send(&Frame{StreamID: 0, Type: FramePong})
		}
	}
}

func (cr *ClientReverse) open(streamID uint32, target string) {
	c, err := net.Dial("tcp", target)
	if err != nil {
		log.Printf("dial target failed %s: %v", target, err)
		_ = cr.tr.Send(&Frame{StreamID: streamID, Type: FrameClose})
		return
	}

	cr.mu.Lock()
	cr.links[streamID] = c
	cr.mu.Unlock()

	// read from target -> send to server
	buf := make([]byte, 2048)
	for {
		n, err := c.Read(buf)
		if n > 0 {
			_ = cr.tr.Send(&Frame{
				StreamID: streamID,
				Type:     FrameData,
				Length:   uint32(n),
				Payload:  append([]byte(nil), buf[:n]...),
			})
		}
		if err != nil {
			break
		}
	}

	_ = cr.tr.Send(&Frame{StreamID: streamID, Type: FrameClose})
	_ = c.Close()
}
