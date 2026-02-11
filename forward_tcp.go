package httpmux

import (
	"net"
)

func forwardTCP(s *Stream, data []byte) {
	conn, _ := net.Dial("tcp", "127.0.0.1:8080") // نمونه
	conn.Write(data)

	buf := make([]byte, 2048)
	n, _ := conn.Read(buf)

	s.Write(buf[:n])
}
