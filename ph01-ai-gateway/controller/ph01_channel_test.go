package controller

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/model"
	"github.com/QuantumNous/new-api/setting/operation_setting"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

func TestPH01ListModelsRequiresChannelID(t *testing.T) {
	gin.SetMode(gin.TestMode)
	rec := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(rec)
	c.Request = httptest.NewRequest(http.MethodGet, "/api/v1/models", nil)

	PH01ListModels(c)

	require.Equal(t, http.StatusBadRequest, rec.Code)
	require.Contains(t, rec.Body.String(), ph01ErrInvalidPayload)
}

func TestPH01PublicStoryModelsUsesRootPublicTokenLimits(t *testing.T) {
	db := setupModelListControllerTestDB(t)
	require.NoError(t, db.AutoMigrate(&model.Token{}, &model.PH01Identity{}))

	oldSelfUseModeEnabled := operation_setting.SelfUseModeEnabled
	operation_setting.SelfUseModeEnabled = true
	t.Cleanup(func() {
		operation_setting.SelfUseModeEnabled = oldSelfUseModeEnabled
	})

	rootUser, _, err := model.FindOrCreateUserFromPH01(1, "root", "beef")
	require.NoError(t, err)
	var publicToken model.Token
	require.NoError(t, db.First(&publicToken, "user_id = ? AND name = ?", rootUser.Id, model.PH01PublicTokenName).Error)
	require.NoError(t, db.Model(&publicToken).Updates(map[string]any{
		"group":                "default",
		"unlimited_quota":      false,
		"remain_quota":         200,
		"model_limits_enabled": true,
		"model_limits":         "story-model",
	}).Error)
	require.NoError(t, db.Create(&[]model.Ability{
		{Group: "default", Model: "story-model", ChannelId: 1, Enabled: true},
		{Group: "default", Model: "chat-model", ChannelId: 1, Enabled: true},
	}).Error)

	rec := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(rec)
	c.Request = httptest.NewRequest(http.MethodGet, "/api/v1/public/story/models", nil)

	PH01PublicStoryModels(c)

	require.Equal(t, http.StatusOK, rec.Code)
	var body struct {
		Models []string `json:"models"`
		Tier   string   `json:"tier"`
	}
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &body))
	require.Equal(t, "public", body.Tier)
	require.Equal(t, []string{"story-model"}, body.Models)
	require.NoError(t, db.First(&publicToken, "id = ?", publicToken.Id).Error)
	require.False(t, publicToken.UnlimitedQuota)
	require.Equal(t, 200, publicToken.RemainQuota)
}

func TestPH01PublicStoryChatRejectsStreamAndTools(t *testing.T) {
	require.NoError(t, ph01ValidatePublicStoryChatRequest(ph01ChatRequest{
		Model:    "story-model",
		Messages: []map[string]interface{}{{"role": "user", "content": "hi"}},
	}))
	require.Error(t, ph01ValidatePublicStoryChatRequest(ph01ChatRequest{
		Model:    "story-model",
		Messages: []map[string]interface{}{{"role": "user", "content": "hi"}},
		Stream:   true,
	}))
	require.Error(t, ph01ValidatePublicStoryChatRequest(ph01ChatRequest{
		Model:    "story-model",
		Messages: []map[string]interface{}{{"role": "user", "content": "hi"}},
		Tools:    []map[string]interface{}{{"type": "function"}},
	}))
}

func TestPH01ChannelStoreMemoryRoundTrip(t *testing.T) {
	oldRedisEnabled := common.RedisEnabled
	oldChannels := ph01Channels
	common.RedisEnabled = false
	ph01Channels = sync.Map{}
	t.Cleanup(func() {
		common.RedisEnabled = oldRedisEnabled
		ph01Channels = oldChannels
	})

	ch := &ph01Channel{
		ID:            "test-channel",
		GatewayUserID: 42,
		TokenID:       7,
		AESKeyHex:     strings.Repeat("0", 64),
		AllowedModels: []string{"gpt-test"},
		CreatedAt:     time.Now(),
		ExpiresAt:     time.Now().Add(time.Minute),
	}

	require.NoError(t, ph01StoreChannel(ch))
	got, err := ph01GetChannel(ch.ID)
	require.NoError(t, err)
	require.NotNil(t, got)
	require.Equal(t, ch.GatewayUserID, got.GatewayUserID)
	require.Equal(t, ch.AllowedModels, got.AllowedModels)
}

func TestPH01BuildRelayBodyFlattensExtra(t *testing.T) {
	body, req, err := ph01BuildRelayBody([]byte(`{
		"model":"gpt-test",
		"messages":[{"role":"user","content":"hi"}],
		"stream":true,
		"extra":{"temperature":0.2}
	}`))

	require.NoError(t, err)
	require.Equal(t, "gpt-test", req.Model)
	require.Contains(t, string(body), `"temperature":0.2`)
	require.NotContains(t, string(body), `"extra"`)
}

func TestPH01BuildRelayBodyPreservesNativeTools(t *testing.T) {
	body, req, err := ph01BuildRelayBody([]byte(`{
		"model":"gpt-test",
		"messages":[{"role":"user","content":"read package"}],
		"stream":true,
		"tools":[{
			"type":"function",
			"function":{
				"name":"read",
				"description":"read local file",
				"parameters":{
					"type":"object",
					"properties":{"path":{"type":"string"}},
					"required":["path"]
				}
			}
		}],
		"tool_choice":"auto"
	}`))

	require.NoError(t, err)
	require.Len(t, req.Tools, 1)

	var raw map[string]interface{}
	require.NoError(t, json.Unmarshal(body, &raw))
	require.Equal(t, "auto", raw["tool_choice"])
	require.Len(t, raw["tools"], 1)
}
