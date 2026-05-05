// Package gateway 用户级限流器（依赖 TierPolicy 决定限额）。
package gateway

import (
	"context"
	"fmt"
	"time"

	"github.com/hanako/ph01-backend/internal/llm"
	"github.com/hanako/ph01-backend/internal/redisx"
	"github.com/redis/go-redis/v9"
)

// UserRateLimiter 实现 RateLimiter：根据 user_id 和 tier，查 TierPolicy
// 然后跑 1 分钟 + 1 天双窗口固定限流。
type UserRateLimiter struct {
	Inner *redisx.FixedWindowLimiter
	LLM   *llm.Repo
}

func NewUserRateLimiter(r *redis.Client, llmRepo *llm.Repo) *UserRateLimiter {
	return &UserRateLimiter{
		Inner: redisx.NewFixedWindowLimiter(r),
		LLM:   llmRepo,
	}
}

// Allow 检查 user_id 在 (per_minute, per_day) 双窗口内是否超限。
func (l *UserRateLimiter) Allow(ctx context.Context, userID uint64, tier string) (bool, error) {
	policy, err := l.LLM.GetTierPolicy(tier)
	if err != nil {
		// 取不到策略时沿用最严的 free 限额
		policy = &llm.TierPolicy{Tier: "free", PerMinute: 10, PerDay: 200}
	}

	// 1 分钟窗口
	scope1 := fmt.Sprintf("u:%d:m", userID)
	ok1, _, err := l.Inner.Allow(ctx, scope1, time.Minute, policy.PerMinute)
	if err != nil {
		return false, err
	}
	if !ok1 {
		return false, nil
	}

	// 1 天窗口
	if policy.PerDay > 0 {
		scope2 := fmt.Sprintf("u:%d:d", userID)
		ok2, _, err := l.Inner.Allow(ctx, scope2, 24*time.Hour, policy.PerDay)
		if err != nil {
			return false, err
		}
		if !ok2 {
			return false, nil
		}
	}
	return true, nil
}
