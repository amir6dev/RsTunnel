package main

import (
	"flag"
	"fmt"
	"io"
	"net"
	"strings"
	"time"

	"github.com/xtaci/smux"
)

// تنظیمات پیش‌فرض (قابل تغییر موقع اجرا)
var (
	tunnelPort = flag.String("l", ":8080", "Listen port for Upstream (e.g. :8080)")
	userPort   = flag.String("u", ":1432", "Listen port for Users (e.g. :1432)")
	fakeHost   = flag.String("h", "fast.com", "Fake HTTP Host header")
)

var globalSession *smux.Session

func main() {
	flag.Parse()
	fmt.Println("🔥 Bridge Core Started (Iran Server)")
	fmt.Printf("   Wait for Upstream on: %s\n   Wait for Users on:    %s\n   Fake Host:            %s\n", *tunnelPort, *userPort, *fakeHost)

	// ۱. گوش دادن به پورت تانل (منتظر سرور خارج)
	go func() {
		l, err := net.Listen("tcp", *tunnelPort)
		if err != nil {
			panic(err)
		}
		for {
			conn, err := l.Accept()
			if err != nil {
				continue
			}
			go handleTunnelHandshake(conn)
		}
	}()

	// ۲. گوش دادن به پورت کاربر (V2Ray Client)
	l, err := net.Listen("tcp", *userPort)
	if err != nil {
		panic(err)
	}

	for {
		userConn, err := l.Accept()
		if err != nil {
			continue
		}

		// چک کنیم تانل وصله یا نه
		if globalSession == nil || globalSession.IsClosed() {
			userConn.Close()
			continue
		}

		// باز کردن یک استریم داخل تانل
		stream, err := globalSession.OpenStream()
		if err != nil {
			userConn.Close()
			continue
		}

		// وصل کردن کاربر به استریم
		go pipe(userConn, stream)
	}
}

func handleTunnelHandshake(conn net.Conn) {
	// خواندن درخواست HTTP فیک
	buf := make([]byte, 1024)
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	n, err := conn.Read(buf)
	if err != nil {
		conn.Close()
		return
	}
	conn.SetReadDeadline(time.Time{})

	req := string(buf[:n])
	// بررسی اینکه آیا هدر Host درسته؟
	if !strings.Contains(req, "Host: "+*fakeHost) {
		fmt.Println("❌ Invalid Handshake. Closing connection.")
		conn.Close()
		return
	}

	// ارسال پاسخ 200 OK
	resp := "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: keep-alive\r\n\r\n"
	conn.Write([]byte(resp))

	// ارتقا به SMUX (مولتی‌پلکس)
	// اینجا ایران نقش Client رو داره چون آغازگر استریمه
	sess, err := smux.Client(conn, smux.DefaultConfig())
	if err != nil {
		conn.Close()
		return
	}
	globalSession = sess
	fmt.Println("✅ Upstream Connected via HTTPMux!")
}

func pipe(a, b io.ReadWriteCloser) {
	defer a.Close()
	defer b.Close()
	go io.Copy(a, b)
	io.Copy(b, a)
}