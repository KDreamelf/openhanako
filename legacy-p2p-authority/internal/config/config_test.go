package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadResolvesRootPrivateKeyFromEnv(t *testing.T) {
	t.Setenv("P2P_TEST_ROOT_KEY", "0000000000000000000000000000000000000000000000000000000000000001")

	tmpDir := t.TempDir()
	path := filepath.Join(tmpDir, "config.hcl")
	err := os.WriteFile(path, []byte(`
root_key {
  key_id              = "test-root"
  private_key_hex_env = "P2P_TEST_ROOT_KEY"
}

server "p2p_authority" {
  listen       = ":8082"
  admin_token  = "admin"
  cors_origins = ["https://app.example"]
}
`), 0o600)
	if err != nil {
		t.Fatal(err)
	}

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.RootKey.PrivateKeyHex != "0000000000000000000000000000000000000000000000000000000000000001" {
		t.Fatal("root private key was not resolved from env")
	}
	if cfg.Servers["p2p_authority"].Listen != ":8082" {
		t.Fatal("server block not decoded")
	}
}
