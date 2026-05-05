// Package config 解析 P2P Authority 的 HCL 配置。
package config

import (
	"fmt"
	"os"

	"github.com/hashicorp/hcl/v2/hclsimple"
)

type Config struct {
	RootKey RootKey
	Servers map[string]*Server
}

type fileConfig struct {
	RootKeys []*RootKey `hcl:"root_key,block"`
	Servers  []*Server  `hcl:"server,block"`
}

type RootKey struct {
	KeyID            string `hcl:"key_id"`
	PrivateKeyHex    string `hcl:"private_key_hex,optional"`
	PrivateKeyHexEnv string `hcl:"private_key_hex_env,optional"`
}

type Server struct {
	Name        string   `hcl:",label"`
	Listen      string   `hcl:"listen"`
	AdminToken  string   `hcl:"admin_token"`
	CORSOrigins []string `hcl:"cors_origins,optional"`
}

func Load(path string) (*Config, error) {
	var raw fileConfig
	if err := hclsimple.DecodeFile(path, nil, &raw); err != nil {
		return nil, fmt.Errorf("decode hcl: %w", err)
	}
	if len(raw.RootKeys) != 1 {
		return nil, fmt.Errorf("expected exactly one root_key block, got %d", len(raw.RootKeys))
	}
	root := *raw.RootKeys[0]
	if root.PrivateKeyHex == "" && root.PrivateKeyHexEnv != "" {
		root.PrivateKeyHex = os.Getenv(root.PrivateKeyHexEnv)
	}
	if root.KeyID == "" {
		return nil, fmt.Errorf("root_key.key_id is required")
	}
	if root.PrivateKeyHex == "" {
		return nil, fmt.Errorf("root private key is required via private_key_hex or private_key_hex_env")
	}

	cfg := &Config{
		RootKey: root,
		Servers: map[string]*Server{},
	}
	for _, item := range raw.Servers {
		if _, exists := cfg.Servers[item.Name]; exists {
			return nil, fmt.Errorf("duplicate server block: %s", item.Name)
		}
		cfg.Servers[item.Name] = item
	}
	return cfg, nil
}
