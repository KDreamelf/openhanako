// Package config HCL 配置文件解析。
//
// 配置文件格式（config.hcl）：
//
//	database "auth" {
//	  driver = "postgres"
//	  dsn    = "host=localhost port=5432 user=hanako password=xxx dbname=auth_db sslmode=disable"
//	}
//
//	redis "auth" {
//	  url = "redis://localhost:6379/0"
//	}
//
//	server "auth_gateway" {
//	  listen       = ":8080"
//	  admin_token  = "..."
//	  public_base_url = "https://auth.xn--lbtx0e.cn"
//	  cors_origins = ["*"]
//	}
//
//	smtp "recovery" {
//	  enabled   = true
//	  host      = "smtp.example.com"
//	  port      = 587
//	  username  = "noreply@example.com"
//	  password  = "..."
//	  from      = "Hanako <noreply@example.com>"
//	  tls_mode  = "require_starttls"
//	}
//
//	ai_gateway_sync "default" {
//	  enabled        = true
//	  base_url       = "https://ph01-ai-gateway:3000"
//	  internal_token = "..."
//	  timeout_ms     = 5000
//	}
//
//	user_pow "default" {
//	  difficulty_bits = 4
//	  memory_kib      = 1048576
//	  round_count     = 2
//	  ttl_seconds     = 600
//	}
package config

import (
	"fmt"

	"github.com/hashicorp/hcl/v2/hclsimple"
)

type Config struct {
	Databases     map[string]*Database
	Redis         map[string]*Redis
	Servers       map[string]*Server
	SMTP          map[string]*SMTP
	AIGatewaySync map[string]*AIGatewaySync
	UserPow       map[string]*UserPow
}

type fileConfig struct {
	Databases     []*Database      `hcl:"database,block"`
	Redis         []*Redis         `hcl:"redis,block"`
	Servers       []*Server        `hcl:"server,block"`
	SMTP          []*SMTP          `hcl:"smtp,block"`
	AIGatewaySync []*AIGatewaySync `hcl:"ai_gateway_sync,block"`
	UserPow       []*UserPow       `hcl:"user_pow,block"`
}

type Database struct {
	Name   string `hcl:",label"`
	Driver string `hcl:"driver"`
	DSN    string `hcl:"dsn"`
}

type Redis struct {
	Name string `hcl:",label"`
	URL  string `hcl:"url"`
}

type Server struct {
	Name        string   `hcl:",label"`
	Listen      string   `hcl:"listen"`
	JWTSecret   string   `hcl:"jwt_secret,optional"` // deprecated: ignored, only for old local config compatibility
	AdminToken  string   `hcl:"admin_token"`
	AuthBase    string   `hcl:"auth_base,optional"`
	PublicBase  string   `hcl:"public_base_url,optional"`
	CORSOrigins []string `hcl:"cors_origins,optional"`
	TLS         *TLS     `hcl:"tls,block"`
}

type TLS struct {
	Enabled           bool   `hcl:"enabled,optional"`
	CertFile          string `hcl:"cert_file,optional"`
	KeyFile           string `hcl:"key_file,optional"`
	ClientCAFile      string `hcl:"client_ca_file,optional"`
	RequireClientCert bool   `hcl:"require_client_cert,optional"`
}

// SMTP 配置用于 auth-gateway 发注册与恢复验证码。
//
// TLSMode:
//   - "require_starttls"：STARTTLS，固定 587 端口。
//   - "tls"：SSL / 隐式 TLS，固定 465 端口。
//
// 兼容旧配置里的 "starttls"，会按 "require_starttls" 处理；不支持明文 SMTP。
type SMTP struct {
	Name     string `hcl:",label"`
	Enabled  bool   `hcl:"enabled,optional"`
	Host     string `hcl:"host"`
	Port     int    `hcl:"port,optional"`
	Username string `hcl:"username,optional"`
	Password string `hcl:"password,optional"`
	From     string `hcl:"from"`
	TLSMode  string `hcl:"tls_mode,optional"`
}

type AIGatewaySync struct {
	Name          string `hcl:",label"`
	Enabled       bool   `hcl:"enabled,optional"`
	BaseURL       string `hcl:"base_url"`
	InternalToken string `hcl:"internal_token,optional"`
	TimeoutMS     int    `hcl:"timeout_ms,optional"`
}

type UserPow struct {
	Name           string `hcl:",label"`
	DifficultyBits int    `hcl:"difficulty_bits,optional"`
	MemoryKiB      int    `hcl:"memory_kib,optional"`
	RoundCount     int    `hcl:"round_count,optional"`
	TTLSeconds     int    `hcl:"ttl_seconds,optional"`
}

func Load(path string) (*Config, error) {
	var raw fileConfig
	if err := hclsimple.DecodeFile(path, nil, &raw); err != nil {
		return nil, fmt.Errorf("decode hcl: %w", err)
	}
	cfg := &Config{
		Databases:     map[string]*Database{},
		Redis:         map[string]*Redis{},
		Servers:       map[string]*Server{},
		SMTP:          map[string]*SMTP{},
		AIGatewaySync: map[string]*AIGatewaySync{},
		UserPow:       map[string]*UserPow{},
	}
	for _, item := range raw.Databases {
		if _, exists := cfg.Databases[item.Name]; exists {
			return nil, fmt.Errorf("duplicate database block: %s", item.Name)
		}
		cfg.Databases[item.Name] = item
	}
	for _, item := range raw.Redis {
		if _, exists := cfg.Redis[item.Name]; exists {
			return nil, fmt.Errorf("duplicate redis block: %s", item.Name)
		}
		cfg.Redis[item.Name] = item
	}
	for _, item := range raw.Servers {
		if _, exists := cfg.Servers[item.Name]; exists {
			return nil, fmt.Errorf("duplicate server block: %s", item.Name)
		}
		cfg.Servers[item.Name] = item
	}
	for _, item := range raw.SMTP {
		if _, exists := cfg.SMTP[item.Name]; exists {
			return nil, fmt.Errorf("duplicate smtp block: %s", item.Name)
		}
		cfg.SMTP[item.Name] = item
	}
	for _, item := range raw.AIGatewaySync {
		if _, exists := cfg.AIGatewaySync[item.Name]; exists {
			return nil, fmt.Errorf("duplicate ai_gateway_sync block: %s", item.Name)
		}
		cfg.AIGatewaySync[item.Name] = item
	}
	for _, item := range raw.UserPow {
		if _, exists := cfg.UserPow[item.Name]; exists {
			return nil, fmt.Errorf("duplicate user_pow block: %s", item.Name)
		}
		cfg.UserPow[item.Name] = item
	}
	return cfg, nil
}
