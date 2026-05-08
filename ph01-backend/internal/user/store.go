// Package user 用户与公钥的模型 + Store。
//
// 与 docs/protocol-spec.md §2 用户与公钥模型 对齐。
package user

import (
	"strconv"
	"strings"
	"time"

	"gorm.io/gorm"
)

// Tier 定义用户的等级，决定可用模型与限流。
type Tier string

const (
	TierFree       Tier = "free"
	TierPro        Tier = "pro"
	TierEnterprise Tier = "enterprise"
)

// Role 定义认证中心侧管理权限。普通业务身份仍然只看 UserID + 公钥。
type Role string

const (
	RoleUser  Role = "user"
	RoleAdmin Role = "admin"
	RoleRoot  Role = "root"
)

// User 用户主表。
type User struct {
	ID        uint64    `gorm:"primaryKey;autoIncrement" json:"id"`
	Username  string    `gorm:"uniqueIndex;size:32;not null" json:"username"`
	Nickname  string    `gorm:"size:64" json:"nickname"`
	Email     string    `gorm:"size:254;index" json:"email,omitempty"`
	Tier      string    `gorm:"size:16;default:'free';not null" json:"tier"`
	Role      string    `gorm:"size:16;default:'user';not null" json:"role"`
	Disabled  bool      `gorm:"default:false;not null" json:"disabled"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`

	Pubkeys []Pubkey `gorm:"foreignKey:UserID" json:"pubkeys,omitempty"`
}

// Pubkey 公钥表（一用户多公钥，支持轮换）。
type Pubkey struct {
	ID         uint64     `gorm:"primaryKey;autoIncrement" json:"id"`
	UserID     uint64     `gorm:"index;not null" json:"user_id"`
	PubkeyHex  string     `gorm:"size:130;not null" json:"pubkey_hex"`
	PubkeyHash string     `gorm:"size:64;uniqueIndex;not null" json:"pubkey_hash"`
	CreatedAt  time.Time  `json:"created_at"`
	RevokedAt  *time.Time `json:"revoked_at,omitempty"`

	User *User `gorm:"foreignKey:UserID" json:"-"`
}

// PubkeyBinding 是一条"用户 ID + 公钥哈希"绑定校验项。
type PubkeyBinding struct {
	UserID     uint64
	PubkeyHash string
}

// PubkeyBindingAt 是带签名时间的公钥绑定校验项。
type PubkeyBindingAt struct {
	UserID     uint64
	PubkeyHash string
	SignedAt   time.Time
}

// AutoMigrate 创建用户与公钥表（幂等）。
func AutoMigrate(db *gorm.DB) error {
	return db.AutoMigrate(&User{}, &Pubkey{})
}

// Store 用户/公钥业务接口。
type Store struct {
	DB *gorm.DB
}

func NewStore(db *gorm.DB) *Store {
	return &Store{DB: db}
}

// CreateWithPubkey 注册新用户：插入 user + 第一个 pubkey。
//
// 这里**不用 Transaction**——glebarez/sqlite 在 WAL 模式下嵌套事务有时
// 会因为 commit 时机导致后续 reader 看不到已写入数据。改成顺序 Create + 失败回滚，
// 重复用户名场景靠 username 的 UNIQUE 约束保证不会有半成品 user 留下。
func (s *Store) CreateWithPubkey(username, nickname, email, pubkeyHex, pubkeyHash string) (*User, error) {
	now := time.Now().UTC().Truncate(time.Second)
	u := User{
		Username: username,
		Nickname: nickname,
		Email:    email,
		Tier:     string(TierFree),
		Role:     string(defaultRoleForUsername(username)),
	}
	if err := s.DB.Create(&u).Error; err != nil {
		return nil, err
	}
	pk := Pubkey{
		UserID:     u.ID,
		PubkeyHex:  pubkeyHex,
		PubkeyHash: pubkeyHash,
		CreatedAt:  now,
	}
	if err := s.DB.Create(&pk).Error; err != nil {
		// pubkey 失败 → 回滚 user
		s.DB.Delete(&u)
		return nil, err
	}
	return s.GetByID(u.ID)
}

