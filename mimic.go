package httpmux

import (
	"net/http"
	"strings"
)

type MimicConfig struct {
	FakeDomain    string   `yaml:"fake_domain"`
	FakePath      string   `yaml:"fake_path"`
	UserAgent     string   `yaml:"user_agent"`
	CustomHeaders []string `yaml:"custom_headers"`
	SessionCookie bool     `yaml:"session_cookie"`
}

func ApplyMimicHeaders(req *http.Request, cfg *MimicConfig, sessionID string) {
	// safe defaults
	req.Header.Set("Accept", "*/*")
	req.Header.Set("Accept-Language", "en-US,en;q=0.9")
	req.Header.Set("Cache-Control", "no-cache")
	req.Header.Set("Pragma", "no-cache")
	req.Header.Set("Connection", "keep-alive")

	if cfg == nil {
		req.Header.Set("User-Agent", "Mozilla/5.0")
		if sessionID != "" {
			req.Header.Set("Cookie", "SESSION="+sessionID)
		}
		return
	}

	if cfg.UserAgent != "" {
		req.Header.Set("User-Agent", cfg.UserAgent)
	} else {
		req.Header.Set("User-Agent", "Mozilla/5.0")
	}

	// Custom headers "Key: Value"
	for _, h := range cfg.CustomHeaders {
		parts := strings.SplitN(h, ":", 2)
		if len(parts) != 2 {
			continue
		}
		k := strings.TrimSpace(parts[0])
		v := strings.TrimSpace(parts[1])
		if k != "" && v != "" {
			req.Header.Set(k, v)
		}
	}

	if cfg.SessionCookie && sessionID != "" {
		req.Header.Set("Cookie", "SESSION="+sessionID)
	}
}
