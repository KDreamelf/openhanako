package admin_test

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	secp "github.com/decred/dcrd/dcrec/secp256k1/v4"
	"github.com/gin-gonic/gin"
	"github.com/hanako/ph01-backend/internal/admin"
	hcrypto "github.com/hanako/ph01-backend/internal/crypto"
	"github.com/hanako/ph01-backend/internal/db"
	"github.com/hanako/ph01-backend/internal/system"
	"github.com/hanako/ph01-backend/internal/user"
	"github.com/hanako/ph01-backend/pkg/api"
)

func TestAdminChallengeLoginCodeIssuesSessionForAdmin(t *testing.T) {
	srv, store := newAdminTestServer(t)
	priv, u := createAdminUser(t, store, "admin_alice", user.RoleAdmin)
	challenge := getAdminChallenge(t, srv.URL)
	sig := signChallenge(t, priv, challenge.Challenge)

	resp := postAdminSignedLogin(t, srv.URL+"/admin/session/login_code", api.AdminSignedLoginRequest{
		UserID:    u.ID,
		Nonce:     challenge.Nonce,
		Signature: sig,
	}, http.StatusOK)

	if resp.Token == "" {
		t.Fatal("expected admin session token")
	}
	if resp.User.ID != u.ID || resp.User.Role != string(user.RoleAdmin) {
		t.Fatalf("unexpected session user: %+v", resp.User)
	}
}

func TestAdminProtocolLoginCompletesPendingChallenge(t *testing.T) {
	srv, store := newAdminTestServer(t)
	priv, u := createAdminUser(t, store, "admin_bob", user.RoleRoot)
	challenge := getAdminChallenge(t, srv.URL)
	sig := signChallenge(t, priv, challenge.Challenge)

	postAdminRaw(t, srv.URL+"/admin/session/protocol/complete", api.AdminSignedLoginRequest{
		UserID:    u.ID,
		Nonce:     challenge.Nonce,
		Signature: sig,
	}, http.StatusOK)

	var resp api.AdminLoginResponse
	getJSON(t, srv.URL+"/admin/session/challenge/"+challenge.ChallengeID+"/status", &resp, http.StatusOK)
	if resp.Token == "" || resp.User.ID != u.ID {
		t.Fatalf("expected completed admin session, got %+v", resp)
	}
}

func TestAdminChallengeProtocolURLUsesConfiguredPublicBase(t *testing.T) {
	srv, _ := newAdminTestServerWithPublicBase(t, "https://auth.example")
	challenge := getAdminChallenge(t, srv.URL)

	protocolURL, err := url.Parse(challenge.ProtocolURL)
	if err != nil {
		t.Fatalf("parse protocol url: %v", err)
	}
	callbackURL, err := url.Parse(protocolURL.Query().Get("callback"))
	if err != nil {
		t.Fatalf("parse callback url: %v", err)
	}
	if got := callbackURL.Scheme + "://" + callbackURL.Host; got != "https://auth.example" {
		t.Fatalf("callback origin = %q", got)
	}
	if got := callbackURL.Path; got != "/admin/session/protocol/complete" {
		t.Fatalf("callback path = %q", got)
	}
	if got := callbackURL.Query().Get("nonce"); got != challenge.Nonce {
		t.Fatalf("callback nonce = %q, want %q", got, challenge.Nonce)
	}
}

func TestAdminChallengeLoginRejectsRegularUser(t *testing.T) {
	srv, store := newAdminTestServer(t)
	priv, u := createAdminUser(t, store, "normal_user", user.RoleUser)
	challenge := getAdminChallenge(t, srv.URL)
	sig := signChallenge(t, priv, challenge.Challenge)

	var errResp api.ErrorResponse
	postJSON(t, srv.URL+"/admin/session/login_code", api.AdminSignedLoginRequest{
		UserID:    u.ID,
		Nonce:     challenge.Nonce,
		Signature: sig,
	}, &errResp, http.StatusForbidden)
	if errResp.Error != api.ErrAdminRequired {
		t.Fatalf("expected admin_required, got %+v", errResp)
	}
}

