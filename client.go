package httpmux

import (
	"context"
	"crypto/tls"
	"net"
	"net/http"
	"time"

	utls "github.com/refraction-networking/utls"
	"golang.org/x/net/http2"
)

type Client struct {
	Transport *HTTPMuxTransport
}

func NewClient(serverURL, sessionID string, mimic *MimicConfig, obfs *ObfsConfig, psk string) *Client {
	pool := 3

	conns := make([]*HTTPConn, pool)
	for i := 0; i < pool; i++ {
		// تعریف Transport اختصاصی با uTLS
		tr := &http.Transport{
			DialTLSContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				// 1. اتصال TCP معمولی
				rawConn, err := net.DialTimeout(network, addr, 10*time.Second)
				if err != nil {
					return nil, err
				}

				// 2. تعیین SNI (نام دامنه برای هندشیک)
				// اگر در کانفیگ FakeDomain ست شده باشد، از آن استفاده می‌کنیم (Domain Fronting)
				// در غیر این صورت از آدرس سرور استفاده می‌شود.
				serverName := mimic.FakeDomain
				if serverName == "" {
					host, _, _ := net.SplitHostPort(addr)
					serverName = host
				}

				// 3. تنظیم uTLS برای شبیه‌سازی Chrome 120
				uConn := utls.UClient(rawConn, &utls.Config{
					ServerName:         serverName,
					InsecureSkipVerify: true, // برای سرتیفیکیت‌های Self-signed
				}, utls.HelloChrome_120)

				// 4. انجام هندشیک
				if err := uConn.Handshake(); err != nil {
					_ = uConn.Close()
					return nil, err
				}

				return uConn, nil
			},
			ForceAttemptHTTP2: true, // اجبار به استفاده از HTTP/2 برای شباهت بیشتر به مرورگر
		}

		// کانفیگ HTTP/2 روی Transport
		_ = http2.ConfigureTransport(tr)

		conns[i] = &HTTPConn{
			Client: &http.Client{
				Transport: tr,
				Timeout:   25 * time.Second,
			},
			Mimic:     mimic,
			Obfs:      obfs,
			PSK:       psk,
			SessionID: sessionID,
			ServerURL: serverURL,
		}
	}

	// ایجاد لایه مالتی‌پلکس روی کانکشن‌های امن شده
	tr := NewHTTPMuxTransport(conns, HTTPMuxConfig{
		FlushInterval: 30 * time.Millisecond,
		MaxBatch:      64,
		IdlePoll:      200 * time.Millisecond,
	})

	_ = tr.Start()
	return &Client{Transport: tr}
}