func defaultRoleForUsername(username string) Role {
	if IsPresetUsername(username) {
		return RoleRoot
	}
	return RoleUser
}

func IsPresetUsername(username string) bool {
	return strings.EqualFold(strings.TrimSpace(username), "root")
}

func NormalizeRole(role string) (Role, bool) {
	switch strings.ToLower(strings.TrimSpace(role)) {
	case "", string(RoleUser):
		return RoleUser, true
	case string(RoleAdmin):
		return RoleAdmin, true
	case string(RoleRoot):
		return RoleRoot, true
	default:
		return "", false
	}
}

func IsAdminRole(role string) bool {
	normalized, ok := NormalizeRole(role)
	return ok && (normalized == RoleAdmin || normalized == RoleRoot)
}

func IsRootRole(role string) bool {
	normalized, ok := NormalizeRole(role)
	return ok && normalized == RoleRoot
}

func NormalizeTier(tier string) (Tier, bool) {
	switch strings.ToLower(strings.TrimSpace(tier)) {
	case "", string(TierFree):
		return TierFree, true
	case string(TierPro):
		return TierPro, true
	case string(TierEnterprise):
		return TierEnterprise, true
	default:
		return "", false
	}
}

// GetByID 取用户（含未撤销公钥）。
func (s *Store) GetByID(id uint64) (*User, error) {
	var u User
	err := s.DB.Preload("Pubkeys",
		"revoked_at IS NULL",
	).First(&u, id).Error
	if err != nil {
		return nil, err
	}
	return &u, nil
}

// GetByIDWithAllPubkeys 取用户并加载全部历史公钥。
//
// 仅用于管理展示和审计；登录/验签路径应继续使用 GetByID / GetByPubkeyHash，
// 保证只接受当前有效公钥。
func (s *Store) GetByIDWithAllPubkeys(id uint64) (*User, error) {
	var u User
	err := s.DB.Preload("Pubkeys", func(db *gorm.DB) *gorm.DB {
		return db.Order("created_at desc, id desc")
	}).First(&u, id).Error
	if err != nil {
		return nil, err
	}
	return &u, nil
}

// GetByUsername 按用户名查（含未撤销公钥）。
func (s *Store) GetByUsername(username string) (*User, error) {
	var u User
	err := s.DB.Preload("Pubkeys",
		"revoked_at IS NULL",
	).Where("username = ?", username).First(&u).Error
	if err != nil {
		return nil, err
	}
	return &u, nil
}

// GetByPubkeyHash 按公钥哈希查（用于验签后取 user）。
// 只返回未撤销公钥对应的 user。
func (s *Store) GetByPubkeyHash(hash string) (*User, *Pubkey, error) {
	var pk Pubkey
	err := s.DB.Where("pubkey_hash = ? AND revoked_at IS NULL", hash).
		First(&pk).Error
	if err != nil {
		return nil, nil, err
	}
	u, err := s.GetByID(pk.UserID)
	if err != nil {
		return nil, nil, err
	}
	return u, &pk, nil
}

// AddPubkey 给已有用户追加公钥（密钥轮换）。
func (s *Store) AddPubkey(userID uint64, pubkeyHex, pubkeyHash string) (*Pubkey, error) {
	pk := Pubkey{
		UserID:     userID,
		PubkeyHex:  pubkeyHex,
		PubkeyHash: pubkeyHash,
		CreatedAt:  time.Now().UTC().Truncate(time.Second),
	}
	if err := s.DB.Create(&pk).Error; err != nil {
		return nil, err
	}
	return &pk, nil
}

