package httpmux

import (
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

// Config is the unified runtime config for RsTunnel (picotun).
// It supports BOTH:
//   - Native RsTunnel keys (server_url, forward.tcp/udp, mimic/obfs)
//   - DaggerConnect-compatible keys (paths, maps, http_mimic, obfuscation, advanced)
//
// NOTE: For client mode, Dagger-style "paths" is preferred (multi-path). For backward
// compatibility, "server_url" is also accepted.
type Config struct {
	// Common
	Mode    string `yaml:"mode"` // server|client
	PSK     string `yaml:"psk"`
	Profile string `yaml:"profile"`
	Verbose bool   `yaml:"verbose"`

	// Server
	Listen         string `yaml:"listen"` // e.g. 0.0.0.0:2020
	Transport      string `yaml:"transport"`
	Heartbeat      int    `yaml:"heartbeat"`
	SessionTimeout int    `yaml:"session_timeout"` // seconds (fallback if advanced.session_timeout exists)

	// Client (legacy single-url mode)
	ServerURL string `yaml:"server_url"` // full URL e.g. http://1.2.3.4:2020/search
	SessionID string `yaml:"session_id"`

	// Dagger-style client paths (recommended)
	Paths []PathConfig `yaml:"paths"`

	// Unified runtime configs
	Mimic MimicConfig `yaml:"mimic"`
	Obfs  ObfsConfig  `yaml:"obfs"`

	// Legacy forward mappings (native RsTunnel)
	Forward struct {
		TCP []string `yaml:"tcp"` // ["0.0.0.0:1457->127.0.0.1:1457"]
		UDP []string `yaml:"udp"`
	} `yaml:"forward"`
}

// PathConfig is a Dagger-like "connection path".
type PathConfig struct {
	Transport      string `yaml:"transport"`        // httpmux/httpsmux/wsmux/...
	Addr           string `yaml:"addr"`             // host:port (no scheme)
	ConnectionPool int    `yaml:"connection_pool"`  // default 2
	AggressivePool bool   `yaml:"aggressive_pool"`  // default false
	RetryInterval  int    `yaml:"retry_interval"`   // seconds
	DialTimeout    int    `yaml:"dial_timeout"`     // seconds
}

// ------------------------------
// Dagger-style YAML compatibility
// ------------------------------

type daggerPath = PathConfig

type daggerMap struct {
	Type   string `yaml:"type"`   // tcp|udp|both
	Bind   string `yaml:"bind"`   // 0.0.0.0:1457
	Target string `yaml:"target"` // 127.0.0.1:1457
}

type daggerObfs struct {
	Enabled     bool    `yaml:"enabled"`
	MinPadding  int     `yaml:"min_padding"`
	MaxPadding  int     `yaml:"max_padding"`
	MinDelayMS  int     `yaml:"min_delay_ms"`
	MaxDelayMS  int     `yaml:"max_delay_ms"`
	BurstChance float64 `yaml:"burst_chance"`
}

type daggerHTTPMimic struct {
	FakeDomain      string   `yaml:"fake_domain"`
	FakePath        string   `yaml:"fake_path"`
	UserAgent       string   `yaml:"user_agent"`
	ChunkedEncoding bool     `yaml:"chunked_encoding"`
	SessionCookie   bool     `yaml:"session_cookie"`
	CustomHeaders   []string `yaml:"custom_headers"`
}

type daggerAdvanced struct {
	SessionTimeout int `yaml:"session_timeout"`
}

type daggerConfig struct {
	Mode      string `yaml:"mode"`
	PSK       string `yaml:"psk"`
	Profile   string `yaml:"profile"`
	Verbose   bool   `yaml:"verbose"`

	Listen    string `yaml:"listen"`
	Transport string `yaml:"transport"`
	Heartbeat int    `yaml:"heartbeat"`

	Paths []daggerPath `yaml:"paths"`
	Maps  []daggerMap  `yaml:"maps"`

	Obfuscation daggerObfs      `yaml:"obfuscation"`
	HTTPMimic   daggerHTTPMimic `yaml:"http_mimic"`
	Advanced    daggerAdvanced  `yaml:"advanced"`

	// Accept native keys if present
	Mimic MimicConfig `yaml:"mimic"`
	Obfs  ObfsConfig  `yaml:"obfs"`

	Forward struct {
		TCP []string `yaml:"tcp"`
		UDP []string `yaml:"udp"`
	} `yaml:"forward"`

	ServerURL      string `yaml:"server_url"`
	SessionID      string `yaml:"session_id"`
	SessionTimeout int    `yaml:"session_timeout"`
}

func normalizePath(p string) string {
	p = strings.TrimSpace(p)
	if p == "" {
		return ""
	}
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	return p
}

func LoadConfig(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	// Unmarshal superset
	var dc daggerConfig
	if err := yaml.Unmarshal(b, &dc); err != nil {
		return nil, err
	}

	// Detect whether dagger-style keys are being used
	useDaggerStyle := false
	if dc.HTTPMimic.FakeDomain != "" ||
		dc.HTTPMimic.FakePath != "" ||
		len(dc.Paths) > 0 ||
		len(dc.Maps) > 0 ||
		dc.Obfuscation.Enabled {
		useDaggerStyle = true
	}

	var c Config
	if useDaggerStyle {
		c.Mode = strings.TrimSpace(dc.Mode)
		c.PSK = dc.PSK
		c.Profile = dc.Profile
		c.Verbose = dc.Verbose
		c.Listen = dc.Listen
		c.Transport = dc.Transport
		c.Heartbeat = dc.Heartbeat
		c.Paths = dc.Paths

		// Session timeout: advanced.session_timeout > session_timeout > default
		if dc.Advanced.SessionTimeout > 0 {
			c.SessionTimeout = dc.Advanced.SessionTimeout
		} else if dc.SessionTimeout > 0 {
			c.SessionTimeout = dc.SessionTimeout
		} else {
			c.SessionTimeout = 15
		}

		// Mimic (Dagger keys)
		c.Mimic.FakeDomain = dc.HTTPMimic.FakeDomain
		c.Mimic.FakePath = normalizePath(dc.HTTPMimic.FakePath)
		c.Mimic.UserAgent = dc.HTTPMimic.UserAgent
		c.Mimic.CustomHeaders = dc.HTTPMimic.CustomHeaders
		c.Mimic.SessionCookie = dc.HTTPMimic.SessionCookie
		c.Mimic.Chunked = dc.HTTPMimic.ChunkedEncoding

		// Obfuscation
		c.Obfs.Enabled = dc.Obfuscation.Enabled
		c.Obfs.MinPadding = dc.Obfuscation.MinPadding
		c.Obfs.MaxPadding = dc.Obfuscation.MaxPadding
		c.Obfs.MinDelayMS = dc.Obfuscation.MinDelayMS
		c.Obfs.MaxDelayMS = dc.Obfuscation.MaxDelayMS
		// ObfsConfig.BurstChance is an int (0..1000) in current code
		c.Obfs.BurstChance = int(dc.Obfuscation.BurstChance * 1000)

		// Maps => Forward
		for _, m := range dc.Maps {
			t := strings.ToLower(strings.TrimSpace(m.Type))
			bind := strings.TrimSpace(m.Bind)
			target := strings.TrimSpace(m.Target)
			if bind == "" || target == "" {
				continue
			}
			entry := bind + "->" + target
			switch t {
			case "tcp":
				c.Forward.TCP = append(c.Forward.TCP, entry)
			case "udp":
				c.Forward.UDP = append(c.Forward.UDP, entry)
			case "both":
				c.Forward.TCP = append(c.Forward.TCP, entry)
				c.Forward.UDP = append(c.Forward.UDP, entry)
			default:
				// default to tcp
				c.Forward.TCP = append(c.Forward.TCP, entry)
			}
		}

		// Legacy fallbacks (if user provided native keys too)
		if dc.Mimic.FakeDomain != "" || dc.Mimic.FakePath != "" {
			c.Mimic = dc.Mimic
			c.Mimic.FakePath = normalizePath(c.Mimic.FakePath)
		}
		if dc.Obfs.Enabled {
			c.Obfs = dc.Obfs
		}
		if len(dc.Forward.TCP) > 0 || len(dc.Forward.UDP) > 0 {
			c.Forward = dc.Forward
		}

		// client legacy single-url (optional)
		c.ServerURL = strings.TrimSpace(dc.ServerURL)
		c.SessionID = strings.TrimSpace(dc.SessionID)
		if c.SessionID == "" {
			c.SessionID = "sess-default"
		}
		return &c, nil
	}

	// Native mode (not Dagger style)
	c.Mode = strings.TrimSpace(dc.Mode)
	c.PSK = dc.PSK
	c.Profile = dc.Profile
	c.Verbose = dc.Verbose
	c.Listen = dc.Listen
	c.Transport = dc.Transport
	c.Heartbeat = dc.Heartbeat
	c.SessionTimeout = dc.SessionTimeout
	c.ServerURL = strings.TrimSpace(dc.ServerURL)
	c.SessionID = strings.TrimSpace(dc.SessionID)
	if c.SessionID == "" {
		c.SessionID = "sess-default"
	}
	c.Mimic = dc.Mimic
	c.Mimic.FakePath = normalizePath(c.Mimic.FakePath)
	c.Obfs = dc.Obfs
	c.Forward = dc.Forward
	c.Paths = dc.Paths
	if c.SessionTimeout <= 0 {
		c.SessionTimeout = 15
	}
	return &c, nil
}
