package auth_test

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	secp "github.com/decred/dcrd/dcrec/secp256k1/v4"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/hanako/ph01-backend/internal/auth"
	hcrypto "github.com/hanako/ph01-backend/internal/crypto"
	"github.com/hanako/ph01-backend/internal/db"
	"github.com/hanako/ph01-backend/internal/user"
	"github.com/hanako/ph01-backend/pkg/api"
)

// TestEndToEndRegisterAndLogin 端到端：
//  1. 启动 auth-gateway（不带 Redis，nonce 防重放跳过）
//  2. 用本地生成的 secp256k1 密钥对调 /api/v1/auth/register
//  3. 验证返回身份摘要，不签发 token
//  4. 同一密钥再调 /api/v1/auth/login 应成功
//  5. 不存在用户名 login 应失败
//  6. 篡改签名 register 应失败
func TestEndToEndRegisterAndLogin(t *testing.T) {
	gin.SetMode(gin.TestMode)

	// 临时数据库
	tmpDir := t.TempDir()
	dsn := filepath.Join(tmpDir, "test.db")

	gormDB, err := db.Open("sqlite", dsn)
	if err != nil {
		t.Fatal(err)
	}
	if err := user.AutoMigrate(gormDB); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		// Windows 上 sqlite 句柄不释放，TempDir 清理会失败。显式关闭。
		sqlDB, _ := gormDB.DB()
		if sqlDB != nil {
			sqlDB.Close()
		}
	})

	userStore := user.NewStore(gormDB)
	verifier := hcrypto.NewSignedRequestVerifier(nil, "nonce:test") // 无 Redis
	regEmailSender := &fakeEmailSender{}
	handler := &auth.Handler{
		UserStore: userStore,
		Verifier:  verifier,
		RegistrationEmail: auth.NewRegistrationEmailService(
			userStore,
			newMemoryRFAStore(),
			regEmailSender,
		),
		GatewaySyncer: &fakeGatewaySyncer{},
	}

	r := gin.New()
	v1 := r.Group("/api/v1")
	handler.Register(v1)
	srv := httptest.NewServer(r)
	defer srv.Close()

	// === 0. 用户名公开预检：注册前可用 ===
	availableBefore := getUsernameAvailability(t, srv.URL+"/api/v1/auth/username_available?username=alice")
	if !availableBefore.Available {
		t.Fatalf("expected username alice available before register, got %+v", availableBefore)
	}

	// === 1. 注册 ===
	priv, _ := secp.GeneratePrivateKey()
	pubHex := hex.EncodeToString(priv.PubKey().SerializeUncompressed())
	emailStart := startRegistrationEmail(t, srv.URL, "alice", "alice@example.com")
	code := regexp.MustCompile(`\d{6}`).FindString(regEmailSender.body)
	if code == "" {
		t.Fatalf("verification code not found in email body: %s", regEmailSender.body)
	}

	regResp, err := signedPost(srv.URL+"/api/v1/auth/register", priv,
		map[string]interface{}{
			"username":           "alice",
			"nickname":           "Alice in Wonderland",
			"email":              "alice@example.com",
			"email_challenge_id": emailStart.ChallengeID,
			"email_code":         code,
			"pubkey_hex":         pubHex,
		})
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	t.Logf("register response body: %s", regResp)

	var reg api.RegisterResponse
	if err := json.Unmarshal(regResp, &reg); err != nil {
		t.Fatalf("decode register: %v body=%s", err, regResp)
	}
	if reg.Username != "alice" {
		t.Fatalf("expected alice, got %s", reg.Username)
	}
	if reg.PubkeyHash == "" {
		t.Fatal("expected pubkey hash")
	}
	if reg.Tier != "free" {
		t.Fatalf("expected tier=free, got %s", reg.Tier)
	}
	syncer := handler.GatewaySyncer.(*fakeGatewaySyncer)
	if syncer.last.Username != "alice" || syncer.last.PH01UserID != reg.UserID {
		t.Fatalf("expected gateway sync with auth username, got %+v", syncer.last)
	}
	if syncer.last.Email != "alice@example.com" {
		t.Fatalf("expected gateway sync with verified email, got %+v", syncer.last)
	}

	// === 1.1 用户名公开预检：注册后不可用，客户端据此进入登录流程 ===
	availableAfter := getUsernameAvailability(t, srv.URL+"/api/v1/auth/username_available?username=alice")
	if availableAfter.Available {
		t.Fatalf("expected username alice unavailable after register, got %+v", availableAfter)
	}

	// === 2. 重复注册同 username 应返回 username_taken ===
	priv2, _ := secp.GeneratePrivateKey()
	pubHex2 := hex.EncodeToString(priv2.PubKey().SerializeUncompressed())
	respBody, status := signedPostStatus(srv.URL+"/api/v1/auth/register", priv2,
		map[string]interface{}{
			"username":   "alice",
			"nickname":   "another",
			"pubkey_hex": pubHex2,
		})
	if status != 409 {
		t.Fatalf("expected 409, got %d body=%s", status, respBody)
	}

	// === 3. login ===
	loginResp, err := signedPost(srv.URL+"/api/v1/auth/login", priv,
		map[string]interface{}{"username": "alice"})
	if err != nil {
		t.Fatalf("login: %v", err)
	}
	var login api.LoginResponse
	if err := json.Unmarshal(loginResp, &login); err != nil {
		t.Fatalf("decode login: %v", err)
	}
	if login.UserID != reg.UserID {
		t.Fatalf("user_id mismatch: %d vs %d", login.UserID, reg.UserID)
	}
	if login.PubkeyHash != reg.PubkeyHash {
		t.Fatalf("pubkey_hash mismatch")
	}

	// === 3.1 内部验签可带 user_id 约束，防止明文 user_id 被改绑 ===
	verifyReq := buildVerifySignatureRequest(priv,
		map[string]interface{}{"purpose": "internal_verify_test"},
		reg.UserID,
	)
	verifyResp := postVerifySignature(t, srv.URL+"/api/v1/auth/verify_signature", verifyReq)
	if !verifyResp.Valid || verifyResp.UserID != reg.UserID {
		t.Fatalf("expected valid verify_signature response, got %+v", verifyResp)
	}
	verifyReq.UserID = reg.UserID + 1
	mismatchResp := postVerifySignature(t, srv.URL+"/api/v1/auth/verify_signature", verifyReq)
	if mismatchResp.Valid || mismatchResp.Error != api.ErrPubkeyNotFound {
		t.Fatalf("expected user_id constrained verify_signature to fail, got %+v", mismatchResp)
	}

	// === 3.2 AI 网关登录挑战：只提交 user_id + signature(challenge) ===
	challengeSig, err := hcrypto.SignMessage(priv.Serialize(), []byte("base64url-challenge-json"))
	if err != nil {
		t.Fatal(err)
	}
	challengeResp := postVerifyChallengeSignature(t, srv.URL+"/api/v1/auth/verify_challenge_signature", api.VerifyChallengeSignatureRequest{
		UserID:       reg.UserID,
		Challenge:    "base64url-challenge-json",
		SignatureHex: challengeSig,
	})
	if !challengeResp.Valid || challengeResp.UserID != reg.UserID || challengeResp.PubkeyHash != reg.PubkeyHash {
		t.Fatalf("expected valid challenge signature response, got %+v", challengeResp)
	}
	badChallengeResp := postVerifyChallengeSignature(t, srv.URL+"/api/v1/auth/verify_challenge_signature", api.VerifyChallengeSignatureRequest{
		UserID:       reg.UserID + 1,
		Challenge:    "base64url-challenge-json",
		SignatureHex: challengeSig,
	})
	if badChallengeResp.Valid || badChallengeResp.Error != api.ErrPubkeyNotFound {
		t.Fatalf("expected wrong user_id challenge signature to fail, got %+v", badChallengeResp)
	}

	// === 4. 用错私钥 login 应失败 ===
	_, status = signedPostStatus(srv.URL+"/api/v1/auth/login", priv2,
		map[string]interface{}{"username": "alice"})
	if status != 401 {
		t.Fatalf("expected 401 for wrong key, got %d", status)
	}

	// === 5. 错误时间戳应失败 ===
	body := buildSignedRequestWithTimestamp(priv,
		map[string]interface{}{"username": "alice"},
		time.Now().Unix()-3600,
	)
	rr, err := http.Post(srv.URL+"/api/v1/auth/login",
		"application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if rr.StatusCode != 401 {
		t.Fatalf("expected 401 for stale timestamp, got %d", rr.StatusCode)
	}
	rr.Body.Close()

	// === 6. 不签发 JWT；身份由私钥签名证明 ===
}

