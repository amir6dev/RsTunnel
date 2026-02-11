package httpmux

import (
	"net/http"
	"time"
)

type Client struct {
	Conns []*HTTPConn
	Mux   *SMUX
}

func NewClient(serverURL, sessionID string, mimic *MimicConfig, obfs *ObfsConfig) *Client {
	pool := 3 // مثل dagger

	conns := make([]*HTTPConn, pool)
	for i := 0; i < pool; i++ {
		conns[i] = &HTTPConn{
			Client: &http.Client{
				Timeout: 20 * time.Second,
			},
			Mimic:     mimic,
			Obfs:      obfs,
			SessionID: sessionID,
			ServerURL: serverURL,
		}
	}

	// SMUX با writer = connection اول
	mux := NewSMUX(nil, conns[0], SMUXConfig{
		KeepAlive:   2 * time.Second,
		MaxStreams:  512,
		MaxFrame:    2048,
		ReadTimeout: 30 * time.Second,
	})

	return &Client{Conns: conns, Mux: mux}
}

func (c *Client) DialStream() (*Stream, error) {
	return c.Mux.OpenStream()
}