func TestAdminUpdateUserPersistsEditableFields(t *testing.T) {
	srv, store := newAdminTestServer(t)
	rootPriv, root := createAdminUser(t, store, "root", user.RoleRoot)
	_, target := createAdminUser(t, store, "editable_user", user.RoleUser)

	challenge := getAdminChallenge(t, srv.URL)
	login := postAdminSignedLogin(t, srv.URL+"/admin/session/login_code", api.AdminSignedLoginRequest{
		UserID:    root.ID,
		Nonce:     challenge.Nonce,
		Signature: signChallenge(t, rootPriv, challenge.Challenge),
	}, http.StatusOK)

	nickname := "Edited Account"
	email := "edited@example.com"
	tier := "pro"
	role := "admin"
	disabled := true
	req := api.AdminUpdateUserRequest{
		Nickname: &nickname,
		Email:    &email,
		Tier:     &tier,
		Role:     &role,
		Disabled: &disabled,
	}
	var updated api.AdminUser
	requestJSON(t, http.MethodPatch, srv.URL+"/admin/users/"+strconv.FormatUint(target.ID, 10), login.Token, req, &updated, http.StatusOK)

	if updated.Nickname != nickname || updated.Email != email || updated.Tier != tier || updated.Role != role || !updated.Disabled {
		t.Fatalf("unexpected updated user: %+v", updated)
	}

	var fetched api.AdminUser
	requestJSON(t, http.MethodGet, srv.URL+"/admin/users/"+strconv.FormatUint(target.ID, 10), login.Token, nil, &fetched, http.StatusOK)
	if fetched.Nickname != nickname || fetched.Email != email || fetched.Tier != tier || fetched.Role != role || !fetched.Disabled {
		t.Fatalf("updated fields were not persisted: %+v", fetched)
	}
}

func TestAdminListUsersIncludesPubkeyPowStatus(t *testing.T) {
	srv, store := newAdminTestServer(t)
	rootPriv, root := createAdminUser(t, store, "root", user.RoleRoot)
	_, target := createAdminUser(t, store, "pow_user", user.RoleUser)
	withPubkeys, err := store.GetByIDWithAllPubkeys(target.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(withPubkeys.Pubkeys) != 1 {
		t.Fatalf("expected one pubkey, got %d", len(withPubkeys.Pubkeys))
	}
	if _, err := store.MarkPubkeyPoWVerified(
		withPubkeys.Pubkeys[0].PubkeyHash,
		"ph01.memory_pow.v1",
		8,
		time.Unix(1770000000, 0),
	); err != nil {
		t.Fatal(err)
	}

	challenge := getAdminChallenge(t, srv.URL)
	login := postAdminSignedLogin(t, srv.URL+"/admin/session/login_code", api.AdminSignedLoginRequest{
		UserID:    root.ID,
		Nonce:     challenge.Nonce,
		Signature: signChallenge(t, rootPriv, challenge.Challenge),
	}, http.StatusOK)

	var list api.AdminUserListResponse
	requestJSON(t, http.MethodGet, srv.URL+"/admin/users?page=1&page_size=20", login.Token, nil, &list, http.StatusOK)
	var found *api.AdminUser
	for i := range list.Items {
		if list.Items[i].ID == target.ID {
			found = &list.Items[i]
			break
		}
	}
	if found == nil || len(found.Pubkeys) != 1 {
		t.Fatalf("target user not found with pubkeys: %+v", list.Items)
	}
	if !found.Pubkeys[0].PowVerified || found.Pubkeys[0].PowScore != 8 || found.Pubkeys[0].PowVerifiedAt != 1770000000 {
		t.Fatalf("pow status missing from admin user: %+v", found.Pubkeys[0])
	}
}

func newAdminTestServer(t *testing.T) (*httptest.Server, *user.Store) {
	t.Helper()
	return newAdminTestServerWithPublicBase(t, "")
}

func newAdminTestServerWithPublicBase(t *testing.T, publicBase string) (*httptest.Server, *user.Store) {
	t.Helper()
	gin.SetMode(gin.TestMode)

	gormDB, err := db.Open("sqlite", filepath.Join(t.TempDir(), "admin.db"))
	if err != nil {
		t.Fatal(err)
	}
	if err := user.AutoMigrate(gormDB); err != nil {
		t.Fatal(err)
	}
	if err := system.AutoMigrate(gormDB); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		sqlDB, _ := gormDB.DB()
		if sqlDB != nil {
			_ = sqlDB.Close()
		}
	})

	store := user.NewStore(gormDB)
	handler := &admin.Handler{
		UserStore:   store,
		SystemStore: system.NewStore(gormDB),
		AdminToken:  "test-admin-session-secret",
		PublicBase:  publicBase,
	}
	r := gin.New()
	handler.Register(r.Group("/admin"))
	srv := httptest.NewServer(r)
	t.Cleanup(srv.Close)
	return srv, store
}

