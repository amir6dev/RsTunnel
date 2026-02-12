package main

import (
	"flag"
	"log"
	"net/http"
	"time"

	httpmux "github.com/amir6dev/RsTunnel/PicoTun"
)

func main() {
	configPath := flag.String("config", "/etc/picotun/config.yaml", "path to config file")
	flag.Parse()

	cfg, err := httpmux.LoadConfig(*configPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	switch cfg.Mode {
	case "server":
		if cfg.Listen == "" {
			cfg.Listen = "0.0.0.0:1010"
		}
		if cfg.SessionTimeout <= 0 {
			cfg.SessionTimeout = 15
		}

		srv := httpmux.NewServer(cfg.SessionTimeout, &cfg.Mimic, &cfg.Obfs, cfg.PSK)

		// Reverse TCP listeners from config
		for _, m := range cfg.Forward.TCP {
			bind, target, ok := httpmux.SplitMap(m)
			if !ok {
				log.Printf("invalid tcp map: %q", m)
				continue
			}
			go srv.StartReverseTCP(bind, target)
		}

		mux := http.NewServeMux()
		mux.HandleFunc("/tunnel", srv.HandleHTTP)

		log.Printf("server running on %s (endpoint /tunnel)", cfg.Listen)
		log.Fatal(http.ListenAndServe(cfg.Listen, mux))

	case "client":
		if cfg.ServerURL == "" {
			log.Fatal("server_url is required in client config")
		}
		if cfg.SessionID == "" {
			cfg.SessionID = "sess-" + time.Now().Format("20060102150405")
		}

		cl := httpmux.NewClient(cfg.ServerURL, cfg.SessionID, &cfg.Mimic, &cfg.Obfs, cfg.PSK)

		rev := httpmux.NewClientReverse(cl.Transport)
		go rev.Run()

		log.Printf("client running. server_url=%s session_id=%s", cfg.ServerURL, cfg.SessionID)
		select {}

	default:
		log.Fatalf("invalid mode: %q (expected server|client)", cfg.Mode)
	}
}
