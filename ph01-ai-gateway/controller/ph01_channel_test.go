package controller

import (
	"bytes"
	"encoding/hex"
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

func TestPH01RevokeChannelsForUserClearsOnlyTargetUser(t *testing.T) {
	oldChannels := ph01Channels
	oldRedisEnabled := common.RedisEnabled
	ph01Channels = sync.Map{}
	common.RedisEnabled = false
	t.Cleanup(func() {
		ph01Channels = oldChannels
		common.RedisEnabled = oldRedisEnabled
	})

	require.NoError(t, ph01StoreChannel(&ph01Channel{
		ID:            "target-1",
		GatewayUserID: 10,
		PH01UserID:    42,
		AESKeyHex:     strings.Repeat("0", 64),
		ExpiresAt:     time.Now().Add(time.Minute),
	}))
	require.NoError(t, ph01StoreChannel(&ph01Channel{
		ID:            "target-2",
		GatewayUserID: 10,
		PH01UserID:    42,
		AESKeyHex:     strings.Repeat("1", 64),
		ExpiresAt:     time.Now().Add(time.Minute),
	}))
	require.NoError(t, ph01StoreChannel(&ph01Channel{
		ID:            "other",
		GatewayUserID: 11,
		PH01UserID:    43,
		AESKeyHex:     strings.Repeat("2", 64),
		ExpiresAt:     time.Now().Add(time.Minute),
	}))

	revoked, err := ph01RevokeChannelsForUser(42)
	require.NoError(t, err)
	require.Equal(t, 2, revoked)
	target1, err := ph01GetChannel("target-1")
	require.NoError(t, err)
	require.Nil(t, target1)
	target2, err := ph01GetChannel("target-2")
	require.NoError(t, err)
	require.Nil(t, target2)
	other, err := ph01GetChannel("other")
	require.NoError(t, err)
	require.NotNil(t, other)
}

func TestPH01InternalRevokeChannelsEndpoint(t *testing.T) {
	oldChannels := ph01Channels
	oldRedisEnabled := common.RedisEnabled
	ph01Channels = sync.Map{}
	common.RedisEnabled = false
	t.Cleanup(func() {
		ph01Channels = oldChannels
		common.RedisEnabled = oldRedisEnabled
	})

	t.Setenv("PH01_AUTH_INTERNAL_TOKEN", "sync-secret")
	require.NoError(t, ph01StoreChannel(&ph01Channel{
		ID:            "target",
		GatewayUserID: 10,
		PH01UserID:    42,
		AESKeyHex:     strings.Repeat("0", 64),
		ExpiresAt:     time.Now().Add(time.Minute),
	}))

	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.POST("/revoke", PH01InternalRevokeChannels)
	body := []byte(`{"ph01_user_id":42,"reason":"pubkey_rotation"}`)
	req := httptest.NewRequest(http.MethodPost, "/revoke", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer sync-secret")
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	require.Equal(t, http.StatusOK, rec.Code)
	var resp struct {
		Success bool `json:"success"`
		Data    struct {
			RevokedCount int `json:"revoked_count"`
		} `json:"data"`
	}
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &resp))
	require.True(t, resp.Success)
	require.Equal(t, 1, resp.Data.RevokedCount)
	ch, err := ph01GetChannel("target")
	require.NoError(t, err)
	require.Nil(t, ch)
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

func TestPH01PublicStoryModelsPreservesPublicTokenLimitOrder(t *testing.T) {
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
		"model_limits":         "login-story-model,gpt-5.5",
	}).Error)
	require.NoError(t, db.Create(&[]model.Ability{
		{Group: "default", Model: "gpt-5.5", ChannelId: 1, Enabled: true},
		{Group: "default", Model: "login-story-model", ChannelId: 1, Enabled: true},
	}).Error)

	rec := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(rec)
	c.Request = httptest.NewRequest(http.MethodGet, "/api/v1/public/story/models", nil)

	PH01PublicStoryModels(c)

	require.Equal(t, http.StatusOK, rec.Code)
	var body struct {
		Models []string `json:"models"`
	}
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &body))
	require.Equal(t, []string{"login-story-model", "gpt-5.5"}, body.Models)
}

