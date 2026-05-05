// Package admin auth-gateway 的管理后台 API。
package admin

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/mail"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/hanako/ph01-backend/internal/auth"
	hcrypto "github.com/hanako/ph01-backend/internal/crypto"
	"github.com/hanako/ph01-backend/internal/system"
	"github.com/hanako/ph01-backend/internal/user"
	"github.com/hanako/ph01-backend/pkg/api"
	"gorm.io/gorm"
)

const defaultSessionTTL = 12 * time.Hour

type Handler struct {
	UserStore   *user.Store
	SystemStore *system.Store
	Verifier    *hcrypto.SignedRequestVerifier
	AdminToken  string
	SessionTTL  time.Duration
}

type sessionClaims struct {
	UserID    uint64 `json:"uid"`
	Username  string `json:"username"`
	Nickname  string `json:"nickname"`
	Role      string `json:"role"`
	ExpiresAt int64  `json:"exp"`
	IssuedAt  int64  `json:"iat"`
}

// Register 把 admin routes 挂到 group（/admin 前缀）。
func (h *Handler) Register(r *gin.RouterGroup) {
	r.POST("/session/login", h.HandleLogin)

	r.Use(h.authMiddleware)
	r.GET("/session/self", h.HandleSelf)
	r.GET("/users", h.HandleListUsers)
	r.GET("/users/:id", h.HandleGetUser)
	r.PATCH("/users/:id", h.HandleUpdateUser)
	r.POST("/users/:id/pubkeys/:pubkey_id/revoke", h.HandleRevokePubkey)
	r.GET("/config/smtp", h.HandleGetSMTP)
	r.PATCH("/config/smtp", h.HandleUpdateSMTP)
	r.POST("/config/smtp/test", h.HandleTestSMTP)
	r.GET("/logs", h.HandleListLogs)
}

func (h *Handler) HandleLogin(c *gin.Context) {
	if h.Verifier == nil {
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, "signed verifier not configured")
		return
	}
	var req api.SignedRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	verified, err := h.Verifier.Verify(c.Request.Context(), &req)
	if err != nil {
		errorJSON(c, http.StatusUnauthorized, api.ErrInvalidSignature, err.Error())
		return
	}
	var payload api.LoginPayload
	if err := json.Unmarshal([]byte(verified.Payload), &payload); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
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
	if !strings.EqualFold(u.Username, strings.TrimSpace(payload.Username)) {
		errorJSON(c, http.StatusUnauthorized, api.ErrPubkeyNotFound, "pubkey does not match username")
		return
	}
	if u.Disabled {
		errorJSON(c, http.StatusForbidden, api.ErrUserDisabled, "")
		return
	}
	if !user.IsAdminRole(u.Role) {
		errorJSON(c, http.StatusForbidden, api.ErrAdminRequired, "")
		return
	}

	token, claims, err := h.issueSession(*u)
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	h.audit(system.AuditActor{ID: u.ID, Username: u.Username, Role: u.Role}, "admin.login", "session", "")
	c.JSON(http.StatusOK, api.AdminLoginResponse{
		Token:     token,
		ExpiresAt: claims.ExpiresAt,
		User:      sessionUserFromClaims(claims),
	})
}

func (h *Handler) HandleSelf(c *gin.Context) {
	actor := actorFromContext(c)
	c.JSON(http.StatusOK, sessionUserFromActor(actor))
}

func (h *Handler) authMiddleware(c *gin.Context) {
	header := c.GetHeader("Authorization")
	if !strings.HasPrefix(header, "Bearer ") {
		c.AbortWithStatusJSON(http.StatusUnauthorized,
			api.ErrorResponse{Error: "missing_bearer"})
		return
	}
	tok := strings.TrimSpace(strings.TrimPrefix(header, "Bearer "))
	if tok == "" {
		c.AbortWithStatusJSON(http.StatusUnauthorized,
			api.ErrorResponse{Error: "missing_bearer"})
		return
	}
	if h.AdminToken != "" && subtle.ConstantTimeCompare([]byte(tok), []byte(h.AdminToken)) == 1 {
		c.Set(contextKey(), system.AuditActor{
			Username: "legacy-admin-token",
			Role:     string(user.RoleRoot),
		})
		c.Next()
		return
	}
	claims, err := h.verifySession(tok)
	if err != nil {
		c.AbortWithStatusJSON(http.StatusUnauthorized,
			api.ErrorResponse{Error: "invalid_admin_session", Message: err.Error()})
		return
	}
	c.Set(contextKey(), system.AuditActor{
		ID:       claims.UserID,
		Username: claims.Username,
		Role:     claims.Role,
	})
	c.Next()
}

