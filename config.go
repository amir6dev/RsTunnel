package httpmux

import (
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

// ═══════════════════════════════════════════════════════════════
//  PicoTun v2.4 — Configuration
// ═══════════════════════════════════════════════════════════════

type Config struct {
	Mode        string `yaml:"mode"`
	Listen      string `yaml:"listen"`
	Transport   string `yaml:"transport"`
	PSK         string `yaml:"psk"`
	Profile     string `yaml:"profile"`
	Verbose     bool   `yaml:"verbose"`
	CertFile    string `yaml:"cert_file"`
	KeyFile     string `yaml:"key_file"`
	MaxSessions int    `yaml:"max_sessions"`
	Heartbeat   int    `yaml:"heartbeat"`

	NumConnections   int  `yaml:"num_connections"`
	EnableDecoy      bool `yaml:"enable_decoy"`
	DecoyInterval    int  `yaml:"decoy_interval"`
	EmbedFakeHeaders bool `yaml:"embed_fake_headers"`

	Maps  []PortMap    `yaml:"maps"`
	Paths []PathConfig `yaml:"paths"`

	Smux        SmuxConfig      `yaml:"smux"`
	KCP         KCPConfig       `yaml:"kcp"`
	Advanced    AdvancedConfig  `yaml:"advanced"`
	Obfuscation ObfsCompat      `yaml:"obfuscation"`
	HTTPMimic   HTTPMimicCompat `yaml:"http_mimic"`
	Fragment    FragmentConfig  `yaml:"fragment"`

	ServerURL  string `yaml:"server_url"`
	SessionID  string `yaml:"session_id"`

	Forward struct {
		TCP []string `yaml:"tcp"`
		UDP []string `yaml:"udp"`
	} `yaml:"forward"`

	Mimic MimicConfig `yaml:"mimic"`
	Obfs  ObfsConfig  `yaml:"obfs"`

	SessionTimeout int `yaml:"session_timeout"`
}

type PathConfig struct {
	Transport      string `yaml:"transport"`
	Addr           string `yaml:"addr"`
	ConnectionPool int    `yaml:"connection_pool"`
	AggressivePool bool   `yaml:"aggressive_pool"`
	RetryInterval  int    `yaml:"retry_interval"`
	DialTimeout    int    `yaml:"dial_timeout"`
}

type PortMap struct {
	Type   string `yaml:"type"`
	Bind   string `yaml:"bind"`
	Target string `yaml:"target"`
}

type SmuxConfig struct {
	KeepAlive int `yaml:"keepalive"`
	MaxRecv   int `yaml:"max_recv"`
	MaxStream int `yaml:"max_stream"`
	FrameSize int `yaml:"frame_size"`
	Version   int `yaml:"version"`
}

type KCPConfig struct {
	NoDelay  int `yaml:"nodelay"`
	Interval int `yaml:"interval"`
	Resend   int `yaml:"resend"`
	NC       int `yaml:"nc"`
	SndWnd   int `yaml:"sndwnd"`
	RcvWnd   int `yaml:"rcvwnd"`
	MTU      int `yaml:"mtu"`
}

type AdvancedConfig struct {
	TCPNoDelay           bool `yaml:"tcp_nodelay"`
	TCPKeepAlive         int  `yaml:"tcp_keepalive"`
	TCPReadBuffer        int  `yaml:"tcp_read_buffer"`
	TCPWriteBuffer       int  `yaml:"tcp_write_buffer"`
	WebSocketReadBuffer  int  `yaml:"websocket_read_buffer"`
	WebSocketWriteBuffer int  `yaml:"websocket_write_buffer"`
	WebSocketCompression bool `yaml:"websocket_compression"`
	CleanupInterval      int  `yaml:"cleanup_interval"`
	SessionTimeout       int  `yaml:"session_timeout"`
	ConnectionTimeout    int  `yaml:"connection_timeout"`
	StreamTimeout        int  `yaml:"stream_timeout"`
	MaxConnections       int  `yaml:"max_connections"`
	MaxUDPFlows          int  `yaml:"max_udp_flows"`
	UDPFlowTimeout       int  `yaml:"udp_flow_timeout"`
	UDPBufferSize        int  `yaml:"udp_buffer_size"`
}

type HTTPMimicCompat struct {
	FakeDomain      string   `yaml:"fake_domain"`
	FakePath        string   `yaml:"fake_path"`
	UserAgent       string   `yaml:"user_agent"`
	ChunkedEncoding bool     `yaml:"chunked_encoding"`
	SessionCookie   bool     `yaml:"session_cookie"`
	CustomHeaders   []string `yaml:"custom_headers"`
}

type ObfsCompat struct {
	Enabled     bool    `yaml:"enabled"`
	MinPadding  int     `yaml:"min_padding"`
	MaxPadding  int     `yaml:"max_padding"`
	MinDelayMS  int     `yaml:"min_delay_ms"`
	MaxDelayMS  int     `yaml:"max_delay_ms"`
	BurstChance float64 `yaml:"burst_chance"`
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

// ═══════════════════════════════════════════════════════════════
// Base defaults — proven optimal for Iranian DPI bypass.
// Small frames (2KB), fast keepalive (1s), small TCP buffers (32KB).
// ═══════════════════════════════════════════════════════════════

func applyBaseDefaults(c *Config) {
	if c.Profile == "" {
		c.Profile = "balanced"
	}
	if c.Heartbeat <= 0 {
		c.Heartbeat = 2
	}
	if c.SessionTimeout <= 0 {
		c.SessionTimeout = 15
	}
	if c.Advanced.SessionTimeout > 0 {
		c.SessionTimeout = c.Advanced.SessionTimeout
	}

	// ─── smux: DPI-safe defaults (NEVER increase frame_size!) ───
	if c.Smux.KeepAlive <= 0 {
		c.Smux.KeepAlive = 1 // 1s — fast dead-conn detection
	}
	if c.Smux.MaxRecv <= 0 {
		c.Smux.MaxRecv = 524288 // 512KB
	}
	if c.Smux.MaxStream <= 0 {
		c.Smux.MaxStream = 524288 // 512KB
	}
	if c.Smux.FrameSize <= 0 {
		c.Smux.FrameSize = 2048 // 2KB — looks like HTTP to DPI
	}
	if c.Smux.Version <= 0 {
		c.Smux.Version = 2
	}

	// ─── TCP ───
	if c.Advanced.TCPKeepAlive <= 0 {
		c.Advanced.TCPKeepAlive = 3
	}
	if c.Advanced.TCPReadBuffer <= 0 {
		c.Advanced.TCPReadBuffer = 32768 // 32KB
	}
	if c.Advanced.TCPWriteBuffer <= 0 {
		c.Advanced.TCPWriteBuffer = 32768 // 32KB
	}
	if c.Advanced.CleanupInterval <= 0 {
		c.Advanced.CleanupInterval = 1
	}
	if c.Advanced.ConnectionTimeout <= 0 {
		c.Advanced.ConnectionTimeout = 20
	}
	if c.Advanced.StreamTimeout <= 0 {
		c.Advanced.StreamTimeout = 45
	}
	if c.Advanced.MaxConnections <= 0 {
		c.Advanced.MaxConnections = 300
	}
	if c.Advanced.MaxUDPFlows <= 0 {
		c.Advanced.MaxUDPFlows = 150
	}
	if c.Advanced.UDPFlowTimeout <= 0 {
		c.Advanced.UDPFlowTimeout = 90
	}
	if c.Advanced.UDPBufferSize <= 0 {
		c.Advanced.UDPBufferSize = 262144
	}
	c.Advanced.TCPNoDelay = true

	// ─── HTTP mimic ───
	if c.HTTPMimic.FakeDomain == "" {
		c.HTTPMimic.FakeDomain = "www.google.com"
	}
	if c.HTTPMimic.FakePath == "" {
		c.HTTPMimic.FakePath = "/search"
	}
	c.HTTPMimic.FakePath = normalizePath(c.HTTPMimic.FakePath)
	if c.HTTPMimic.UserAgent == "" {
		c.HTTPMimic.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
	}
	if !c.HTTPMimic.SessionCookie {
		c.HTTPMimic.SessionCookie = true
	}

	// ─── Obfuscation ───
	if c.Obfuscation.MinPadding <= 0 {
		c.Obfuscation.MinPadding = 8
	}
	if c.Obfuscation.MaxPadding <= 0 {
		c.Obfuscation.MaxPadding = 32
	}

	// ─── Pool ───
	if c.NumConnections <= 0 {
		c.NumConnections = 4
	}
	if c.DecoyInterval <= 0 {
		c.DecoyInterval = 5
	}

	// ─── TLS Fragment ───
	if c.Fragment.MinSize <= 0 {
		c.Fragment.MinSize = 64
	}
	if c.Fragment.MaxSize <= 0 {
		c.Fragment.MaxSize = 191
	}
	if c.Fragment.MinDelay <= 0 {
		c.Fragment.MinDelay = 1
	}
	if c.Fragment.MaxDelay <= 0 {
		c.Fragment.MaxDelay = 2
	}
	transport := strings.ToLower(c.Transport)
	if !c.Fragment.Enabled && (transport == "httpsmux" || transport == "wssmux") {
		c.Fragment.Enabled = true
	}
}

// ═══════════════════════════════════════════════════════════════
//  PicoTun Profiles
//
//  All profiles keep DPI-safe base settings (frame=2KB, keepalive=1s).
//  They only vary pool size, retry behavior, and buffering.
//
//  ┌─────────────┬──────┬─────────┬─────────┬───────────┬──────────┐
//  │ Profile     │ Pool │ Retry   │ Timeout │ Buffers   │ Use      │
//  ├─────────────┼──────┼─────────┼─────────┼───────────┼──────────┤
//  │ speed       │ 4    │ 2s      │ 10s     │ 512KB     │ Download │
//  │ balanced    │ 3    │ 3s      │ 10s     │ 512KB     │ General  │
//  │ gaming      │ 4    │ 1s      │ 5s      │ 512KB     │ Games    │
//  │ streaming   │ 3    │ 2s      │ 10s     │ 1MB       │ Video    │
//  │ lowcpu      │ 2    │ 5s      │ 15s     │ 256KB     │ Low-end  │
//  └─────────────┴──────┴─────────┴─────────┴───────────┴──────────┘
// ═══════════════════════════════════════════════════════════════

func applyProfile(c *Config) {
	switch strings.ToLower(c.Profile) {

	case "speed", "aggressive":
		// Max throughput — big pool, fast retry, zero delay
		c.Obfuscation.MinDelayMS = 0
		c.Obfuscation.MaxDelayMS = 0
		c.HTTPMimic.ChunkedEncoding = false
		for i := range c.Paths {
			if c.Paths[i].ConnectionPool < 4 {
				c.Paths[i].ConnectionPool = 4
			}
			c.Paths[i].AggressivePool = true
			if c.Paths[i].RetryInterval <= 0 || c.Paths[i].RetryInterval > 2 {
				c.Paths[i].RetryInterval = 2
			}
			if c.Paths[i].DialTimeout <= 0 {
				c.Paths[i].DialTimeout = 10
			}
		}

	case "gaming", "latency":
		// Ultra-low latency — fast keepalive, quick reconnect
		c.Smux.KeepAlive = 1
		c.Advanced.TCPKeepAlive = 1
		c.Obfuscation.MinDelayMS = 0
		c.Obfuscation.MaxDelayMS = 0
		c.HTTPMimic.ChunkedEncoding = false
		for i := range c.Paths {
			if c.Paths[i].ConnectionPool < 4 {
				c.Paths[i].ConnectionPool = 4
			}
			c.Paths[i].AggressivePool = true
			if c.Paths[i].RetryInterval <= 0 || c.Paths[i].RetryInterval > 1 {
				c.Paths[i].RetryInterval = 1
			}
			if c.Paths[i].DialTimeout <= 0 {
				c.Paths[i].DialTimeout = 5
			}
		}

	case "streaming":
		// High throughput + stability for video/audio
		c.Smux.MaxRecv = 1048576  // 1MB — bigger buffers for video
		c.Smux.MaxStream = 1048576
		c.Obfuscation.MinDelayMS = 0
		c.Obfuscation.MaxDelayMS = 0
		for i := range c.Paths {
			if c.Paths[i].ConnectionPool < 3 {
				c.Paths[i].ConnectionPool = 3
			}
			if c.Paths[i].RetryInterval <= 0 {
				c.Paths[i].RetryInterval = 2
			}
			if c.Paths[i].DialTimeout <= 0 {
				c.Paths[i].DialTimeout = 10
			}
		}

	case "lowcpu", "cpu-efficient":
		// Minimal resources — fewer connections, slower keepalive
		c.Smux.KeepAlive = 3
		c.Smux.MaxRecv = 262144 // 256KB
		c.Smux.MaxStream = 262144
		for i := range c.Paths {
			if c.Paths[i].ConnectionPool <= 0 || c.Paths[i].ConnectionPool > 2 {
				c.Paths[i].ConnectionPool = 2
			}
			if c.Paths[i].RetryInterval <= 0 {
				c.Paths[i].RetryInterval = 5
			}
			if c.Paths[i].DialTimeout <= 0 {
				c.Paths[i].DialTimeout = 15
			}
		}

	default: // balanced
		c.Obfuscation.MinDelayMS = 0
		c.Obfuscation.MaxDelayMS = 0
		for i := range c.Paths {
			if c.Paths[i].ConnectionPool <= 0 {
				c.Paths[i].ConnectionPool = 3
			}
			if c.Paths[i].RetryInterval <= 0 {
				c.Paths[i].RetryInterval = 3
			}
			if c.Paths[i].DialTimeout <= 0 {
				c.Paths[i].DialTimeout = 10
			}
		}
	}
}

// ══════════════════ Alias sync ══════════════════

func syncAliases(c *Config) {
	if c.Mimic.FakeDomain == "" {
		c.Mimic.FakeDomain = c.HTTPMimic.FakeDomain
	}
	if c.Mimic.FakePath == "" {
		c.Mimic.FakePath = c.HTTPMimic.FakePath
	}
	if c.Mimic.UserAgent == "" {
		c.Mimic.UserAgent = c.HTTPMimic.UserAgent
	}
	if len(c.Mimic.CustomHeaders) == 0 && len(c.HTTPMimic.CustomHeaders) > 0 {
		c.Mimic.CustomHeaders = append([]string{}, c.HTTPMimic.CustomHeaders...)
	}
	c.Mimic.Chunked = c.HTTPMimic.ChunkedEncoding
	c.Mimic.SessionCookie = c.HTTPMimic.SessionCookie

	if !c.Obfs.Enabled {
		c.Obfs.Enabled = c.Obfuscation.Enabled
	}
	if c.Obfs.MinPadding <= 0 {
		c.Obfs.MinPadding = c.Obfuscation.MinPadding
	}
	if c.Obfs.MaxPadding <= 0 {
		c.Obfs.MaxPadding = c.Obfuscation.MaxPadding
	}
	if c.Obfs.MinDelayMS <= 0 {
		c.Obfs.MinDelayMS = c.Obfuscation.MinDelayMS
	}
	if c.Obfs.MaxDelayMS <= 0 {
		c.Obfs.MaxDelayMS = c.Obfuscation.MaxDelayMS
	}
	if c.Obfs.BurstChance <= 0 {
		c.Obfs.BurstChance = int(c.Obfuscation.BurstChance * 1000)
	}
}

func convertMapsToForward(c *Config) {
	if len(c.Forward.TCP) == 0 && len(c.Forward.UDP) == 0 {
		for _, m := range c.Maps {
			entry := strings.TrimSpace(m.Bind) + "->" + strings.TrimSpace(m.Target)
			switch strings.ToLower(strings.TrimSpace(m.Type)) {
			case "udp":
				c.Forward.UDP = append(c.Forward.UDP, entry)
			case "both":
				c.Forward.TCP = append(c.Forward.TCP, entry)
				c.Forward.UDP = append(c.Forward.UDP, entry)
			default:
				c.Forward.TCP = append(c.Forward.TCP, entry)
			}
		}
	}
}

func LoadConfig(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Config
	if err := yaml.Unmarshal(b, &c); err != nil {
		return nil, err
	}

	c.Mode = strings.ToLower(strings.TrimSpace(c.Mode))
	c.Transport = strings.ToLower(strings.TrimSpace(c.Transport))
	c.Profile = strings.ToLower(strings.TrimSpace(c.Profile))
	c.Listen = strings.TrimSpace(c.Listen)
	c.ServerURL = strings.TrimSpace(c.ServerURL)

	if c.Mode == "server" && c.Listen == "" {
		c.Listen = "0.0.0.0:2020"
	}

	applyBaseDefaults(&c)
	applyProfile(&c)
	convertMapsToForward(&c)
	syncAliases(&c)
	return &c, nil
}
