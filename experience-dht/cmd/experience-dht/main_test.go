package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadConfigReadsYAMLWithComments(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.yml")
	data := []byte(`
# 注释必须允许存在，部署包正式配置会依赖它降低理解成本。
listen: ":8091"
init_password: "secret"
`)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatalf("load config: %v", err)
	}

	if cfg.Listen != ":8091" || cfg.StatePath != "" {
		t.Fatalf("unexpected config: %+v", cfg)
	}
	if cfg.InitPassword != "secret" {
		t.Fatalf("unexpected init password: %q", cfg.InitPassword)
	}
}

func TestLoadConfigIgnoresStatePath(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.yml")
	data := []byte(`
listen: ":8091"
state_path: "/wrong/container/path/state.json"
init_password: "secret"
`)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatalf("load config: %v", err)
	}

	if cfg.StatePath != "" {
		t.Fatalf("state_path should not be read from config: %+v", cfg)
	}
}

func TestLoadConfigUsesEnvWhenConfigFileMissing(t *testing.T) {
	t.Setenv("EXPERIENCE_DHT_INIT_PASSWORD", "secret-from-env")
	t.Setenv("EXPERIENCE_DHT_LISTEN", ":18091")

	cfg, err := loadConfig(filepath.Join(t.TempDir(), "missing.yml"))
	if err != nil {
		t.Fatalf("load config: %v", err)
	}

	if cfg.Listen != ":18091" {
		t.Fatalf("unexpected listen: %q", cfg.Listen)
	}
	if cfg.InitPassword != "secret-from-env" {
		t.Fatalf("unexpected init password: %q", cfg.InitPassword)
	}
}

func TestLoadConfigRejectsMissingConfigWithoutInitPasswordEnv(t *testing.T) {
	t.Setenv("EXPERIENCE_DHT_INIT_PASSWORD", "")

	_, err := loadConfig(filepath.Join(t.TempDir(), "missing.yml"))
	if err == nil {
		t.Fatal("expected missing config without env password to fail")
	}
}

func TestResolveStatePathUsesInternalContainerDir(t *testing.T) {
	dir := t.TempDir()

	if got := resolveStatePath(dir); got != filepath.Join(dir, containerStateFile) {
		t.Fatalf("unexpected container state path: %q", got)
	}
	if got := resolveStatePath(filepath.Join(t.TempDir(), "missing")); got != defaultStatePath {
		t.Fatalf("unexpected local state path: %q", got)
	}
}
