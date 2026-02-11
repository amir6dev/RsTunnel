package httpmux

import (
	"crypto/rand"
	"time"
)

type ObfsConfig struct {
	Enabled      bool
	MinPadding   int
	MaxPadding   int
	MinDelay     int
	MaxDelay     int
	BurstChance  int
}

func ApplyObfuscation(data []byte, cfg *ObfsConfig) []byte {
	if !cfg.Enabled {
		return data
	}

	pad := cfg.MinPadding
	if cfg.MaxPadding > cfg.MinPadding {
		pad = cfg.MinPadding + int(randomByte())%(cfg.MaxPadding-cfg.MinPadding)
	}

	padding := make([]byte, pad)
	rand.Read(padding)

	return append(data, padding...)
}

func randomByte() byte {
	b := make([]byte, 1)
	rand.Read(b)
	return b[0]
}

func RandomDelay(cfg *ObfsConfig) {
	if cfg.MaxDelay == 0 {
		return
	}
	d := cfg.MinDelay + int(randomByte())%(cfg.MaxDelay-cfg.MinDelay)
	time.Sleep(time.Duration(d) * time.Millisecond)
}