// HandleListUsers GET /admin/users?page=1&page_size=50
func (h *Handler) HandleListUsers(c *gin.Context) {
	page := atoi(c.DefaultQuery("page", "1"))
	pageSize := atoi(c.DefaultQuery("page_size", "50"))
	users, total, err := h.UserStore.List(page, pageSize)
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	items := make([]api.AdminUser, 0, len(users))
	for _, u := range users {
		items = append(items, toAdminUser(u))
	}
	c.JSON(http.StatusOK, api.AdminUserListResponse{
		Total: int(total),
		Page:  page,
		Items: items,
	})
}

// HandleGetUser GET /admin/users/:id
func (h *Handler) HandleGetUser(c *gin.Context) {
	id := uint64Atoi(c.Param("id"))
	u, err := h.UserStore.GetByID(id)
	if err != nil {
		errorJSON(c, http.StatusNotFound, api.ErrUserNotFound, "")
		return
	}
	c.JSON(http.StatusOK, toAdminUser(*u))
}

// HandleUpdateUser PATCH /admin/users/:id
func (h *Handler) HandleUpdateUser(c *gin.Context) {
	actor := actorFromContext(c)
	id := uint64Atoi(c.Param("id"))
	var req api.AdminUpdateUserRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	target, err := h.UserStore.GetByID(id)
	if err != nil {
		errorJSON(c, http.StatusNotFound, api.ErrUserNotFound, "")
		return
	}
	if user.IsRootRole(target.Role) || user.IsPresetUsername(target.Username) {
		if !user.IsRootRole(actor.Role) {
			errorJSON(c, http.StatusForbidden, api.ErrAdminRequired, "root required")
			return
		}
		if req.Disabled != nil && *req.Disabled {
			errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "root user cannot be disabled")
			return
		}
	}
	if req.Tier != nil {
		tier, ok := user.NormalizeTier(*req.Tier)
		if !ok {
			errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "tier invalid")
			return
		}
		if err := h.UserStore.SetTier(id, tier); err != nil {
			errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
			return
		}
	}
	if req.Disabled != nil {
		if err := h.UserStore.SetDisabled(id, *req.Disabled); err != nil {
			errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
			return
		}
	}
	if req.Email != nil {
		email, err := normalizeEmail(*req.Email)
		if err != nil {
			errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "email invalid")
			return
		}
		if err := h.UserStore.SetEmail(id, email); err != nil {
			errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
			return
		}
	}
	if req.Role != nil {
		if !user.IsRootRole(actor.Role) {
			errorJSON(c, http.StatusForbidden, api.ErrAdminRequired, "root required")
			return
		}
		role, ok := user.NormalizeRole(*req.Role)
		if !ok {
			errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "role invalid")
			return
		}
		if user.IsRootRole(target.Role) || user.IsPresetUsername(target.Username) || role == user.RoleRoot {
			errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "root role is reserved")
			return
		}
		if err := h.UserStore.SetRole(id, role); err != nil {
			errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
			return
		}
	}
	updated, err := h.UserStore.GetByID(id)
	if err != nil {
		errorJSON(c, http.StatusNotFound, api.ErrUserNotFound, "")
		return
	}
	h.audit(actor, "admin.update_user", "user:"+strconv.FormatUint(id, 10), jsonDetail(req))
	c.JSON(http.StatusOK, toAdminUser(*updated))
}

