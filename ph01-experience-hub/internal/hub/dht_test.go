package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"ph01-experience-hub/internal/governance"
)

type fakeDHTHealthChecker struct {
	status string
}

func (f fakeDHTHealthChecker) CheckDHTNode(context.Context, DHTNode) DHTHealthResult {
	return DHTHealthResult{Status: f.status}
}

func TestDefaultDHTHealthCheckerUsesUDPHealthPing(t *testing.T) {
	conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	go func() {
		buf := make([]byte, 1024)
		_, remote, err := conn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		_, _ = conn.WriteToUDP([]byte(`{"ok":true,"service":"experience-dht-udp"}`+"\n"), remote)
	}()
	addr := conn.LocalAddr().(*net.UDPAddr)
	result := DefaultDHTHealthChecker{Timeout: time.Second}.CheckDHTNode(context.Background(), DHTNode{
		NodeID: "dht_udp_health",
		Endpoints: []DHTEndpoint{{
			Network: "udp",
			Host:    "127.0.0.1",
			Port:    addr.Port,
		}},
	})
	if result.Status != DHTHealthHealthy {
		t.Fatalf("expected healthy udp dht, got %+v", result)
	}
}

func TestDHTRegisterListAndExpiration(t *testing.T) {
	root := t.TempDir()
	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	handler := &Handler{
		Store:     store,
		DHTHealth: fakeDHTHealthChecker{status: DHTHealthHealthy},
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	proof := dhtOwnerProofForTest(t)
	reqBody, _ := json.Marshal(DHTRegisterRequest{
		SchemaVersion:      DHTRegisterSchemaVersion,
		NodeID:             "dht_public_01",
		OwnerKind:          DHTOwnerKindUser,
		OwnerPeerID:        proof.PubkeyHex,
		Region:             "cn-east",
		Endpoints:          []DHTEndpoint{{Network: "udp", Host: "203.0.113.10", Port: 41001}},
		RelayPolicy:        DHTRelayPolicyPublic,
		AdminSignedRequest: &proof,
		Capabilities: map[string]bool{
			"relay":      true,
			"hole_punch": true,
		},
		Load: DHTLoad{RelayActiveSessions: 2, RelayCapacity: 100},
	})
	resp, err := http.Post(srv.URL+"/api/v1/dht/nodes/register", "application/json", bytes.NewReader(reqBody))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("register status=%d", resp.StatusCode)
	}
	var registered DHTNode
	if err := json.NewDecoder(resp.Body).Decode(&registered); err != nil {
		t.Fatal(err)
	}
	if registered.SchemaVersion != DHTNodeSchemaVersion || registered.HealthStatus != DHTHealthHealthy {
		t.Fatalf("unexpected registered node: %+v", registered)
	}

	expired := registered
	expired.NodeID = "dht_expired"
	expired.ExpiresAt = time.Now().UTC().Add(-time.Minute).Format(time.RFC3339)
	if _, err := store.UpsertDHTNode(expired); err != nil {
		t.Fatalf("insert expired node: %v", err)
	}

	resp, err = http.Get(srv.URL + "/api/v1/dht/nodes")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var list struct {
		Items []DHTNode `json:"items"`
		Total int       `json:"total"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&list); err != nil {
		t.Fatal(err)
	}
	if list.Total != 1 || len(list.Items) != 1 {
		t.Fatalf("expected one visible node, got %+v", list)
	}
	if list.Items[0].NodeID != "dht_public_01" || list.Items[0].RelayPolicy != DHTRelayPolicyPublic {
		t.Fatalf("unexpected listed node: %+v", list.Items[0])
	}
}

func TestDHTUnhealthyNodeIsHidden(t *testing.T) {
	root := t.TempDir()
	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	handler := &Handler{
		Store:     store,
		DHTHealth: fakeDHTHealthChecker{status: DHTHealthUnhealthy},
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	proof := dhtOwnerProofForTest(t)
	body, _ := json.Marshal(DHTRegisterRequest{
		NodeID:             "dht_bad",
		OwnerPeerID:        proof.PubkeyHex,
		Endpoints:          []DHTEndpoint{{Network: "tcp", Host: "203.0.113.10", Port: 41001}},
		AdminSignedRequest: &proof,
	})
	resp, err := http.Post(srv.URL+"/api/v1/dht/nodes/register", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("register status=%d", resp.StatusCode)
	}

	resp, err = http.Get(srv.URL + "/api/v1/dht/nodes")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var list struct {
		Items []DHTNode `json:"items"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&list); err != nil {
		t.Fatal(err)
	}
	if len(list.Items) != 0 {
		t.Fatalf("unhealthy node must be hidden, got %+v", list.Items)
	}
}

