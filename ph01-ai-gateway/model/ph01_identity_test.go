package model

import (
	"testing"

	"github.com/QuantumNous/new-api/common"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func TestFindOrCreateUserFromPH01(t *testing.T) {
	oldRedisEnabled := common.RedisEnabled
	oldDB := DB
	oldLogDB := LOG_DB
	common.RedisEnabled = false
	t.Cleanup(func() {
		common.RedisEnabled = oldRedisEnabled
		DB = oldDB
		LOG_DB = oldLogDB
	})

	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	DB = db
	LOG_DB = db
	if err := db.AutoMigrate(&User{}, &Token{}, &PH01Identity{}); err != nil {
		t.Fatal(err)
	}

	user1, identity1, err := FindOrCreateUserFromPH01(12345, "angel", "ABCDEF")
	if err != nil {
		t.Fatal(err)
	}
	if user1.Id == 0 || identity1.UserId != user1.Id {
		t.Fatalf("unexpected mapping user=%+v identity=%+v", user1, identity1)
	}
	if user1.Username != "angel" {
		t.Fatalf("unexpected synced username: %s", user1.Username)
	}
	if identity1.PubkeyHash != "abcdef" {
		t.Fatalf("expected normalized hash, got %s", identity1.PubkeyHash)
	}

	user2, identity2, err := FindOrCreateUserFromPH01(12345, "angel-new", "1234")
	if err != nil {
		t.Fatal(err)
	}
	if user2.Id != user1.Id || identity2.UserId != user1.Id {
		t.Fatalf("expected existing mapping, got user=%+v identity=%+v", user2, identity2)
	}
	if identity2.PH01Username != "angel-new" || identity2.PubkeyHash != "1234" {
		t.Fatalf("expected updated identity, got %+v", identity2)
	}

	var token Token
	if err := db.First(&token, "user_id = ? AND name = ?", user1.Id, PH01DefaultTokenName).Error; err != nil {
		t.Fatalf("expected PH01 default token: %v", err)
	}
	if token.Status != common.TokenStatusEnabled || token.ExpiredTime != -1 || !token.UnlimitedQuota {
		t.Fatalf("unexpected PH01 default token: %+v", token)
	}

	rootUser, _, err := FindOrCreateUserFromPH01(1, "root", "beef")
	if err != nil {
		t.Fatal(err)
	}
	if rootUser.Username != "root" || rootUser.Role != common.RoleRootUser {
		t.Fatalf("expected PH01 root to map to local root, got %+v", rootUser)
	}
}
