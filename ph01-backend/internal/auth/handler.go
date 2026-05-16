// Package auth HTTP handler：注册、登录、恢复期公钥查询、内部验签接口。
package auth

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"net/mail"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	hcrypto "github.com/hanako/ph01-backend/internal/crypto"
	"github.com/hanako/ph01-backend/internal/user"
	"github.com/hanako/ph01-backend/pkg/api"
	"gorm.io/gorm"
)

// Handler 把所有认证类 HTTP route 注册到 gin engine。
type Handler struct {
	UserStore *user.Store
	Verifier  *hcrypto.SignedRequestVerifier

	// 恢复期 limiter（IP / username 频率限制），通过 RateLimiter 注入
	RecoveryLimiter RecoveryLimiter

	// 第二阶段恢复 RFA，默认邮箱验证码。
	RFA *RFAService

	// 注册邮箱验证码。新账号注册必须先验证邮箱。
	RegistrationEmail *RegistrationEmailService

	// 注册成功后同步 AI 网关账号。认证中心用户名直接作为 AI 网关用户名。
	GatewaySyncer GatewayUserSyncer

	// 用户 PoW 挑战缓存。挑战短期保存在内存/进程内，持久状态只写回公钥。
	Pow *UserPowService

	// 外部委托 PoW 挑战/证明缓存。状态只用于外部系统短期校验，不写用户持久状态。
	DelegatedPow *DelegatedPowService
}

type GatewayUserSyncRequest struct {
	PH01UserID    uint64 `json:"ph01_user_id"`
	Username      string `json:"username"`
	Nickname      string `json:"nickname,omitempty"`
	Email         string `json:"email,omitempty"`
	Tier          string `json:"tier"`
	PubkeyHash    string `json:"pubkey_hash"`
	PowVerified   bool   `json:"pow_verified,omitempty"`
	PowAlgorithm  string `json:"pow_algorithm,omitempty"`
	PowScore      int    `json:"pow_score,omitempty"`
	PowVerifiedAt int64  `json:"pow_verified_at,omitempty"`
}

type GatewayChannelRevokeRequest struct {
	PH01UserID    uint64 `json:"ph01_user_id"`
	Username      string `json:"username,omitempty"`
	Reason        string `json:"reason,omitempty"`
	OldPubkeyHash string `json:"old_pubkey_hash,omitempty"`
	NewPubkeyHash string `json:"new_pubkey_hash,omitempty"`
	EffectiveAt   int64  `json:"effective_at,omitempty"`
}

type GatewayUserSyncer interface {
	SyncUser(ctx context.Context, req GatewayUserSyncRequest) error
	RevokePH01Channels(ctx context.Context, req GatewayChannelRevokeRequest) error
}

// RecoveryLimiter 抽象：检查 username 在 IP 上的恢复请求频率。
type RecoveryLimiter interface {
	AllowRecovery(ip, username string) (bool, error)
}

// Register 把 routes 挂到 gin。
func (h *Handler) Register(r *gin.RouterGroup) {
	r.GET("/auth/username_available", h.HandleUsernameAvailable)
	r.POST("/auth/register_email/start", h.HandleRegistrationEmailStart)
	r.POST("/auth/register", h.HandleRegister)
	r.POST("/auth/login", h.HandleLogin)
	r.POST("/auth/rotate_pubkey_email/start", h.HandleRotatePubkeyEmailStart)
	r.POST("/auth/rotate_pubkey", h.HandleRotatePubkey)
	r.POST("/auth/recovery_candidates", h.HandleRecoveryCandidates)
	r.POST("/auth/recovery_rfa/start", h.HandleRecoveryRFAStart)
	r.POST("/auth/recovery_rfa/verify", h.HandleRecoveryRFAVerify)
	r.POST("/auth/verify_signature", h.HandleVerifySignature)
	r.POST("/auth/verify_challenge_signature", h.HandleVerifyChallengeSignature)
	r.POST("/auth/verify_pubkeys", h.HandleVerifyPubkeys)
	r.POST("/auth/verify_pubkeys_at", h.HandleVerifyPubkeysAt)
	r.POST("/auth/pow/challenge", h.HandleUserPowChallenge)
	r.POST("/auth/pow/verify", h.HandleUserPowVerify)
	r.POST("/auth/pow/delegated/challenge", h.HandleDelegatedPowChallenge)
	r.GET("/auth/pow/delegated/challenge/:challenge_id", h.HandleDelegatedPowChallengeDetail)
	r.POST("/auth/pow/delegated/verify", h.HandleDelegatedPowVerify)
	r.POST("/auth/pow/delegated/status", h.HandleDelegatedPowStatus)
	r.POST("/auth/pubkeys/status", h.HandlePubkeyStatus)
	r.GET("/auth/user_state/changes", h.HandleUserStateChanges)
}

// HandleRegistrationEmailStart 处理 POST /auth/register_email/start。
func (h *Handler) HandleRegistrationEmailStart(c *gin.Context) {
	if h.RegistrationEmail == nil {
		errorJSON(c, http.StatusServiceUnavailable, api.ErrEmailNotConfigured, "registration email service not configured")
		return
	}
	var req api.RegistrationEmailStartRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	resp, err := h.RegistrationEmail.Start(c.Request.Context(), req.Username, req.Email)
	if err != nil {
		rfaErrorJSON(c, err)
		return
	}
	c.JSON(http.StatusOK, resp)
}

