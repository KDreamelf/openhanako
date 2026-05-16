package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadHCLConfig(t *testing.T) {
	tmpDir := t.TempDir()
	path := filepath.Join(tmpDir, "config.hcl")
	err := os.WriteFile(path, []byte(`
database "auth" {
  driver = "postgres"
  dsn    = "host=localhost port=5432 user=hanako password=test dbname=hanako_auth sslmode=disable"
}

redis "auth" {
  url = "redis://localhost:6379/0"
}

server "auth_gateway" {
  listen       = ":8080"
  admin_token  = "auth-admin"
  public_base_url = "https://auth.example"
  cors_origins = ["https://app.example"]
}

server "auth_gateway_mtls" {
  listen       = ":8443"
  admin_token  = "internal-admin"
  cors_origins = ["https://ai.example"]

  tls {
    enabled             = true
    cert_file           = "/etc/ph01/certs/auth-center.pem"
    key_file            = "/etc/ph01/certs/auth-center-key.pem"
    client_ca_file      = "/etc/ph01/certs/root-ca.pem"
    require_client_cert = true
  }
}

smtp "recovery" {
  enabled  = true
  host     = "smtp.example.com"
  port     = 587
  username = "noreply@example.com"
  password = "smtp-secret"
  from     = "Hanako <noreply@example.com>"
  tls_mode = "require_starttls"
}

ai_gateway_sync "default" {
  enabled        = true
  base_url       = "https://ph01-ai-gateway:3000"
  internal_token = "sync-secret"
  timeout_ms     = 7000
}

user_pow "default" {
  difficulty_bits = 4
  memory_kib      = 1048576
  round_count     = 2
  ttl_seconds     = 600
}
`), 0o600)
	if err != nil {
		t.Fatal(err)
	}

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if got := cfg.Databases["auth"].Driver; got != "postgres" {
		t.Fatalf("database auth driver = %q", got)
	}
	if got := cfg.Redis["auth"].URL; got != "redis://localhost:6379/0" {
		t.Fatalf("redis auth url = %q", got)
	}
	if got := cfg.Servers["auth_gateway"].CORSOrigins[0]; got != "https://app.example" {
		t.Fatalf("server auth_gateway cors = %q", got)
	}
	if got := cfg.Servers["auth_gateway"].PublicBase; got != "https://auth.example" {
		t.Fatalf("server auth_gateway public_base_url = %q", got)
	}
	if got := cfg.Servers["auth_gateway_mtls"].TLS.CertFile; got != "/etc/ph01/certs/auth-center.pem" {
		t.Fatalf("server auth_gateway_mtls tls cert_file = %q", got)
	}
	if !cfg.Servers["auth_gateway_mtls"].TLS.RequireClientCert {
		t.Fatal("server auth_gateway_mtls tls require_client_cert = false")
	}
	if got := cfg.SMTP["recovery"].Host; got != "smtp.example.com" {
		t.Fatalf("smtp recovery host = %q", got)
	}
	if got := cfg.SMTP["recovery"].TLSMode; got != "require_starttls" {
		t.Fatalf("smtp recovery tls_mode = %q", got)
	}
	if got := cfg.AIGatewaySync["default"].BaseURL; got != "https://ph01-ai-gateway:3000" {
		t.Fatalf("ai gateway sync base_url = %q", got)
	}
	if got := cfg.AIGatewaySync["default"].TimeoutMS; got != 7000 {
		t.Fatalf("ai gateway sync timeout_ms = %d", got)
	}
	if got := cfg.UserPow["default"].DifficultyBits; got != 4 {
		t.Fatalf("user pow difficulty_bits = %d", got)
	}
	if got := cfg.UserPow["default"].MemoryKiB; got != 1048576 {
		t.Fatalf("user pow memory_kib = %d", got)
	}
	if got := cfg.UserPow["default"].RoundCount; got != 2 {
		t.Fatalf("user pow round_count = %d", got)
	}
	if got := cfg.UserPow["default"].TTLSeconds; got != 600 {
		t.Fatalf("user pow ttl_seconds = %d", got)
	}
}

func TestUpdateSMTPBlock(t *testing.T) {
	tmpDir := t.TempDir()
	path := filepath.Join(tmpDir, "config.hcl")
	err := os.WriteFile(path, []byte(`
database "auth" {
  driver = "postgres"
  dsn    = "host=localhost port=5432 user=hanako password=test dbname=hanako_auth sslmode=disable"
}

smtp "recovery" {
  enabled  = false
  host     = "smtp.example.com"
  port     = 587
  username = "old@example.com"
  password = "old-secret"
  from     = "PH01 <old@example.com>"
  tls_mode = "require_starttls"
}
`), 0o600)
	if err != nil {
		t.Fatal(err)
	}

	err = UpdateSMTPBlock(path, &SMTP{
		Name:     "recovery",
		Enabled:  true,
		Host:     "smtp.mail.example",
		Port:     465,
		Username: "noreply@example.com",
		Password: "new-secret",
		From:     "PH01 <noreply@example.com>",
		TLSMode:  "tls",
	})
	if err != nil {
		t.Fatalf("update smtp: %v", err)
	}

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	smtp := cfg.SMTP["recovery"]
	if smtp == nil {
		t.Fatal("smtp recovery block missing")
	}
	if !smtp.Enabled || smtp.Host != "smtp.mail.example" || smtp.Port != 465 || smtp.TLSMode != "tls" {
		t.Fatalf("unexpected smtp after update: %+v", smtp)
	}
	if smtp.Password != "new-secret" {
		t.Fatalf("smtp password = %q", smtp.Password)
	}
}
