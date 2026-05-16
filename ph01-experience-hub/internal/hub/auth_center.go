package hub

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"
)

var ErrAuthCenterAdminRequired = errors.New("auth-center admin session required")

type AuthCenterAdminVerifier interface {
	VerifyAdminSession(ctx context.Context, cfg AuthCenterConfig, bearerToken string) (AuthCenterAdmin, error)
}

type DelegatedPowClient interface {
	CreateDelegatedPowChallenge(ctx context.Context, cfg AuthCenterConfig, purpose, subjectHash, pubkeyHash string) (AuthCenterDelegatedPowChallenge, error)
	FetchDelegatedPowStatus(ctx context.Context, cfg AuthCenterConfig, challengeID, purpose, subjectHash, pubkeyHash string) (AuthCenterDelegatedPowStatus, error)
}

type AuthCenterAdmin struct {
	ID       uint64 `json:"id"`
	Username string `json:"username"`
	Nickname string `json:"nickname,omitempty"`
	Role     string `json:"role"`
}

type AuthCenterPubkeyStatus struct {
	Valid       bool   `json:"valid"`
	UserID      uint64 `json:"user_id,omitempty"`
	Username    string `json:"username,omitempty"`
	Role        string `json:"role,omitempty"`
	IsAdmin     bool   `json:"is_admin,omitempty"`
	PubkeyHash  string `json:"pubkey_hash"`
	PowVerified bool   `json:"pow_verified"`
}

type AuthCenterDelegatedPowChallenge struct {
	ChallengeID string `json:"challenge_id"`
	Purpose     string `json:"purpose,omitempty"`
	SubjectHash string `json:"subject_hash,omitempty"`
	PubkeyHash  string `json:"pubkey_hash,omitempty"`
	ExpiresAt   int64  `json:"expires_at,omitempty"`
}

type AuthCenterDelegatedPowStatus struct {
	ChallengeID string `json:"challenge_id"`
	Purpose     string `json:"purpose,omitempty"`
	SubjectHash string `json:"subject_hash,omitempty"`
	PubkeyHash  string `json:"pubkey_hash,omitempty"`
	Verified    bool   `json:"verified"`
	Algorithm   string `json:"algorithm,omitempty"`
	Score       int    `json:"score,omitempty"`
	VerifiedAt  int64  `json:"verified_at,omitempty"`
	ExpiresAt   int64  `json:"expires_at,omitempty"`
}

type authCenterPubkeyStatusResponse struct {
	Items []AuthCenterPubkeyStatus `json:"items"`
}

func (a AuthCenterAdmin) IsAdmin() bool {
	switch strings.ToLower(strings.TrimSpace(a.Role)) {
	case "root", "admin":
		return true
	default:
		return false
	}
}

func (s AuthCenterPubkeyStatus) HasAdminRole() bool {
	if s.IsAdmin {
		return true
	}
	switch strings.ToLower(strings.TrimSpace(s.Role)) {
	case "root", "admin":
		return true
	default:
		return false
	}
}

type HTTPAuthCenterAdminVerifier struct {
	Client *http.Client
}

type HTTPDelegatedPowClient struct {
	Client *http.Client
}

