package controller

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/model"
	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

func TestLookupPH01IPLocationUsesAPIAndCache(t *testing.T) {
	oldCache := ph01GeoIPCache
	ph01GeoIPCache = sync.Map{}
	t.Cleanup(func() {
		ph01GeoIPCache = oldCache
	})

	var hits atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"status":     "success",
			"country":    "CN",
			"regionName": "Beijing",
			"city":       "Beijing",
		})
	}))
	defer server.Close()

	t.Setenv("PH01_GEOIP_API_URL", server.URL+"/json/{ip}")
	t.Setenv("PH01_GEOIP_CACHE_TTL_HOURS", "24")

	first := lookupPH01IPLocation("8.8.8.8")
	second := lookupPH01IPLocation("8.8.8.8")

	require.Equal(t, "CN / Beijing / Beijing", first)
	require.Equal(t, first, second)
	require.Equal(t, int32(1), hits.Load())
}

func TestLookupPH01IPLocationPrivateIP(t *testing.T) {
	require.Equal(t, "local/private", lookupPH01IPLocation("127.0.0.1"))
}

func TestPH01SignedLoginRequiresUserID(t *testing.T) {
	req := PH01SignedLoginRequest{
		Signature: "abcd",
		Nonce:     "nonce",
	}
	require.Error(t, req.normalize())

	req.UserID = 42
	require.NoError(t, req.normalize())
}

func TestResolvePH01ProtocolChallengeByQueryOrBody(t *testing.T) {
	oldStore := ph01PendingChallenges
	ph01PendingChallenges = sync.Map{}
	t.Cleanup(func() {
		ph01PendingChallenges = oldStore
	})

	challenge := PH01LoginChallenge{
		Version:     1,
		Purpose:     ph01GatewayLoginPurpose,
		ChallengeID: "nonce",
		Nonce:       "nonce",
		IP:          "127.0.0.1",
		IPLocation:  "local/private",
		UserAgent:   "test-agent",
		IssuedAt:    1,
		ExpiresAt:   1 << 62,
	}
	encoded, err := encodePH01Challenge(challenge)
	require.NoError(t, err)
	ph01PendingChallenges.Store(challenge.ChallengeID, &ph01PendingChallenge{
		Challenge: challenge,
		Encoded:   encoded,
	})

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodPost, "/callback?nonce=nonce", nil)

	record, err := resolvePH01LoginChallenge(c, "", "")
	require.NoError(t, err)
	require.Equal(t, challenge.ChallengeID, record.Challenge.ChallengeID)

	c.Request = httptest.NewRequest(http.MethodPost, "/callback", nil)
	record, err = resolvePH01LoginChallenge(c, "nonce", encoded)
	require.NoError(t, err)
	require.Equal(t, challenge.ChallengeID, record.Challenge.ChallengeID)
}

func TestPH01InternalSyncUserUsesAuthUsername(t *testing.T) {
	oldRedisEnabled := common.RedisEnabled
	oldDB := model.DB
	oldLogDB := model.LOG_DB
	common.RedisEnabled = false
	t.Cleanup(func() {
		common.RedisEnabled = oldRedisEnabled
		model.DB = oldDB
		model.LOG_DB = oldLogDB
	})

	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	model.DB = db
	model.LOG_DB = db
	require.NoError(t, db.AutoMigrate(&model.User{}, &model.Token{}, &model.PH01Identity{}))

	t.Setenv("PH01_AUTH_INTERNAL_TOKEN", "sync-secret")
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.POST("/sync", PH01InternalSyncUser)

	body := []byte(`{"ph01_user_id":42,"username":"angel","pubkey_hash":"ABCDEF"}`)
	req := httptest.NewRequest(http.MethodPost, "/sync", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer sync-secret")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	require.Equal(t, http.StatusOK, w.Code)
	var resp struct {
		Success bool `json:"success"`
		Data    struct {
			Username string `json:"username"`
		} `json:"data"`
	}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &resp))
	require.True(t, resp.Success)
	require.Equal(t, "angel", resp.Data.Username)

	var u model.User
	require.NoError(t, db.First(&u, "username = ?", "angel").Error)
	var identity model.PH01Identity
	require.NoError(t, db.First(&identity, "ph01_user_id = ?", uint64(42)).Error)
	require.Equal(t, u.Id, identity.UserId)
}
