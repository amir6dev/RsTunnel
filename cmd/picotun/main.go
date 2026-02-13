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
	// Dagger-like UX: support both -version and -v
	showVersion := flag.Bool("version", false, "print version and exit")
	showVersionShort := flag.Bool("v", false, "print version and exit")
	configPath := flag.String("config", "/etc/picotun/config.yaml", "path to config file")
	configShort := flag.String("c", "", "alias for -config")
	flag.Parse()

	if *showVersion || *showVersionShort {
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
		// Prefer Dagger-style paths (multi-path)
		var paths []httpmux.PathConfig
		if len(cfg.Paths) > 0 {
			paths = cfg.Paths
<<<<<<< HEAD
<<<<<<< HEAD
=======
<<<<<<< HEAD
=======
=======
		// Prefer Dagger-style paths
		var path httpmux.PathConfig
		if len(cfg.Paths) > 0 {
			path = cfg.Paths[0]
>>>>>>> de61458072bfcfd0a2ba33f1a1c20aaacc44f94c
>>>>>>> 62fc88353bdf49aa22a0ab96b51f1b4749e1d595
>>>>>>> 761e0881dbe95042a42689a9d133dc400c8d6457
=======
>>>>>>> 6b30d3e (New Update)
		} else {
			if strings.TrimSpace(cfg.ServerURL) == "" {
				log.Fatal("client requires either 'paths:' or 'server_url:'")
			}
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
				Addr:           cfg.ServerURL,
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
		rev := httpmux.NewClientReverse(cl.Transport)
		go rev.Run()

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
			}
		}

		cl := httpmux.NewClientFromPath(path, cfg.SessionID, &cfg.Mimic, &cfg.Obfs, cfg.PSK)
		rev := httpmux.NewClientReverse(cl.Transport)
		go rev.Run()

		log.Printf("client started. transport=%s addr=%s session_id=%s", path.Transport, path.Addr, cfg.SessionID)
>>>>>>> de61458072bfcfd0a2ba33f1a1c20aaacc44f94c
>>>>>>> 62fc88353bdf49aa22a0ab96b51f1b4749e1d595
>>>>>>> 761e0881dbe95042a42689a9d133dc400c8d6457
=======
>>>>>>> 6b30d3e (New Update)
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
