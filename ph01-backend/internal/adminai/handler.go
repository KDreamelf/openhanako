// Package adminai AI 网关的管理后台 API。
package adminai

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/hanako/ph01-backend/internal/llm"
	"github.com/hanako/ph01-backend/pkg/api"
)

type Handler struct {
	LLM        *llm.Repo
	AdminToken string
}

func (h *Handler) Register(r *gin.RouterGroup) {
	r.Use(h.authMiddleware)
	// Upstream
	r.GET("/upstreams", h.ListUpstreams)
	r.POST("/upstreams", h.CreateUpstream)
	r.PATCH("/upstreams/:id", h.UpdateUpstream)
	r.DELETE("/upstreams/:id", h.DeleteUpstream)
	// Mapping
	r.GET("/mappings", h.ListMappings)
	r.POST("/mappings", h.CreateMapping)
	r.PATCH("/mappings/:id", h.UpdateMapping)
	r.DELETE("/mappings/:id", h.DeleteMapping)
	// TierPolicy
	r.GET("/tiers", h.ListTiers)
	r.PATCH("/tiers/:tier", h.UpdateTier)
}

func (h *Handler) authMiddleware(c *gin.Context) {
	header := c.GetHeader("Authorization")
	if !strings.HasPrefix(header, "Bearer ") {
		c.AbortWithStatusJSON(http.StatusUnauthorized,
			api.ErrorResponse{Error: "missing_bearer"})
		return
	}
	tok := strings.TrimPrefix(header, "Bearer ")
	if tok != h.AdminToken {
		c.AbortWithStatusJSON(http.StatusUnauthorized,
			api.ErrorResponse{Error: "invalid_admin_token"})
		return
	}
	c.Next()
}

func (h *Handler) ListUpstreams(c *gin.Context) {
	us, err := h.LLM.ListUpstreams()
	if err != nil {
		errResp(c, http.StatusInternalServerError, err)
		return
	}
	// 不返回完整 api_key
	for i := range us {
		if len(us[i].APIKey) > 8 {
			us[i].APIKey = us[i].APIKey[:4] + "..." + us[i].APIKey[len(us[i].APIKey)-4:]
		}
	}
	c.JSON(http.StatusOK, gin.H{"items": us})
}

func (h *Handler) CreateUpstream(c *gin.Context) {
	var u llm.Upstream
	if err := c.ShouldBindJSON(&u); err != nil {
		errResp(c, http.StatusBadRequest, err)
		return
	}
	if u.Format == "" {
		u.Format = "openai"
	}
	u.Enabled = true
	if err := h.LLM.CreateUpstream(&u); err != nil {
		errResp(c, http.StatusInternalServerError, err)
		return
	}
	c.JSON(http.StatusOK, u)
}

func (h *Handler) UpdateUpstream(c *gin.Context) {
	id := uint64Atoi(c.Param("id"))
	var existing llm.Upstream
	if err := h.LLM.DB.First(&existing, id).Error; err != nil {
		errResp(c, http.StatusNotFound, err)
		return
	}
	var patch llm.Upstream
	if err := c.ShouldBindJSON(&patch); err != nil {
		errResp(c, http.StatusBadRequest, err)
		return
	}
	if patch.Name != "" {
		existing.Name = patch.Name
	}
	if patch.BaseURL != "" {
		existing.BaseURL = patch.BaseURL
	}
	if patch.Format != "" {
		existing.Format = patch.Format
	}
	if patch.APIKey != "" {
		existing.APIKey = patch.APIKey
	}
	existing.Enabled = patch.Enabled
	if err := h.LLM.UpdateUpstream(&existing); err != nil {
		errResp(c, http.StatusInternalServerError, err)
		return
	}
	c.JSON(http.StatusOK, existing)
}

func (h *Handler) DeleteUpstream(c *gin.Context) {
	id := uint64Atoi(c.Param("id"))
	if err := h.LLM.DeleteUpstream(id); err != nil {
		errResp(c, http.StatusInternalServerError, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (h *Handler) ListMappings(c *gin.Context) {
	ms, err := h.LLM.ListMappings()
	if err != nil {
		errResp(c, http.StatusInternalServerError, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": ms})
}

func (h *Handler) CreateMapping(c *gin.Context) {
	var m llm.ModelMapping
	if err := c.ShouldBindJSON(&m); err != nil {
		errResp(c, http.StatusBadRequest, err)
		return
	}
	if m.MinTier == "" {
		m.MinTier = "free"
	}
	m.Enabled = true
	if err := h.LLM.CreateMapping(&m); err != nil {
		errResp(c, http.StatusInternalServerError, err)
		return
	}
	c.JSON(http.StatusOK, m)
}

func (h *Handler) UpdateMapping(c *gin.Context) {
	id := uint64Atoi(c.Param("id"))
	var existing llm.ModelMapping
	if err := h.LLM.DB.First(&existing, id).Error; err != nil {
		errResp(c, http.StatusNotFound, err)
		return
	}
	var patch llm.ModelMapping
	if err := c.ShouldBindJSON(&patch); err != nil {
		errResp(c, http.StatusBadRequest, err)
		return
	}
	if patch.PublicName != "" {
		existing.PublicName = patch.PublicName
	}
	if patch.UpstreamID != 0 {
		existing.UpstreamID = patch.UpstreamID
	}
	if patch.UpstreamName != "" {
		existing.UpstreamName = patch.UpstreamName
	}
	if patch.MinTier != "" {
		existing.MinTier = patch.MinTier
	}
	existing.Enabled = patch.Enabled
	if err := h.LLM.UpdateMapping(&existing); err != nil {
		errResp(c, http.StatusInternalServerError, err)
		return
	}
	c.JSON(http.StatusOK, existing)
}

func (h *Handler) DeleteMapping(c *gin.Context) {
	id := uint64Atoi(c.Param("id"))
	if err := h.LLM.DeleteMapping(id); err != nil {
		errResp(c, http.StatusInternalServerError, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (h *Handler) ListTiers(c *gin.Context) {
	ts, err := h.LLM.ListTierPolicies()
	if err != nil {
		errResp(c, http.StatusInternalServerError, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": ts})
}

func (h *Handler) UpdateTier(c *gin.Context) {
	tier := c.Param("tier")
	t, err := h.LLM.GetTierPolicy(tier)
	if err != nil {
		errResp(c, http.StatusNotFound, err)
		return
	}
	var patch llm.TierPolicy
	if err := c.ShouldBindJSON(&patch); err != nil {
		errResp(c, http.StatusBadRequest, err)
		return
	}
	if patch.PerMinute > 0 {
		t.PerMinute = patch.PerMinute
	}
	if patch.PerDay != 0 {
		t.PerDay = patch.PerDay
	}
	if patch.MaxTokensIn > 0 {
		t.MaxTokensIn = patch.MaxTokensIn
	}
	if patch.MaxTokensOut > 0 {
		t.MaxTokensOut = patch.MaxTokensOut
	}
	if err := h.LLM.UpdateTierPolicy(t); err != nil {
		errResp(c, http.StatusInternalServerError, err)
		return
	}
	c.JSON(http.StatusOK, t)
}

func errResp(c *gin.Context, status int, err error) {
	c.JSON(status, api.ErrorResponse{
		Error:   "error",
		Message: err.Error(),
	})
}

func uint64Atoi(s string) uint64 {
	var n uint64
	for _, ch := range s {
		if ch < '0' || ch > '9' {
			return 0
		}
		n = n*10 + uint64(ch-'0')
	}
	return n
}
