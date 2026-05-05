// Package gateway 调 auth-gateway 验签的客户端。
package gateway

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/hanako/ph01-backend/pkg/api"
)

// AuthClient 调 auth-gateway 的内部 HTTP 客户端。
type AuthClient struct {
	BaseURL string
	HTTP    *http.Client
}

func NewAuthClient(baseURL string) *AuthClient {
	return &AuthClient{
		BaseURL: baseURL,
		HTTP:    &http.Client{Timeout: 5 * time.Second},
	}
}

// VerifySignature 调 POST /api/v1/auth/verify_signature。
func (c *AuthClient) VerifySignature(ctx context.Context, req *api.VerifySignatureRequest) (*api.VerifySignatureResponse, error) {
	body, _ := json.Marshal(req)
	httpReq, err := http.NewRequestWithContext(ctx, "POST",
		c.BaseURL+"/api/v1/auth/verify_signature", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := c.HTTP.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("auth-gateway unreachable: %w", err)
	}
	defer resp.Body.Close()
	var out api.VerifySignatureResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return &out, nil
}