func TestRegisterRequiresEmailVerification(t *testing.T) {
	gin.SetMode(gin.TestMode)
	tmpDir := t.TempDir()
	dsn := filepath.Join(tmpDir, "test.db")
	gormDB, err := db.Open("sqlite", dsn)
	if err != nil {
		t.Fatalf("db open: %v", err)
	}
	if err := user.AutoMigrate(gormDB); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	t.Cleanup(func() {
		sqlDB, _ := gormDB.DB()
		if sqlDB != nil {
			sqlDB.Close()
		}
	})

	store := user.NewStore(gormDB)
	sender := &fakeEmailSender{}
	handler := &auth.Handler{
		UserStore: store,
		Verifier:  hcrypto.NewSignedRequestVerifier(nil, "nonce:test"),
		RegistrationEmail: auth.NewRegistrationEmailService(
			store,
			newMemoryRFAStore(),
			sender,
		),
	}
	r := gin.New()
	v1 := r.Group("/api/v1")
	handler.Register(v1)
	srv := httptest.NewServer(r)
	defer srv.Close()

	start := startRegistrationEmail(t, srv.URL, "verified_user", "verified@example.com")
	priv, _ := secp.GeneratePrivateKey()
	pub := hex.EncodeToString(priv.PubKey().SerializeUncompressed())

	respBody, status := signedPostStatus(srv.URL+"/api/v1/auth/register", priv, map[string]interface{}{
		"username":           "verified_user",
		"nickname":           "Verified",
		"email":              "verified@example.com",
		"email_challenge_id": start.ChallengeID,
		"email_code":         "000000",
		"pubkey_hex":         pub,
	})
	if status != http.StatusUnauthorized {
		t.Fatalf("expected 401 for wrong registration email code, got %d body=%s", status, respBody)
	}

	code := regexp.MustCompile(`\d{6}`).FindString(sender.body)
	if code == "" {
		t.Fatalf("verification code not found in email body: %s", sender.body)
	}
	respBody, status = signedPostStatus(srv.URL+"/api/v1/auth/register", priv, map[string]interface{}{
		"username":           "verified_user",
		"nickname":           "Verified",
		"email":              "verified@example.com",
		"email_challenge_id": start.ChallengeID,
		"email_code":         code,
		"pubkey_hex":         pub,
	})
	if status != http.StatusOK {
		t.Fatalf("expected 200 with correct registration email code, got %d body=%s", status, respBody)
	}
}

