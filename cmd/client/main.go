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
<<<<<<< HEAD
<<<<<<< HEAD
	var paths []httpmux.PathConfig
	if len(cfg.Paths) > 0 {
		paths = cfg.Paths
=======
<<<<<<< HEAD
	var paths []httpmux.PathConfig
	if len(cfg.Paths) > 0 {
		paths = cfg.Paths
=======
<<<<<<< HEAD
	var paths []httpmux.PathConfig
	if len(cfg.Paths) > 0 {
		paths = cfg.Paths
=======
	var path httpmux.PathConfig
	if len(cfg.Paths) > 0 {
		path = cfg.Paths[0]
>>>>>>> de61458072bfcfd0a2ba33f1a1c20aaacc44f94c
>>>>>>> 62fc88353bdf49aa22a0ab96b51f1b4749e1d595
>>>>>>> 761e0881dbe95042a42689a9d133dc400c8d6457
=======
	var paths []httpmux.PathConfig
	if len(cfg.Paths) > 0 {
		paths = cfg.Paths
>>>>>>> 6b30d3e (New Update)
	} else {
		// legacy mode: server_url must be provided
		if strings.TrimSpace(cfg.ServerURL) == "" {
			log.Fatal("client config requires either 'paths:' (recommended) or 'server_url:'")
		}
		// Convert legacy server_url into a path
<<<<<<< HEAD
<<<<<<< HEAD
		paths = append(paths, httpmux.PathConfig{
=======
<<<<<<< HEAD
		paths = append(paths, httpmux.PathConfig{
=======
<<<<<<< HEAD
		paths = append(paths, httpmux.PathConfig{
=======
		path = httpmux.PathConfig{
>>>>>>> de61458072bfcfd0a2ba33f1a1c20aaacc44f94c
>>>>>>> 62fc88353bdf49aa22a0ab96b51f1b4749e1d595
>>>>>>> 761e0881dbe95042a42689a9d133dc400c8d6457
=======
		paths = append(paths, httpmux.PathConfig{
>>>>>>> 6b30d3e (New Update)
			Transport:      "httpmux",
			Addr:           cfg.ServerURL, // buildServerURL handles full URL too
			ConnectionPool: 2,
			AggressivePool: true,
			RetryInterval:  3,
			DialTimeout:    10,
<<<<<<< HEAD
<<<<<<< HEAD
=======
<<<<<<< HEAD
=======
<<<<<<< HEAD
>>>>>>> 62fc88353bdf49aa22a0ab96b51f1b4749e1d595
>>>>>>> 761e0881dbe95042a42689a9d133dc400c8d6457
=======
>>>>>>> 6b30d3e (New Update)
		})
	}

	cl := httpmux.NewClientFromPaths(paths, cfg.SessionID, &cfg.Mimic, &cfg.Obfs, cfg.PSK)
<<<<<<< HEAD
<<<<<<< HEAD
=======
<<<<<<< HEAD
=======
=======
		}
	}

	cl := httpmux.NewClientFromPath(path, cfg.SessionID, &cfg.Mimic, &cfg.Obfs, cfg.PSK)
>>>>>>> de61458072bfcfd0a2ba33f1a1c20aaacc44f94c
>>>>>>> 62fc88353bdf49aa22a0ab96b51f1b4749e1d595
>>>>>>> 761e0881dbe95042a42689a9d133dc400c8d6457
=======
>>>>>>> 6b30d3e (New Update)

	// Reverse runner: handles FrameOpen/FrameData/FrameClose
	rev := httpmux.NewClientReverse(cl.Transport)
	go rev.Run()

<<<<<<< HEAD
<<<<<<< HEAD
=======
<<<<<<< HEAD
=======
<<<<<<< HEAD
>>>>>>> 62fc88353bdf49aa22a0ab96b51f1b4749e1d595
>>>>>>> 761e0881dbe95042a42689a9d133dc400c8d6457
=======
>>>>>>> 6b30d3e (New Update)
	if len(paths) > 0 {
		log.Printf("client started. paths=%d first_transport=%s first_addr=%s session_id=%s", len(paths), paths[0].Transport, paths[0].Addr, cfg.SessionID)
	} else {
		log.Printf("client started. (no paths?) session_id=%s", cfg.SessionID)
	}
<<<<<<< HEAD
<<<<<<< HEAD
=======
<<<<<<< HEAD
=======
=======
	log.Printf("client started. transport=%s addr=%s session_id=%s", path.Transport, path.Addr, cfg.SessionID)
>>>>>>> de61458072bfcfd0a2ba33f1a1c20aaacc44f94c
>>>>>>> 62fc88353bdf49aa22a0ab96b51f1b4749e1d595
>>>>>>> 761e0881dbe95042a42689a9d133dc400c8d6457
=======
>>>>>>> 6b30d3e (New Update)

	for {
		time.Sleep(60 * time.Second)
	}
}