func createAdminUser(t *testing.T, store *user.Store, username string, role user.Role) (*secp.PrivateKey, *user.User) {
	t.Helper()
	priv, err := secp.GeneratePrivateKey()
	if err != nil {
		t.Fatal(err)
	}
	pubHex := hex.EncodeToString(priv.PubKey().SerializeUncompressed())
	hash, err := hcrypto.PubkeyHash(pubHex)
	if err != nil {
		t.Fatal(err)
	}
	u, err := store.CreateWithPubkey(username, username, "", pubHex, hash)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.SetRole(u.ID, role); err != nil {
		t.Fatal(err)
	}
	u, err = store.GetByID(u.ID)
	if err != nil {
		t.Fatal(err)
	}
	return priv, u
}

func getAdminChallenge(t *testing.T, baseURL string) api.AdminLoginChallengeResponse {
	t.Helper()
	var out api.AdminLoginChallengeResponse
	getJSON(t, baseURL+"/admin/session/challenge", &out, http.StatusOK)
	if out.Challenge == "" || out.Nonce == "" || out.ProtocolURL == "" {
		t.Fatalf("incomplete challenge: %+v", out)
	}
	if out.Detail.Purpose != "ph01_auth_admin_login" {
		t.Fatalf("unexpected challenge purpose: %+v", out.Detail)
	}
	return out
}

func signChallenge(t *testing.T, priv *secp.PrivateKey, challenge string) string {
	t.Helper()
	sig, err := hcrypto.SignMessage(priv.Serialize(), []byte(challenge))
	if err != nil {
		t.Fatal(err)
	}
	return sig
}

func postAdminSignedLogin(t *testing.T, url string, req api.AdminSignedLoginRequest, status int) api.AdminLoginResponse {
	t.Helper()
	var out api.AdminLoginResponse
	postJSON(t, url, req, &out, status)
	return out
}

func postAdminRaw(t *testing.T, url string, req api.AdminSignedLoginRequest, status int) {
	t.Helper()
	var out map[string]any
	postJSON(t, url, req, &out, status)
}

func getJSON(t *testing.T, url string, out any, status int) {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != status {
		t.Fatalf("GET %s status=%d body=%s", url, resp.StatusCode, string(body))
	}
	if len(body) > 0 {
		if err := json.Unmarshal(body, out); err != nil {
			t.Fatalf("decode response: %v body=%s", err, string(body))
		}
	}
}

func requestJSON(t *testing.T, method, url, token string, req any, out any, status int) {
	t.Helper()
	var body io.Reader
	if req != nil {
		raw, err := json.Marshal(req)
		if err != nil {
			t.Fatal(err)
		}
		body = bytes.NewReader(raw)
	}
	httpReq, err := http.NewRequest(method, url, body)
	if err != nil {
		t.Fatal(err)
	}
	if req != nil {
		httpReq.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		httpReq.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != status {
		t.Fatalf("%s %s status=%d body=%s", method, url, resp.StatusCode, string(respBody))
	}
	if len(respBody) > 0 && out != nil {
		if err := json.Unmarshal(respBody, out); err != nil {
			t.Fatalf("decode response: %v body=%s", err, string(respBody))
		}
	}
}

func postJSON(t *testing.T, url string, req any, out any, status int) {
	t.Helper()
	raw, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.Post(url, "application/json", bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != status {
		t.Fatalf("POST %s status=%d body=%s", url, resp.StatusCode, string(body))
	}
	if len(body) > 0 && out != nil {
		if err := json.Unmarshal(body, out); err != nil {
			t.Fatalf("decode response: %v body=%s", err, string(body))
		}
	}
}
