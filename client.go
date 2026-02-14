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

// FIXED: Added cfg parameter to pass through Dagger-like features
func NewClientFromPaths(paths []PathConfig, sessionID string, mimic *MimicConfig, obfs *ObfsConfig, psk string, cfg HTTPMuxConfig) *Client {
	if mimic == nil {
		mimic = &MimicConfig{}
	}
	if obfs == nil {
		obfs = &ObfsConfig{}
	}

	if len(paths) == 0 {
		paths = []PathConfig{{Transport: "httpmux", Addr: "", ConnectionPool: 2, RetryInterval: 3, DialTimeout: 10}}
	}

	var conns []*HTTPConn

	for _, path := range paths {
		transport := strings.ToLower(strings.TrimSpace(path.Transport))
		addr := strings.TrimSpace(path.Addr)
		if addr == "" {
			continue
		}

		pool := path.ConnectionPool
		if pool <= 0 {
			pool = 2
		}
		retryInterval := time.Duration(path.RetryInterval) * time.Second
		if retryInterval <= 0 {
			retryInterval = 3 * time.Second
		}
		dialTimeout := time.Duration(path.DialTimeout) * time.Second
		if dialTimeout <= 0 {
			dialTimeout = 10 * time.Second
		}

		serverURL := buildServerURL(transport, addr, mimic)

		for i := 0; i < pool; i++ {
			var tr *http.Transport

			if transport == "httpmux" || transport == "wsmux" || transport == "tcpmux" || transport == "" {
				dialer := &net.Dialer{Timeout: dialTimeout, KeepAlive: 30 * time.Second}
				tr = &http.Transport{
					DialContext:           dialer.DialContext,
					DisableCompression:    false,
					ForceAttemptHTTP2:     false,
					MaxIdleConns:          1024,
					MaxIdleConnsPerHost:   256,
					IdleConnTimeout:       90 * time.Second,
					TLSHandshakeTimeout:   dialTimeout,
					ExpectContinueTimeout: 1 * time.Second,
				}
			} else {
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
							InsecureSkipVerify: true,
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

			conns = append(conns, &HTTPConn{
				Client: &http.Client{
					Transport: tr,
					Timeout:   25 * time.Second,
				},
				Mimic:            mimic,
				Obfs:             obfs,
				PSK:              psk,
				SessionID:        sessionID,
				ServerURL:        serverURL,
				RetryInterval:    retryInterval,
				Aggressive:       path.AggressivePool,
				EmbedFakeHeaders: cfg.EmbedFakeHeaders, // ✅ FIXED: Now actually set!
			})
		}
	}

	// ✅ FIXED: Pass full cfg instead of just hardcoded values
	mt := NewHTTPMuxTransport(conns, cfg)
	_ = mt.Start()
	return &Client{Transport: mt}
}

// FIXED: Added cfg parameter (backward compatibility wrapper)
func NewClientFromPath(path PathConfig, sessionID string, mimic *MimicConfig, obfs *ObfsConfig, psk string) *Client {
	// Use default config for backward compatibility
	cfg := HTTPMuxConfig{
		FlushInterval:    200 * time.Millisecond,
		MaxBatch:         64,
		IdlePoll:         250 * time.Millisecond,
		NumConnections:   4,
		EnableDecoy:      true,
		DecoyInterval:    5 * time.Second,
		EmbedFakeHeaders: true,
	}
	return NewClientFromPaths([]PathConfig{path}, sessionID, mimic, obfs, psk, cfg)
}

func buildServerURL(transport, addr string, mimic *MimicConfig) string {
	addr = strings.TrimSpace(addr)
	if addr == "" {
		return ""
	}

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
