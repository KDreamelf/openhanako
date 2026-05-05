// Package redisx Redis 客户端封装（小一层包装方便测试）。
package redisx

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

// Open 打开 Redis 连接。url 形如 redis://localhost:6379/0
func Open(url string) (*redis.Client, error) {
	opt, err := redis.ParseURL(url)
	if err != nil {
		return nil, fmt.Errorf("parse redis url: %w", err)
	}
	cli := redis.NewClient(opt)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := cli.Ping(ctx).Err(); err != nil {
		return nil, fmt.Errorf("redis ping: %w", err)
	}
	return cli, nil
}

// FixedWindowLimiter 固定窗口限流。
//
// key 格式：rl:{scope}:{ts/window}
// 每次 INCR + EXPIRE，超出 limit 返回 false。
type FixedWindowLimiter struct {
	Client *redis.Client
}

func NewFixedWindowLimiter(c *redis.Client) *FixedWindowLimiter {
	return &FixedWindowLimiter{Client: c}
}

// Allow 检查并 +1。limit 为 -1 时无限制。
func (l *FixedWindowLimiter) Allow(ctx context.Context, scope string, window time.Duration, limit int64) (bool, int64, error) {
	if limit < 0 {
		return true, 0, nil
	}
	now := time.Now().Unix()
	bucket := now / int64(window.Seconds())
	key := fmt.Sprintf("rl:%s:%d", scope, bucket)
	cnt, err := l.Client.Incr(ctx, key).Result()
	if err != nil {
		return false, 0, err
	}
	if cnt == 1 {
		// 第一次创建 key，设过期
		l.Client.Expire(ctx, key, window+10*time.Second)
	}
	return cnt <= limit, cnt, nil
}

// RecoveryLimiter 实现 auth.RecoveryLimiter 接口：
// 同 IP 1 小时最多 5 次恢复请求；同 username 24 小时最多 5 次。
type RecoveryLimiter struct {
	Inner *FixedWindowLimiter
}

func NewRecoveryLimiter(c *redis.Client) *RecoveryLimiter {
	return &RecoveryLimiter{Inner: NewFixedWindowLimiter(c)}
}

func (r *RecoveryLimiter) AllowRecovery(ip, username string) (bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	ok1, _, err := r.Inner.Allow(ctx, "recovery:ip:"+ip, time.Hour, 5)
	if err != nil {
		return false, err
	}
	if !ok1 {
		return false, nil
	}
	ok2, _, err := r.Inner.Allow(ctx, "recovery:user:"+username, 24*time.Hour, 5)
	if err != nil {
		return false, err
	}
	return ok2, nil
}

// ErrNotConnected 占位错误。
var ErrNotConnected = errors.New("redis not connected")
