package model

import (
	"errors"
	"testing"

	"github.com/QuantumNous/new-api/common"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func TestFindOrCreateUserFromPH01(t *testing.T) {
	oldRedisEnabled := common.RedisEnabled
	oldUsingSQLite := common.UsingSQLite
	oldUsingMySQL := common.UsingMySQL
	oldUsingPostgreSQL := common.UsingPostgreSQL
	oldDB := DB
	oldLogDB := LOG_DB
	common.RedisEnabled = false
	common.UsingSQLite = true
	common.UsingMySQL = false
	common.UsingPostgreSQL = false
	initCol()
	t.Cleanup(func() {
		common.RedisEnabled = oldRedisEnabled
		common.UsingSQLite = oldUsingSQLite
		common.UsingMySQL = oldUsingMySQL
		common.UsingPostgreSQL = oldUsingPostgreSQL
		initCol()
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
	var commonUserTokenCount int64
	if err := db.Model(&Token{}).Where("user_id = ?", user1.Id).Count(&commonUserTokenCount).Error; err != nil {
		t.Fatal(err)
	}
	if commonUserTokenCount != 1 {
		t.Fatalf("expected non-root PH01 user to have only default token, got %d", commonUserTokenCount)
	}

	rootUser, _, err := FindOrCreateUserFromPH01(1, "root", "beef")
	if err != nil {
		t.Fatal(err)
	}
	if rootUser.Username != "root" || rootUser.Role != common.RoleRootUser {
		t.Fatalf("expected PH01 root to map to local root, got %+v", rootUser)
	}
	var rootTokens []Token
	if err := db.Where("user_id = ?", rootUser.Id).Find(&rootTokens).Error; err != nil {
		t.Fatal(err)
	}
	if len(rootTokens) != 2 {
		t.Fatalf("expected PH01 root to have default and public tokens, got %+v", rootTokens)
	}
	var publicToken Token
	if err := db.First(&publicToken, "user_id = ? AND name = ?", rootUser.Id, PH01PublicTokenName).Error; err != nil {
		t.Fatalf("expected PH01 public token: %v", err)
	}
	if publicToken.Status != common.TokenStatusEnabled || publicToken.ExpiredTime != -1 || !publicToken.UnlimitedQuota {
		t.Fatalf("unexpected PH01 public token: %+v", publicToken)
	}
	if _, err := ValidateUserToken(publicToken.Key); !errors.Is(err, ErrTokenInvalid) {
		t.Fatalf("expected PH01 public token to be rejected as an API credential, got %v", err)
	}
	if err := db.Delete(&publicToken).Error; err != nil {
		t.Fatal(err)
	}
	if err := EnsurePH01RootManagedTokens(); err != nil {
		t.Fatal(err)
	}
	var activePublicTokenCount int64
	if err := db.Model(&Token{}).Where("user_id = ? AND name = ?", rootUser.Id, PH01PublicTokenName).Count(&activePublicTokenCount).Error; err != nil {
		t.Fatal(err)
	}
	if activePublicTokenCount != 1 {
		t.Fatalf("expected PH01 root public token to be backfilled, got %d", activePublicTokenCount)
	}
}
