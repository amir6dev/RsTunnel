package httpmux

import (
	"math/rand"
	"net/http"
	"net/url"
	"strings"
	"time"
)

func init() {
	// rand is used only for fake path generation; seed it once.
	rand.Seed(time.Now().UnixNano())
}

type MimicConfig struct {
	FakeDomain    string   `yaml:"fake_domain"`
	FakePath      string   `yaml:"fake_path"`
	UserAgent     string   `yaml:"user_agent"`
	CustomHeaders []string `yaml:"custom_headers"`
	SessionCookie bool     `yaml:"session_cookie"`
	Chunked       bool     `yaml:"chunked"`
}

func ApplyMimicHeaders(req *http.Request, cfg *MimicConfig, cookieName, cookieValue string) {
	req.Header.Set("Accept", "*/*")
	req.Header.Set("Accept-Language", "en-US,en;q=0.9")
	req.Header.Set("Cache-Control", "no-cache")
	req.Header.Set("Pragma", "no-cache")
	req.Header.Set("Connection", "keep-alive")

	if cfg == nil {
		req.Header.Set("User-Agent", "Mozilla/5.0")
		if cookieValue != "" {
			if cookieName == "" {
				cookieName = "session"
			}
			req.Header.Set("Cookie", cookieName+"="+cookieValue)
		}
		return
	}

	if cfg.UserAgent != "" {
		req.Header.Set("User-Agent", cfg.UserAgent)
	} else {
		req.Header.Set("User-Agent", "Mozilla/5.0")
	}

	if len(cfg.CustomHeaders) == 0 {
		req.Header.Set("X-Requested-With", "XMLHttpRequest")
		if cfg.FakeDomain != "" {
			req.Header.Set("Referer", "https://"+cfg.FakeDomain+"/")
		}
	}

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

	if cfg.SessionCookie {
		if cookieName == "" {
			cookieName = "session"
		}
		if cookieValue != "" {
			req.Header.Set("Cookie", cookieName+"="+cookieValue)
		}
	}
}


// BuildURLWithFakePath returns a URL string based on baseURL but with its path replaced by fakePath.
// If fakePath contains "{rand}", it will be replaced with a random 8-char alphanumeric string.
func BuildURLWithFakePath(baseURL, fakePath string) (string, error) {
	if fakePath == "" {
		return baseURL, nil
	}
	u, err := url.Parse(baseURL)
	if err != nil {
		return "", err
	}
	fp := fakePath
	if strings.Contains(fp, "{rand}") {
		fp = strings.ReplaceAll(fp, "{rand}", randAlphaNum(8))
	}
	if !strings.HasPrefix(fp, "/") {
		fp = "/" + fp
	}
	u.Path = fp
	return u.String(), nil
}

func randAlphaNum(n int) string {
	const letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	b := make([]byte, n)
	for i := range b {
		b[i] = letters[rand.Intn(len(letters))]
	}
	return string(b)
}