// TestRecoveryCandidates 测试恢复期接口返回该用户名下所有未撤销公钥哈希。
func TestRecoveryCandidates(t *testing.T) {
	gin.SetMode(gin.TestMode)
	tmpDir := t.TempDir()
	dsn := filepath.Join(tmpDir, "test.db")
	gormDB, err := db.Open("sqlite", dsn)
	if err != nil {
		t.Fatalf("db open: %v", err)
	}
	if err := user.AutoMigrate(gormDB); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	t.Cleanup(func() {
		sqlDB, _ := gormDB.DB()
		if sqlDB != nil {
			sqlDB.Close()
		}
	})

	store := user.NewStore(gormDB)
	verifier := hcrypto.NewSignedRequestVerifier(nil, "nonce:test")

	priv1, _ := secp.GeneratePrivateKey()
	pub1 := hex.EncodeToString(priv1.PubKey().SerializeUncompressed())
	hash1, _ := hcrypto.PubkeyHash(pub1)
	store.CreateWithPubkey("bob", "Bob", "", pub1, hash1)

	// 给 bob 加第二个公钥
	priv2, _ := secp.GeneratePrivateKey()
	pub2 := hex.EncodeToString(priv2.PubKey().SerializeUncompressed())
	hash2, _ := hcrypto.PubkeyHash(pub2)
	u, _ := store.GetByUsername("bob")
	store.AddPubkey(u.ID, pub2, hash2)

	handler := &auth.Handler{UserStore: store, Verifier: verifier}
	r := gin.New()
	v1 := r.Group("/api/v1")
	handler.Register(v1)
	srv := httptest.NewServer(r)
	defer srv.Close()

	// 不签名请求
	body, _ := json.Marshal(map[string]string{"username": "bob"})
	rr, err := http.Post(srv.URL+"/api/v1/auth/recovery_candidates",
		"application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer rr.Body.Close()
	if rr.StatusCode != 200 {
		bb, _ := io.ReadAll(rr.Body)
		t.Fatalf("expected 200, got %d body=%s", rr.StatusCode, bb)
	}
	var resp api.RecoveryCandidatesResponse
	json.NewDecoder(rr.Body).Decode(&resp)
	if len(resp.PubkeyHashes) != 2 {
		t.Fatalf("expected 2 hashes, got %d", len(resp.PubkeyHashes))
	}

	// 撤销其中一个
	pks := u.Pubkeys
	if len(pks) == 0 {
		t.Skip()
	}
	store.RevokePubkey(pks[0].ID)
	body, _ = json.Marshal(map[string]string{"username": "bob"})
	rr2, err := http.Post(srv.URL+"/api/v1/auth/recovery_candidates",
		"application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer rr2.Body.Close()
	var resp2 api.RecoveryCandidatesResponse
	json.NewDecoder(rr2.Body).Decode(&resp2)
	if len(resp2.PubkeyHashes) != 1 {
		t.Fatalf("expected 1 active hash, got %d", len(resp2.PubkeyHashes))
	}
}

func TestVerifyPubkeysBatch(t *testing.T) {
	gin.SetMode(gin.TestMode)
	tmpDir := t.TempDir()
	dsn := filepath.Join(tmpDir, "test.db")
	gormDB, err := db.Open("sqlite", dsn)
	if err != nil {
		t.Fatalf("db open: %v", err)
	}
	if err := user.AutoMigrate(gormDB); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	t.Cleanup(func() {
		sqlDB, _ := gormDB.DB()
		if sqlDB != nil {
			sqlDB.Close()
		}
	})

	store := user.NewStore(gormDB)
	handler := &auth.Handler{
		UserStore: store,
		Verifier:  hcrypto.NewSignedRequestVerifier(nil, "nonce:test"),
	}
	r := gin.New()
	v1 := r.Group("/api/v1")
	handler.Register(v1)
	srv := httptest.NewServer(r)
	defer srv.Close()

	priv1, _ := secp.GeneratePrivateKey()
	pub1 := hex.EncodeToString(priv1.PubKey().SerializeUncompressed())
	hash1, _ := hcrypto.PubkeyHash(pub1)
	u1, err := store.CreateWithPubkey("verify_alice", "Alice", "", pub1, hash1)
	if err != nil {
		t.Fatal(err)
	}

	priv2, _ := secp.GeneratePrivateKey()
	pub2 := hex.EncodeToString(priv2.PubKey().SerializeUncompressed())
	hash2, _ := hcrypto.PubkeyHash(pub2)
	u2, err := store.CreateWithPubkey("verify_bob", "Bob", "", pub2, hash2)
	if err != nil {
		t.Fatal(err)
	}

	validReq := api.VerifyPubkeysRequest{
		Items: []api.PubkeyBindingCheck{
			{UserID: u1.ID, PubkeyHash: strings.ToUpper(hash1)},
			{UserID: u2.ID, PubkeyHash: hash2},
		},
	}
	validResp := postVerifyPubkeys(t, srv.URL+"/api/v1/auth/verify_pubkeys", validReq, http.StatusOK)
	if !validResp.OK || len(validResp.Missing) != 0 {
		t.Fatalf("expected all valid, got %+v", validResp)
	}

	mixedReq := api.VerifyPubkeysRequest{
		Items: []api.PubkeyBindingCheck{
			{UserID: u1.ID, PubkeyHash: hash1},
			{UserID: u2.ID, PubkeyHash: hash1},
		},
	}
	mixedResp := postVerifyPubkeys(t, srv.URL+"/api/v1/auth/verify_pubkeys", mixedReq, http.StatusOK)
	if mixedResp.OK {
		t.Fatalf("expected missing item, got %+v", mixedResp)
	}
	if len(mixedResp.Missing) != 1 {
		t.Fatalf("expected 1 missing, got %+v", mixedResp.Missing)
	}
	if mixedResp.Missing[0].UserID != u2.ID || mixedResp.Missing[0].PubkeyHash != hash1 {
		t.Fatalf("unexpected missing item: %+v", mixedResp.Missing[0])
	}

	if err := store.SetDisabled(u1.ID, true); err != nil {
		t.Fatal(err)
	}
	disabledResp := postVerifyPubkeys(t, srv.URL+"/api/v1/auth/verify_pubkeys", api.VerifyPubkeysRequest{
		Items: []api.PubkeyBindingCheck{{UserID: u1.ID, PubkeyHash: hash1}},
	}, http.StatusOK)
	if disabledResp.OK || len(disabledResp.Missing) != 1 {
		t.Fatalf("disabled user pubkey should be missing, got %+v", disabledResp)
	}

	invalidBody, _ := json.Marshal(api.VerifyPubkeysRequest{
		Items: []api.PubkeyBindingCheck{{UserID: u1.ID, PubkeyHash: "bad"}},
	})
	resp, err := http.Post(srv.URL+"/api/v1/auth/verify_pubkeys", "application/json", bytes.NewReader(invalidBody))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		bb, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected 400 for invalid hash, got %d body=%s", resp.StatusCode, bb)
	}
}

// TestRecoveryRFAEmailFlow 测试第二阶段邮箱验证码：发起挑战、错码失败、对码换取 recovery grant。
func TestRecoveryRFAEmailFlow(t *testing.T) {
	gin.SetMode(gin.TestMode)
	tmpDir := t.TempDir()
	dsn := filepath.Join(tmpDir, "test.db")
	gormDB, err := db.Open("sqlite", dsn)
	if err != nil {
		t.Fatalf("db open: %v", err)
	}
	if err := user.AutoMigrate(gormDB); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	t.Cleanup(func() {
		sqlDB, _ := gormDB.DB()
		if sqlDB != nil {
			sqlDB.Close()
		}
	})

	store := user.NewStore(gormDB)
	priv, _ := secp.GeneratePrivateKey()
	pub := hex.EncodeToString(priv.PubKey().SerializeUncompressed())
	hash, _ := hcrypto.PubkeyHash(pub)
	if _, err := store.CreateWithPubkey("rfa_user", "RFA", "rfa@example.com", pub, hash); err != nil {
		t.Fatal(err)
	}

	rfaStore := newMemoryRFAStore()
	sender := &fakeEmailSender{}
	rfaSvc := auth.NewRFAService(store, rfaStore, sender)
	rfaSvc.ChallengeTTL = time.Minute
	rfaSvc.GrantTTL = 2 * time.Minute

	handler := &auth.Handler{
		UserStore: store,
		Verifier:  hcrypto.NewSignedRequestVerifier(nil, "nonce:test"),
		RFA:       rfaSvc,
	}
	r := gin.New()
	v1 := r.Group("/api/v1")
	handler.Register(v1)
	srv := httptest.NewServer(r)
	defer srv.Close()

	startBody, _ := json.Marshal(map[string]string{"username": "rfa_user"})
	startResp, err := http.Post(srv.URL+"/api/v1/auth/recovery_rfa/start",
		"application/json", bytes.NewReader(startBody))
	if err != nil {
		t.Fatal(err)
	}
	defer startResp.Body.Close()
	if startResp.StatusCode != 200 {
		bb, _ := io.ReadAll(startResp.Body)
		t.Fatalf("expected 200, got %d body=%s", startResp.StatusCode, bb)
	}
	var start api.RecoveryRFAStartResponse
	if err := json.NewDecoder(startResp.Body).Decode(&start); err != nil {
		t.Fatal(err)
	}
	if start.ChallengeID == "" {
		t.Fatal("expected challenge_id")
	}
	if start.Delivery != "r***a@example.com" {
		t.Fatalf("unexpected masked delivery: %s", start.Delivery)
	}
	if sender.to != "rfa@example.com" {
		t.Fatalf("expected email to rfa@example.com, got %s", sender.to)
	}
	code := regexp.MustCompile(`\d{6}`).FindString(sender.body)
	if code == "" {
		t.Fatalf("verification code not found in email body: %s", sender.body)
	}

	wrongCode := "000000"
	if code == wrongCode {
		wrongCode = "111111"
	}
	wrongBody, _ := json.Marshal(map[string]string{
		"challenge_id": start.ChallengeID,
		"code":         wrongCode,
	})
	wrongResp, err := http.Post(srv.URL+"/api/v1/auth/recovery_rfa/verify",
		"application/json", bytes.NewReader(wrongBody))
	if err != nil {
		t.Fatal(err)
	}
	if wrongResp.StatusCode != 401 {
		bb, _ := io.ReadAll(wrongResp.Body)
		t.Fatalf("expected 401 for wrong code, got %d body=%s", wrongResp.StatusCode, bb)
	}
	wrongResp.Body.Close()

	verifyBody, _ := json.Marshal(map[string]string{
		"challenge_id": start.ChallengeID,
		"code":         code,
	})
	verifyResp, err := http.Post(srv.URL+"/api/v1/auth/recovery_rfa/verify",
		"application/json", bytes.NewReader(verifyBody))
	if err != nil {
		t.Fatal(err)
	}
	defer verifyResp.Body.Close()
	if verifyResp.StatusCode != 200 {
		bb, _ := io.ReadAll(verifyResp.Body)
		t.Fatalf("expected 200, got %d body=%s", verifyResp.StatusCode, bb)
	}
	var verified api.RecoveryRFAVerifyResponse
	if err := json.NewDecoder(verifyResp.Body).Decode(&verified); err != nil {
		t.Fatal(err)
	}
	if verified.RecoveryGrant == "" {
		t.Fatal("expected recovery grant")
	}
	if verified.MaxCandidatesPerColumn != 4 {
		t.Fatalf("expected max K=4, got %d", verified.MaxCandidatesPerColumn)
	}
	if _, err := rfaStore.GetGrant(context.Background(), verified.RecoveryGrant); err != nil {
		t.Fatalf("grant should be stored: %v", err)
	}
}

func TestRecoveryRFAUnavailableAndEmailNotBound(t *testing.T) {
	gin.SetMode(gin.TestMode)
	tmpDir := t.TempDir()
	dsn := filepath.Join(tmpDir, "test.db")
	gormDB, err := db.Open("sqlite", dsn)
	if err != nil {
		t.Fatalf("db open: %v", err)
	}
	if err := user.AutoMigrate(gormDB); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	t.Cleanup(func() {
		sqlDB, _ := gormDB.DB()
		if sqlDB != nil {
			sqlDB.Close()
		}
	})

	store := user.NewStore(gormDB)
	priv, _ := secp.GeneratePrivateKey()
	pub := hex.EncodeToString(priv.PubKey().SerializeUncompressed())
	hash, _ := hcrypto.PubkeyHash(pub)
	if _, err := store.CreateWithPubkey("no_email", "No Email", "", pub, hash); err != nil {
		t.Fatal(err)
	}

	handler := &auth.Handler{
		UserStore: store,
		Verifier:  hcrypto.NewSignedRequestVerifier(nil, "nonce:test"),
	}
	r := gin.New()
	v1 := r.Group("/api/v1")
	handler.Register(v1)
	srv := httptest.NewServer(r)
	defer srv.Close()

	body, _ := json.Marshal(map[string]string{"username": "no_email"})
	resp, err := http.Post(srv.URL+"/api/v1/auth/recovery_rfa/start",
		"application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != 503 {
		bb, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected 503 without RFA service, got %d body=%s", resp.StatusCode, bb)
	}
	resp.Body.Close()

	handler.RFA = auth.NewRFAService(store, newMemoryRFAStore(), &fakeEmailSender{})
	resp, err = http.Post(srv.URL+"/api/v1/auth/recovery_rfa/start",
		"application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 400 {
		bb, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected 400 for unbound email, got %d body=%s", resp.StatusCode, bb)
	}
	var er api.ErrorResponse
	if err := json.NewDecoder(resp.Body).Decode(&er); err != nil {
		t.Fatal(err)
	}
	if er.Error != api.ErrEmailNotBound {
		t.Fatalf("expected email_not_bound, got %s", er.Error)
	}
}

func TestRegistrationEmailStartCooldown(t *testing.T) {
	gin.SetMode(gin.TestMode)
	tmpDir := t.TempDir()
	dsn := filepath.Join(tmpDir, "test.db")
	gormDB, err := db.Open("sqlite", dsn)
	if err != nil {
		t.Fatalf("db open: %v", err)
	}
	if err := user.AutoMigrate(gormDB); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	t.Cleanup(func() {
		sqlDB, _ := gormDB.DB()
		if sqlDB != nil {
			sqlDB.Close()
		}
	})

	store := user.NewStore(gormDB)
	sender := &fakeEmailSender{}
	registrationEmail := auth.NewRegistrationEmailService(store, newMemoryRFAStore(), sender)
	registrationEmail.SendCooldown = time.Minute
	handler := &auth.Handler{
		UserStore:         store,
		Verifier:          hcrypto.NewSignedRequestVerifier(nil, "nonce:test"),
		RegistrationEmail: registrationEmail,
	}
	r := gin.New()
	v1 := r.Group("/api/v1")
	handler.Register(v1)
	srv := httptest.NewServer(r)
	defer srv.Close()

	body, _ := json.Marshal(api.RegistrationEmailStartRequest{
		Username: "cooldown_user",
		Email:    "cooldown@example.com",
	})
	resp, err := http.Post(srv.URL+"/api/v1/auth/register_email/start", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		bb, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected 200, got %d body=%s", resp.StatusCode, bb)
	}
	var start api.RegistrationEmailStartResponse
	if err := json.NewDecoder(resp.Body).Decode(&start); err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if start.CooldownSeconds != 60 {
		t.Fatalf("expected cooldown 60s, got %d", start.CooldownSeconds)
	}

	resp, err = http.Post(srv.URL+"/api/v1/auth/register_email/start", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusTooManyRequests {
		bb, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected 429, got %d body=%s", resp.StatusCode, bb)
	}
	if resp.Header.Get("Retry-After") == "" {
		t.Fatal("expected Retry-After header")
	}
	var er api.ErrorResponse
	if err := json.NewDecoder(resp.Body).Decode(&er); err != nil {
		t.Fatal(err)
	}
	if er.Error != api.ErrRateLimitExceeded || er.RetryAfter <= 0 {
		t.Fatalf("expected rate_limit_exceeded with retry_after, got %+v", er)
	}
	if sender.count != 1 {
		t.Fatalf("expected one email to be sent, got %d", sender.count)
	}
}

func TestRecoveryRFAStartCooldown(t *testing.T) {
	gin.SetMode(gin.TestMode)
	tmpDir := t.TempDir()
	dsn := filepath.Join(tmpDir, "test.db")
	gormDB, err := db.Open("sqlite", dsn)
	if err != nil {
		t.Fatalf("db open: %v", err)
	}
	if err := user.AutoMigrate(gormDB); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	t.Cleanup(func() {
		sqlDB, _ := gormDB.DB()
		if sqlDB != nil {
			sqlDB.Close()
		}
	})

	store := user.NewStore(gormDB)
	priv, _ := secp.GeneratePrivateKey()
	pub := hex.EncodeToString(priv.PubKey().SerializeUncompressed())
	hash, _ := hcrypto.PubkeyHash(pub)
	if _, err := store.CreateWithPubkey("rfa_cooldown", "RFA Cooldown", "rfa-cooldown@example.com", pub, hash); err != nil {
		t.Fatal(err)
	}
	sender := &fakeEmailSender{}
	rfaSvc := auth.NewRFAService(store, newMemoryRFAStore(), sender)
	rfaSvc.SendCooldown = time.Minute
	handler := &auth.Handler{
		UserStore: store,
		Verifier:  hcrypto.NewSignedRequestVerifier(nil, "nonce:test"),
		RFA:       rfaSvc,
	}
	r := gin.New()
	v1 := r.Group("/api/v1")
	handler.Register(v1)
	srv := httptest.NewServer(r)
	defer srv.Close()

	body, _ := json.Marshal(api.RecoveryRFAStartRequest{Username: "rfa_cooldown"})
	resp, err := http.Post(srv.URL+"/api/v1/auth/recovery_rfa/start", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		bb, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected 200, got %d body=%s", resp.StatusCode, bb)
	}
	var start api.RecoveryRFAStartResponse
	if err := json.NewDecoder(resp.Body).Decode(&start); err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if start.CooldownSeconds != 60 {
		t.Fatalf("expected cooldown 60s, got %d", start.CooldownSeconds)
	}

	resp, err = http.Post(srv.URL+"/api/v1/auth/recovery_rfa/start", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusTooManyRequests {
		bb, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected 429, got %d body=%s", resp.StatusCode, bb)
	}
	var er api.ErrorResponse
	if err := json.NewDecoder(resp.Body).Decode(&er); err != nil {
		t.Fatal(err)
	}
	if er.Error != api.ErrRateLimitExceeded || er.RetryAfter <= 0 {
		t.Fatalf("expected rate_limit_exceeded with retry_after, got %+v", er)
	}
	if sender.count != 1 {
		t.Fatalf("expected one email to be sent, got %d", sender.count)
	}
}

// === helpers ===

type fakeEmailSender struct {
	to      string
	subject string
	body    string
	count   int
}

type fakeGatewaySyncer struct {
	last auth.GatewayUserSyncRequest
}

func (f *fakeGatewaySyncer) SyncUser(_ context.Context, req auth.GatewayUserSyncRequest) error {
	f.last = req
	return nil
}

func (f *fakeEmailSender) Send(_ context.Context, to, subject, body string) error {
	f.to = to
	f.subject = subject
	f.body = body
	f.count++
	return nil
}

type memoryRFAStore struct {
	mu         sync.Mutex
	challenges map[string]*auth.RFAChallenge
	grants     map[string]*auth.RecoveryGrant
	cooldowns  map[string]time.Time
}

func newMemoryRFAStore() *memoryRFAStore {
	return &memoryRFAStore{
		challenges: map[string]*auth.RFAChallenge{},
		grants:     map[string]*auth.RecoveryGrant{},
		cooldowns:  map[string]time.Time{},
	}
}

func (s *memoryRFAStore) SaveChallenge(_ context.Context, ch *auth.RFAChallenge, _ time.Duration) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	cp := *ch
	s.challenges[ch.ID] = &cp
	return nil
}

func (s *memoryRFAStore) GetChallenge(_ context.Context, id string) (*auth.RFAChallenge, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ch, ok := s.challenges[id]
	if !ok {
		return nil, auth.ErrRFAChallengeNotFound
	}
	cp := *ch
	return &cp, nil
}

func (s *memoryRFAStore) DeleteChallenge(_ context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.challenges, id)
	return nil
}

func (s *memoryRFAStore) SaveGrant(_ context.Context, grant *auth.RecoveryGrant, _ time.Duration) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	cp := *grant
	s.grants[grant.Token] = &cp
	return nil
}

