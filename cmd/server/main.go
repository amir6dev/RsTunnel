package main

import (
	"flag"
	"log"
	"net/http"
	"strings"

	httpmux "github.com/amir6dev/rstunnel/PicoTun"
)

func main() {
	// Support both -config and -c for compatibility with installer scripts
	configPath := flag.String("config", "/etc/picotun/config.yaml", "path to config file")
	configShort := flag.String("c", "", "alias for -config")
	flag.Parse()

	cfgPath := *configPath
	if *configShort != "" {
		cfgPath = *configShort
	}

	cfg, err := httpmux.LoadConfig(cfgPath)
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

	// Reverse UDP listeners
	for _, m := range cfg.Forward.UDP {
		bind, target, ok := splitMap(m)
		if !ok {
			log.Printf("invalid udp map: %q (expected bind->target or port->target)", m)
			continue
		}
		go srv.StartReverseUDP(bind, target)
	}

	// Dagger-style: the tunnel endpoint MUST match http_mimic.fake_path
	// (installer defaults to /search). We'll also keep /tunnel for compatibility.
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
	// last-resort fallback (some proxies rewrite paths)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// only accept POST (to avoid looking like a full website)
		if r.Method != http.MethodPost {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		srv.HandleHTTP(w, r)
	})

	log.Printf("server listening on %s (tunnel endpoint: %s)", cfg.Listen, path)
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