// HandleUsernameAvailable 处理 GET /auth/username_available?username=alice。
//
// 这是公开预检接口，不要求签名。客户端用它在首次引导中判断：
//   - available=true  → 注册新身份
//   - available=false → 进入既有账号登录 / 恢复流程
func (h *Handler) HandleUsernameAvailable(c *gin.Context) {
	username := strings.TrimSpace(c.Query("username"))
	if username == "" || len(username) > 32 {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "username invalid")
		return
	}
	_, err := h.UserStore.GetByUsername(username)
	if err == nil {
		c.JSON(http.StatusOK, api.UsernameAvailabilityResponse{
			Username:  username,
			Available: false,
		})
		return
	}
	if errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusOK, api.UsernameAvailabilityResponse{
			Username:  username,
			Available: true,
		})
		return
	}
	errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
}

// HandleRegister 处理 POST /auth/register
func (h *Handler) HandleRegister(c *gin.Context) {
	var req api.SignedRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	verified, err := h.Verifier.Verify(c.Request.Context(), &req)
	if err != nil {
		errorJSON(c, http.StatusUnauthorized, classifyVerifyErr(err), err.Error())
		return
	}

	var payload api.RegisterPayload
	if err := json.Unmarshal([]byte(verified.Payload), &payload); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}

	// 一致性检查：payload.PubkeyHex 必须等于外层 pubkey
	if !strings.EqualFold(payload.PubkeyHex, verified.PubkeyHex) {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload,
			"payload.pubkey_hex mismatch outer pubkey")
		return
	}
	if payload.Username == "" || len(payload.Username) > 32 {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload,
			"username invalid")
		return
	}
	// 占用检查
	if existing, _ := h.UserStore.GetByUsername(payload.Username); existing != nil {
		errorJSON(c, http.StatusConflict, api.ErrUsernameTaken, "")
		return
	}
	email, err := normalizeEmailRequired(payload.Email)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload,
			"email invalid")
		return
	}
	if taken, err := h.UserStore.EmailExists(email); err != nil {
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	} else if taken {
		errorJSON(c, http.StatusConflict, api.ErrEmailTaken, "")
		return
	}
	if h.RegistrationEmail == nil {
		errorJSON(c, http.StatusServiceUnavailable, api.ErrEmailNotConfigured, "registration email service not configured")
		return
	}
	if err := h.RegistrationEmail.Verify(c.Request.Context(), payload.EmailChallengeID, payload.Username, email, payload.EmailCode); err != nil {
		rfaErrorJSON(c, err)
		return
	}
	if taken, err := h.UserStore.EmailExists(email); err != nil {
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	} else if taken {
		errorJSON(c, http.StatusConflict, api.ErrEmailTaken, "")
		return
	}

	u, err := h.UserStore.CreateWithPubkey(
		payload.Username,
		payload.Nickname,
		email,
		verified.PubkeyHex,
		verified.PubkeyHash,
	)
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}

	if h.GatewaySyncer != nil && !user.IsPresetUsername(u.Username) {
		err := h.GatewaySyncer.SyncUser(c.Request.Context(), GatewayUserSyncRequest{
			PH01UserID: u.ID,
			Username:   u.Username,
			Nickname:   u.Nickname,
			Email:      u.Email,
			Tier:       u.Tier,
			PubkeyHash: verified.PubkeyHash,
		})
		if err != nil {
			_ = h.UserStore.DeleteUserHard(u.ID)
			errorJSON(c, http.StatusBadGateway, api.ErrGatewaySyncFailed, err.Error())
			return
		}
	}

	c.JSON(http.StatusOK, api.RegisterResponse{
		UserID:     u.ID,
		Username:   u.Username,
		Tier:       u.Tier,
		PubkeyHash: verified.PubkeyHash,
	})
}

// HandleLogin 处理 POST /auth/login
func (h *Handler) HandleLogin(c *gin.Context) {
	var req api.SignedRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	verified, err := h.Verifier.Verify(c.Request.Context(), &req)
	if err != nil {
		errorJSON(c, http.StatusUnauthorized, classifyVerifyErr(err), err.Error())
		return
	}

	var payload api.LoginPayload
	if err := json.Unmarshal([]byte(verified.Payload), &payload); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}

	// 用 pubkey_hash 查 user
	u, _, err := h.UserStore.GetByPubkeyHash(verified.PubkeyHash)
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			errorJSON(c, http.StatusUnauthorized, api.ErrPubkeyNotFound, "")
			return
		}
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}

	// 比对 username
	if !strings.EqualFold(u.Username, payload.Username) {
		errorJSON(c, http.StatusUnauthorized, api.ErrPubkeyNotFound,
			"pubkey does not match username")
		return
	}
	if u.Disabled {
		errorJSON(c, http.StatusForbidden, api.ErrUserDisabled, "")
		return
	}

	c.JSON(http.StatusOK, api.LoginResponse{
		UserID:     u.ID,
		Username:   u.Username,
		Tier:       u.Tier,
		PubkeyHash: verified.PubkeyHash,
	})
}