func (s *memoryRFAStore) GetGrant(_ context.Context, token string) (*auth.RecoveryGrant, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	grant, ok := s.grants[token]
	if !ok {
		return nil, auth.ErrRFAChallengeNotFound
	}
	cp := *grant
	return &cp, nil
}

func (s *memoryRFAStore) ReserveCooldown(_ context.Context, key string, ttl time.Duration) (time.Duration, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	if expiresAt, ok := s.cooldowns[key]; ok {
		if now.Before(expiresAt) {
			return time.Until(expiresAt), false, nil
		}
		delete(s.cooldowns, key)
	}
	s.cooldowns[key] = now.Add(ttl)
	return 0, true, nil
}

func (s *memoryRFAStore) ClearCooldown(_ context.Context, key string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.cooldowns, key)
	return nil
}

func signedPost(url string, priv *secp.PrivateKey, payload map[string]interface{}) ([]byte, error) {
	body := buildSignedRequest(priv, payload)
	resp, err := http.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("status=%d body=%s", resp.StatusCode, respBody)
	}
	return respBody, nil
}

func signedPostStatus(url string, priv *secp.PrivateKey, payload map[string]interface{}) ([]byte, int) {
	body := buildSignedRequest(priv, payload)
	resp, err := http.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		return nil, 0
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	return respBody, resp.StatusCode
}