// RotatePubkey 追加新公钥，并把该用户旧的当前有效公钥失效时间置为新公钥生效时间。
//
// 旧公钥不会删除。后续历史验证可以根据签名时间戳匹配 created_at / revoked_at。
func (s *Store) RotatePubkey(userID uint64, pubkeyHex, pubkeyHash string) (*Pubkey, int64, error) {
	now := time.Now().UTC().Truncate(time.Second)
	var revokedCount int64
	var created Pubkey
	err := s.DB.Transaction(func(tx *gorm.DB) error {
		pk := Pubkey{
			UserID:     userID,
			PubkeyHex:  pubkeyHex,
			PubkeyHash: pubkeyHash,
			CreatedAt:  now,
		}
		if err := tx.Create(&pk).Error; err != nil {
			return err
		}
		result := tx.Model(&Pubkey{}).
			Where("user_id = ? AND id <> ? AND revoked_at IS NULL", userID, pk.ID).
			Update("revoked_at", now)
		if result.Error != nil {
			return result.Error
		}
		revokedCount = result.RowsAffected
		created = pk
		return nil
	})
	if err != nil {
		return nil, 0, err
	}
	return &created, revokedCount, nil
}

// RevokePubkey 撤销公钥。
func (s *Store) RevokePubkey(pubkeyID uint64) error {
	now := time.Now()
	return s.DB.Model(&Pubkey{}).
		Where("id = ?", pubkeyID).
		Update("revoked_at", now).Error
}

// ListPubkeyHashesForUsername 列出某用户名所有未撤销公钥的哈希。
// 用于恢复期接口。
func (s *Store) ListPubkeyHashesForUsername(username string) ([]string, error) {
	var hashes []string
	err := s.DB.Table("pubkeys").
		Joins("JOIN users ON users.id = pubkeys.user_id").
		Where("users.username = ? AND pubkeys.revoked_at IS NULL", username).
		Pluck("pubkeys.pubkey_hash", &hashes).Error
	return hashes, err
}

// VerifyPubkeyBindings 批量校验公钥哈希是否属于指定用户。
//
// 只接受未撤销公钥和未禁用用户；返回值只包含未命中的原始项。
func (s *Store) VerifyPubkeyBindings(items []PubkeyBinding) ([]PubkeyBinding, error) {
	if len(items) == 0 {
		return nil, nil
	}

	userIDs := make([]uint64, 0, len(items))
	hashes := make([]string, 0, len(items))
	seenUserID := make(map[uint64]struct{}, len(items))
	seenHash := make(map[string]struct{}, len(items))
	normalized := make([]PubkeyBinding, 0, len(items))
	for _, item := range items {
		hash := strings.ToLower(strings.TrimSpace(item.PubkeyHash))
		normalized = append(normalized, PubkeyBinding{
			UserID:     item.UserID,
			PubkeyHash: hash,
		})
		if _, ok := seenUserID[item.UserID]; !ok {
			userIDs = append(userIDs, item.UserID)
			seenUserID[item.UserID] = struct{}{}
		}
		if _, ok := seenHash[hash]; !ok {
			hashes = append(hashes, hash)
			seenHash[hash] = struct{}{}
		}
	}

	type foundRow struct {
		UserID     uint64
		PubkeyHash string
	}
	var rows []foundRow
	err := s.DB.Table("pubkeys").
		Select("pubkeys.user_id, pubkeys.pubkey_hash").
		Joins("JOIN users ON users.id = pubkeys.user_id").
		Where("pubkeys.user_id IN ? AND pubkeys.pubkey_hash IN ? AND pubkeys.revoked_at IS NULL AND users.disabled = ?", userIDs, hashes, false).
		Find(&rows).Error
	if err != nil {
		return nil, err
	}

	found := make(map[string]struct{}, len(rows))
	for _, row := range rows {
		found[bindingKey(row.UserID, row.PubkeyHash)] = struct{}{}
	}

	missing := make([]PubkeyBinding, 0)
	for _, item := range normalized {
		if _, ok := found[bindingKey(item.UserID, item.PubkeyHash)]; !ok {
			missing = append(missing, item)
		}
	}
	return missing, nil
}

