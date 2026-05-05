// Package crypto 的 SignedRequest 验证逻辑。
//
// 与 docs/protocol-spec.md §3.2 对齐。
package crypto

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/hanako/ph01-backend/pkg/api"
	"github.com/redis/go-redis/v9"
)

// SignedRequestVerifier 校验 SignedRequest 包装：
//   1. timestamp 在 ±maxSkew 内
//   2. nonce 未在过去 nonceTTL 内出现过（Redis 保护）
//   3. 重组待签名串，做 ECDSA 验签
type SignedRequestVerifier struct {
	Redis    *redis.Client
	MaxSkew  time.Duration // 默认 5 分钟
	NonceTTL time.Duration // 默认 5 分钟
	NoncePrefix string     // Redis key 前缀，例如 "nonce:auth"
}

// DefaultMaxSkew 是协议约定的时间戳容忍窗口。
const DefaultMaxSkew = 5 * time.Minute

// DefaultNonceTTL 是 nonce 防重放窗口（必须 ≥ MaxSkew * 2）。
const DefaultNonceTTL = 10 * time.Minute

// NewSignedRequestVerifier 创建一个验证器。
func NewSignedRequestVerifier(rdb *redis.Client, prefix string) *SignedRequestVerifier {
	return &SignedRequestVerifier{
		Redis:       rdb,
		MaxSkew:     DefaultMaxSkew,
		NonceTTL:    DefaultNonceTTL,
		NoncePrefix: prefix,
	}
}

// VerifyResult 验证通过后的副产物。
type VerifyResult struct {
	PubkeyHex   string // 验签所用公钥
	PubkeyHash  string // 该公钥的 SHA-256 哈希（hex），调用方用此查 user_id
	Payload     string // 原始 payload 字符串（业务层 json.Unmarshal 自取）
}

// Verify 完整验证 SignedRequest：
//   1. 时间戳
//   2. nonce
//   3. 签名
// 不做用户存在性 / 公钥撤销检查——由业务层基于返回的 PubkeyHash 自查。
func (v *SignedRequestVerifier) Verify(ctx context.Context, req *api.SignedRequest) (*VerifyResult, error) {
	// 1. 时间戳
	now := time.Now().Unix()
	if delta := now - req.Timestamp; delta > int64(v.MaxSkew.Seconds()) ||
		delta < -int64(v.MaxSkew.Seconds()) {
		return nil, fmt.Errorf("%s: skew=%ds (max=%v)",
			api.ErrTimestampExpired, delta, v.MaxSkew)
	}

	// 2. nonce 防重放
	if v.Redis != nil {
		key := fmt.Sprintf("%s:%s", v.NoncePrefix, req.Nonce)
		ok, err := v.Redis.SetNX(ctx, key, "1", v.NonceTTL).Result()
		if err != nil {
			return nil, fmt.Errorf("nonce check redis: %w", err)
		}
		if !ok {
			return nil, errors.New(api.ErrNonceReplayed)
		}
	}

	// 3. 验签
	signed := req.Payload + "\n" + req.PubkeyHex + "\n" +
		fmt.Sprintf("%d", req.Timestamp) + "\n" + req.Nonce
	if err := VerifySignature(req.PubkeyHex, []byte(signed), req.SignatureHex); err != nil {
		return nil, fmt.Errorf("%s: %w", api.ErrInvalidSignature, err)
	}

	hash, err := PubkeyHash(req.PubkeyHex)
	if err != nil {
		return nil, fmt.Errorf("pubkey hash: %w", err)
	}

	return &VerifyResult{
		PubkeyHex:  req.PubkeyHex,
		PubkeyHash: hash,
		Payload:    req.Payload,
	}, nil
}
