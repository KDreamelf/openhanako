// Package db GORM 初始化。支持 PostgreSQL 与 SQLite（测试用）。
package db

import (
	"fmt"

	"github.com/glebarez/sqlite"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// Open 根据 driver 打开数据库。
//   - driver="postgres": dsn 形如 "host=... port=5432 user=... password=... dbname=... sslmode=..."
//   - driver="sqlite": dsn 形如 "data/auth.db" 或 ":memory:"
func Open(driver, dsn string) (*gorm.DB, error) {
	var dialector gorm.Dialector
	switch driver {
	case "postgres":
		dialector = postgres.Open(dsn)
	case "sqlite":
		dialector = sqlite.Open(dsn)
	default:
		return nil, fmt.Errorf("unsupported driver: %s", driver)
	}

	db, err := gorm.Open(dialector, &gorm.Config{
		Logger: logger.Default.LogMode(logger.Warn),
	})
	if err != nil {
		return nil, fmt.Errorf("gorm open: %w", err)
	}

	// SQLite 优化（PG 不需要）
	if driver == "sqlite" {
		if err := db.Exec("PRAGMA journal_mode = DELETE").Error; err != nil {
			return nil, err
		}
		if err := db.Exec("PRAGMA synchronous = NORMAL").Error; err != nil {
			return nil, err
		}
	}

	return db, nil
}