// HandleRotatePubkeyEmailStart 处理 POST /auth/rotate_pubkey_email/start。
//
// 发起轮换邮箱验证码也必须由当前有效私钥签名，防止仅凭邮箱控制权触发轮换流程。
func (h *Handler) HandleRotatePubkeyEmailStart(c *gin.Context) {
	if h.RFA == nil {
		errorJSON(c, http.StatusServiceUnavailable, api.ErrRFANotAvailable, "rfa service not configured")
		return
	}
	var req api.SignedRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	verified, err := h.Verifier.Verify(c.Request.Context(), &req)
	if err != nil {
		errorJSON(c, http.StatusUnauthorized, classifyVerifyErr(err), err.Error())
		return
	}

	var payload api.RotatePubkeyEmailStartPayload
	if err := json.Unmarshal([]byte(verified.Payload), &payload); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	if strings.TrimSpace(payload.Username) == "" {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "username required")
		return
	}

	u, _, err := h.UserStore.GetByPubkeyHash(verified.PubkeyHash)
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			errorJSON(c, http.StatusUnauthorized, api.ErrPubkeyNotFound, "")
			return
		}
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	if !strings.EqualFold(u.Username, payload.Username) {
		errorJSON(c, http.StatusUnauthorized, api.ErrPubkeyNotFound, "pubkey does not match username")
		return
	}
	if u.Disabled {
		errorJSON(c, http.StatusForbidden, api.ErrUserDisabled, "")
		return
	}

	resp, err := h.RFA.StartPubkeyRotation(c.Request.Context(), u)
	if err != nil {
		rfaErrorJSON(c, err)
		return
	}
	c.JSON(http.StatusOK, resp)
}

// HandleRotatePubkey 处理 POST /auth/rotate_pubkey。
//
// 外层 SignedRequest 必须由当前有效旧公钥签名，payload 必须携带轮换邮箱验证码。
// 轮换成功后，旧公钥的失效时间等于新公钥的生效时间；后续登录/网关验签只接受新公钥。
func (h *Handler) HandleRotatePubkey(c *gin.Context) {
	if h.RFA == nil {
		errorJSON(c, http.StatusServiceUnavailable, api.ErrRFANotAvailable, "rfa service not configured")
		return
	}
	var req api.SignedRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	verified, err := h.Verifier.Verify(c.Request.Context(), &req)
	if err != nil {
		errorJSON(c, http.StatusUnauthorized, classifyVerifyErr(err), err.Error())
		return
	}

	var payload api.RotatePubkeyPayload
	if err := json.Unmarshal([]byte(verified.Payload), &payload); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	if strings.TrimSpace(payload.Username) == "" {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "username required")
		return
	}
	newPubkeyHex := strings.TrimSpace(payload.NewPubkeyHex)
	if _, err := hcrypto.ParsePubkey(newPubkeyHex); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "new_pubkey_hex invalid")
		return
	}
	newHash, err := hcrypto.PubkeyHash(newPubkeyHex)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "new_pubkey_hex invalid")
		return
	}
	if strings.EqualFold(newHash, verified.PubkeyHash) {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "new pubkey must differ from current pubkey")
		return
	}

	u, _, err := h.UserStore.GetByPubkeyHash(verified.PubkeyHash)
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			errorJSON(c, http.StatusUnauthorized, api.ErrPubkeyNotFound, "")
			return
		}
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	if !strings.EqualFold(u.Username, payload.Username) {
		errorJSON(c, http.StatusUnauthorized, api.ErrPubkeyNotFound, "pubkey does not match username")
		return
	}
	if u.Disabled {
		errorJSON(c, http.StatusForbidden, api.ErrUserDisabled, "")
		return
	}
	if strings.TrimSpace(payload.EmailChallengeID) == "" || strings.TrimSpace(payload.EmailCode) == "" {
		errorJSON(c, http.StatusBadRequest, api.ErrEmailVerificationRequired, api.ErrEmailVerificationRequired)
		return
	}
	if err := h.RFA.VerifyPubkeyRotation(c.Request.Context(), payload.EmailChallengeID, payload.EmailCode, u.ID, u.Username); err != nil {
		rfaErrorJSON(c, err)
		return
	}

	revocationWarning := h.revokeGatewayChannels(c.Request.Context(), GatewayChannelRevokeRequest{
		PH01UserID:    u.ID,
		Username:      u.Username,
		Reason:        "pubkey_rotation_before_commit",
		OldPubkeyHash: verified.PubkeyHash,
	})

	newPubkey, revokedCount, err := h.UserStore.RotatePubkey(u.ID, newPubkeyHex, newHash)
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	if warning := h.revokeGatewayChannels(c.Request.Context(), GatewayChannelRevokeRequest{
		PH01UserID:    u.ID,
		Username:      u.Username,
		Reason:        "pubkey_rotation_after_commit",
		OldPubkeyHash: verified.PubkeyHash,
		NewPubkeyHash: newPubkey.PubkeyHash,
		EffectiveAt:   newPubkey.CreatedAt.Unix(),
	}); warning != "" {
		if revocationWarning != "" {
			revocationWarning += "; " + warning
		} else {
			revocationWarning = warning
		}
	}
	c.JSON(http.StatusOK, api.RotatePubkeyResponse{
		UserID:               u.ID,
		Username:             u.Username,
		Tier:                 u.Tier,
		OldPubkeyHash:        verified.PubkeyHash,
		NewPubkeyHash:        newPubkey.PubkeyHash,
		EffectiveAt:          newPubkey.CreatedAt.Unix(),
		RevokedPreviousCount: revokedCount,
		GatewayRevokeWarning: revocationWarning,
	})
}

