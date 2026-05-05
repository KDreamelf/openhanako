package authority

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/hanako/legacy-p2p-authority/internal/rootkey"
)

func TestSignVetoBlock(t *testing.T) {
	gin.SetMode(gin.TestMode)
	key, err := rootkey.Load("test-root", "0000000000000000000000000000000000000000000000000000000000000001")
	if err != nil {
		t.Fatal(err)
	}

	r := gin.New()
	(&Handler{Root: key, AdminToken: "admin"}).Register(r)
	srv := httptest.NewServer(r)
	defer srv.Close()

	body := []byte(`{
  "target_experience_id": "exp_1",
  "veto_target": "ratings",
  "vetoed_pubkeys": ["pk_a"],
  "reason": "bot_attack_detected",
  "prev_hashes": ["sha256_prev"],
  "timestamp": "2026-04-30T16:00:00Z"
}`)
	req, err := http.NewRequest(http.MethodPost, srv.URL+"/api/v1/veto_blocks/sign", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer admin")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var out struct {
		VetoBlock        VetoBlock       `json:"veto_block"`
		SignaturePayload json.RawMessage `json:"signature_payload"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if out.VetoBlock.MasterRootSignature == "" {
		t.Fatal("missing signature")
	}
	if err := rootkey.Verify(key.PublicKeyHex, out.SignaturePayload, out.VetoBlock.MasterRootSignature); err != nil {
		t.Fatalf("verify signature: %v", err)
	}
}
