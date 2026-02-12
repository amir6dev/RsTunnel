package main

import (
	"flag"
	"log"
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
	if cfg.ServerURL == "" {
		log.Fatal("server_url is required in client config")
	}
	if cfg.SessionID == "" {
		cfg.SessionID = "sess-default"
	}

	cl := httpmux.NewClient(cfg.ServerURL, cfg.SessionID, &cfg.Mimic, &cfg.Obfs, cfg.PSK)

	// Reverse runner: handles FrameOpen/FrameData/FrameClose
	rev := httpmux.NewClientReverse(cl.Transport)
	go rev.Run()

	log.Printf("client started. server_url=%s session_id=%s", cfg.ServerURL, cfg.SessionID)

	for {
		time.Sleep(60 * time.Second)
	}
}
