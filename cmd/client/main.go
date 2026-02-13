package main

import (
	"flag"
	"log"
	"strings"
	"time"

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

	if cfg.SessionID == "" {
		cfg.SessionID = "sess-default"
	}

	// Prefer Dagger-style paths (multi-path). Fallback to server_url.
	var paths []httpmux.PathConfig
	if len(cfg.Paths) > 0 {
		paths = cfg.Paths
	} else {
		// legacy mode: server_url must be provided
		if strings.TrimSpace(cfg.ServerURL) == "" {
			log.Fatal("client config requires either 'paths:' (recommended) or 'server_url:'")
		}
		// Convert legacy server_url into a path
		paths = append(paths, httpmux.PathConfig{
			Transport:      "httpmux",
			Addr:           cfg.ServerURL, // buildServerURL handles full URL too
			ConnectionPool: 2,
			AggressivePool: true,
			RetryInterval:  3,
			DialTimeout:    10,
		})
	}

	cl := httpmux.NewClientFromPaths(paths, cfg.SessionID, &cfg.Mimic, &cfg.Obfs, cfg.PSK)

	// Reverse runner: handles FrameOpen/FrameData/FrameClose
	rev := httpmux.NewClientReverse(cl.Transport)
	go rev.Run()

	if len(paths) > 0 {
		log.Printf("client started. paths=%d first_transport=%s first_addr=%s session_id=%s", len(paths), paths[0].Transport, paths[0].Addr, cfg.SessionID)
	} else {
		log.Printf("client started. (no paths?) session_id=%s", cfg.SessionID)
	}

	for {
		time.Sleep(60 * time.Second)
	}
}