func (h *Handler) revokeGatewayChannels(ctx context.Context, req GatewayChannelRevokeRequest) string {
	if h.GatewaySyncer == nil || req.PH01UserID == 0 {
		return ""
	}
	if err := h.GatewaySyncer.RevokePH01Channels(ctx, req); err != nil {
		msg := "ai gateway channel revoke failed: " + err.Error()
		log.Printf("[warn] ph01 pubkey rotation channel revoke failed user_id=%d reason=%s err=%v", req.PH01UserID, req.Reason, err)
		return msg
	}
	return ""
}

// HandleRecoveryCandidates 处理 POST /auth/recovery_candidates
//
// 此接口不签名（用户此时尚未持有私钥），但严格限频。
func (h *Handler) HandleRecoveryCandidates(c *gin.Context) {
	var req api.RecoveryCandidatesRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	if req.Username == "" {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "username required")
		return
	}

	if h.RecoveryLimiter != nil {
		ok, err := h.RecoveryLimiter.AllowRecovery(c.ClientIP(), req.Username)
		if err != nil {
			errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
			return
		}
		if !ok {
			errorJSON(c, http.StatusTooManyRequests, api.ErrRateLimitExceeded, "")
			return
		}
	}

	hashes, err := h.UserStore.ListPubkeyHashesForUsername(req.Username)
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}

	c.JSON(http.StatusOK, api.RecoveryCandidatesResponse{
		Username:        req.Username,
		PubkeyHashes:    hashes,
		ServerSignature: "", // TODO: 服务端 root 私钥签名
	})
}

// HandleRecoveryRFAStart 处理 POST /auth/recovery_rfa/start。
func (h *Handler) HandleRecoveryRFAStart(c *gin.Context) {
	if h.RFA == nil {
		errorJSON(c, http.StatusServiceUnavailable, api.ErrRFANotAvailable, "rfa service not configured")
		return
	}
	var req api.RecoveryRFAStartRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	if req.Username == "" {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "username required")
		return
	}
	if h.RecoveryLimiter != nil {
		ok, err := h.RecoveryLimiter.AllowRecovery(c.ClientIP(), req.Username)
		if err != nil {
			errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
			return
		}
		if !ok {
			errorJSON(c, http.StatusTooManyRequests, api.ErrRateLimitExceeded, "")
			return
		}
	}
	resp, err := h.RFA.Start(c.Request.Context(), req.Username)
	if err != nil {
		rfaErrorJSON(c, err)
		return
	}
	c.JSON(http.StatusOK, resp)
}

// HandleRecoveryRFAVerify 处理 POST /auth/recovery_rfa/verify。
func (h *Handler) HandleRecoveryRFAVerify(c *gin.Context) {
	if h.RFA == nil {
		errorJSON(c, http.StatusServiceUnavailable, api.ErrRFANotAvailable, "rfa service not configured")
		return
	}
	var req api.RecoveryRFAVerifyRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	resp, err := h.RFA.Verify(c.Request.Context(), req.ChallengeID, req.Code)
	if err != nil {
		rfaErrorJSON(c, err)
		return
	}
	c.JSON(http.StatusOK, resp)
}

// HandleVerifySignature 内部接口：ai-gateway 调本接口验签，避免重复实现。
//
// 不强制 mTLS（同集群部署可走 localhost）；生产环境应通过 internal-only network。
func (h *Handler) HandleVerifySignature(c *gin.Context) {
	var req api.VerifySignatureRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, api.VerifySignatureResponse{
			Valid: false,
			Error: api.ErrInvalidPayload,
		})
		return
	}
	if h.Verifier == nil {
		c.JSON(http.StatusOK, api.VerifySignatureResponse{
			Valid: false,
			Error: api.ErrInternalError,
		})
		return
	}
	verified, err := h.Verifier.Verify(c.Request.Context(), &api.SignedRequest{
		Payload:      req.Payload,
		PubkeyHex:    req.PubkeyHex,
		SignatureHex: req.SignatureHex,
		Timestamp:    req.Timestamp,
		Nonce:        req.Nonce,
	})
	if err != nil {
		c.JSON(http.StatusOK, api.VerifySignatureResponse{
			Valid: false,
			Error: classifyVerifyErr(err),
		})
		return
	}
	u, pk, err := h.UserStore.GetByPubkeyHash(verified.PubkeyHash)
	if err != nil {
		c.JSON(http.StatusOK, api.VerifySignatureResponse{
			Valid: false,
			Error: api.ErrPubkeyNotFound,
		})
		return
	}
	if u.Disabled {
		c.JSON(http.StatusOK, api.VerifySignatureResponse{
			Valid: false,
			Error: api.ErrUserDisabled,
		})
		return
	}
	if req.UserID != 0 && req.UserID != u.ID {
		c.JSON(http.StatusOK, api.VerifySignatureResponse{
			Valid: false,
			Error: api.ErrPubkeyNotFound,
		})
		return
	}
	c.JSON(http.StatusOK, api.VerifySignatureResponse{
		Valid:         true,
		UserID:        u.ID,
		Username:      u.Username,
		Tier:          u.Tier,
		PubkeyHash:    verified.PubkeyHash,
		PowVerified:   pk.PowVerified,
		PowAlgorithm:  pk.PowAlgorithm,
		PowScore:      pk.PowScore,
		PowVerifiedAt: unixPtr(pk.PowVerifiedAt),
	})
}

