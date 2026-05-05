package model

import (
	"errors"
	"strings"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/setting"
	"gorm.io/gorm"
)

const PH01DefaultTokenName = "PH01 Default Key"

type PH01Identity struct {
	Id           int    `json:"id"`
	UserId       int    `json:"user_id" gorm:"uniqueIndex;not null"`
	PH01UserID   uint64 `json:"ph01_user_id" gorm:"uniqueIndex;not null"`
	PH01Username string `json:"ph01_username" gorm:"size:64;index"`
	PubkeyHash   string `json:"pubkey_hash" gorm:"size:64;index"`
	CreatedAt    int64  `json:"created_at" gorm:"autoCreateTime;column:created_at"`
	UpdatedAt    int64  `json:"updated_at" gorm:"autoUpdateTime;column:updated_at"`
}

func FindOrCreateUserFromPH01(ph01UserID uint64, ph01Username string, pubkeyHash string) (*User, *PH01Identity, error) {
	if ph01UserID == 0 {
		return nil, nil, errors.New("ph01 user id is empty")
	}
	ph01Username = strings.TrimSpace(ph01Username)
	pubkeyHash = strings.ToLower(strings.TrimSpace(pubkeyHash))

	var user User
	var identity PH01Identity
	created := false
	err := DB.Transaction(func(tx *gorm.DB) error {
		err := tx.Where("ph01_user_id = ?", ph01UserID).First(&identity).Error
		if err == nil {
			if err := tx.First(&user, "id = ?", identity.UserId).Error; err != nil {
				return err
			}
			if err := syncPH01UserFields(tx, &user, ph01Username); err != nil {
				return err
			}
			identity.PH01Username = ph01Username
			identity.PubkeyHash = pubkeyHash
			if err := tx.Model(&identity).Updates(map[string]any{
				"ph01_username": ph01Username,
				"pubkey_hash":   pubkeyHash,
			}).Error; err != nil {
				return err
			}
			return ensurePH01DefaultTokenWithTx(tx, user.Id)
		}
		if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}

		user, created, err = findOrCreateGatewayUserWithTx(tx, ph01Username)
		if err != nil {
			return err
		}
		identity = PH01Identity{
			UserId:       user.Id,
			PH01UserID:   ph01UserID,
			PH01Username: ph01Username,
			PubkeyHash:   pubkeyHash,
		}
		if err := tx.Create(&identity).Error; err != nil {
			return err
		}
		return ensurePH01DefaultTokenWithTx(tx, user.Id)
	})
	if err != nil {
		return nil, nil, err
	}
	if created {
		user.FinalizeOAuthUserCreation(0)
	}
	return &user, &identity, nil
}

func GetPH01IdentityByUserID(userID int) (*PH01Identity, error) {
	if userID <= 0 {
		return nil, errors.New("user id is empty")
	}
	var identity PH01Identity
	if err := DB.First(&identity, "user_id = ?", userID).Error; err != nil {
		return nil, err
	}
	return &identity, nil
}

func IsPH01User(userID int) bool {
	if userID <= 0 {
		return false
	}
	var count int64
	if err := DB.Model(&PH01Identity{}).Where("user_id = ?", userID).Count(&count).Error; err != nil {
		return false
	}
	return count > 0
}

func IsPH01DefaultToken(token *Token) bool {
	return token != nil && token.Name == PH01DefaultTokenName && IsPH01User(token.UserId)
}

func EnsurePH01DefaultToken(userID int) (*Token, error) {
	if userID <= 0 {
		return nil, errors.New("user id is empty")
	}
	if err := ensurePH01DefaultTokenWithTx(DB, userID); err != nil {
		return nil, err
	}
	var token Token
	if err := DB.First(&token, "user_id = ? AND name = ?", userID, PH01DefaultTokenName).Error; err != nil {
		return nil, err
	}
	return &token, nil
}

func findOrCreateGatewayUserWithTx(tx *gorm.DB, ph01Username string) (User, bool, error) {
	username, err := normalizePH01GatewayUsername(ph01Username)
	if err != nil {
		return User{}, false, err
	}

	var user User
	if err := tx.First(&user, "username = ?", username).Error; err == nil {
		if err := syncPH01UserFields(tx, &user, ph01Username); err != nil {
			return user, false, err
		}
		return user, false, nil
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		return user, false, err
	}

	user = User{
		Username:    username,
		Password:    common.GetRandomString(32),
		DisplayName: normalizePH01DisplayName(ph01Username, username),
		Role:        common.RoleCommonUser,
		Status:      common.UserStatusEnabled,
		Group:       "default",
	}
	if isPH01RootUsername(ph01Username) {
		user.Role = common.RoleRootUser
	}
	if err := user.InsertWithTx(tx, 0); err != nil {
		return user, false, err
	}
	return user, true, nil
}

func syncPH01UserFields(tx *gorm.DB, user *User, ph01Username string) error {
	updates := map[string]any{}
	username, err := normalizePH01GatewayUsername(ph01Username)
	if err != nil {
		return err
	}
	if user.Username != username {
		updates["username"] = username
		user.Username = username
	}
	if displayName := normalizePH01DisplayName(ph01Username, user.Username); displayName != user.DisplayName {
		updates["display_name"] = displayName
		user.DisplayName = displayName
	}
	if isPH01RootUsername(ph01Username) && user.Role != common.RoleRootUser {
		updates["role"] = common.RoleRootUser
		user.Role = common.RoleRootUser
	}
	if len(updates) == 0 {
		return nil
	}
	return tx.Model(user).Updates(updates).Error
}

func ensurePH01DefaultTokenWithTx(tx *gorm.DB, userID int) error {
	var token Token
	err := tx.First(&token, "user_id = ? AND name = ?", userID, PH01DefaultTokenName).Error
	if err == nil {
		updates := map[string]any{}
		if token.Status != common.TokenStatusEnabled {
			updates["status"] = common.TokenStatusEnabled
		}
		if token.ExpiredTime != -1 {
			updates["expired_time"] = -1
		}
		if !token.UnlimitedQuota {
			updates["unlimited_quota"] = true
		}
		if len(updates) == 0 {
			return nil
		}
		return tx.Model(&token).Updates(updates).Error
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return err
	}

	key, err := common.GenerateKey()
	if err != nil {
		return err
	}
	group := "default"
	if setting.DefaultUseAutoGroup {
		group = "auto"
	}
	token = Token{
		UserId:             userID,
		Name:               PH01DefaultTokenName,
		Key:                key,
		Status:             common.TokenStatusEnabled,
		CreatedTime:        common.GetTimestamp(),
		AccessedTime:       common.GetTimestamp(),
		ExpiredTime:        -1,
		UnlimitedQuota:     true,
		ModelLimitsEnabled: false,
		Group:              group,
	}
	return tx.Create(&token).Error
}

func isPH01RootUsername(name string) bool {
	return strings.EqualFold(strings.TrimSpace(name), "root")
}

func normalizePH01GatewayUsername(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", errors.New("ph01 username is empty")
	}
	runes := []rune(name)
	if len(runes) > UserNameMaxLength {
		return "", errors.New("ph01 username is too long for gateway user")
	}
	return name, nil
}

func normalizePH01DisplayName(name string, fallback string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		name = fallback
	}
	runes := []rune(name)
	if len(runes) > UserNameMaxLength {
		runes = runes[:UserNameMaxLength]
	}
	return string(runes)
}
