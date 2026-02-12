package httpmux

import (
	"context"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	utls "github.com/refraction-networking/utls"
	"golang.org/x/net/http2"
)

type Client struct {
	Transport *HTTPMuxTransport
}

// NewClientFromPath creates a client based on a single Dagger-like path config.
// For httpmux: plain HTTP (no TLS) + Host spoofing + mimic headers.
// For httpsmux: TLS (uTLS) + HTTP/2.
func NewClientFromPath(path PathConfig, sessionID string, mimic *MimicConfig, obfs *ObfsConfig, psk string) *Client {
	if mimic == nil {
		mimic = &MimicConfig{}
	}
	if obfs == nil {
		obfs = &ObfsConfig{}
	}

	transport := strings.ToLower(strings.TrimSpace(path.Transport))
	addr := strings.TrimSpace(path.Addr)

	// sensible defaults like Dagger
	pool := path.ConnectionPool
	if pool <= 0 {
		pool = 2
	}
	dialTimeout := time.Duration(path.DialTimeout) * time.Second
	if dialTimeout <= 0 {
		dialTimeout = 10 * time.Second
	}

	serverURL := buildServerURL(transport, addr, mimic)

	conns := make([]*HTTPConn, pool)
	for i := 0; i < pool; i++ {
		var tr *http.Transport

		// httpmux: plain HTTP mimicry
		if transport == "httpmux" || transport == "wsmux" || transport == "tcpmux" || transport == "" {
			dialer := &net.Dialer{Timeout: dialTimeout, KeepAlive: 30 * time.Second}
			tr = &http.Transport{
				DialContext:           dialer.DialContext,
				DisableCompression:    false,
				ForceAttemptHTTP2:     false, // keep it HTTP/1.1-like
				MaxIdleConns:          1024,
				MaxIdleConnsPerHost:   256,
				IdleConnTimeout:       90 * time.Second,
				TLSHandshakeTimeout:   dialTimeout,
				ExpectContinueTimeout: 1 * time.Second,
			}
		} else {
			// httpsmux / wssmux: TLS mimicry (uTLS) + HTTP/2
			tr = &http.Transport{
				DialTLSContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
					rawConn, err := net.DialTimeout(network, addr, dialTimeout)
					if err != nil {
						return nil, err
					}

					serverName := mimic.FakeDomain
					if serverName == "" {
						host, _, _ := net.SplitHostPort(addr)
						serverName = host
					}

					uConn := utls.UClient(rawConn, &utls.Config{
						ServerName:         serverName,
						InsecureSkipVerify: true, // allow self-signed
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
		}

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
		IdlePoll:      250 * time.Millisecond,
	})

	_ = mt.Start()
	return &Client{Transport: mt}
}

func buildServerURL(transport, addr string, mimic *MimicConfig) string {
	addr = strings.TrimSpace(addr)
	if addr == "" {
		return ""
	}

	// addr may be "1.2.3.4:2020" (Dagger-style) or a full URL.
	if strings.Contains(addr, "://") {
		return normalizeServerURL(addr, mimic)
	}

	scheme := "http"
	switch strings.ToLower(strings.TrimSpace(transport)) {
	case "httpsmux", "wssmux":
		scheme = "https"
	}
	return normalizeServerURL(scheme+"://"+addr, mimic)
}

// normalizeServerURL ensures URL has a path (Dagger-style).
// If user passes only "http(s)://host:port" we append mimic.fake_path (default: /tunnel).
func normalizeServerURL(raw string, mimic *MimicConfig) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return raw
	}
	u, err := url.Parse(raw)
	if err != nil {
		return raw
	}
	path := strings.TrimSpace(u.Path)
	if path == "" || path == "/" {
		tunnelPath := strings.TrimSpace(mimic.FakePath)
		if tunnelPath == "" {
			tunnelPath = "/tunnel"
		}
		if !strings.HasPrefix(tunnelPath, "/") {
			tunnelPath = "/" + tunnelPath
		}
		u.Path = tunnelPath
	}
	return u.String()
}
