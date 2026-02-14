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
		runServer(cfg)
	case "client":
		runClient(cfg)
	default:
		log.Fatalf("unknown mode: %q (expected server/client)", cfg.Mode)
	}
}

func runServer(cfg *httpmux.Config) {
	srv := httpmux.NewServer(cfg.SessionTimeout, &cfg.Mimic, &cfg.Obfs, cfg.PSK)
	for _, m := range cfg.Forward.TCP {
		if bind, target, ok := splitMapLegacy(m); ok {
			go srv.StartReverseTCP(bind, target)
		}
	}
	for _, m := range cfg.Forward.UDP {
		if bind, target, ok := splitMapLegacy(m); ok {
			go srv.StartReverseUDP(bind, target)
		}
	}
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
}

func runClient(cfg *httpmux.Config) {
	if cfg.SessionID == "" {
		cfg.SessionID = "sess-default"
	}
	paths := cfg.Paths
	if len(paths) == 0 {
		if strings.TrimSpace(cfg.ServerURL) == "" {
			log.Fatal("client requires either 'paths:' or 'server_url:'")
		}
		paths = append(paths, httpmux.PathConfig{
			Transport:      "httpmux",
			Addr:           cfg.ServerURL,
			ConnectionPool: 2,
			AggressivePool: true,
			RetryInterval:  3,
			DialTimeout:    10,
		})
	}

	// ✅ FIXED: Create proper HTTPMuxConfig with all Dagger-like features
	muxCfg := httpmux.HTTPMuxConfig{
		FlushInterval:    200 * time.Millisecond,
		MaxBatch:         64,
		IdlePoll:         250 * time.Millisecond,
		NumConnections:   cfg.NumConnections,
		EnableDecoy:      cfg.EnableDecoy,
		DecoyInterval:    time.Duration(cfg.DecoyInterval) * time.Second,
		EmbedFakeHeaders: cfg.EmbedFakeHeaders,
	}

	// ✅ FIXED: Pass muxCfg to NewClientFromPaths
	cl := httpmux.NewClientFromPaths(paths, cfg.SessionID, &cfg.Mimic, &cfg.Obfs, cfg.PSK, muxCfg)
	rev := httpmux.NewClientReverse(cl.Transport)
	go rev.Run()

	// ✅ FIXED: Send initial ping to establish connection immediately
	log.Printf("client started. paths=%d first_transport=%s first_addr=%s session_id=%s",
		len(paths), paths[0].Transport, paths[0].Addr, cfg.SessionID)

	// Send first ping right away to establish connection
	_ = cl.Transport.Send(&httpmux.Frame{
		StreamID: 0,
		Type:     httpmux.FramePing,
	})

	// ✅ FIXED: Start heartbeat goroutine to keep connection alive
	go func() {
		heartbeatInterval := time.Duration(cfg.Heartbeat) * time.Second
		if heartbeatInterval <= 0 {
			heartbeatInterval = 10 * time.Second
		}

		ticker := time.NewTicker(heartbeatInterval)
		defer ticker.Stop()

		for {
			<-ticker.C
			// Send periodic ping to keep connection alive and prevent NAT timeout
			_ = cl.Transport.Send(&httpmux.Frame{
				StreamID: 0,
				Type:     httpmux.FramePing,
			})
			if cfg.Verbose {
				log.Printf("heartbeat ping sent")
			}
		}
	}()

	// Keep main goroutine alive
	for {
		time.Sleep(60 * time.Second)
	}
}

func splitMapLegacy(s string) (bind string, target string, ok bool) {
	parts := strings.Split(s, "->")
	if len(parts) != 2 {
		return "", "", false
	}
	bind, target = strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1])
	if !strings.Contains(bind, ":") {
		bind = "0.0.0.0:" + bind
	}
	return bind, target, true
}
