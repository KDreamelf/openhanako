// Package syncai 调用 AI 网关内部接口，同步认证中心用户。
package syncai

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/hanako/ph01-backend/internal/auth"
)

type Client struct {
	BaseURL       string
	InternalToken string
	HTTPClient    *http.Client
}

func NewClient(baseURL, internalToken string, timeout time.Duration) *Client {
	baseURL = strings.TrimRight(strings.TrimSpace(baseURL), "/")
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	return &Client{
		BaseURL:       baseURL,
		InternalToken: strings.TrimSpace(internalToken),
		HTTPClient:    &http.Client{Timeout: timeout},
	}
}

func (c *Client) SyncUser(ctx context.Context, in auth.GatewayUserSyncRequest) error {
	if c == nil || strings.TrimSpace(c.BaseURL) == "" {
		return fmt.Errorf("ai gateway sync base_url is empty")
	}
	body, err := json.Marshal(in)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.BaseURL+"/api/ph01/internal/users/sync", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.InternalToken != "" {
		req.Header.Set("Authorization", "Bearer "+c.InternalToken)
	}
	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("ai gateway sync status=%d body=%s", resp.StatusCode, string(respBody))
	}
	var out struct {
		Success bool   `json:"success"`
		Message string `json:"message"`
	}
	if len(respBody) > 0 {
		if err := json.Unmarshal(respBody, &out); err == nil && !out.Success {
			if strings.TrimSpace(out.Message) == "" {
				out.Message = "ai gateway sync failed"
			}
			return errors.New(out.Message)
		}
	}
	return nil
}
