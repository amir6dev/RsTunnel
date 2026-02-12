package httpmux

import (
	"crypto/rand"
	"encoding/binary"
	"time"
)

type ObfsConfig struct {
	Enabled     bool
	MinPadding  int
	MaxPadding  int
	MinDelayMS  int
	MaxDelayMS  int
	BurstChance int // فعلاً استفاده نمی‌کنیم
}

// ApplyObfuscation: [2 bytes padLen][data][padding]
func ApplyObfuscation(data []byte, cfg *ObfsConfig) []byte {
	if cfg == nil || !cfg.Enabled {
		return data
	}

	pad := cfg.MinPadding
	if cfg.MaxPadding > cfg.MinPadding {
		pad = cfg.MinPadding + int(randomByte())%(cfg.MaxPadding-cfg.MinPadding+1)
	}

	out := make([]byte, 2+len(data)+pad)
	binary.BigEndian.PutUint16(out[:2], uint16(pad))
	copy(out[2:], data)

	if pad > 0 {
		padding := out[2+len(data):]
		_, _ = rand.Read(padding)
	}

	return out
}

func StripObfuscation(data []byte, cfg *ObfsConfig) []byte {
	if cfg == nil || !cfg.Enabled {
		return data
	}
	if len(data) < 2 {
		return nil
	}
	pad := int(binary.BigEndian.Uint16(data[:2]))
	body := data[2:]
	if pad < 0 || pad > len(body) {
		return nil
	}
	return body[:len(body)-pad]
}

func ApplyDelay(cfg *ObfsConfig) {
	if cfg == nil {
		return
	}
	if cfg.MaxDelayMS <= 0 {
		return
	}
	min := cfg.MinDelayMS
	max := cfg.MaxDelayMS
	if max < min {
		max = min
	}
	d := min
	if max > min {
		d = min + int(randomByte())%(max-min+1)
	}
	time.Sleep(time.Duration(d) * time.Millisecond)
}

func randomByte() byte {
	b := make([]byte, 1)
	_, _ = rand.Read(b)
	return b[0]
}
