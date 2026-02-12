package main

import (
	"flag"
	"log"
	"net/http"
	"strings"

	"rstunnel/httpmux"
)

func main() {
	configPath := flag.String("config", "/etc/picotun/config.yaml", "path to config file")
	flag.Parse()

	cfg, err := httpmux.LoadConfig(*configPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}
	if cfg.Listen == "" {
		cfg.Listen = "0.0.0.0:8080"
	}
	if cfg.SessionTimeout <= 0 {
		cfg.SessionTimeout = 15
	}

	srv := httpmux.NewServer(cfg.SessionTimeout, &cfg.Mimic, &cfg.Obfs, cfg.PSK)

	// Reverse TCP listeners
	for _, m := range cfg.Forward.TCP {
		bind, target, ok := splitMap(m)
		if !ok {
			log.Printf("invalid tcp map: %q (expected bind->target or port->target)", m)
			continue
		}
		go srv.StartReverseTCP(bind, target)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/tunnel", srv.HandleHTTP)

	log.Printf("server listening on %s (tunnel endpoint: /tunnel)", cfg.Listen)
	log.Fatal(http.ListenAndServe(cfg.Listen, mux))
}

func splitMap(s string) (bind string, target string, ok bool) {
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