func TestPH01PublicStoryModelsUsesExplicitPublicTokenLimitsAsSourceOfTruth(t *testing.T) {
	db := setupModelListControllerTestDB(t)
	require.NoError(t, db.AutoMigrate(&model.Token{}, &model.PH01Identity{}))

	oldSelfUseModeEnabled := operation_setting.SelfUseModeEnabled
	operation_setting.SelfUseModeEnabled = false
	t.Cleanup(func() {
		operation_setting.SelfUseModeEnabled = oldSelfUseModeEnabled
	})

	rootUser, _, err := model.FindOrCreateUserFromPH01(1, "root", "beef")
	require.NoError(t, err)
	var publicToken model.Token
	require.NoError(t, db.First(&publicToken, "user_id = ? AND name = ?", rootUser.Id, model.PH01PublicTokenName).Error)
	require.NoError(t, db.Model(&publicToken).Updates(map[string]any{
		"group":                "default",
		"unlimited_quota":      true,
		"model_limits_enabled": true,
		"model_limits":         "explicit-story-model",
	}).Error)
	require.NoError(t, db.Create(&model.Ability{
		Group: "default", Model: "different-chat-model", ChannelId: 1, Enabled: true,
	}).Error)

	rec := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(rec)
	c.Request = httptest.NewRequest(http.MethodGet, "/api/v1/public/story/models", nil)

	PH01PublicStoryModels(c)

	require.Equal(t, http.StatusOK, rec.Code)
	var body struct {
		Models []string `json:"models"`
	}
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &body))
	require.Equal(t, []string{"explicit-story-model"}, body.Models)
}

func TestPH01PublicStoryModelsAcceptsEncryptedEnvelope(t *testing.T) {
	db := setupModelListControllerTestDB(t)
	require.NoError(t, db.AutoMigrate(&model.Token{}, &model.PH01Identity{}))

	oldSelfUseModeEnabled := operation_setting.SelfUseModeEnabled
	oldChannels := ph01Channels
	operation_setting.SelfUseModeEnabled = true
	ph01Channels = sync.Map{}
	t.Cleanup(func() {
		operation_setting.SelfUseModeEnabled = oldSelfUseModeEnabled
		ph01Channels = oldChannels
	})

	rootUser, _, err := model.FindOrCreateUserFromPH01(1, "root", "beef")
	require.NoError(t, err)
	var publicToken model.Token
	require.NoError(t, db.First(&publicToken, "user_id = ? AND name = ?", rootUser.Id, model.PH01PublicTokenName).Error)
	require.NoError(t, db.Model(&publicToken).Updates(map[string]any{
		"group":                "default",
		"unlimited_quota":      true,
		"model_limits_enabled": true,
		"model_limits":         "story-model",
		"allow_ips":            "203.0.113.1/32",
	}).Error)
	require.NoError(t, db.Create(&model.Ability{
		Group: "default", Model: "story-model", ChannelId: 1, Enabled: true,
	}).Error)

	aesKey := []byte("0123456789abcdef0123456789abcdef")
	ch := &ph01Channel{
		ID:            "story-models-channel",
		GatewayUserID: rootUser.Id,
		PH01UserID:    1,
		Username:      "root",
		Tier:          "free",
		TokenID:       int(publicToken.Id),
		AESKeyHex:     hex.EncodeToString(aesKey),
		AllowedModels: []string{"chat-model"},
		CreatedAt:     time.Now(),
		ExpiresAt:     time.Now().Add(time.Minute),
	}
	require.NoError(t, ph01StoreChannel(ch))

	nonce, ciphertext, tag, err := ph01EncryptGCM(aesKey, []byte(`{"purpose":"public_story_models"}`))
	require.NoError(t, err)
	reqBody, err := json.Marshal(ph01EncryptedEnvelope{
		ChannelID:  ch.ID,
		Nonce:      nonce,
		Ciphertext: ciphertext,
		Tag:        tag,
	})
	require.NoError(t, err)

	rec := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(rec)
	c.Request = httptest.NewRequest(http.MethodPost, "/api/v1/public/story/models", strings.NewReader(string(reqBody)))
	c.Request.RemoteAddr = "198.51.100.2:12345"

	PH01PublicStoryModels(c)

	require.Equal(t, http.StatusOK, rec.Code)
	var encryptedResp ph01EncryptedEnvelope
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &encryptedResp))
	plaintext, err := ph01DecryptGCM(
		aesKey,
		encryptedResp.Nonce,
		encryptedResp.Ciphertext,
		encryptedResp.Tag,
	)
	require.NoError(t, err)
	var body struct {
		Models []string `json:"models"`
		Tier   string   `json:"tier"`
	}
	require.NoError(t, json.Unmarshal(plaintext, &body))
	require.Equal(t, "public", body.Tier)
	require.Equal(t, []string{"story-model"}, body.Models)
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