func postVerifyPubkeys(t *testing.T, url string, req api.VerifyPubkeysRequest, status int) api.VerifyPubkeysResponse {
	t.Helper()
	body, _ := json.Marshal(req)
	resp, err := http.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != status {
		t.Fatalf("expected status=%d got=%d body=%s", status, resp.StatusCode, respBody)
	}
	var out api.VerifyPubkeysResponse
	if err := json.Unmarshal(respBody, &out); err != nil {
		t.Fatalf("decode verify_pubkeys: %v body=%s", err, respBody)
	}
	return out
}

func getUsernameAvailability(t *testing.T, url string) api.UsernameAvailabilityResponse {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected status=200 got=%d body=%s", resp.StatusCode, respBody)
	}
	var out api.UsernameAvailabilityResponse
	if err := json.Unmarshal(respBody, &out); err != nil {
		t.Fatalf("decode username_available: %v body=%s", err, respBody)
	}
	return out
}

func startRegistrationEmail(t *testing.T, baseURL, username, email string) api.RegistrationEmailStartResponse {
	t.Helper()
	body, _ := json.Marshal(api.RegistrationEmailStartRequest{
		Username: username,
		Email:    email,
	})
	resp, err := http.Post(baseURL+"/api/v1/auth/register_email/start", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected status=200 got=%d body=%s", resp.StatusCode, respBody)
	}
	var out api.RegistrationEmailStartResponse
	if err := json.Unmarshal(respBody, &out); err != nil {
		t.Fatalf("decode register_email/start: %v body=%s", err, respBody)
	}
	if out.ChallengeID == "" {
		t.Fatalf("expected challenge_id in register_email/start response")
	}
	return out
}

