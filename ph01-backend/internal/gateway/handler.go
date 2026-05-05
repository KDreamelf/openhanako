// Package gateway ECDH 短期通信通道 handler + 加密 LLM 代理 handler。
package gateway

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"net/http"

	"github.com/gin-gonic/gin"
	hcrypto "github.com/hanako/ph01-backend/internal/crypto"
	"github.com/hanako/ph01-backend/internal/llm"
	"github.com/hanako/ph01-backend/pkg/api"
)

// Handler 实现 ECDH 握手 + 加密 chat 代理。
type Handler struct {
	Auth         *AuthClient
	Channels     *ChannelStore
	LLM          *llm.Repo
	UpstreamPipe *UpstreamPipe // 实际转发 LLM 调用
}

func (h *Handler) Register(r *gin.RouterGroup) {
	r.POST("/channel/handshake", h.HandleHandshake)
	r.POST("/llm/chat", h.HandleChat)
	r.GET("/models", h.HandleListModels)
}

// HandleHandshake 处理 ECDH 协商：
//  1. 收子体的临时公钥 + 用长期私钥的签名
//  2. 调 auth-gateway 验签 → 拿 user_id / tier
//  3. 服务端生成临时 ECDH 密钥对
//  4. 双方共享密钥 = HKDF(ECDH(s_priv, e_pub))
//  5. 写 channel 到 Redis，返回 channel_id + s_pub + 可用模型
func (h *Handler) HandleHandshake(c *gin.Context) {
	var req api.SignedRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errResp(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}

	// 1. 调 auth-gateway 验签
	verResp, err := h.Auth.VerifySignature(c.Request.Context(), &api.VerifySignatureRequest{
		PubkeyHex:    req.PubkeyHex,
		SignatureHex: req.SignatureHex,
		Payload:      req.Payload,
		Timestamp:    req.Timestamp,
		Nonce:        req.Nonce,
	})
	if err != nil {
		errResp(c, http.StatusBadGateway, api.ErrInternalError,
			"auth-gateway: "+err.Error())
		return
	}
	if !verResp.Valid {
		code := verResp.Error
		if code == "" {
			code = api.ErrInvalidSignature
		}
		errResp(c, http.StatusUnauthorized, code, "")
		return
	}

	// 2. 解析 payload
	var payload api.HandshakePayload
	if err := json.Unmarshal([]byte(req.Payload), &payload); err != nil {
		errResp(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	clientPub, err := hcrypto.ParsePubkey(payload.EphemeralPubkey)
	if err != nil {
		errResp(c, http.StatusBadRequest, api.ErrInvalidPayload,
			"ephemeral pubkey: "+err.Error())
		return
	}

	// 3. 服务端生成临时 ECDH 密钥
	server, err := hcrypto.NewEphemeralKey()
	if err != nil {
		errResp(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}

	// 4. 派生 AES key
	aesKey, err := hcrypto.DeriveSharedKey(server.PrivateKey, clientPub)
	if err != nil {
		errResp(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}

	// 5. 列出该 tier 可用的 model
	allowedModels, err := h.LLM.AllowedModelsForTier(verResp.Tier)
	if err != nil {
		errResp(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}

	// 6. 写短期通信通道到 Redis
	ch := &Channel{
		UserID:        verResp.UserID,
		Username:      verResp.Username,
		Tier:          verResp.Tier,
		AESKeyHex:     hex.EncodeToString(aesKey),
		AllowedModels: allowedModels,
	}
	if err := h.Channels.Create(c.Request.Context(), ch); err != nil {
		errResp(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}

	c.JSON(http.StatusOK, api.HandshakeResponse{
		ChannelID:       ch.ID,
		EphemeralPubkey: server.PublicKeyHex(),
		IdleExpiresIn:   int(ChannelIdleTTL.Seconds()),
		AllowedModels:   allowedModels,
	})
}

// HandleChat 处理加密 LLM 调用。
func (h *Handler) HandleChat(c *gin.Context) {
	var env api.EncryptedEnvelope
	if err := c.ShouldBindJSON(&env); err != nil {
		errResp(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}

	// 取短期通信通道
	ch, err := h.Channels.Get(c.Request.Context(), env.ChannelID)
	if err != nil {
		errResp(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	if ch == nil {
		errResp(c, http.StatusUnauthorized, api.ErrInvalidChannel, "")
		return
	}

	// 解密 plaintext
	aesKey, err := hex.DecodeString(ch.AESKeyHex)
	if err != nil {
		errResp(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	pt, err := hcrypto.DecryptGCM(aesKey, env.Nonce, env.Ciphertext, env.Tag)
	if err != nil {
		errResp(c, http.StatusBadRequest, api.ErrDecryptionFailed, err.Error())
		return
	}

	var chatReq api.ChatRequest
	if err := json.Unmarshal(pt, &chatReq); err != nil {
		errResp(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}

	// 校验 model 是否在该通道允许范围内
	if !contains(ch.AllowedModels, chatReq.Model) {
		errResp(c, http.StatusForbidden, api.ErrModelNotAllowed,
			"model "+chatReq.Model+" not allowed for tier "+ch.Tier)
		return
	}

	// 取 mapping
	mapping, err := h.LLM.GetMappingByPublicName(chatReq.Model)
	if err != nil || mapping.Upstream == nil {
		errResp(c, http.StatusNotFound, api.ErrModelNotAllowed,
			"unknown model: "+chatReq.Model)
		return
	}

	// 限流（在 UpstreamPipe 内部，根据 tier 查 TierPolicy 做计数）
	if h.UpstreamPipe.RateLimiter != nil {
		ok, err := h.UpstreamPipe.RateLimiter.Allow(c.Request.Context(),
			ch.UserID, ch.Tier)
		if err != nil {
			errResp(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
			return
		}
		if !ok {
			errResp(c, http.StatusTooManyRequests, api.ErrRateLimitExceeded, "")
			return
		}
	}

	// 转发到上游
	if chatReq.Stream {
		h.UpstreamPipe.StreamChat(c, ch, mapping, &chatReq, aesKey)
	} else {
		h.UpstreamPipe.NonStreamChat(c, ch, mapping, &chatReq, aesKey)
	}
	if err := h.Channels.Touch(c.Request.Context(), ch.ID); err != nil {
		// 非致命：本次请求已完成，下一次若通道过期客户端会静默重握手。
		_ = err
	}
}

// HandleListModels GET /api/v1/models?channel_id=...
//
// 不需要解密，但需要 channel_id 绑定短期通信通道。
func (h *Handler) HandleListModels(c *gin.Context) {
	cid := c.Query("channel_id")
	if cid == "" {
		errResp(c, http.StatusBadRequest, api.ErrInvalidPayload, "channel_id required")
		return
	}
	ch, err := h.Channels.Get(c.Request.Context(), cid)
	if err != nil {
		errResp(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	if ch == nil {
		errResp(c, http.StatusUnauthorized, api.ErrInvalidChannel, "")
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"models": ch.AllowedModels,
		"tier":   ch.Tier,
	})
}

// ----- helpers -----

func errResp(c *gin.Context, status int, code, msg string) {
	c.JSON(status, api.ErrorResponse{Error: code, Message: msg})
}

func contains(arr []string, s string) bool {
	for _, x := range arr {
		if x == s {
			return true
		}
	}
	return false
}

// 占位以避免未使用 import
var _ = context.Background