// HandleVerifyChallengeSignature 内部接口：按 user_id 查有效公钥，验证 challenge 签名。
func (h *Handler) HandleVerifyChallengeSignature(c *gin.Context) {
	var req api.VerifyChallengeSignatureRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, api.VerifySignatureResponse{
			Valid: false,
			Error: api.ErrInvalidPayload,
		})
		return
	}
	if req.UserID == 0 || strings.TrimSpace(req.Challenge) == "" || strings.TrimSpace(req.SignatureHex) == "" {
		c.JSON(http.StatusBadRequest, api.VerifySignatureResponse{
			Valid: false,
			Error: api.ErrInvalidPayload,
		})
		return
	}
	u, err := h.UserStore.GetByID(req.UserID)
	if err != nil {
		c.JSON(http.StatusOK, api.VerifySignatureResponse{
			Valid: false,
			Error: api.ErrPubkeyNotFound,
		})
		return
	}
	if u.Disabled {
		c.JSON(http.StatusOK, api.VerifySignatureResponse{
			Valid: false,
			Error: api.ErrUserDisabled,
		})
		return
	}
	for _, pk := range u.Pubkeys {
		if err := hcrypto.VerifySignature(pk.PubkeyHex, []byte(req.Challenge), req.SignatureHex); err == nil {
			c.JSON(http.StatusOK, api.VerifySignatureResponse{
				Valid:         true,
				UserID:        u.ID,
				Username:      u.Username,
				Tier:          u.Tier,
				PubkeyHash:    pk.PubkeyHash,
				PowVerified:   pk.PowVerified,
				PowAlgorithm:  pk.PowAlgorithm,
				PowScore:      pk.PowScore,
				PowVerifiedAt: unixPtr(pk.PowVerifiedAt),
			})
			return
		}
	}
	c.JSON(http.StatusOK, api.VerifySignatureResponse{
		Valid: false,
		Error: api.ErrInvalidSignature,
	})
}

const maxVerifyPubkeyItems = 1000

// HandleVerifyPubkeys 内部接口：批量验证 user_id + pubkey_hash 的绑定关系。
//
// 全部命中只返回 {"ok": true}；未命中时返回 missing 列表。
func (h *Handler) HandleVerifyPubkeys(c *gin.Context) {
	var req api.VerifyPubkeysRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	if len(req.Items) == 0 {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "items required")
		return
	}
	if len(req.Items) > maxVerifyPubkeyItems {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "too many items")
		return
	}

	items := make([]user.PubkeyBinding, 0, len(req.Items))
	for _, item := range req.Items {
		hash, err := normalizePubkeyHash(item.PubkeyHash)
		if err != nil || item.UserID == 0 {
			errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "invalid pubkey binding item")
			return
		}
		items = append(items, user.PubkeyBinding{
			UserID:     item.UserID,
			PubkeyHash: hash,
		})
	}

	missing, err := h.UserStore.VerifyPubkeyBindings(items)
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	resp := api.VerifyPubkeysResponse{
		OK: len(missing) == 0,
	}
	if len(missing) > 0 {
		resp.Missing = make([]api.PubkeyBindingCheck, 0, len(missing))
		for _, item := range missing {
			resp.Missing = append(resp.Missing, api.PubkeyBindingCheck{
				UserID:     item.UserID,
				PubkeyHash: item.PubkeyHash,
			})
		}
	}
	c.JSON(http.StatusOK, resp)
}

// HandleVerifyPubkeysAt 内部接口：按签名时间批量验证历史公钥绑定关系。
//
// 预留给经验网络：调用方带上签名发生时的 Unix 秒时间戳，认证中心按
// pubkeys.created_at / revoked_at 判断当时哪把公钥有效。
func (h *Handler) HandleVerifyPubkeysAt(c *gin.Context) {
	var req api.VerifyPubkeysAtRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	if len(req.Items) == 0 {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "items required")
		return
	}
	if len(req.Items) > maxVerifyPubkeyItems {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "too many items")
		return
	}

	items := make([]user.PubkeyBindingAt, 0, len(req.Items))
	for _, item := range req.Items {
		hash, err := normalizePubkeyHash(item.PubkeyHash)
		if err != nil || item.UserID == 0 || item.SignedAt <= 0 {
			errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "invalid historical pubkey binding item")
			return
		}
		items = append(items, user.PubkeyBindingAt{
			UserID:     item.UserID,
			PubkeyHash: hash,
			SignedAt:   time.Unix(item.SignedAt, 0).UTC(),
		})
	}

	missing, err := h.UserStore.VerifyPubkeyBindingsAt(items)
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	resp := api.VerifyPubkeysAtResponse{
		OK: len(missing) == 0,
	}
	if len(missing) > 0 {
		resp.Missing = make([]api.PubkeyBindingAtCheck, 0, len(missing))
		for _, item := range missing {
			resp.Missing = append(resp.Missing, api.PubkeyBindingAtCheck{
				UserID:     item.UserID,
				PubkeyHash: item.PubkeyHash,
				SignedAt:   item.SignedAt.Unix(),
			})
		}
	}
	c.JSON(http.StatusOK, resp)
}