func (v HTTPAuthCenterAdminVerifier) VerifyAdminSession(ctx context.Context, cfg AuthCenterConfig, bearerToken string) (AuthCenterAdmin, error) {
	base := strings.TrimRight(strings.TrimSpace(cfg.BaseURL), "/")
	if base == "" {
		return AuthCenterAdmin{}, errors.New("auth_center.base_url is required")
	}
	token := strings.TrimSpace(bearerToken)
	if token == "" {
		return AuthCenterAdmin{}, ErrAuthCenterAdminRequired
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/admin/session/self", nil)
	if err != nil {
		return AuthCenterAdmin{}, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	client := v.Client
	if client == nil {
		client = &http.Client{Timeout: 5 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return AuthCenterAdmin{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return AuthCenterAdmin{}, fmt.Errorf("%w: auth-center status %d", ErrAuthCenterAdminRequired, resp.StatusCode)
	}
	var admin AuthCenterAdmin
	if err := json.NewDecoder(resp.Body).Decode(&admin); err != nil {
		return AuthCenterAdmin{}, err
	}
	if !admin.IsAdmin() {
		return AuthCenterAdmin{}, ErrAuthCenterAdminRequired
	}
	return admin, nil
}

func FetchAuthCenterPubkeyStatuses(ctx context.Context, cfg AuthCenterConfig, hashes []string) (map[string]AuthCenterPubkeyStatus, error) {
	base := strings.TrimRight(strings.TrimSpace(cfg.BaseURL), "/")
	if base == "" || len(hashes) == 0 {
		return map[string]AuthCenterPubkeyStatus{}, nil
	}
	body := strings.NewReader(mustJSON(map[string]any{"pubkey_hashes": hashes}))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/api/v1/auth/pubkeys/status", body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("auth-center pubkey status returned %d", resp.StatusCode)
	}
	var out authCenterPubkeyStatusResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	byHash := make(map[string]AuthCenterPubkeyStatus, len(out.Items))
	for _, item := range out.Items {
		byHash[strings.ToLower(strings.TrimSpace(item.PubkeyHash))] = item
	}
	return byHash, nil
}

func (v HTTPDelegatedPowClient) CreateDelegatedPowChallenge(ctx context.Context, cfg AuthCenterConfig, purpose, subjectHash, pubkeyHash string) (AuthCenterDelegatedPowChallenge, error) {
	base := strings.TrimRight(strings.TrimSpace(cfg.BaseURL), "/")
	if base == "" {
		return AuthCenterDelegatedPowChallenge{}, errors.New("auth_center.base_url is required")
	}
	body := strings.NewReader(mustJSON(map[string]any{
		"purpose":      strings.TrimSpace(purpose),
		"subject_hash": strings.ToLower(strings.TrimSpace(subjectHash)),
		"pubkey_hash":  strings.ToLower(strings.TrimSpace(pubkeyHash)),
	}))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/api/v1/auth/pow/delegated/challenge", body)
	if err != nil {
		return AuthCenterDelegatedPowChallenge{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	client := v.Client
	if client == nil {
		client = &http.Client{Timeout: 5 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return AuthCenterDelegatedPowChallenge{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return AuthCenterDelegatedPowChallenge{}, fmt.Errorf("auth-center delegated pow challenge returned %d", resp.StatusCode)
	}
	var out AuthCenterDelegatedPowChallenge
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return AuthCenterDelegatedPowChallenge{}, err
	}
	return out, nil
}

func (v HTTPDelegatedPowClient) FetchDelegatedPowStatus(ctx context.Context, cfg AuthCenterConfig, challengeID, purpose, subjectHash, pubkeyHash string) (AuthCenterDelegatedPowStatus, error) {
	base := strings.TrimRight(strings.TrimSpace(cfg.BaseURL), "/")
	if base == "" {
		return AuthCenterDelegatedPowStatus{}, errors.New("auth_center.base_url is required")
	}
	body := strings.NewReader(mustJSON(map[string]any{
		"challenge_id": strings.TrimSpace(challengeID),
		"purpose":      strings.TrimSpace(purpose),
		"subject_hash": strings.ToLower(strings.TrimSpace(subjectHash)),
		"pubkey_hash":  strings.ToLower(strings.TrimSpace(pubkeyHash)),
	}))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/api/v1/auth/pow/delegated/status", body)
	if err != nil {
		return AuthCenterDelegatedPowStatus{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	client := v.Client
	if client == nil {
		client = &http.Client{Timeout: 5 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return AuthCenterDelegatedPowStatus{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return AuthCenterDelegatedPowStatus{}, fmt.Errorf("auth-center delegated pow status returned %d", resp.StatusCode)
	}
	var out AuthCenterDelegatedPowStatus
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return AuthCenterDelegatedPowStatus{}, err
	}
	return out, nil
}

func ExperiencePackagePowSubjectHash(packageSHA256, pubkeyHash string) string {
	return sha256Hex([]byte(strings.Join([]string{
		ExperiencePackagePowPurpose,
		strings.ToLower(strings.TrimSpace(packageSHA256)),
		strings.ToLower(strings.TrimSpace(pubkeyHash)),
	}, "\n")))
}

func mustJSON(v any) string {
	data, err := json.Marshal(v)
	if err != nil {
		return "{}"
	}
	return string(data)
}
