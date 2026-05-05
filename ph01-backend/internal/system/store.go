// Package system 保存认证中心管理审计日志，并读取 / 回写配置文件。
package system

import (
	"errors"
	"strings"
	"time"

	"github.com/hanako/ph01-backend/internal/config"
	"gorm.io/gorm"
)

type AuditLog struct {
	ID            uint64    `gorm:"primaryKey;autoIncrement"`
	ActorID       uint64    `gorm:"index"`
	ActorUsername string    `gorm:"size:64;index"`
	ActorRole     string    `gorm:"size:16"`
	Action        string    `gorm:"size:64;index;not null"`
	Target        string    `gorm:"size:128;index"`
	Detail        string    `gorm:"type:text"`
	CreatedAt     time.Time `gorm:"index"`
}

type AuditActor struct {
	ID       uint64
	Username string
	Role     string
}

type SMTPSettings struct {
	Enabled  bool   `json:"enabled"`
	Host     string `json:"host"`
	Port     int    `json:"port"`
	Username string `json:"username"`
	Password string `json:"password"`
	From     string `json:"from"`
	TLSMode  string `json:"tls_mode"`
}

type Store struct {
	DB         *gorm.DB
	ConfigPath string
}

func AutoMigrate(db *gorm.DB) error {
	if err := db.AutoMigrate(&AuditLog{}); err != nil {
		return err
	}
	if db.Migrator().HasTable("options") {
		return db.Migrator().DropTable("options")
	}
	return nil
}

func NewStore(db *gorm.DB, configPath ...string) *Store {
	s := &Store{DB: db}
	if len(configPath) > 0 {
		s.ConfigPath = configPath[0]
	}
	return s
}

func SMTPSettingsFromConfig(cfg *config.SMTP) SMTPSettings {
	if cfg == nil {
		return defaultSMTPSettings()
	}
	settings := SMTPSettings{
		Enabled:  cfg.Enabled,
		Host:     strings.TrimSpace(cfg.Host),
		Port:     cfg.Port,
		Username: strings.TrimSpace(cfg.Username),
		Password: cfg.Password,
		From:     strings.TrimSpace(cfg.From),
		TLSMode:  strings.TrimSpace(cfg.TLSMode),
	}
	normalizeSMTPSettings(&settings)
	return settings
}

func (s *Store) GetSMTPSettings() (SMTPSettings, error) {
	settings := defaultSMTPSettings()
	if s == nil || strings.TrimSpace(s.ConfigPath) == "" {
		return settings, nil
	}
	cfg, err := config.Load(s.ConfigPath)
	if err != nil {
		return settings, err
	}
	return SMTPSettingsFromConfig(cfg.SMTP["recovery"]), nil
}

func (s *Store) SaveSMTPSettings(settings SMTPSettings) error {
	if s == nil || strings.TrimSpace(s.ConfigPath) == "" {
		return errors.New("config path not configured")
	}
	normalizeSMTPSettings(&settings)
	return config.UpdateSMTPBlock(s.ConfigPath, SMTPSettingsToConfig("recovery", settings))
}

func SMTPSettingsToConfig(name string, settings SMTPSettings) *config.SMTP {
	return &config.SMTP{
		Name:     name,
		Enabled:  settings.Enabled,
		Host:     settings.Host,
		Port:     settings.Port,
		Username: settings.Username,
		Password: settings.Password,
		From:     settings.From,
		TLSMode:  settings.TLSMode,
	}
}

func (s *Store) AppendAudit(actor AuditActor, action, target, detail string) {
	if s == nil || s.DB == nil {
		return
	}
	action = strings.TrimSpace(action)
	if action == "" {
		return
	}
	log := AuditLog{
		ActorID:       actor.ID,
		ActorUsername: strings.TrimSpace(actor.Username),
		ActorRole:     strings.TrimSpace(actor.Role),
		Action:        action,
		Target:        strings.TrimSpace(target),
		Detail:        detail,
	}
	_ = s.DB.Create(&log).Error
}

func (s *Store) ListAuditLogs(page, pageSize int) ([]AuditLog, int64, error) {
	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 200 {
		pageSize = 50
	}
	var total int64
	if err := s.DB.Model(&AuditLog{}).Count(&total).Error; err != nil {
		return nil, 0, err
	}
	var items []AuditLog
	err := s.DB.Order("id desc").
		Offset((page - 1) * pageSize).
		Limit(pageSize).
		Find(&items).Error
	return items, total, err
}

func defaultSMTPSettings() SMTPSettings {
	return SMTPSettings{
		Port:    587,
		TLSMode: "require_starttls",
	}
}

func NormalizeSMTPSettings(settings *SMTPSettings) {
	normalizeSMTPSettings(settings)
}

func normalizeSMTPSettings(settings *SMTPSettings) {
	settings.Host = strings.TrimSpace(settings.Host)
	settings.Username = strings.TrimSpace(settings.Username)
	settings.From = strings.TrimSpace(settings.From)
	settings.TLSMode = strings.ToLower(strings.TrimSpace(settings.TLSMode))
	if settings.TLSMode == "" || settings.TLSMode == "starttls" {
		settings.TLSMode = "require_starttls"
	}
	if settings.Port == 0 {
		if settings.TLSMode == "tls" {
			settings.Port = 465
		} else {
			settings.Port = 587
		}
	}
}
