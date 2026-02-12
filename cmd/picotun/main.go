package main

import (
	"flag"
	"log"
	"net/http"
	"strings"
	"time"

	httpmux "github.com/amir6dev/rstunnel/PicoTun"
)

var version = "dev"

func main() {
	showVersion := flag.Bool("version", false, "print version and exit")
	configPath := flag.String("config", "/etc/picotun/config.yaml", "path to config file")
	configShort := flag.String("c", "", "alias for -config")
	flag.Parse()

	if *showVersion {
		log.Printf("%s", version)
		return
	}

	cfgPath := *configPath
	if *configShort != "" {
		cfgPath = *configShort
	}

	cfg, err := httpmux.LoadConfig(cfgPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	switch strings.ToLower(strings.TrimSpace(cfg.Mode)) {
	case "server":
		if cfg.Listen == "" {
			cfg.Listen = "0.0.0.0:2020"
		}
		if cfg.Heartbeat <= 0 {
			cfg.Heartbeat = 2
		}
		if cfg.SessionTimeout <= 0 {
			cfg.SessionTimeout = 15
		}
		srv := httpmux.NewServer(cfg.SessionTimeout, &cfg.Mimic, &cfg.Obfs, cfg.PSK)

		// maps from new schema
		for _, m := range cfg.Maps {
			if strings.ToLower(m.Type) == "tcp" {
				go srv.StartReverseTCP(m.Bind, m.Target)
			} else if strings.ToLower(m.Type) == "udp" {
				go srv.StartReverseUDP(m.Bind, m.Target)
			}
		}
		// maps from legacy schema
		for _, m := range cfg.Forward.TCP {
			bind, target, ok := splitMapLegacy(m)
			if ok {
				go srv.StartReverseTCP(bind, target)
			}
		}
		for _, m := range cfg.Forward.UDP {
			bind, target, ok := splitMapLegacy(m)
			if ok {
				go srv.StartReverseUDP(bind, target)
			}
		}

		mux := http.NewServeMux()
		mux.HandleFunc("/tunnel", srv.HandleHTTP)

		log.Printf("server listening on %s (tunnel endpoint: /tunnel)", cfg.Listen)
		log.Fatal(http.ListenAndServe(cfg.Listen, mux))

	case "client":
		if cfg.ServerURL == "" {
			log.Fatal("server_url is required")
		}
		if cfg.SessionID == "" {
			cfg.SessionID = "sess-default"
		}
		cl := httpmux.NewClient(cfg.ServerURL, cfg.SessionID, &cfg.Mimic, &cfg.Obfs, cfg.PSK)
		rev := httpmux.NewClientReverse(cl.Transport)
		go rev.Run()

		log.Printf("client started. server_url=%s session_id=%s", cfg.ServerURL, cfg.SessionID)
		for {
			time.Sleep(60 * time.Second)
		}
	default:
		log.Fatalf("unknown mode: %q (expected server/client)", cfg.Mode)
	}
}

func splitMapLegacy(s string) (bind string, target string, ok bool) {
	parts := strings.Split(s, "->")
	if len(parts) != 2 {
		return "", "", false
	}
	bind = strings.TrimSpace(parts[0])
	target = strings.TrimSpace(parts[1])
	if !strings.Contains(bind, ":") {
		bind = "0.0.0.0:" + bind
	}
	return bind, target, true
}
