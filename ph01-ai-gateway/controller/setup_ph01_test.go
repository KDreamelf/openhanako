package controller

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestPostSetupDisabledWhenPH01AuthConfigured(t *testing.T) {
	t.Setenv("PH01_AUTH_BASE_URL", "https://ph01-auth-center:8443")
	gin.SetMode(gin.TestMode)

	r := gin.New()
	r.POST("/setup", PostSetup)

	req := httptest.NewRequest(http.MethodPost, "/setup", strings.NewReader(`{}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "PH01 AI 网关初始化由认证中心接管") {
		t.Fatalf("expected PH01 setup disabled response, got %s", rec.Body.String())
	}
}
