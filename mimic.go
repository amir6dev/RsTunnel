package httpmux

import (
	"net/http"
)

type MimicConfig struct {
	FakeDomain      string
	FakePath        string
	UserAgent       string
	CustomHeaders   []string
	SessionCookie   bool
	ChunkedEncoding bool
}

func ApplyMimicHeaders(req *http.Request, cfg *MimicConfig, sessionID string) {
	req.Host = cfg.FakeDomain
	req.Header.Set("User-Agent", cfg.UserAgent)

	for _, h := range cfg.CustomHeaders {
		parts := SplitHeader(h)
		req.Header.Set(parts[0], parts[1])
	}

	if cfg.SessionCookie {
		req.Header.Set("Cookie", "SESSION="+sessionID)
	}
}

func SplitHeader(h string) [2]string {
	for i := 0; i < len(h); i++ {
		if h[i] == ':' {
			return [2]string{h[:i], h[i+2:]}
		}
	}
	return [2]string{"Invalid", ""}
}