// HandleRevokePubkey POST /admin/users/:id/pubkeys/:pubkey_id/revoke
func (h *Handler) HandleRevokePubkey(c *gin.Context) {
	actor := actorFromContext(c)
	userID := uint64Atoi(c.Param("id"))
	pkID := uint64Atoi(c.Param("pubkey_id"))
	if err := h.UserStore.RevokePubkey(pkID); err != nil {
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	h.audit(actor, "admin.revoke_pubkey", "user:"+strconv.FormatUint(userID, 10), "pubkey:"+strconv.FormatUint(pkID, 10))
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (h *Handler) HandleGetSMTP(c *gin.Context) {
	settings, err := h.SystemStore.GetSMTPSettings()
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	c.JSON(http.StatusOK, smtpConfigResponse(settings))
}

func (h *Handler) HandleUpdateSMTP(c *gin.Context) {
	actor := actorFromContext(c)
	settings, err := h.SystemStore.GetSMTPSettings()
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	var req api.AdminUpdateSMTPConfigRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	if req.Enabled != nil {
		settings.Enabled = *req.Enabled
	}
	if req.Host != nil {
		settings.Host = *req.Host
	}
	if req.Port != nil {
		settings.Port = *req.Port
	}
	if req.Username != nil {
		settings.Username = *req.Username
	}
	if req.Password != nil {
		settings.Password = *req.Password
	}
	if req.From != nil {
		settings.From = *req.From
	}
	if req.TLSMode != nil {
		settings.TLSMode = *req.TLSMode
	}
	system.NormalizeSMTPSettings(&settings)
	if err := validateSMTPSettings(settings); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	if err := h.SystemStore.SaveSMTPSettings(settings); err != nil {
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	h.audit(actor, "admin.update_smtp", "smtp.recovery", jsonDetail(smtpConfigResponse(settings)))
	c.JSON(http.StatusOK, smtpConfigResponse(settings))
}

func (h *Handler) HandleTestSMTP(c *gin.Context) {
	actor := actorFromContext(c)
	var req api.AdminTestSMTPRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	to := strings.TrimSpace(req.To)
	if _, err := mail.ParseAddress(to); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, "to email invalid")
		return
	}
	settings, err := h.SystemStore.GetSMTPSettings()
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	if err := validateSMTPSettings(settings); err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	sender, err := auth.NewSMTPSender(auth.SMTPConfig{
		Host:     settings.Host,
		Port:     settings.Port,
		Username: settings.Username,
		Password: settings.Password,
		From:     settings.From,
		TLSMode:  settings.TLSMode,
	})
	if err != nil {
		errorJSON(c, http.StatusBadRequest, api.ErrInvalidPayload, err.Error())
		return
	}
	if err := sender.Send(c.Request.Context(), to, "PH01 认证中心 SMTP 测试", "这是一封来自 PH01 认证中心管理端的 SMTP 测试邮件。\n"); err != nil {
		errorJSON(c, http.StatusBadGateway, api.ErrEmailNotConfigured, err.Error())
		return
	}
	h.audit(actor, "admin.test_smtp", "smtp.recovery", to)
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (h *Handler) HandleListLogs(c *gin.Context) {
	page := atoi(c.DefaultQuery("page", "1"))
	pageSize := atoi(c.DefaultQuery("page_size", "50"))
	logs, total, err := h.SystemStore.ListAuditLogs(page, pageSize)
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	items := make([]api.AdminLog, 0, len(logs))
	for _, item := range logs {
		items = append(items, api.AdminLog{
			ID:            item.ID,
			ActorID:       item.ActorID,
			ActorUsername: item.ActorUsername,
			ActorRole:     item.ActorRole,
			Action:        item.Action,
			Target:        item.Target,
			Detail:        item.Detail,
			CreatedAt:     item.CreatedAt.Format(time.RFC3339),
		})
	}
	c.JSON(http.StatusOK, api.AdminLogListResponse{
		Total: int(total),
		Page:  page,
		Items: items,
	})
}

// ----- helpers -----

func (h *Handler) issueSession(u user.User) (string, *sessionClaims, error) {
	if strings.TrimSpace(h.AdminToken) == "" {
		return "", nil, errors.New("admin_token is required for session signing")
	}
	ttl := h.SessionTTL
	if ttl <= 0 {
		ttl = defaultSessionTTL
	}
	now := time.Now()
	claims := &sessionClaims{
		UserID:    u.ID,
		Username:  u.Username,
		Nickname:  u.Nickname,
		Role:      u.Role,
		IssuedAt:  now.Unix(),
		ExpiresAt: now.Add(ttl).Unix(),
	}
	raw, err := json.Marshal(claims)
	if err != nil {
		return "", nil, err
	}
	payload := base64.RawURLEncoding.EncodeToString(raw)
	mac := hmac.New(sha256.New, []byte(h.AdminToken))
	mac.Write([]byte(payload))
	sig := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return payload + "." + sig, claims, nil
}

func (h *Handler) verifySession(token string) (*sessionClaims, error) {
	if strings.TrimSpace(h.AdminToken) == "" {
		return nil, errors.New("admin_token is required")
	}
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		return nil, errors.New("bad token format")
	}
	mac := hmac.New(sha256.New, []byte(h.AdminToken))
	mac.Write([]byte(parts[0]))
	expected := mac.Sum(nil)
	got, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, err
	}
	if subtle.ConstantTimeCompare(got, expected) != 1 {
		return nil, errors.New("bad token signature")
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, err
	}
	var claims sessionClaims
	if err := json.Unmarshal(raw, &claims); err != nil {
		return nil, err
	}
	if time.Now().Unix() > claims.ExpiresAt {
		return nil, errors.New("token expired")
	}
	if !user.IsAdminRole(claims.Role) {
		return nil, errors.New("admin role required")
	}
	return &claims, nil
}

