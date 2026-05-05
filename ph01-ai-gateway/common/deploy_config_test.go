package common

import (
	"os"
	"path/filepath"
	"testing"
)

func TestApplyDeploymentConfig(t *testing.T) {
	oldPort := *Port
	oldLogDir := *LogDir
	defer func() {
		*Port = oldPort
		*LogDir = oldLogDir
	}()

	tmpDir := t.TempDir()
	path := filepath.Join(tmpDir, "ai-gateway.yaml")
	err := os.WriteFile(path, []byte(`
server:
  port: 3100
  log_dir: /tmp/ph01-logs
  node_name: test-node
database:
  sql_dsn: postgresql://user:pass@postgres:5432/ph01_ai?sslmode=require
redis:
  conn_string: redis://:pass@redis:6379/1
  pool_size: 12
security:
  session_secret: test-session-secret
  crypto_secret: test-crypto-secret
  trust_proxy_headers: true
runtime:
  memory_cache_enabled: true
  error_log_enabled: true
  generate_default_token: false
ph01_auth:
  base_url: https://ph01-auth-center:8443
  ca_cert: /etc/ph01/certs/root-ca.pem
  client_cert: /etc/ph01/certs/ai-gateway.pem
  client_key: /etc/ph01/certs/ai-gateway-key.pem
  server_name: ph01-auth-center
`), 0o600)
	if err != nil {
		t.Fatal(err)
	}

	for _, key := range []string{
		"SQL_DSN",
		"REDIS_CONN_STRING",
		"PH01_AUTH_CLIENT_KEY",
		"PH01_TRUST_PROXY_HEADERS",
		"GENERATE_DEFAULT_TOKEN",
	} {
		t.Setenv(key, "")
	}
	if err := ApplyDeploymentConfig(path); err != nil {
		t.Fatalf("apply deployment config: %v", err)
	}

	if got := os.Getenv("SQL_DSN"); got != "postgresql://user:pass@postgres:5432/ph01_ai?sslmode=require" {
		t.Fatalf("SQL_DSN = %q", got)
	}
	if got := os.Getenv("REDIS_CONN_STRING"); got != "redis://:pass@redis:6379/1" {
		t.Fatalf("REDIS_CONN_STRING = %q", got)
	}
	if got := os.Getenv("PH01_AUTH_CLIENT_KEY"); got != "/etc/ph01/certs/ai-gateway-key.pem" {
		t.Fatalf("PH01_AUTH_CLIENT_KEY = %q", got)
	}
	if got := os.Getenv("PH01_TRUST_PROXY_HEADERS"); got != "true" {
		t.Fatalf("PH01_TRUST_PROXY_HEADERS = %q", got)
	}
	if got := os.Getenv("GENERATE_DEFAULT_TOKEN"); got != "false" {
		t.Fatalf("GENERATE_DEFAULT_TOKEN = %q", got)
	}
	if *Port != 3100 {
		t.Fatalf("Port = %d", *Port)
	}
	if *LogDir != "/tmp/ph01-logs" {
		t.Fatalf("LogDir = %q", *LogDir)
	}
}