func TestDHTRegisterTreatsRegistrationAsPublic(t *testing.T) {
	root := t.TempDir()
	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	srv := httptest.NewServer(&Handler{Store: store, DHTHealth: fakeDHTHealthChecker{status: DHTHealthHealthy}})
	defer srv.Close()

	proof := dhtOwnerProofForTest(t)
	body, _ := json.Marshal(DHTRegisterRequest{
		NodeID:             "dht_public_by_action",
		OwnerPeerID:        proof.PubkeyHex,
		Endpoints:          []DHTEndpoint{{Network: "udp", Host: "203.0.113.12", Port: 41001}},
		AdminSignedRequest: &proof,
	})
	resp, err := http.Post(srv.URL+"/api/v1/dht/nodes/register", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("register status=%d", resp.StatusCode)
	}
	var registered DHTNode
	if err := json.NewDecoder(resp.Body).Decode(&registered); err != nil {
		t.Fatal(err)
	}
	items, err := store.ListDHTNodes(time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].NodeID != "dht_public_by_action" {
		t.Fatalf("registered node should be listed by action, got %+v", items)
	}
}

func TestDHTDeleteRequiresOwnerProof(t *testing.T) {
	root := t.TempDir()
	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	proof := dhtOwnerProofForTest(t)
	node, err := NewDHTNodeFromRegister(DHTRegisterRequest{
		NodeID:      "dht_delete",
		OwnerPeerID: proof.PubkeyHex,
		Endpoints:   []DHTEndpoint{{Network: "udp", Host: "203.0.113.10", Port: 41001}},
	}, time.Now().UTC(), false)
	if err != nil {
		t.Fatalf("node: %v", err)
	}
	node.HealthStatus = DHTHealthHealthy
	if _, err := store.UpsertDHTNode(node); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	srv := httptest.NewServer(&Handler{Store: store})
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodDelete, srv.URL+"/api/v1/dht/nodes/dht_delete", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("delete without proof status=%d", resp.StatusCode)
	}

	proofBody, _ := json.Marshal(proof)
	req, _ = http.NewRequest(http.MethodDelete, srv.URL+"/api/v1/dht/nodes/dht_delete", bytes.NewReader(proofBody))
	req.Header.Set("Content-Type", "application/json")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("delete with token status=%d", resp.StatusCode)
	}

	items, err := store.ListDHTNodes(time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 0 {
		t.Fatalf("deleted node should not be listed: %s", strings.Join([]string{items[0].NodeID}, ","))
	}
}

func dhtOwnerProofForTest(t *testing.T) SignedRequest {
	t.Helper()
	cert := governance.SignedMasterCertificate{
		Certificate: governance.MasterCertificatePayload{
			PublicKeyHex: governancePublicKeyOne,
			NotBefore:    "2026-01-01T00:00:00Z",
			NotAfter:     "2036-01-01T00:00:00Z",
		},
	}
	key, err := governance.LoadMasterKey(governancePrivateKeyOne, cert)
	if err != nil {
		t.Fatal(err)
	}
	payload := `{"enabled":true}`
	ts := time.Now().UTC().Unix()
	nonce := strconv.FormatInt(time.Now().UnixNano(), 16)
	signed := payload + "\n" + key.PublicKeyHex + "\n" + strconv.FormatInt(ts, 10) + "\n" + nonce
	signature, err := governance.Sign(key.PrivateKey, []byte(signed))
	if err != nil {
		t.Fatal(err)
	}
	return SignedRequest{
		Payload:      payload,
		PubkeyHex:    key.PublicKeyHex,
		SignatureHex: signature,
		Timestamp:    ts,
		Nonce:        nonce,
	}
}