func toAdminUser(u user.User) api.AdminUser {
	pks := make([]api.AdminPubkey, 0, len(u.Pubkeys))
	for _, p := range u.Pubkeys {
		var revAt *string
		if p.RevokedAt != nil {
			s := p.RevokedAt.Format(time.RFC3339)
			revAt = &s
		}
		pks = append(pks, api.AdminPubkey{
			ID:         p.ID,
			PubkeyHash: p.PubkeyHash,
			PubkeyHex:  p.PubkeyHex,
			CreatedAt:  p.CreatedAt.Format(time.RFC3339),
			RevokedAt:  revAt,
		})
	}
	role := u.Role
	if role == "" {
		role = string(user.RoleUser)
	}
	return api.AdminUser{
		ID:        u.ID,
		Username:  u.Username,
		Nickname:  u.Nickname,
		Email:     u.Email,
		Tier:      u.Tier,
		Role:      role,
		Disabled:  u.Disabled,
		CreatedAt: u.CreatedAt.Format(time.RFC3339),
		Pubkeys:   pks,
	}
}

func smtpConfigResponse(settings system.SMTPSettings) api.AdminSMTPConfig {
	return api.AdminSMTPConfig{
		Enabled:     settings.Enabled,
		Host:        settings.Host,
		Port:        settings.Port,
		Username:    settings.Username,
		From:        settings.From,
		TLSMode:     settings.TLSMode,
		PasswordSet: strings.TrimSpace(settings.Password) != "",
	}
}

func validateSMTPSettings(settings system.SMTPSettings) error {
	mode := strings.ToLower(strings.TrimSpace(settings.TLSMode))
	switch mode {
	case "", "starttls", "require_starttls", "tls":
	default:
		return errors.New("tls_mode invalid")
	}
	if settings.Port < 0 || settings.Port > 65535 {
		return errors.New("port invalid")
	}
	if settings.Enabled {
		_, err := auth.NewSMTPSender(auth.SMTPConfig{
			Host:     settings.Host,
			Port:     settings.Port,
			Username: settings.Username,
			Password: settings.Password,
			From:     settings.From,
			TLSMode:  settings.TLSMode,
		})
		return err
	}
	return nil
}

func actorFromContext(c *gin.Context) system.AuditActor {
	v, ok := c.Get(contextKey())
	if !ok {
		return system.AuditActor{}
	}
	actor, ok := v.(system.AuditActor)
	if !ok {
		return system.AuditActor{}
	}
	return actor
}

func sessionUserFromClaims(claims *sessionClaims) api.AdminSessionUser {
	if claims == nil {
		return api.AdminSessionUser{}
	}
	return api.AdminSessionUser{
		ID:       claims.UserID,
		Username: claims.Username,
		Nickname: claims.Nickname,
		Role:     claims.Role,
	}
}

func sessionUserFromActor(actor system.AuditActor) api.AdminSessionUser {
	return api.AdminSessionUser{
		ID:       actor.ID,
		Username: actor.Username,
		Role:     actor.Role,
	}
}

func (h *Handler) audit(actor system.AuditActor, action, target, detail string) {
	if h.SystemStore != nil {
		h.SystemStore.AppendAudit(actor, action, target, detail)
	}
}

func jsonDetail(v any) string {
	raw, err := json.Marshal(v)
	if err != nil {
		return ""
	}
	return string(raw)
}

func contextKey() string {
	return "admin_actor"
}

func errorJSON(c *gin.Context, status int, code, msg string) {
	c.JSON(status, api.ErrorResponse{Error: code, Message: msg})
}

func atoi(s string) int {
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + int(c-'0')
	}
	return n
}

func uint64Atoi(s string) uint64 {
	var n uint64
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + uint64(c-'0')
	}
	return n
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
