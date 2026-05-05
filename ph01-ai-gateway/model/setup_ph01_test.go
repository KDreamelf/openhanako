package model

import (
	"testing"

	"github.com/QuantumNous/new-api/constant"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func TestCheckSetupMarksPH01DeploymentInitializedWithoutGatewayRoot(t *testing.T) {
	oldDB := DB
	oldLogDB := LOG_DB
	oldSetup := constant.Setup
	t.Cleanup(func() {
		DB = oldDB
		LOG_DB = oldLogDB
		constant.Setup = oldSetup
	})
	t.Setenv("PH01_AUTH_BASE_URL", "https://ph01-auth-center:8443")

	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	DB = db
	LOG_DB = db
	constant.Setup = false
	if err := db.AutoMigrate(&User{}, &Setup{}); err != nil {
		t.Fatal(err)
	}

	CheckSetup()
	if !constant.Setup {
		t.Fatalf("expected PH01 gateway setup to be initialized")
	}
	if setup := GetSetup(); setup == nil {
		t.Fatalf("expected setup record to be created")
	}

	var userCount int64
	if err := db.Model(&User{}).Count(&userCount).Error; err != nil {
		t.Fatal(err)
	}
	if userCount != 0 {
		t.Fatalf("expected no local gateway root bootstrap, got %d users", userCount)
	}
}
