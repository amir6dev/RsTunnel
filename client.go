package httpmux

import (
	"context"
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
		// تنظیم ترنسپورت اختصاصی برای uTLS
		tr := &http.Transport{
			DialTLSContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				// 1. اتصال TCP ساده
				rawConn, err := net.DialTimeout(network, addr, 10*time.Second)
				if err != nil {
					return nil, err
				}

				// 2. تعیین SNI (نام دامنه برای هندشیک)
				serverName := mimic.FakeDomain
				if serverName == "" {
					host, _, _ := net.SplitHostPort(addr)
					serverName = host
				}

				// 3. استفاده از uTLS برای شبیه‌سازی Chrome 120
				uConn := utls.UClient(rawConn, &utls.Config{
					ServerName:         serverName,
					InsecureSkipVerify: true, // برای سرتیفیکیت‌های Self-signed
				}, utls.HelloChrome_120)

				if err := uConn.Handshake(); err != nil {
					_ = uConn.Close()
					return nil, err
				}
				return uConn, nil
			},
			ForceAttemptHTTP2: true,
		}

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

	mt := NewHTTPMuxTransport(conns, HTTPMuxConfig{
		FlushInterval: 200 * time.Millisecond,
		MaxBatch:      64,
		IdlePoll:      250 * time.Millisecond, // Long-polling idle check
	})

	_ = mt.Start()
	return &Client{Transport: mt}
}