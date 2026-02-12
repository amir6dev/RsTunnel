package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"gopkg.in/yaml.v3"

	"rstunnel" // چون module rstunnel هست و پکیج‌ها در ریشه با package httpmux تعریف شدن
)

// اگر دوست داری اسم پکیج رو تغییر بدیم/فولدر بندی کنیم بعداً انجام می‌دیم.
// فعلاً همین سریع‌ترین fix برای build/deploy هست.

type Config struct {
	Mode           string `yaml:"mode"`            // server|client
	Listen         string `yaml:"listen"`          // server listen addr
	ServerURL      string `yaml:"server_url"`      // client
	SessionID      string `yaml:"session_id"`      // client
	SessionTimeout int    `yaml:"session_timeout"` // server

	Mimic struct {
		FakeDomain    string   `yaml:"fake_domain"`
		FakePath      string   `yaml:"fake_path"`
		UserAgent     string   `yaml:"user_agent"`
		CustomHeaders []string `yaml:"custom_headers"`
		SessionCookie bool     `yaml:"session_cookie"`
	} `yaml:"mimic"`

	Obfs struct {
		Enabled    bool `yaml:"enabled"`
		MinPadding int  `yaml:"min_padding"`
		MaxPadding int  `yaml:"max_padding"`
		MinDelay   int  `yaml:"min_delay"`
		MaxDelay   int  `yaml:"max_delay"`
	} `yaml:"obfs"`

	Forward struct {
		TCP []string `yaml:"tcp"`
		UDP []string `yaml:"udp"`
	} `yaml:"forward"`
}

func loadConfig(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg Config
	if err := yaml.Unmarshal(b, &cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func main() {
	configPath := flag.String("config", "/etc/picotun/config.yaml", "config file path")
	flag.Parse()

	cfg, err := loadConfig(*configPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	mimic := &rstunnel.MimicConfig{
		FakeDomain:    cfg.Mimic.FakeDomain,
		FakePath:      cfg.Mimic.FakePath,
		UserAgent:     cfg.Mimic.UserAgent,
		CustomHeaders: cfg.Mimic.CustomHeaders,
		SessionCookie: cfg.Mimic.SessionCookie,
	}

	obfs := &rstunnel.ObfsConfig{
		Enabled:    cfg.Obfs.Enabled,
		MinPadding: cfg.Obfs.MinPadding,
		MaxPadding: cfg.Obfs.MaxPadding,
		MinDelayMS: cfg.Obfs.MinDelay,
		MaxDelayMS: cfg.Obfs.MaxDelay,
	}

	switch cfg.Mode {
	case "server":
		addr := cfg.Listen
		if addr == "" {
			addr = "0.0.0.0:8080"
		}
		timeout := cfg.SessionTimeout
		if timeout <= 0 {
			timeout = 15
		}

		srv := rstunnel.NewServer(timeout, obfs) // این باید با server.go فعلی‌ات match باشد
		http.HandleFunc("/tunnel", srv.HandleHTTP) // اگر اسم هندلر فرق دارد، همینجا fix می‌کنیم

		log.Printf("picotun server listening on %s", addr)
		log.Fatal(http.ListenAndServe(addr, nil))

	case "client":
		if cfg.ServerURL == "" {
			log.Fatal("server_url is required for client")
		}
		if cfg.SessionID == "" {
			cfg.SessionID = fmt.Sprintf("sess-%d", time.Now().Unix())
		}

		_ = mimic
		_ = obfs

		// فعلاً برای deploy مرحله اول، فقط باینری و config-ready بودن مهمه.
		// بعدش در مرحله HTTPMUX واقعی، کلاینت رو کامل می‌کنیم.
		log.Printf("client mode configured. server_url=%s session_id=%s", cfg.ServerURL, cfg.SessionID)
		select {}

	default:
		log.Fatalf("invalid mode: %s (expected server|client)", cfg.Mode)
	}
}
