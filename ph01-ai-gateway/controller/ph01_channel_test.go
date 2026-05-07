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
