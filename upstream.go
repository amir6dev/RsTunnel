package main

import (
	"flag"
	"fmt"
	"io"
	"net"
	"time"

	"github.com/xtaci/smux"
)

var (
	bridgeAddr = flag.String("c", "127.0.0.1:8080", "Iran Bridge Address (IP:Port)")
	panelAddr  = flag.String("p", "127.0.0.1:1432", "Local Panel Address (e.g. 127.0.0.1:1432)")
	fakeHost   = flag.String("h", "fast.com", "Fake HTTP Host header")
)

func main() {
	flag.Parse()
	fmt.Println("🚀 Upstream Core Started (Foreign Server)")
	fmt.Printf("   Target Bridge: %s\n   Local Panel:   %s\n   Fake Host:     %s\n", *bridgeAddr, *panelAddr, *fakeHost)

	for {
		connect()
		fmt.Println("⚠️ Connection lost. Retrying in 3 seconds...")
		time.Sleep(3 * time.Second)
	}
}

func connect() {
	conn, err := net.Dial("tcp", *bridgeAddr)
	if err != nil {
		fmt.Println("❌ Connect failed:", err)
		return
	}

	// ارسال درخواست HTTP فیک (HTTP Mimicry)
	req := fmt.Sprintf("GET / HTTP/1.1\r\nHost: %s\r\nUser-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36\r\nConnection: keep-alive\r\n\r\n", *fakeHost)
	conn.Write([]byte(req))

	// خواندن پاسخ ایران
	buf := make([]byte, 1024)
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	n, err := conn.Read(buf)
	if err != nil {
		conn.Close()
		return
	}
	conn.SetReadDeadline(time.Time{})

	// بررسی پاسخ 200 OK
	if string(buf[:n])[9:12] != "200" {
		fmt.Println("❌ Handshake Failed (Not 200 OK).")
		conn.Close()
		return
	}

	// تبدیل به SMUX Server (منتظر استریم از ایران)
	session, err := smux.Server(conn, smux.DefaultConfig())
	if err != nil {
		conn.Close()
		return
	}
	fmt.Println("✅ Connected to Bridge! Waiting for users...")

	// قبول کردن ترافیک کاربران
	for {
		stream, err := session.AcceptStream()
		if err != nil {
			break
		}
		go handleStream(stream)
	}
}

func handleStream(stream net.Conn) {
	// اتصال به پنل VLESS لوکال
	panel, err := net.Dial("tcp", *panelAddr)
	if err != nil {
		stream.Close()
		return
	}
	// کپی دو طرفه دیتا
	go pipe(panel, stream)
}

func pipe(a, b io.ReadWriteCloser) {
	defer a.Close()
	defer b.Close()
	go io.Copy(a, b)
	io.Copy(b, a)
}