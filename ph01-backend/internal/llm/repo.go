// Package llm AI 网关的 LLM 上游配置 + 模型路由 + 限流策略。
package llm

import (
	"time"

	"gorm.io/gorm"
)

// Upstream 上游 LLM 提供商配置（管理后台维护）。
type Upstream struct {
	ID        uint64    `gorm:"primaryKey;autoIncrement" json:"id"`
	Name      string    `gorm:"size:64;uniqueIndex;not null" json:"name"`
	BaseURL   string    `gorm:"size:255;not null" json:"base_url"`
	APIKey    string    `gorm:"size:512" json:"api_key"`
	Format    string    `gorm:"size:32;not null" json:"format"` // openai / anthropic
	Enabled   bool      `gorm:"default:true" json:"enabled"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

// ModelMapping 把对外 model 名映射到上游。
type ModelMapping struct {
	ID           uint64    `gorm:"primaryKey;autoIncrement" json:"id"`
	PublicName   string    `gorm:"size:64;uniqueIndex;not null" json:"public_name"`
	UpstreamID   uint64    `gorm:"index;not null" json:"upstream_id"`
	UpstreamName string    `gorm:"size:128;not null" json:"upstream_name"`
	MinTier      string    `gorm:"size:16;default:'free';not null" json:"min_tier"` // free/pro/enterprise
	Enabled      bool      `gorm:"default:true" json:"enabled"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`

	Upstream *Upstream `gorm:"foreignKey:UpstreamID" json:"upstream,omitempty"`
}

// TierPolicy 套餐限流策略（管理后台维护）。
type TierPolicy struct {
	ID            uint64    `gorm:"primaryKey;autoIncrement" json:"id"`
	Tier          string    `gorm:"size:16;uniqueIndex;not null" json:"tier"`
	PerMinute     int64     `gorm:"default:10" json:"per_minute"`
	PerDay        int64     `gorm:"default:200" json:"per_day"` // -1 = unlimited
	MaxTokensIn   int64     `gorm:"default:4096" json:"max_tokens_in"`
	MaxTokensOut  int64     `gorm:"default:2048" json:"max_tokens_out"`
	UpdatedAt     time.Time `json:"updated_at"`
}

// AutoMigrate 创建上游 / 模型映射 / 套餐策略表。
func AutoMigrate(db *gorm.DB) error {
	return db.AutoMigrate(&Upstream{}, &ModelMapping{}, &TierPolicy{})
}

// Repo 业务接口。
type Repo struct {
	DB *gorm.DB
}

func NewRepo(db *gorm.DB) *Repo {
	return &Repo{DB: db}
}

// Seed 在表首次创建时灌入默认数据，方便启动即可用。
func (r *Repo) Seed() error {
	// 默认 tier 策略
	defaultTiers := []TierPolicy{
		{Tier: "free", PerMinute: 10, PerDay: 200, MaxTokensIn: 4096, MaxTokensOut: 2048},
		{Tier: "pro", PerMinute: 60, PerDay: 5000, MaxTokensIn: 16384, MaxTokensOut: 8192},
		{Tier: "enterprise", PerMinute: 300, PerDay: -1, MaxTokensIn: 64000, MaxTokensOut: 32000},
	}
	for _, t := range defaultTiers {
		var exists TierPolicy
		err := r.DB.Where("tier = ?", t.Tier).First(&exists).Error
		if err == gorm.ErrRecordNotFound {
			r.DB.Create(&t)
		}
	}
	return nil
}

func (r *Repo) ListUpstreams() ([]Upstream, error) {
	var us []Upstream
	err := r.DB.Order("id").Find(&us).Error
	return us, err
}

func (r *Repo) CreateUpstream(u *Upstream) error {
	return r.DB.Create(u).Error
}

func (r *Repo) UpdateUpstream(u *Upstream) error {
	return r.DB.Save(u).Error
}

func (r *Repo) DeleteUpstream(id uint64) error {
	return r.DB.Delete(&Upstream{}, id).Error
}

func (r *Repo) ListMappings() ([]ModelMapping, error) {
	var ms []ModelMapping
	err := r.DB.Preload("Upstream").Order("id").Find(&ms).Error
	return ms, err
}

func (r *Repo) GetMappingByPublicName(name string) (*ModelMapping, error) {
	var m ModelMapping
	err := r.DB.Preload("Upstream").
		Where("public_name = ? AND enabled = ?", name, true).
		First(&m).Error
	if err != nil {
		return nil, err
	}
	return &m, nil
}

func (r *Repo) CreateMapping(m *ModelMapping) error {
	return r.DB.Create(m).Error
}

func (r *Repo) UpdateMapping(m *ModelMapping) error {
	return r.DB.Save(m).Error
}

func (r *Repo) DeleteMapping(id uint64) error {
	return r.DB.Delete(&ModelMapping{}, id).Error
}

func (r *Repo) GetTierPolicy(tier string) (*TierPolicy, error) {
	var t TierPolicy
	err := r.DB.Where("tier = ?", tier).First(&t).Error
	if err != nil {
		return nil, err
	}
	return &t, nil
}

func (r *Repo) UpdateTierPolicy(t *TierPolicy) error {
	return r.DB.Save(t).Error
}

func (r *Repo) ListTierPolicies() ([]TierPolicy, error) {
	var ts []TierPolicy
	err := r.DB.Order("tier").Find(&ts).Error
	return ts, err
}

// AllowedModelsForTier 列出该 tier 能用的所有 public_name。
func (r *Repo) AllowedModelsForTier(tier string) ([]string, error) {
	var models []string
	rank := map[string]int{"free": 0, "pro": 1, "enterprise": 2}
	userRank := rank[tier]
	mappings, err := r.ListMappings()
	if err != nil {
		return nil, err
	}
	for _, m := range mappings {
		if !m.Enabled {
			continue
		}
		if rank[m.MinTier] > userRank {
			continue
		}
		models = append(models, m.PublicName)
	}
	return models, nil
}

// TierRank 套餐等级数值（越高越强）。
func TierRank(tier string) int {
	switch tier {
	case "free":
		return 0
	case "pro":
		return 1
	case "enterprise":
		return 2
	}
	return 0
}
