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

		// Reverse TCP/UDP listeners (Dagger "maps" are converted into Forward by LoadConfig)
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

		// Tunnel endpoint should match mimic.fake_path; keep /tunnel too.
		path := strings.TrimSpace(cfg.Mimic.FakePath)
		if path == "" || path == "/" {
			path = "/tunnel"
		}
		if !strings.HasPrefix(path, "/") {
			path = "/" + path
		}

		mux := http.NewServeMux()
		mux.HandleFunc(path, srv.HandleHTTP)
		if path != "/tunnel" {
			mux.HandleFunc("/tunnel", srv.HandleHTTP)
		}

		log.Printf("server listening on %s (tunnel endpoint: %s)", cfg.Listen, path)
		log.Fatal(http.ListenAndServe(cfg.Listen, mux))

	case "client":
		if cfg.SessionID == "" {
			cfg.SessionID = "sess-default"
		}

		// Prefer Dagger-style paths
		var path httpmux.PathConfig
		if len(cfg.Paths) > 0 {
			path = cfg.Paths[0]
		} else {
			if strings.TrimSpace(cfg.ServerURL) == "" {
				log.Fatal("client requires either 'paths:' or 'server_url:'")
			}
			path = httpmux.PathConfig{
				Transport:      "httpmux",
				Addr:           cfg.ServerURL,
				ConnectionPool: 2,
				AggressivePool: true,
				RetryInterval:  3,
				DialTimeout:    10,
			}
		}

		cl := httpmux.NewClientFromPath(path, cfg.SessionID, &cfg.Mimic, &cfg.Obfs, cfg.PSK)
		rev := httpmux.NewClientReverse(cl.Transport)
		go rev.Run()

		log.Printf("client started. transport=%s addr=%s session_id=%s", path.Transport, path.Addr, cfg.SessionID)
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

	// if bind is only port "1412" -> "0.0.0.0:1412"
	if !strings.Contains(bind, ":") {
		bind = "0.0.0.0:" + bind
	}
	return bind, target, true
}
