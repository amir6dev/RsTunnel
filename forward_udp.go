package httpmux

import (
	"net"
)

func forwardUDP(str *Stream, target string, payload []byte) {
	addr, _ := net.ResolveUDPAddr("udp", target)
	conn, _ := net.DialUDP("udp", nil, addr)
	conn.Write(payload)
	buf := make([]byte, 4096)
	n, _, _ := conn.ReadFromUDP(buf)
	str.Write(buf[:n])
}