// HandleUserPowChallenge 创建用户 PoW 挑战。它只检查公钥存在，不改变登录/注册流程。
func (h *Handler) HandleUserPowChallenge(c *gin.Context) {
	var req api.UserPowChallengeRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	hash, err := normalizePubkeyHash(req.PubkeyHash)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "pubkey_hash invalid")
		return
	}
	u, _, err := h.UserStore.GetByPubkeyHash(hash)
	if err != nil {
		errorJSON(c, http.StatusNotFound, api.ErrPubkeyNotFound, "")
		return
	}
	if u.Disabled {
		errorJSON(c, http.StatusForbidden, api.ErrUserDisabled, "")
		return
	}
	resp, err := h.powService().Create(hash, timeNowUTC())
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	c.JSON(http.StatusOK, resp)
}

// HandleUserPowVerify 校验 SignedRequest 中的 PoW 结果，并把状态写回公钥。
func (h *Handler) HandleUserPowVerify(c *gin.Context) {
	var req api.SignedRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	verified, err := h.Verifier.Verify(c.Request.Context(), &req)
	if err != nil {
		errorJSON(c, http.StatusUnauthorized, classifyVerifyErr(err), err.Error())
		return
	}
	var payload api.UserPowVerifyPayload
	if err := json.Unmarshal([]byte(verified.Payload), &payload); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	hash, err := normalizePubkeyHash(payload.PubkeyHash)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "pubkey_hash invalid")
		return
	}
	if !strings.EqualFold(hash, verified.PubkeyHash) {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "payload.pubkey_hash mismatch signed pubkey")
		return
	}
	challenge, err := h.powService().Verify(payload, timeNowUTC())
	if err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, ErrPowChallengeNotFound) {
			status = http.StatusNotFound
		}
		errorJSON(c, status, api.ErrInvalidPayload, err.Error())
		return
	}
	status, err := h.UserStore.MarkPubkeyPoWVerified(hash, challenge.Algorithm, UserPowScore(challenge), timeNowUTC())
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			errorJSON(c, http.StatusNotFound, api.ErrPubkeyNotFound, "")
			return
		}
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	if h.GatewaySyncer != nil {
		_ = h.GatewaySyncer.SyncUser(c.Request.Context(), GatewayUserSyncRequest{
			PH01UserID:    status.UserID,
			Username:      status.Username,
			Tier:          status.Tier,
			PubkeyHash:    status.PubkeyHash,
			PowVerified:   status.PowVerified,
			PowAlgorithm:  status.PowAlgorithm,
			PowScore:      status.PowScore,
			PowVerifiedAt: unixPtr(status.PowVerifiedAt),
		})
	}
	c.JSON(http.StatusOK, pubkeyStatusToAPI(status))
}

// HandleDelegatedPowChallenge 为外部系统创建通用委托 PoW 挑战。
func (h *Handler) HandleDelegatedPowChallenge(c *gin.Context) {
	var req api.DelegatedPowChallengeRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	purpose, err := normalizeDelegatedPowPurpose(req.Purpose)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "purpose invalid")
		return
	}
	subjectHash, err := normalizeSHA256Hex(req.SubjectHash)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "subject_hash invalid")
		return
	}
	pubkeyHash := ""
	if strings.TrimSpace(req.PubkeyHash) != "" {
		hash, err := normalizePubkeyHash(req.PubkeyHash)
		if err != nil {
			errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "pubkey_hash invalid")
			return
		}
		pubkeyHash = hash
	}
	resp, err := h.delegatedPowService().Create(purpose, subjectHash, pubkeyHash, timeNowUTC())
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	c.JSON(http.StatusOK, resp)
}

// HandleDelegatedPowChallengeDetail 让客户端通过 challenge_id 从认证中心取得具体计算参数。
func (h *Handler) HandleDelegatedPowChallengeDetail(c *gin.Context) {
	challengeID := strings.TrimSpace(c.Param("challenge_id"))
	if challengeID == "" {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "challenge_id required")
		return
	}
	challenge, ok := h.delegatedPowService().Challenge(challengeID, timeNowUTC())
	if !ok {
		errorJSON(c, http.StatusNotFound, api.ErrInvalidPayload, ErrPowChallengeNotFound.Error())
		return
	}
	c.JSON(http.StatusOK, challenge)
}

// HandleDelegatedPowVerify 校验委托 PoW，并把结果留存在短期缓存中供外部系统查询。
func (h *Handler) HandleDelegatedPowVerify(c *gin.Context) {
	var req api.SignedRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	verified, err := h.Verifier.Verify(c.Request.Context(), &req)
	if err != nil {
		errorJSON(c, http.StatusUnauthorized, classifyVerifyErr(err), err.Error())
		return
	}
	var payload api.DelegatedPowVerifyPayload
	if err := json.Unmarshal([]byte(verified.Payload), &payload); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	purpose, err := normalizeDelegatedPowPurpose(payload.Purpose)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "purpose invalid")
		return
	}
	subjectHash, err := normalizeSHA256Hex(payload.SubjectHash)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "subject_hash invalid")
		return
	}
	hash := strings.TrimSpace(payload.PubkeyHash)
	if hash == "" {
		hash = verified.PubkeyHash
	}
	hash, err = normalizePubkeyHash(hash)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "pubkey_hash invalid")
		return
	}
	if !strings.EqualFold(hash, verified.PubkeyHash) {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "payload.pubkey_hash mismatch signed pubkey")
		return
	}
	u, _, err := h.UserStore.GetByPubkeyHash(hash)
	if err != nil {
		errorJSON(c, http.StatusNotFound, api.ErrPubkeyNotFound, "")
		return
	}
	if u.Disabled {
		errorJSON(c, http.StatusForbidden, api.ErrUserDisabled, "")
		return
	}
	payload.Purpose = purpose
	payload.SubjectHash = subjectHash
	payload.PubkeyHash = hash
	status, err := h.delegatedPowService().Verify(payload, timeNowUTC())
	if err != nil {
		statusCode := http.StatusBadRequest
		if errors.Is(err, ErrPowChallengeNotFound) {
			statusCode = http.StatusNotFound
		}
		errorJSON(c, statusCode, api.ErrInvalidPayload, err.Error())
		return
	}
	c.JSON(http.StatusOK, status)
}

