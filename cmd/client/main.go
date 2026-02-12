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
	var path httpmux.PathConfig
	if len(cfg.Paths) > 0 {
		path = cfg.Paths[0]
	} else {
		// legacy mode: server_url must be provided
		if strings.TrimSpace(cfg.ServerURL) == "" {
			log.Fatal("client config requires either 'paths:' (recommended) or 'server_url:'")
		}
		// Convert legacy server_url into a path
		path = httpmux.PathConfig{
			Transport:      "httpmux",
			Addr:           cfg.ServerURL, // buildServerURL handles full URL too
			ConnectionPool: 2,
			AggressivePool: true,
			RetryInterval:  3,
			DialTimeout:    10,
		}
	}

	cl := httpmux.NewClientFromPath(path, cfg.SessionID, &cfg.Mimic, &cfg.Obfs, cfg.PSK)

	// Reverse runner: handles FrameOpen/FrameData/FrameClose
	rev := httpmux.NewClientReverse(cl.Transport)
	go rev.Run()

	log.Printf("client started. transport=%s addr=%s session_id=%s", path.Transport, path.Addr, cfg.SessionID)

	for {
		time.Sleep(60 * time.Second)
	}
}
