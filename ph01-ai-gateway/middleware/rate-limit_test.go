package middleware

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/QuantumNous/new-api/common"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

func TestPublicStoryRateLimitLimitsAnonymousRequests(t *testing.T) {
	gin.SetMode(gin.TestMode)

	oldRedisEnabled := common.RedisEnabled
	oldLimitNum := common.PublicStoryRateLimitNum
	oldLimitDuration := common.PublicStoryRateLimitDuration
	common.RedisEnabled = false
	common.PublicStoryRateLimitNum = 1
	common.PublicStoryRateLimitDuration = 30 * 60
	t.Cleanup(func() {
		common.RedisEnabled = oldRedisEnabled
		common.PublicStoryRateLimitNum = oldLimitNum
		common.PublicStoryRateLimitDuration = oldLimitDuration
	})

	router := gin.New()
	router.POST("/story", PublicStoryRateLimit(), func(c *gin.Context) {
		raw, err := io.ReadAll(c.Request.Body)
		require.NoError(t, err)
		c.String(http.StatusOK, string(raw))
	})

	ip := "198.51.100.77:12345"
	plain := `{"model":"story-model"}`
	first := performPublicStoryRequest(router, ip, plain)
	require.Equal(t, http.StatusOK, first.Code)
	require.Equal(t, plain, first.Body.String())

	second := performPublicStoryRequest(router, ip, plain)
	require.Equal(t, http.StatusTooManyRequests, second.Code)
}

func performPublicStoryRequest(
	router *gin.Engine,
	remoteAddr string,
	body string,
) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/story", strings.NewReader(body))
	req.RemoteAddr = remoteAddr
	router.ServeHTTP(rec, req)
	return rec
}
