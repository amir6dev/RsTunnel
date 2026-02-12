package httpmux

import (
	"net/http"
	"time"
)

type Client struct {
	Conns []*HTTPConn
	Tr    *HTTPMuxTransport
	Mux   *SMUX
}

func NewClient(serverURL, sessionID string, mimic *MimicConfig, obfs *ObfsConfig) *Client {
	pool := 3 // مثل dagger

	conns := make([]*HTTPConn, pool)
	for i := 0; i < pool; i++ {
		conns[i] = &HTTPConn{
			Client: &http.Client{
				Timeout: 25 * time.Second,
			},
			Mimic:     mimic,
			Obfs:      obfs,
			SessionID: sessionID,
			ServerURL: serverURL,
		}
	}

	tr := NewHTTPMuxTransport(conns, HTTPMuxConfig{
		FlushInterval: 30 * time.Millisecond,
		MaxBatch:      64,
		IdlePoll:      250 * time.Millisecond,
	})

	mux := NewSMUX(tr, SMUXConfig{
		KeepAlive:  2 * time.Second,
		MaxStreams: 512,
		MaxFrame:   2048,
	}, true)

	return &Client{Conns: conns, Tr: tr, Mux: mux}
}

func (c *Client) DialStream() (*Stream, error) {
	return c.Mux.OpenStream()
}
