package system

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/hanako/ph01-backend/internal/db"
)

func TestAutoMigrateDropsLegacyOptionsTable(t *testing.T) {
	gormDB, err := db.Open("sqlite", filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("db open: %v", err)
	}
	t.Cleanup(func() {
		sqlDB, _ := gormDB.DB()
		if sqlDB != nil {
			_ = sqlDB.Close()
		}
	})
	if err := gormDB.Exec(`CREATE TABLE options (key text primary key, value text not null)`).Error; err != nil {
		t.Fatalf("create legacy options: %v", err)
	}
	if err := AutoMigrate(gormDB); err != nil {
		t.Fatalf("auto migrate: %v", err)
	}
	if gormDB.Migrator().HasTable("options") {
		t.Fatal("legacy options table should be dropped")
	}
	if !gormDB.Migrator().HasTable(&AuditLog{}) {
		t.Fatal("audit_logs table should exist")
	}
}

func TestSMTPSettingsUseConfigFileAsSource(t *testing.T) {
	tmpDir := t.TempDir()
	path := filepath.Join(tmpDir, "config.hcl")
	if err := os.WriteFile(path, []byte(`
smtp "recovery" {
  enabled  = false
  host     = "smtp.example.com"
  port     = 587
  username = "old@example.com"
  password = "old-secret"
  from     = "PH01 <old@example.com>"
  tls_mode = "require_starttls"
}
`), 0o600); err != nil {
		t.Fatal(err)
	}

	store := NewStore(nil, path)
	settings, err := store.GetSMTPSettings()
	if err != nil {
		t.Fatalf("get smtp: %v", err)
	}
	if settings.Host != "smtp.example.com" || settings.Port != 587 || settings.TLSMode != "require_starttls" {
		t.Fatalf("unexpected initial smtp settings: %+v", settings)
	}

	settings.Enabled = true
	settings.Host = "smtp.mail.example"
	settings.Port = 465
	settings.Username = "noreply@example.com"
	settings.Password = "new-secret"
	settings.From = "PH01 <noreply@example.com>"
	settings.TLSMode = "tls"
	if err := store.SaveSMTPSettings(settings); err != nil {
		t.Fatalf("save smtp: %v", err)
	}

	reloaded, err := store.GetSMTPSettings()
	if err != nil {
		t.Fatalf("reload smtp: %v", err)
	}
	if !reloaded.Enabled || reloaded.Host != "smtp.mail.example" || reloaded.Port != 465 || reloaded.TLSMode != "tls" {
		t.Fatalf("unexpected reloaded smtp settings: %+v", reloaded)
	}
	if reloaded.Password != "new-secret" {
		t.Fatalf("password = %q", reloaded.Password)
	}
}
