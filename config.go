package httpmux

import (
	"os"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Mode           string `yaml:"mode"`   // server|client
	Listen         string `yaml:"listen"` // server listen, e.g. 0.0.0.0:1010
	ServerURL      string `yaml:"server_url"`
	SessionID      string `yaml:"session_id"`
	SessionTimeout int    `yaml:"session_timeout"`
	PSK            string `yaml:"psk"`

	Mimic MimicConfig `yaml:"mimic"`
	Obfs  ObfsConfig  `yaml:"obfs"`

	Forward struct {
		TCP []string `yaml:"tcp"` // e.g. ["1412->127.0.0.1:1412"] or ["0.0.0.0:443->127.0.0.1:22"]
		UDP []string `yaml:"udp"`
	} `yaml:"forward"`
}

func LoadConfig(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Config
	if err := yaml.Unmarshal(b, &c); err != nil {
		return nil, err
	}
	return &c, nil
}
