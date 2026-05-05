package ph01auth

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

const defaultAuthBaseURL = "http://localhost:8080"

type Client struct {
	BaseURL    string
	HTTPClient *http.Client
	initErr    error
}

type TLSFiles struct {
	CACertPath     string
	ClientCertPath string
	ClientKeyPath  string
	ServerName     string
}

type VerifySignatureRequest struct {
	// UserID is optional. When set, auth-gateway must confirm the public key
	// belongs to this PH01 user id.
	UserID       uint64 `json:"user_id,omitempty"`
	PubkeyHex    string `json:"pubkey_hex"`
	SignatureHex string `json:"signature_hex"`
	Payload      string `json:"payload"`
	Timestamp    int64  `json:"timestamp"`
	Nonce        string `json:"nonce"`
}

type VerifySignatureResponse struct {
	Valid      bool   `json:"valid"`
	UserID     uint64 `json:"user_id,omitempty"`
	Username   string `json:"username,omitempty"`
	Tier       string `json:"tier,omitempty"`
	PubkeyHash string `json:"pubkey_hash,omitempty"`
	Error      string `json:"error,omitempty"`
}

type VerifyChallengeSignatureRequest struct {
	UserID       uint64 `json:"user_id"`
	Challenge    string `json:"challenge"`
	SignatureHex string `json:"signature_hex"`
}

type PubkeyBindingCheck struct {
	UserID     uint64 `json:"user_id"`
	PubkeyHash string `json:"pubkey_hash"`
}

type VerifyPubkeysRequest struct {
	Items []PubkeyBindingCheck `json:"items"`
}

type VerifyPubkeysResponse struct {
	OK      bool                 `json:"ok"`
	Missing []PubkeyBindingCheck `json:"missing,omitempty"`
}

func NewClient(baseURL string) *Client {
	baseURL = strings.TrimSpace(baseURL)
	if baseURL == "" {
		baseURL = defaultAuthBaseURL
	}
	return &Client{
		BaseURL: strings.TrimRight(baseURL, "/"),
		HTTPClient: &http.Client{
			Timeout: 10 * time.Second,
		},
	}
}

func NewClientWithTLS(baseURL string, files TLSFiles) (*Client, error) {
	client := NewClient(baseURL)
	transport := http.DefaultTransport.(*http.Transport).Clone()
	tlsConfig := &tls.Config{
		MinVersion: tls.VersionTLS12,
		ServerName: strings.TrimSpace(files.ServerName),
	}

	if files.CACertPath != "" {
		caPEM, err := os.ReadFile(files.CACertPath)
		if err != nil {
			return nil, fmt.Errorf("read PH01 auth CA cert: %w", err)
		}
		roots := x509.NewCertPool()
		if !roots.AppendCertsFromPEM(caPEM) {
			return nil, fmt.Errorf("PH01 auth CA cert contains no PEM certificates")
		}
		tlsConfig.RootCAs = roots
	}

	if files.ClientCertPath != "" || files.ClientKeyPath != "" {
		if files.ClientCertPath == "" || files.ClientKeyPath == "" {
			return nil, fmt.Errorf("PH01 auth client cert and key must be configured together")
		}
		cert, err := tls.LoadX509KeyPair(files.ClientCertPath, files.ClientKeyPath)
		if err != nil {
			return nil, fmt.Errorf("load PH01 auth client certificate: %w", err)
		}
		tlsConfig.Certificates = []tls.Certificate{cert}
	}

	transport.TLSClientConfig = tlsConfig
	client.HTTPClient = &http.Client{
		Timeout:   10 * time.Second,
		Transport: transport,
	}
	return client, nil
}

func NewFromEnv() *Client {
	baseURL := os.Getenv("PH01_AUTH_BASE_URL")
	if baseURL == "" {
		baseURL = os.Getenv("PH01_AUTH_BASE")
	}
	caCert := strings.TrimSpace(os.Getenv("PH01_AUTH_CA_CERT"))
	clientCert := strings.TrimSpace(os.Getenv("PH01_AUTH_CLIENT_CERT"))
	clientKey := strings.TrimSpace(os.Getenv("PH01_AUTH_CLIENT_KEY"))
	if caCert == "" || clientCert == "" || clientKey == "" {
		client := NewClient(baseURL)
		client.initErr = fmt.Errorf("ph01 mtls env is incomplete: PH01_AUTH_CA_CERT, PH01_AUTH_CLIENT_CERT and PH01_AUTH_CLIENT_KEY are required")
		return client
	}
	client, err := NewClientWithTLS(baseURL, TLSFiles{
		CACertPath:     caCert,
		ClientCertPath: clientCert,
		ClientKeyPath:  clientKey,
		ServerName:     strings.TrimSpace(os.Getenv("PH01_AUTH_SERVER_NAME")),
	})
	if err != nil {
		client = NewClient(baseURL)
		client.initErr = err
	}
	return client
}

func (c *Client) VerifySignature(ctx context.Context, req VerifySignatureRequest) (*VerifySignatureResponse, error) {
	var out VerifySignatureResponse
	if err := c.postJSON(ctx, "/api/v1/auth/verify_signature", req, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *Client) VerifyChallengeSignature(ctx context.Context, req VerifyChallengeSignatureRequest) (*VerifySignatureResponse, error) {
	var out VerifySignatureResponse
	if err := c.postJSON(ctx, "/api/v1/auth/verify_challenge_signature", req, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *Client) VerifyPubkeys(ctx context.Context, req VerifyPubkeysRequest) (*VerifyPubkeysResponse, error) {
	var out VerifyPubkeysResponse
	if err := c.postJSON(ctx, "/api/v1/auth/verify_pubkeys", req, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (c *Client) postJSON(ctx context.Context, path string, in any, out any) error {
	if c.initErr != nil {
		return c.initErr
	}
	if c.HTTPClient == nil {
		c.HTTPClient = &http.Client{Timeout: 10 * time.Second}
	}
	body, err := json.Marshal(in)
	if err != nil {
		return err
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.BaseURL+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	if token := strings.TrimSpace(os.Getenv("PH01_AUTH_INTERNAL_TOKEN")); token != "" {
		httpReq.Header.Set("Authorization", "Bearer "+token)
	}

	resp, err := c.HTTPClient.Do(httpReq)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("ph01 auth center status=%d body=%s", resp.StatusCode, string(respBody))
	}
	if len(respBody) == 0 {
		return fmt.Errorf("ph01 auth center empty response")
	}
	if err := json.Unmarshal(respBody, out); err != nil {
		return fmt.Errorf("decode ph01 auth center response: %w", err)
	}
	return nil
}