// HandleDelegatedPowStatus 给外部系统查询某个委托 PoW 是否已完成。
func (h *Handler) HandleDelegatedPowStatus(c *gin.Context) {
	var req api.DelegatedPowStatusRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	if strings.TrimSpace(req.ChallengeID) == "" {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "challenge_id required")
		return
	}
	if strings.TrimSpace(req.Purpose) != "" {
		purpose, err := normalizeDelegatedPowPurpose(req.Purpose)
		if err != nil {
			errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "purpose invalid")
			return
		}
		req.Purpose = purpose
	}
	if strings.TrimSpace(req.SubjectHash) != "" {
		subjectHash, err := normalizeSHA256Hex(req.SubjectHash)
		if err != nil {
			errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "subject_hash invalid")
			return
		}
		req.SubjectHash = subjectHash
	}
	if strings.TrimSpace(req.PubkeyHash) != "" {
		hash, err := normalizePubkeyHash(req.PubkeyHash)
		if err != nil {
			errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "pubkey_hash invalid")
			return
		}
		req.PubkeyHash = hash
	}
	c.JSON(http.StatusOK, h.delegatedPowService().Status(req, timeNowUTC()))
}

// HandlePubkeyStatus 批量查询公钥状态，给经验网络握手时校验散花用户使用。
func (h *Handler) HandlePubkeyStatus(c *gin.Context) {
	var req api.PubkeyStatusRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	if len(req.PubkeyHashes) == 0 {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "pubkey_hashes required")
		return
	}
	if len(req.PubkeyHashes) > maxVerifyPubkeyItems {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "too many items")
		return
	}
	statuses, err := h.UserStore.GetPubkeyStatuses(req.PubkeyHashes)
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	byHash := make(map[string]user.PubkeyStatus, len(statuses))
	for _, status := range statuses {
		byHash[status.PubkeyHash] = status
	}
	items := make([]api.UserPubkeyStatus, 0, len(req.PubkeyHashes))
	seen := map[string]struct{}{}
	for _, raw := range req.PubkeyHashes {
		hash := strings.ToLower(strings.TrimSpace(raw))
		if _, ok := seen[hash]; ok {
			continue
		}
		seen[hash] = struct{}{}
		if status, ok := byHash[hash]; ok {
			items = append(items, pubkeyStatusToAPI(status))
			continue
		}
		items = append(items, api.UserPubkeyStatus{Valid: false, PubkeyHash: hash})
	}
	c.JSON(http.StatusOK, api.PubkeyStatusResponse{Items: items})
}

// HandleUserStateChanges 供 AI 网关按时间戳拉取用户状态增量。
func (h *Handler) HandleUserStateChanges(c *gin.Context) {
	sinceUnix, _ := strconv.ParseInt(strings.TrimSpace(c.Query("since")), 10, 64)
	limit, _ := strconv.Atoi(strings.TrimSpace(c.Query("limit")))
	var since time.Time
	if sinceUnix > 0 {
		since = time.Unix(sinceUnix, 0).UTC()
	}
	statuses, err := h.UserStore.ListPubkeyStatesSince(since, limit)
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	items := make([]api.UserPubkeyStatus, 0, len(statuses))
	nextSince := sinceUnix
	for _, status := range statuses {
		item := pubkeyStatusToAPI(status)
		items = append(items, item)
		if item.UpdatedAt > nextSince {
			nextSince = item.UpdatedAt
		}
	}
	c.JSON(http.StatusOK, api.UserStateChangesResponse{
		Items:     items,
		NextSince: nextSince,
	})
}

// ----- helpers -----

func (h *Handler) powService() *UserPowService {
	if h.Pow == nil {
		h.Pow = NewUserPowService()
	}
	return h.Pow
}

func (h *Handler) delegatedPowService() *DelegatedPowService {
	if h.DelegatedPow == nil {
		h.DelegatedPow = NewDelegatedPowService()
	}
	return h.DelegatedPow
}

func pubkeyStatusToAPI(status user.PubkeyStatus) api.UserPubkeyStatus {
	return api.UserPubkeyStatus{
		Valid:         status.Valid,
		UserID:        status.UserID,
		Username:      status.Username,
		Tier:          status.Tier,
		Role:          status.Role,
		IsAdmin:       user.IsAdminRole(status.Role),
		Disabled:      status.Disabled,
		PubkeyHash:    status.PubkeyHash,
		PowVerified:   status.PowVerified,
		PowAlgorithm:  status.PowAlgorithm,
		PowScore:      status.PowScore,
		PowVerifiedAt: unixPtr(status.PowVerifiedAt),
		UpdatedAt:     unixTime(status.UpdatedAt),
	}
}