// VerifyPubkeyBindingsAt 批量校验公钥哈希是否在签名时间点属于指定用户。
//
// 该方法保留历史公钥验证能力：签名时间落在
// [created_at, revoked_at) 的公钥视为有效。revoked_at 为空代表仍然有效。
// SignedAt 的协议精度是 Unix 秒，因此查询按整秒窗口处理。
func (s *Store) VerifyPubkeyBindingsAt(items []PubkeyBindingAt) ([]PubkeyBindingAt, error) {
	if len(items) == 0 {
		return nil, nil
	}

	missing := make([]PubkeyBindingAt, 0)
	for _, item := range items {
		hash := strings.ToLower(strings.TrimSpace(item.PubkeyHash))
		signedAtStart := item.SignedAt.UTC().Truncate(time.Second)
		signedAtEnd := signedAtStart.Add(time.Second - time.Nanosecond)

		var count int64
		err := s.DB.Table("pubkeys").
			Joins("JOIN users ON users.id = pubkeys.user_id").
			Where("pubkeys.user_id = ? AND pubkeys.pubkey_hash = ? AND users.disabled = ?", item.UserID, hash, false).
			Where("pubkeys.created_at <= ?", signedAtEnd).
			Where("(pubkeys.revoked_at IS NULL OR pubkeys.revoked_at > ?)", signedAtStart).
			Count(&count).Error
		if err != nil {
			return nil, err
		}
		if count == 0 {
			missing = append(missing, PubkeyBindingAt{
				UserID:     item.UserID,
				PubkeyHash: hash,
				SignedAt:   signedAtStart,
			})
		}
	}
	return missing, nil
}

func bindingKey(userID uint64, pubkeyHash string) string {
	return strconv.FormatUint(userID, 10) + "\x00" + pubkeyHash
}

// SetTier 修改用户等级。
func (s *Store) SetTier(userID uint64, tier Tier) error {
	return s.DB.Model(&User{}).Where("id = ?", userID).
		Update("tier", string(tier)).Error
}

// SetRole 修改用户管理权限。
func (s *Store) SetRole(userID uint64, role Role) error {
	return s.DB.Model(&User{}).Where("id = ?", userID).
		Update("role", string(role)).Error
}

// SetDisabled 禁用 / 启用用户。
func (s *Store) SetDisabled(userID uint64, disabled bool) error {
	return s.DB.Model(&User{}).Where("id = ?", userID).
		Update("disabled", disabled).Error
}

// SetEmail 修改用户恢复邮箱。空字符串表示未绑定邮箱。
func (s *Store) SetEmail(userID uint64, email string) error {
	return s.DB.Model(&User{}).Where("id = ?", userID).
		Update("email", email).Error
}

// List 分页列出用户（管理后台用）。
func (s *Store) List(page, pageSize int) ([]User, int64, error) {
	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 200 {
		pageSize = 50
	}
	var total int64
	if err := s.DB.Model(&User{}).Count(&total).Error; err != nil {
		return nil, 0, err
	}
	var items []User
	err := s.DB.Preload("Pubkeys", func(db *gorm.DB) *gorm.DB {
		return db.Order("created_at desc, id desc")
	}).
		Order("id desc").
		Offset((page - 1) * pageSize).
		Limit(pageSize).
		Find(&items).Error
	return items, total, err
}

// EnsureBootstrapRootRole 兼容旧库：username=root 的认证中心用户始终是 root。
func (s *Store) EnsureBootstrapRootRole() error {
	return s.DB.Model(&User{}).
		Where("username = ?", "root").
		Update("role", string(RoleRoot)).Error
}

// DeleteUserHard 删除注册失败时留下的用户和首个公钥。只在跨服务同步失败回滚时使用。
func (s *Store) DeleteUserHard(userID uint64) error {
	if userID == 0 {
		return nil
	}
	return s.DB.Transaction(func(tx *gorm.DB) error {
		if err := tx.Unscoped().Where("user_id = ?", userID).Delete(&Pubkey{}).Error; err != nil {
			return err
		}
		return tx.Unscoped().Where("id = ?", userID).Delete(&User{}).Error
	})
}
