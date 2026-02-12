package main

import (
	"flag"
	"log"
	"time"

	"rstunnel/httpmux"
)

func main() {
	configPath := flag.String("config", "/etc/picotun/config.yaml", "path to config file")
	flag.Parse()

	cfg, err := httpmux.LoadConfig(*configPath)
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