func unixPtr(t *time.Time) int64 {
	if t == nil || t.IsZero() {
		return 0
	}
	return t.UTC().Unix()
}

func unixTime(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.UTC().Unix()
}

func timeNowUTC() time.Time {
	return time.Now().UTC()
}

func errorJSON(c *gin.Context, status int, code, msg string) {
	c.JSON(status, api.ErrorResponse{Error: code, Message: msg})
}

func errorJSONWithRetryAfter(c *gin.Context, status int, code, msg string, retryAfter int) {
	c.Header("Retry-After", strconv.Itoa(retryAfter))
	c.JSON(status, api.ErrorResponse{Error: code, Message: msg, RetryAfter: retryAfter})
}

func rfaErrorJSON(c *gin.Context, err error) {
	status, code := classifyRFAErr(err)
	if retryAfter := emailCooldownRetryAfterSeconds(err); retryAfter > 0 {
		errorJSONWithRetryAfter(c, status, code, err.Error(), retryAfter)
		return
	}
	errorJSON(c, status, code, err.Error())
}

func classifyVerifyErr(err error) string {
	s := err.Error()
	switch {
	case strings.Contains(s, api.ErrTimestampExpired):
		return api.ErrTimestampExpired
	case strings.Contains(s, api.ErrNonceReplayed):
		return api.ErrNonceReplayed
	case strings.Contains(s, api.ErrInvalidSignature):
		return api.ErrInvalidSignature
	}
	return api.ErrInvalidSignature
}

func classifyRFAErr(err error) (int, string) {
	switch {
	case errors.Is(err, ErrRFANotAvailable):
		return http.StatusServiceUnavailable, api.ErrRFANotAvailable
	case errors.Is(err, ErrEmailNotConfigured):
		return http.StatusServiceUnavailable, api.ErrEmailNotConfigured
	case errors.Is(err, ErrEmailNotBound):
		return http.StatusBadRequest, api.ErrEmailNotBound
	case errors.Is(err, ErrEmailCooldown):
		return http.StatusTooManyRequests, api.ErrRateLimitExceeded
	case strings.Contains(err.Error(), api.ErrEmailVerificationRequired):
		return http.StatusBadRequest, api.ErrEmailVerificationRequired
	case strings.Contains(err.Error(), api.ErrUsernameTaken):
		return http.StatusConflict, api.ErrUsernameTaken
	case strings.Contains(err.Error(), api.ErrEmailTaken):
		return http.StatusConflict, api.ErrEmailTaken
	case errors.Is(err, ErrRFAChallengeNotFound):
		return http.StatusNotFound, api.ErrRFAChallengeNotFound
	case errors.Is(err, ErrRFACodeExpired):
		return http.StatusBadRequest, api.ErrRFACodeExpired
	case errors.Is(err, ErrRFACodeInvalid):
		return http.StatusUnauthorized, api.ErrRFACodeInvalid
	case errors.Is(err, gorm.ErrRecordNotFound):
		return http.StatusNotFound, api.ErrUserNotFound
	case strings.Contains(err.Error(), api.ErrInvalidPayload):
		return http.StatusBadRequest, api.ErrInvalidPayload
	case strings.Contains(err.Error(), api.ErrUserDisabled):
		return http.StatusForbidden, api.ErrUserDisabled
	default:
		return http.StatusInternalServerError, api.ErrInternalError
	}
}

func normalizeEmail(email string) (string, error) {
	email = strings.TrimSpace(email)
	if email == "" {
		return "", nil
	}
	if len(email) > 254 {
		return "", errors.New("email too long")
	}
	addr, err := mail.ParseAddress(email)
	if err != nil {
		return "", err
	}
	if addr.Address != email {
		return "", errors.New("email must be a plain address")
	}
	return strings.ToLower(addr.Address), nil
}

func normalizeEmailRequired(email string) (string, error) {
	normalized, err := normalizeEmail(email)
	if err != nil {
		return "", errors.New(api.ErrInvalidPayload)
	}
	if normalized == "" {
		return "", errors.New(api.ErrInvalidPayload)
	}
	return normalized, nil
}

func normalizePubkeyHash(hash string) (string, error) {
	hash = strings.ToLower(strings.TrimSpace(hash))
	if len(hash) != 64 {
		return "", errors.New("pubkey_hash must be 64 hex chars")
	}
	if _, err := hex.DecodeString(hash); err != nil {
		return "", err
	}
	return hash, nil
}

func normalizeSHA256Hex(hash string) (string, error) {
	hash = strings.ToLower(strings.TrimSpace(hash))
	if len(hash) != 64 {
		return "", errors.New("sha256 must be 64 hex chars")
	}
	if _, err := hex.DecodeString(hash); err != nil {
		return "", err
	}
	return hash, nil
}

func normalizeDelegatedPowPurpose(purpose string) (string, error) {
	purpose = strings.TrimSpace(purpose)
	if purpose == "" || len(purpose) > 128 {
		return "", errors.New("purpose required")
	}
	for _, ch := range purpose {
		if ch >= 'a' && ch <= 'z' {
			continue
		}
		if ch >= 'A' && ch <= 'Z' {
			continue
		}
		if ch >= '0' && ch <= '9' {
			continue
		}
		if ch == '.' || ch == '_' || ch == '-' || ch == ':' {
			continue
		}
		return "", errors.New("purpose contains invalid characters")
	}
	return purpose, nil
}
