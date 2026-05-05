// Package gateway UpstreamPipe：把解密后的 chat 请求转发到上游 LLM。
//
// 当前支持两种上游格式：
//   - openai：OpenAI compatible（含 DashScope/VolcEngine/MiniMax 等兼容服务）
//   - anthropic：Anthropic Messages API
//
// 流式响应：SSE 一边读一边加密回写到客户端。
package gateway

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	hcrypto "github.com/hanako/ph01-backend/internal/crypto"
	"github.com/hanako/ph01-backend/internal/llm"
	"github.com/hanako/ph01-backend/pkg/api"
)

// RateLimiter 抽象（避免直接依赖 redis 包）。
type RateLimiter interface {
	Allow(ctx context.Context, userID uint64, tier string) (bool, error)
}

// UpstreamPipe 转发引擎。
type UpstreamPipe struct {
	HTTPClient  *http.Client
	RateLimiter RateLimiter
}

func NewUpstreamPipe() *UpstreamPipe {
	return &UpstreamPipe{
		HTTPClient: &http.Client{Timeout: 5 * time.Minute},
	}
}

// NonStreamChat 非流式：拿到完整响应后整体加密返回。
func (p *UpstreamPipe) NonStreamChat(c *gin.Context, ch *Channel, mapping *llm.ModelMapping, req *api.ChatRequest, aesKey []byte) {
	// 把 model 名替换为上游 model 名
	upstreamReq := buildUpstreamRequest(mapping, req)

	body, _ := json.Marshal(upstreamReq)
	httpReq, err := buildHTTPRequest(c.Request.Context(), mapping, body, false)
	if err != nil {
		errResp(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	resp, err := p.HTTPClient.Do(httpReq)
	if err != nil {
		errResp(c, http.StatusBadGateway, api.ErrInternalError, err.Error())
		return
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)

	if resp.StatusCode >= 400 {
		errResp(c, resp.StatusCode, api.ErrInternalError, string(respBody))
		return
	}

	// 加密响应
	nonceHex, ctHex, tagHex, err := hcrypto.EncryptGCM(aesKey, respBody)
	if err != nil {
		errResp(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	c.JSON(http.StatusOK, api.EncryptedEnvelope{
		ChannelID:  ch.ID,
		Nonce:      nonceHex,
		Ciphertext: ctHex,
		Tag:        tagHex,
	})
}

// StreamChat 流式：边读边加密回写。
func (p *UpstreamPipe) StreamChat(c *gin.Context, ch *Channel, mapping *llm.ModelMapping, req *api.ChatRequest, aesKey []byte) {
	upstreamReq := buildUpstreamRequest(mapping, req)
	body, _ := json.Marshal(upstreamReq)
	httpReq, err := buildHTTPRequest(c.Request.Context(), mapping, body, true)
	if err != nil {
		errResp(c, http.StatusInternalServerError, api.ErrInternalError, err.Error())
		return
	}
	resp, err := p.HTTPClient.Do(httpReq)
	if err != nil {
		errResp(c, http.StatusBadGateway, api.ErrInternalError, err.Error())
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		respBody, _ := io.ReadAll(resp.Body)
		errResp(c, resp.StatusCode, api.ErrInternalError, string(respBody))
		return
	}

	// 设 SSE header
	c.Header("Content-Type", "text/event-stream")
	c.Header("Cache-Control", "no-cache")
	c.Header("Connection", "keep-alive")
	c.Header("X-Accel-Buffering", "no")

	flusher, ok := c.Writer.(http.Flusher)
	if !ok {
		errResp(c, http.StatusInternalServerError, api.ErrInternalError, "no flusher")
		return
	}

	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		// 直接把上游 SSE 一行一行加密转发
		nonceHex, ctHex, tagHex, err := hcrypto.EncryptGCM(aesKey, line)
		if err != nil {
			break
		}
		envBytes, _ := json.Marshal(api.EncryptedEnvelope{
			ChannelID:  ch.ID,
			Nonce:      nonceHex,
			Ciphertext: ctHex,
			Tag:        tagHex,
		})
		fmt.Fprintf(c.Writer, "data: %s\n\n", envBytes)
		flusher.Flush()
	}
	// 标识结束
	fmt.Fprint(c.Writer, "data: [DONE]\n\n")
	flusher.Flush()
}

// buildUpstreamRequest 把网关侧的 ChatRequest 转换成上游所需的请求体。
func buildUpstreamRequest(mapping *llm.ModelMapping, req *api.ChatRequest) map[string]interface{} {
	out := map[string]interface{}{
		"model":    mapping.UpstreamName,
		"messages": req.Messages,
		"stream":   req.Stream,
	}
	if len(req.Tools) > 0 {
		out["tools"] = req.Tools
	}
	for k, v := range req.Extra {
		out[k] = v
	}
	return out
}

// buildHTTPRequest 根据上游 format 构造 http.Request（含 endpoint 与认证）。
func buildHTTPRequest(ctx context.Context, mapping *llm.ModelMapping, body []byte, stream bool) (*http.Request, error) {
	if mapping.Upstream == nil {
		return nil, fmt.Errorf("upstream not loaded")
	}
	upstream := mapping.Upstream

	var path string
	switch strings.ToLower(upstream.Format) {
	case "openai":
		path = "/chat/completions"
	case "anthropic":
		path = "/messages"
	default:
		path = "/chat/completions"
	}

	req, err := http.NewRequestWithContext(ctx, "POST",
		strings.TrimRight(upstream.BaseURL, "/")+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if stream {
		req.Header.Set("Accept", "text/event-stream")
	}
	switch strings.ToLower(upstream.Format) {
	case "openai":
		if upstream.APIKey != "" {
			req.Header.Set("Authorization", "Bearer "+upstream.APIKey)
		}
	case "anthropic":
		req.Header.Set("x-api-key", upstream.APIKey)
		req.Header.Set("anthropic-version", "2023-06-01")
	}
	return req, nil
}
