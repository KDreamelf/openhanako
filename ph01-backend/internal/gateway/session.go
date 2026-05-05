// Package gateway AI 网关核心：ECDH 握手、短期通信通道管理、签名验证缓存。
package gateway

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

// ChannelIdleTTL 是短期通信通道的空闲有效期。
// 通道不是登录态；过期后客户端用长期私钥静默重新握手。
const ChannelIdleTTL = 10 * time.Minute

// Channel 协商建立后的短期加密通信通道。
type Channel struct {
	ID            string    `json:"id"`
	UserID        uint64    `json:"user_id"`
	Username      string    `json:"username"`
	Tier          string    `json:"tier"`
	AESKeyHex     string    `json:"aes_key_hex"` // 32 字节 AES key 的 hex
	CreatedAt     time.Time `json:"created_at"`
	ExpiresAt     time.Time `json:"expires_at"`
	AllowedModels []string  `json:"allowed_models"`
}

// ChannelStore 通信通道存储抽象。
type ChannelStore struct {
	Redis *redis.Client
}

func NewChannelStore(r *redis.Client) *ChannelStore {
	return &ChannelStore{Redis: r}
}

const channelKeyPrefix = "channel:"

// Create 在 Redis 中创建一个新的短期通信通道。
func (s *ChannelStore) Create(ctx context.Context, ch *Channel) error {
	if ch.ID == "" {
		ch.ID = uuid.NewString()
	}
	if ch.CreatedAt.IsZero() {
		ch.CreatedAt = time.Now()
	}
	if ch.ExpiresAt.IsZero() {
		ch.ExpiresAt = ch.CreatedAt.Add(ChannelIdleTTL)
	}
	data, err := json.Marshal(ch)
	if err != nil {
		return err
	}
	ttl := time.Until(ch.ExpiresAt)
	if ttl <= 0 {
		return fmt.Errorf("channel already expired")
	}
	return s.Redis.Set(ctx, channelKeyPrefix+ch.ID, data, ttl).Err()
}

// Get 取一个通信通道。不存在或过期返回 nil, nil。
func (s *ChannelStore) Get(ctx context.Context, id string) (*Channel, error) {
	data, err := s.Redis.Get(ctx, channelKeyPrefix+id).Bytes()
	if err == redis.Nil {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var ch Channel
	if err := json.Unmarshal(data, &ch); err != nil {
		return nil, err
	}
	return &ch, nil
}

// Delete 删除通信通道。
func (s *ChannelStore) Delete(ctx context.Context, id string) error {
	return s.Redis.Del(ctx, channelKeyPrefix+id).Err()
}

// Touch 刷新通信通道的空闲有效期。
func (s *ChannelStore) Touch(ctx context.Context, id string) error {
	return s.Redis.Expire(ctx, channelKeyPrefix+id, ChannelIdleTTL).Err()
}