func postVerifySignature(t *testing.T, url string, req api.VerifySignatureRequest) api.VerifySignatureResponse {
	t.Helper()
	body, _ := json.Marshal(req)
	resp, err := http.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected status=200 got=%d body=%s", resp.StatusCode, respBody)
	}
	var out api.VerifySignatureResponse
	if err := json.Unmarshal(respBody, &out); err != nil {
		t.Fatalf("decode verify_signature: %v body=%s", err, respBody)
	}
	return out
}

func postVerifyChallengeSignature(t *testing.T, url string, req api.VerifyChallengeSignatureRequest) api.VerifySignatureResponse {
	t.Helper()
	body, _ := json.Marshal(req)
	resp, err := http.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected status=200 got=%d body=%s", resp.StatusCode, respBody)
	}
	var out api.VerifySignatureResponse
	if err := json.Unmarshal(respBody, &out); err != nil {
		t.Fatalf("decode verify_challenge_signature: %v body=%s", err, respBody)
	}
	return out
}

func buildSignedRequest(priv *secp.PrivateKey, payload map[string]interface{}) []byte {
	return buildSignedRequestWithTimestamp(priv, payload, time.Now().Unix())
}

func buildVerifySignatureRequest(priv *secp.PrivateKey, payload map[string]interface{}, userID uint64) api.VerifySignatureRequest {
	var req api.SignedRequest
	if err := json.Unmarshal(buildSignedRequest(priv, payload), &req); err != nil {
		panic(err)
	}
	return api.VerifySignatureRequest{
		UserID:       userID,
		PubkeyHex:    req.PubkeyHex,
		SignatureHex: req.SignatureHex,
		Payload:      req.Payload,
		Timestamp:    req.Timestamp,
		Nonce:        req.Nonce,
	}
}

func buildSignedRequestWithTimestamp(priv *secp.PrivateKey, payload map[string]interface{}, ts int64) []byte {
	pubHex := hex.EncodeToString(priv.PubKey().SerializeUncompressed())
	payloadStr, _ := json.Marshal(payload)
	nonce := uuid.NewString()[:16]
	signed := fmt.Sprintf("%s\n%s\n%d\n%s", string(payloadStr), pubHex, ts, nonce)

	sigHex, _ := hcrypto.SignMessage(priv.Serialize(), []byte(signed))

	req := api.SignedRequest{
		Payload:      string(payloadStr),
		PubkeyHex:    pubHex,
		SignatureHex: sigHex,
		Timestamp:    ts,
		Nonce:        nonce,
	}
	body, _ := json.Marshal(req)
	return body
}

// 让 import 工作
var _ = os.TempDir
var _ = context.Background
