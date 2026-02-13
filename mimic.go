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
	// Chunked controls whether the client uses Transfer-Encoding: chunked.
	// Dagger's config key is "chunked_encoding"; config.go maps that to this field.
	Chunked bool `yaml:"chunked"`
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
			req.Header.Set("Cookie", "session="+sessionID)
		}
		return
	}

	if cfg.UserAgent != "" {
		req.Header.Set("User-Agent", cfg.UserAgent)
	} else {
		req.Header.Set("User-Agent", "Mozilla/5.0")
	}

<<<<<<< HEAD
<<<<<<< HEAD
	// Dagger-style mimic: Host spoof + path request are handled elsewhere.
	// Here we only ensure headers look browser-like.
=======

>>>>>>> 761e0881dbe95042a42689a9d133dc400c8d6457
=======
	// Dagger-style mimic: Host spoof + path request are handled elsewhere.
	// Here we only ensure headers look browser-like.
>>>>>>> 6b30d3e (New Update)
	// If no custom headers provided, apply a Dagger-like minimal set.
	if len(cfg.CustomHeaders) == 0 {
		req.Header.Set("X-Requested-With", "XMLHttpRequest")
		if cfg.FakeDomain != "" {
			refer := "https://" + cfg.FakeDomain + "/"
			req.Header.Set("Referer", refer)
		}
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
		// Dagger uses cookie name "session" (lowercase) in its decoy responses.
		req.Header.Set("Cookie", "session="+sessionID)
	}
}
