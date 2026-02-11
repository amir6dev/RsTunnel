package main

import (
	"crypto/tls"
	"flag"
	"fmt"
	"io"
	"net"
	"time"

	"github.com/xtaci/smux"
)

var (
	bridgeAddr = flag.String("c", "127.0.0.1:443", "Bridge Address")
	panelAddr  = flag.String("p", "127.0.0.1:1432", "Panel Address")
	mode       = flag.String("m", "httpmux", "Mode")
	profile    = flag.String("profile", "balanced", "Profile")
	fakeHost   = flag.String("h", "www.google.com", "Fake Host")
)

func main() {
	flag.Parse()
	fmt.Printf("🌍 Upstream Core Running | Target: %s | Mode: %s\n", *bridgeAddr, *mode)
	config := getSmuxConfig(*profile)

	for {
		connect(config)
		time.Sleep(3 * time.Second)
	}
}

func connect(config *smux.Config) {
	var conn net.Conn
	var err error

	if *mode == "httpsmux" {
		conn, err = tls.Dial("tcp", *bridgeAddr, &tls.Config{InsecureSkipVerify: true})
	} else {
		conn, err = net.Dial("tcp", *bridgeAddr)
	}
	if err != nil { return }

	req := fmt.Sprintf("GET / HTTP/1.1\r\nHost: %s\r\nUser-Agent: Chrome\r\n\r\n", *fakeHost)
	conn.Write([]byte(req))

	buf := make([]byte, 1024)
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	conn.Read(buf)
	conn.SetDeadline(time.Time{})

	session, err := smux.Server(conn, config)
	if err != nil { conn.Close(); return }
	fmt.Println("✅ Connected to Bridge!")

	for {
		stream, err := session.AcceptStream()
		if err != nil { break }
		go handleStream(stream)
	}
}

func handleStream(stream net.Conn) {
	panel, err := net.Dial("tcp", *panelAddr)
	if err != nil { stream.Close(); return }
	go pipe(panel, stream)
}

func getSmuxConfig(p string) *smux.Config {
	c := smux.DefaultConfig()
	switch p {
	case "aggressive":
		c.KeepAliveInterval = 5 * time.Second
		c.MaxReceiveBuffer = 16 * 1024 * 1024
	case "gaming":
		c.KeepAliveInterval = 1 * time.Second
	}
	return c
}

func pipe(a, b io.ReadWriteCloser) {
	defer a.Close()
	defer b.Close()
	go io.Copy(a, b)
	io.Copy(b, a)
}