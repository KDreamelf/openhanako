// Package auth HTTP handler：注册、登录、恢复期公钥查询、内部验签接口。
package auth

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/mail"
	"strings"

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
}

type GatewayUserSyncRequest struct {
	PH01UserID uint64 `json:"ph01_user_id"`
	Username   string `json:"username"`
	Nickname   string `json:"nickname,omitempty"`
	Email      string `json:"email,omitempty"`
	Tier       string `json:"tier"`
	PubkeyHash string `json:"pubkey_hash"`
}

type GatewayUserSyncer interface {
	SyncUser(ctx context.Context, req GatewayUserSyncRequest) error
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
	r.POST("/auth/recovery_candidates", h.HandleRecoveryCandidates)
	r.POST("/auth/recovery_rfa/start", h.HandleRecoveryRFAStart)
	r.POST("/auth/recovery_rfa/verify", h.HandleRecoveryRFAVerify)
	r.POST("/auth/verify_signature", h.HandleVerifySignature)
	r.POST("/auth/verify_challenge_signature", h.HandleVerifyChallengeSignature)
	r.POST("/auth/verify_pubkeys", h.HandleVerifyPubkeys)
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
		status, code := classifyRFAErr(err)
		errorJSON(c, status, code, err.Error())
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
	if h.RegistrationEmail == nil {
		errorJSON(c, http.StatusServiceUnavailable, api.ErrEmailNotConfigured, "registration email service not configured")
		return
	}
	if err := h.RegistrationEmail.Verify(c.Request.Context(), payload.EmailChallengeID, payload.Username, email, payload.EmailCode); err != nil {
		status, code := classifyRFAErr(err)
		errorJSON(c, status, code, err.Error())
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
		status, code := classifyRFAErr(err)
		errorJSON(c, status, code, err.Error())
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
		status, code := classifyRFAErr(err)
		errorJSON(c, status, code, err.Error())
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
	u, _, err := h.UserStore.GetByPubkeyHash(verified.PubkeyHash)
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
		Valid:      true,
		UserID:     u.ID,
		Username:   u.Username,
		Tier:       u.Tier,
		PubkeyHash: verified.PubkeyHash,
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
				Valid:      true,
				UserID:     u.ID,
				Username:   u.Username,
				Tier:       u.Tier,
				PubkeyHash: pk.PubkeyHash,
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

// ----- helpers -----

func errorJSON(c *gin.Context, status int, code, msg string) {
	c.JSON(status, api.ErrorResponse{Error: code, Message: msg})
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
	case strings.Contains(err.Error(), api.ErrEmailVerificationRequired):
		return http.StatusBadRequest, api.ErrEmailVerificationRequired
	case strings.Contains(err.Error(), api.ErrUsernameTaken):
		return http.StatusConflict, api.ErrUsernameTaken
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
