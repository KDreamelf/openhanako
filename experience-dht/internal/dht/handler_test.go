package dht

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	secp "github.com/decred/dcrd/dcrec/secp256k1/v4"
	ecdsa "github.com/decred/dcrd/dcrec/secp256k1/v4/ecdsa"
)

var signedRequestNonceCounter uint64

type fakeManager struct {
	registered   []NodeDescriptor
	unregistered []string
	nodes        []NodeDescriptor
	proofs       []SignedRequest
}

func (m *fakeManager) ListDHTNodes(_ context.Context) ([]NodeDescriptor, error) {
	return append([]NodeDescriptor(nil), m.nodes...), nil
}

func (m *fakeManager) Register(_ context.Context, node NodeDescriptor, proof *SignedRequest) error {
	m.registered = append(m.registered, node)
	if proof != nil {
		m.proofs = append(m.proofs, *proof)
	}
	return nil
}

func (m *fakeManager) Unregister(_ context.Context, nodeID string, _ *SignedRequest) error {
	m.unregistered = append(m.unregistered, nodeID)
	return nil
}

func TestBindStoresPubkeyAndHonorsReinitializeFlag(t *testing.T) {
	cfg := testConfig(t)
	store := testStore(t, cfg)
	pubHex := testKey(t).PubKey().SerializeUncompressed()

	state, err := store.Bind(cfg, hex.EncodeToString(pubHex), "secret")
	if err != nil {
		t.Fatalf("bind: %v", err)
	}
	if state.BoundPubkeyHex == "" {
		t.Fatalf("bound pubkey missing")
	}

	cfg.AllowReinitialize = false
	_, err = store.Bind(cfg, hex.EncodeToString(pubHex), "secret")
	if err == nil {
		t.Fatalf("expected reinitialize to be rejected")
	}
}

func TestBindCanSetBootstrapManagerURL(t *testing.T) {
	cfg := testConfig(t)
	cfg.ManagerBaseURL = ""
	priv := testKey(t)
	handler, _, _ := testHandler(t, cfg)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	body, _ := json.Marshal(BindRequest{
		InitPassword:   "secret",
		PubkeyHex:      pubHex(priv),
		ManagerBaseURL: " https://experience.test/ ",
	})
	resp, err := http.Post(srv.URL+"/api/v1/admin/bind", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("bind status=%d body=%s", resp.StatusCode, readBody(t, resp))
	}
	var out struct {
		State State `json:"state"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if out.State.BootstrapManagerURL != "https://experience.test" {
		t.Fatalf("bootstrap manager url not stored: %+v", out.State)
	}
}

func TestStateInitGeneratesAndPersistsNodeID(t *testing.T) {
	store := NewStateStore(filepath.Join(t.TempDir(), "state.json"))
	if err := store.Init(""); err != nil {
		t.Fatalf("init: %v", err)
	}
	state, err := store.Get()
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(state.NodeID) == "" {
		t.Fatalf("node id not generated: %+v", state)
	}
	generated := state.NodeID
	if err := store.Init("manual_override"); err != nil {
		t.Fatalf("second init: %v", err)
	}
	state, err = store.Get()
	if err != nil {
		t.Fatal(err)
	}
	if state.NodeID != generated {
		t.Fatalf("node id should persist, got %q want %q", state.NodeID, generated)
	}
}

func TestUDPHealthServerResponds(t *testing.T) {
	handler, _, _ := testHandler(t, testConfig(t))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	addr := freeUDPAddr(t)
	errCh := make(chan error, 1)
	go func() {
		errCh <- handler.RunUDPServer(ctx, addr)
	}()
	var response string
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("udp", addr, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		_ = conn.SetDeadline(time.Now().Add(100 * time.Millisecond))
		_, writeErr := conn.Write([]byte("healthz\n"))
		buf := make([]byte, 1024)
		n, readErr := conn.Read(buf)
		_ = conn.Close()
		if writeErr == nil && readErr == nil {
			response = string(buf[:n])
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !strings.Contains(response, `"ok":true`) || !strings.Contains(response, `"service":"experience-dht-udp"`) {
		t.Fatalf("unexpected udp health response: %s", response)
	}
	cancel()
	select {
	case err := <-errCh:
		if err != nil {
			t.Fatalf("udp server returned error: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatalf("udp server did not stop")
	}
}

func TestSignedAdminPublicModeRegistersAndUnregisters(t *testing.T) {
	cfg := testConfig(t)
	priv := testKey(t)
	handler, store, manager := testHandler(t, cfg)
	if _, err := store.Bind(cfg, pubHex(priv), "secret"); err != nil {
		t.Fatalf("bind: %v", err)
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := postSigned(t, srv.URL+"/api/v1/admin/public", priv, PublicModeRequest{Enabled: true})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("enable public status=%d body=%s", resp.StatusCode, readBody(t, resp))
	}
	if len(manager.registered) != 1 {
		t.Fatalf("expected one manager registration, got %d", len(manager.registered))
	}
	if len(manager.proofs) != 1 || !strings.EqualFold(manager.proofs[0].PubkeyHex, pubHex(priv)) {
		t.Fatalf("expected public registration proof from bound key, got %+v", manager.proofs)
	}
	if len(manager.registered[0].Endpoints) != 2 {
		t.Fatalf("expected http and udp endpoints, got %+v", manager.registered[0].Endpoints)
	}
	if manager.registered[0].Endpoints[0].Network != "http" || manager.registered[0].Endpoints[0].Port != 8091 {
		t.Fatalf("expected public API endpoint first, got %+v", manager.registered[0].Endpoints[0])
	}
	if manager.registered[0].Endpoints[1].Network != "udp" || manager.registered[0].Endpoints[1].Port != 41001 {
		t.Fatalf("expected public UDP endpoint second, got %+v", manager.registered[0].Endpoints[1])
	}
	state, err := store.Get()
	if err != nil {
		t.Fatal(err)
	}
	if !state.PublicEnabled || !state.PublicRegistered {
		t.Fatalf("public state not set: %+v", state)
	}
	if state.PublicManagerURL != cfg.ManagerBaseURL {
		t.Fatalf("public manager url not stored: %+v", state)
	}

	resp = postSigned(t, srv.URL+"/api/v1/admin/public", priv, PublicModeRequest{Enabled: false})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("disable public status=%d body=%s", resp.StatusCode, readBody(t, resp))
	}
	if len(manager.unregistered) != 1 || manager.unregistered[0] != cfg.NodeID {
		t.Fatalf("expected unregister for node, got %+v", manager.unregistered)
	}
}

func TestPublicModeEnableRequiresManagerBaseURL(t *testing.T) {
	cfg := testConfig(t)
	cfg.ManagerBaseURL = ""
	priv := testKey(t)
	handler, store, manager := testHandler(t, cfg)
	if _, err := store.Bind(cfg, pubHex(priv), "secret"); err != nil {
		t.Fatalf("bind: %v", err)
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := postSigned(t, srv.URL+"/api/v1/admin/public", priv, PublicModeRequest{Enabled: true})
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected bad request, got %d body=%s", resp.StatusCode, readBody(t, resp))
	}
	if len(manager.registered) != 0 {
		t.Fatalf("expected no manager registration, got %+v", manager.registered)
	}
}

func TestPublicModeCanUseSignedManagerBaseURL(t *testing.T) {
	cfg := testConfig(t)
	cfg.ManagerBaseURL = ""
	priv := testKey(t)
	handler, store, manager := testHandler(t, cfg)
	if _, err := store.Bind(cfg, pubHex(priv), "secret"); err != nil {
		t.Fatalf("bind: %v", err)
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := postSigned(t, srv.URL+"/api/v1/admin/public", priv, PublicModeRequest{
		Enabled:        true,
		ManagerBaseURL: " https://experience.test/ ",
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("enable public status=%d body=%s", resp.StatusCode, readBody(t, resp))
	}
	if len(manager.registered) != 1 {
		t.Fatalf("expected one manager registration, got %d", len(manager.registered))
	}
	state, err := store.Get()
	if err != nil {
		t.Fatal(err)
	}
	if state.PublicManagerURL != "https://experience.test" {
		t.Fatalf("public manager url not stored: %+v", state)
	}
}

func TestSignedAdminRuntimeConfigUpdatesPublicDescriptor(t *testing.T) {
	cfg := testConfig(t)
	cfg.PublicAPIBaseURL = ""
	cfg.PublicHost = ""
	cfg.PublicPort = 0
	priv := testKey(t)
	handler, store, _ := testHandler(t, cfg)
	if _, err := store.Bind(cfg, pubHex(priv), "secret"); err != nil {
		t.Fatalf("bind: %v", err)
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := postSigned(t, srv.URL+"/api/v1/admin/config", priv, RuntimeConfigRequest{
		RuntimeConfig: RuntimeConfig{
			PublicAPIBaseURL: "http://203.0.113.20:8091",
			CandidateEndpoints: []Endpoint{
				{Network: "quic", Host: "203.0.113.20", Port: 41002},
				{Network: "udp", Host: "203.0.113.20", Port: 41001, RequiresHolePunch: true},
			},
			RelayPolicy: RelayPolicyOwnerOnly,
		},
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("runtime config status=%d body=%s", resp.StatusCode, readBody(t, resp))
	}
	state, err := store.Get()
	if err != nil {
		t.Fatal(err)
	}
	node := handler.publicDescriptor(state)
	if node.NodeID != state.NodeID || len(node.Endpoints) != 3 {
		t.Fatalf("unexpected descriptor: state=%+v node=%+v", state, node)
	}
	if node.Endpoints[0].Network != "http" || node.Endpoints[0].Host != "203.0.113.20" {
		t.Fatalf("runtime http endpoint not used: %+v", node.Endpoints)
	}
	if node.Endpoints[1].Network != "quic" || node.Endpoints[1].Port != 41002 {
		t.Fatalf("runtime quic endpoint not used before udp: %+v", node.Endpoints)
	}
	if node.Endpoints[2].Network != "udp" || node.Endpoints[2].Port != 41001 || !node.Endpoints[2].RequiresHolePunch {
		t.Fatalf("runtime udp endpoint not used after quic: %+v", node.Endpoints)
	}
	if node.RelayPolicy != RelayPolicyOwnerOnly {
		t.Fatalf("runtime relay policy not used: %+v", node)
	}
}

func TestManagerURLSelectionSeparatesPublicAndBootstrap(t *testing.T) {
	handler, _, _ := testHandler(t, testConfig(t))
	state := State{
		BootstrapManagerURL: "https://bootstrap.test",
		PublicManagerURL:    "https://public.test",
	}
	publicURL, err := handler.publicManagerBaseURL("", state)
	if err != nil {
		t.Fatal(err)
	}
	bootstrapURL, err := handler.bootstrapManagerBaseURL("", state)
	if err != nil {
		t.Fatal(err)
	}
	if publicURL != "https://public.test" {
		t.Fatalf("unexpected public manager url: %s", publicURL)
	}
	if bootstrapURL != "https://bootstrap.test" {
		t.Fatalf("unexpected bootstrap manager url: %s", bootstrapURL)
	}
}

func TestHeartbeatKeepsDefaultPrivateDHTLocal(t *testing.T) {
	cfg := testConfig(t)
	handler, store, manager := testHandler(t, cfg)

	handler.heartbeat(context.Background())

	if len(manager.registered) != 0 {
		t.Fatalf("expected no manager registration, got %+v", manager.registered)
	}
	state, err := store.Get()
	if err != nil {
		t.Fatal(err)
	}
	if state.PublicEnabled || state.PublicRegistered {
		t.Fatalf("expected private state, got %+v", state)
	}
}

func TestHeartbeatRegistersOnlyAfterClientEnabledPublicState(t *testing.T) {
	cfg := testConfig(t)
	handler, store, manager := testHandler(t, cfg)
	if _, err := store.SetPublic(true, false, "https://experience.test", nil); err != nil {
		t.Fatalf("set public: %v", err)
	}

	handler.heartbeat(context.Background())

	if len(manager.registered) != 1 {
		t.Fatalf("expected one manager registration, got %d", len(manager.registered))
	}
	state, err := store.Get()
	if err != nil {
		t.Fatal(err)
	}
	if !state.PublicEnabled || !state.PublicRegistered {
		t.Fatalf("expected public registered state, got %+v", state)
	}
}

func TestBootstrapPeersPullsPublicDHTList(t *testing.T) {
	cfg := testConfig(t)
	handler, _, manager := testHandler(t, cfg)
	manager.nodes = []NodeDescriptor{
		{
			NodeID: "remote_dht",
			Endpoints: []Endpoint{{
				Network: "http",
				Host:    "203.0.113.11",
				Port:    8091,
			}},
			HealthStatus: HealthHealthy,
			ExpiresAt:    time.Now().UTC().Add(time.Minute).Format(time.RFC3339),
		},
		{
			NodeID: cfg.NodeID,
			Endpoints: []Endpoint{{
				Network: "http",
				Host:    "203.0.113.10",
				Port:    8091,
			}},
			HealthStatus: HealthHealthy,
		},
	}

	handler.bootstrapPeers(context.Background())

	upstreams := handler.upstreamNodes()
	if len(upstreams) != 1 || upstreams[0].NodeID != "remote_dht" {
		t.Fatalf("unexpected upstreams: %+v", upstreams)
	}
}

func TestSignedAdminRejectsUnboundPubkey(t *testing.T) {
	cfg := testConfig(t)
	owner := testKey(t)
	other := testKey(t)
	handler, store, _ := testHandler(t, cfg)
	if _, err := store.Bind(cfg, pubHex(owner), "secret"); err != nil {
		t.Fatalf("bind: %v", err)
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := postSigned(t, srv.URL+"/api/v1/admin/status", other, map[string]string{"op": "status"})
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("expected forbidden, got %d body=%s", resp.StatusCode, readBody(t, resp))
	}
}

func TestPresenceAndProviderLookup(t *testing.T) {
	cfg := testConfig(t)
	cfg.RelayPolicy = RelayPolicyOwnerOnly
	owner := testKey(t)
	handler, store, _ := testHandler(t, cfg)
	if _, err := store.Bind(cfg, pubHex(owner), "secret"); err != nil {
		t.Fatalf("bind: %v", err)
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	presence := PresenceRequest{
		PeerID: "peer_owner_device",
		Endpoints: []Endpoint{{
			Network: "tcp",
			Host:    "2001:db8::20",
			Port:    41002,
		}},
		PackageHashes: []string{"sha256:abc"},
	}
	resp := postSigned(t, srv.URL+"/api/v1/peers/presence", owner, presence)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("presence status=%d body=%s", resp.StatusCode, readBody(t, resp))
	}

	resp, err := http.Get(srv.URL + "/api/v1/providers?package_hash=sha256:abc")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out struct {
		Items []ProviderRecord `json:"items"`
		Total int              `json:"total"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if out.Total != 1 || out.Items[0].PeerID != "peer_owner_device" {
		t.Fatalf("unexpected providers: %+v", out)
	}
}

func TestProviderLookupIncludesFederatedUpstream(t *testing.T) {
	cfg := testConfig(t)
	owner := testKey(t)
	remoteHandler, _, _ := testHandler(t, cfg)
	remoteSrv := httptest.NewServer(remoteHandler)
	defer remoteSrv.Close()

	resp := postSigned(t, remoteSrv.URL+"/api/v1/peers/presence", owner, PresenceRequest{
		PeerID:        "peer_remote",
		PackageHashes: []string{"sha256:fed"},
		Endpoints: []Endpoint{{
			Network: "tcp",
			Host:    "203.0.113.21",
			Port:    41002,
		}},
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("remote presence status=%d body=%s", resp.StatusCode, readBody(t, resp))
	}
	_ = resp.Body.Close()

	localCfg := testConfig(t)
	localCfg.NodeID = "dht_local_federated"
	localHandler, _, _ := testHandler(t, localCfg)
	localHandler.setUpstreams([]NodeDescriptor{testServerNode(t, "dht_remote_federated", remoteSrv.URL)})
	localSrv := httptest.NewServer(localHandler)
	defer localSrv.Close()

	items := fetchProviders(t, localSrv.URL, "sha256:fed")
	if len(items) != 1 || items[0].PeerID != "peer_remote" {
		t.Fatalf("unexpected federated providers: %+v", items)
	}
}

func TestPresenceFanoutToUpstreamDHT(t *testing.T) {
	remoteHandler, _, _ := testHandler(t, testConfig(t))
	remoteSrv := httptest.NewServer(remoteHandler)
	defer remoteSrv.Close()

	localCfg := testConfig(t)
	localCfg.NodeID = "dht_local_fanout"
	localHandler, _, _ := testHandler(t, localCfg)
	localHandler.setUpstreams([]NodeDescriptor{testServerNode(t, "dht_remote_fanout", remoteSrv.URL)})
	localSrv := httptest.NewServer(localHandler)
	defer localSrv.Close()

	owner := testKey(t)
	resp := postSigned(t, localSrv.URL+"/api/v1/peers/presence", owner, PresenceRequest{
		PeerID:        "peer_fanout",
		PackageHashes: []string{"sha256:fanout"},
		Endpoints: []Endpoint{{
			Network: "tcp",
			Host:    "203.0.113.22",
			Port:    41002,
		}},
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("local presence status=%d body=%s", resp.StatusCode, readBody(t, resp))
	}
	_ = resp.Body.Close()

	deadline := time.Now().Add(time.Second)
	for {
		items := fetchProviders(t, remoteSrv.URL, "sha256:fanout")
		if len(items) == 1 && items[0].PeerID == "peer_fanout" {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("remote DHT did not receive fanout")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestOwnerOnlyPresenceRejectsOtherPubkey(t *testing.T) {
	cfg := testConfig(t)
	cfg.RelayPolicy = RelayPolicyOwnerOnly
	owner := testKey(t)
	other := testKey(t)
	handler, store, _ := testHandler(t, cfg)
	if _, err := store.Bind(cfg, pubHex(owner), "secret"); err != nil {
		t.Fatalf("bind: %v", err)
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := postSigned(t, srv.URL+"/api/v1/peers/presence", other, PresenceRequest{
		PeerID: "peer_other",
		Endpoints: []Endpoint{{
			Network: "tcp",
			Host:    "198.51.100.20",
			Port:    41002,
		}},
	})
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("expected forbidden, got %d body=%s", resp.StatusCode, readBody(t, resp))
	}
}

func TestRelaySessionUploadsAndDownloadsExactBytes(t *testing.T) {
	cfg := testConfig(t)
	cfg.RelayPolicy = RelayPolicyPublic
	cfg.RelayMaxBytes = 1024
	requester := testKey(t)
	handler, _, _ := testHandler(t, cfg)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	session := createRelaySession(t, srv.URL, requester, RelaySessionRequest{
		RequestID:       "req_1",
		ExperienceID:    "exp_1",
		PackageHash:     "sha256:abc",
		RequesterPeerID: "peer_requester",
		ProviderPeerID:  "peer_provider",
		MaxBytes:        1024,
	})
	if session.Status != "open" {
		t.Fatalf("expected open session, got %+v", session)
	}

	payload := []byte("hxp-bytes")
	req, err := http.NewRequest(http.MethodPut, srv.URL+"/api/v1/relay/sessions/"+session.SessionID+"/package", bytes.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var uploaded RelaySession
	if err := json.NewDecoder(resp.Body).Decode(&uploaded); err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("upload status=%d session=%+v", resp.StatusCode, uploaded)
	}
	if uploaded.Status != "uploaded" || uploaded.Bytes != int64(len(payload)) {
		t.Fatalf("unexpected uploaded session: %+v", uploaded)
	}

	resp, err = http.Get(srv.URL + "/api/v1/relay/sessions/" + session.SessionID + "/package")
	if err != nil {
		t.Fatal(err)
	}
	body := []byte(readBody(t, resp))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("download status=%d body=%s", resp.StatusCode, body)
	}
	if !bytes.Equal(body, payload) {
		t.Fatalf("downloaded bytes mismatch: %q", body)
	}
	if resp.Header.Get("X-PH01-Relay-Payload-SHA256") != hex.EncodeToString(sha256Bytes(payload)) {
		t.Fatalf("payload hash header mismatch")
	}

	resp, err = http.Get(srv.URL + "/api/v1/cache/packages/abc")
	if err != nil {
		t.Fatal(err)
	}
	body = []byte(readBody(t, resp))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("cache download status=%d body=%s", resp.StatusCode, body)
	}
	if !bytes.Equal(body, payload) {
		t.Fatalf("cached relay bytes mismatch: %q", body)
	}
	if resp.Header.Get("X-PH01-Package-Hash") != "sha256:abc" {
		t.Fatalf("cache package hash header mismatch: %s", resp.Header.Get("X-PH01-Package-Hash"))
	}
}

func TestOwnerOnlyRelayRejectsUnrelatedSession(t *testing.T) {
	cfg := testConfig(t)
	cfg.RelayPolicy = RelayPolicyOwnerOnly
	owner := testKey(t)
	other := testKey(t)
	handler, store, _ := testHandler(t, cfg)
	if _, err := store.Bind(cfg, pubHex(owner), "secret"); err != nil {
		t.Fatalf("bind: %v", err)
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := postSigned(t, srv.URL+"/api/v1/relay/sessions", other, RelaySessionRequest{
		RequestID:       "req_1",
		PackageHash:     "sha256:abc",
		RequesterPeerID: "peer_requester",
		ProviderPeerID:  "peer_provider",
	})
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("expected forbidden, got %d body=%s", resp.StatusCode, readBody(t, resp))
	}
}

func TestOwnerOnlyRelayAllowsOwnerParticipant(t *testing.T) {
	cfg := testConfig(t)
	cfg.RelayPolicy = RelayPolicyOwnerOnly
	owner := testKey(t)
	other := testKey(t)
	handler, store, _ := testHandler(t, cfg)
	ownerPeer := pubHex(owner)
	if _, err := store.Bind(cfg, ownerPeer, "secret"); err != nil {
		t.Fatalf("bind: %v", err)
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	session := createRelaySession(t, srv.URL, other, RelaySessionRequest{
		RequestID:            "req_1",
		PackageHash:          "sha256:abc",
		RequesterPeerID:      "peer_requester_device",
		RequesterOwnerPeerID: ownerPeer,
		ProviderPeerID:       "peer_provider",
	})
	if session.SessionID == "" {
		t.Fatalf("session missing: %+v", session)
	}
}

func TestRelayRejectsOversizedPayload(t *testing.T) {
	cfg := testConfig(t)
	cfg.RelayPolicy = RelayPolicyPublic
	cfg.RelayMaxBytes = 4
	requester := testKey(t)
	handler, _, _ := testHandler(t, cfg)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	session := createRelaySession(t, srv.URL, requester, RelaySessionRequest{
		RequestID:       "req_1",
		PackageHash:     "sha256:abc",
		RequesterPeerID: "peer_requester",
		ProviderPeerID:  "peer_provider",
	})
	resp, err := http.DefaultClient.Do(mustRequest(t, http.MethodPut, srv.URL+"/api/v1/relay/sessions/"+session.SessionID+"/package", []byte("12345")))
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413, got %d body=%s", resp.StatusCode, readBody(t, resp))
	}
	_ = resp.Body.Close()
}

func TestHolePunchSessionReportsAndStatus(t *testing.T) {
	cfg := testConfig(t)
	cfg.RelayPolicy = RelayPolicyPublic
	requester := testKey(t)
	provider := testKey(t)
	handler, _, _ := testHandler(t, cfg)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	session := createHolePunchSession(t, srv.URL, requester, HolePunchSessionRequest{
		RequestID:       "req_1",
		ExperienceID:    "exp_1",
		PackageHash:     "sha256:abc",
		RequesterPeerID: "peer_requester",
		RequesterAddrs: []Endpoint{{
			Network:           "udp",
			Host:              "198.51.100.10",
			Port:              41010,
			RequiresHolePunch: true,
		}},
		ProviderPeerID: "peer_provider",
		ProviderAddrs: []Endpoint{{
			Network:           "udp",
			Host:              "198.51.100.20",
			Port:              41020,
			RequiresHolePunch: true,
		}},
	})
	if session.Status != "open" || session.PunchToken == "" {
		t.Fatalf("unexpected session: %+v", session)
	}

	report := HolePunchReport{
		PeerID: "peer_requester",
		Role:   "requester",
		Result: "attempting",
		ObservedEndpoint: &Endpoint{
			Network: "udp",
			Host:    "203.0.113.10",
			Port:    50000,
		},
	}
	resp := postSigned(t, srv.URL+"/api/v1/hole-punch/sessions/"+session.SessionID+"/reports", requester, report)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("requester report status=%d body=%s", resp.StatusCode, readBody(t, resp))
	}
	var updated HolePunchSession
	if err := json.NewDecoder(resp.Body).Decode(&updated); err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if updated.Status != "attempting" || updated.RequesterReport == nil {
		t.Fatalf("unexpected requester report session: %+v", updated)
	}

	resp = postSigned(t, srv.URL+"/api/v1/hole-punch/sessions/"+session.SessionID+"/reports", provider, HolePunchReport{
		PeerID: "peer_provider",
		Role:   "provider",
		Result: "succeeded",
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("provider report status=%d body=%s", resp.StatusCode, readBody(t, resp))
	}
	_ = resp.Body.Close()

	resp, err := http.Get(srv.URL + "/api/v1/hole-punch/sessions/" + session.SessionID)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out HolePunchSession
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if out.Status != "succeeded" || out.ProviderReport == nil {
		t.Fatalf("unexpected hole punch status: %+v", out)
	}
}

func TestOwnerOnlyHolePunchRejectsUnrelatedSession(t *testing.T) {
	cfg := testConfig(t)
	cfg.RelayPolicy = RelayPolicyOwnerOnly
	owner := testKey(t)
	other := testKey(t)
	handler, store, _ := testHandler(t, cfg)
	if _, err := store.Bind(cfg, pubHex(owner), "secret"); err != nil {
		t.Fatalf("bind: %v", err)
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := postSigned(t, srv.URL+"/api/v1/hole-punch/sessions", other, HolePunchSessionRequest{
		RequestID:       "req_1",
		PackageHash:     "sha256:abc",
		RequesterPeerID: "peer_requester",
		ProviderPeerID:  "peer_provider",
	})
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("expected forbidden, got %d body=%s", resp.StatusCode, readBody(t, resp))
	}
}

func TestOwnerOnlyHolePunchAllowsOwnerParticipant(t *testing.T) {
	cfg := testConfig(t)
	cfg.RelayPolicy = RelayPolicyOwnerOnly
	owner := testKey(t)
	other := testKey(t)
	handler, store, _ := testHandler(t, cfg)
	ownerPeer := pubHex(owner)
	if _, err := store.Bind(cfg, ownerPeer, "secret"); err != nil {
		t.Fatalf("bind: %v", err)
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	session := createHolePunchSession(t, srv.URL, other, HolePunchSessionRequest{
		RequestID:            "req_1",
		PackageHash:          "sha256:abc",
		RequesterPeerID:      "peer_requester_device",
		RequesterOwnerPeerID: ownerPeer,
		ProviderPeerID:       "peer_provider",
	})
	if session.SessionID == "" {
		t.Fatalf("session missing: %+v", session)
	}
}

func TestHolePunchDisabledByCapability(t *testing.T) {
	cfg := testConfig(t)
	cfg.Capabilities["hole_punch"] = false
	requester := testKey(t)
	handler, _, _ := testHandler(t, cfg)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := postSigned(t, srv.URL+"/api/v1/hole-punch/sessions", requester, HolePunchSessionRequest{
		RequestID:       "req_1",
		PackageHash:     "sha256:abc",
		RequesterPeerID: "peer_requester",
		ProviderPeerID:  "peer_provider",
	})
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("expected service unavailable, got %d body=%s", resp.StatusCode, readBody(t, resp))
	}
}

func TestPackageRequestOfferRouting(t *testing.T) {
	cfg := testConfig(t)
	cfg.RelayPolicy = RelayPolicyPublic
	requester := testKey(t)
	provider := testKey(t)
	handler, _, _ := testHandler(t, cfg)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := postSigned(t, srv.URL+"/api/v1/package-requests", requester, PackageRequest{
		RequestID:       "req_1",
		ExperienceID:    "exp_1",
		PackageHash:     "sha256:abc",
		RequesterPeerID: "peer_requester",
		RequesterAddrs: []Endpoint{{
			Network: "udp",
			Host:    "198.51.100.10",
			Port:    41010,
		}},
		PreferredTransports: []string{"ipv4_hole_punch", "dht_relay"},
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("request publish status=%d body=%s", resp.StatusCode, readBody(t, resp))
	}
	_ = resp.Body.Close()

	resp, err := http.Get(srv.URL + "/api/v1/package-requests?package_hash=sha256:abc")
	if err != nil {
		t.Fatal(err)
	}
	var requests struct {
		Items []PackageRequestRecord `json:"items"`
		Total int                    `json:"total"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&requests); err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if requests.Total != 1 || requests.Items[0].RequestID != "req_1" {
		t.Fatalf("unexpected requests: %+v", requests)
	}

	resp = postSigned(t, srv.URL+"/api/v1/package-requests/req_1/offers", provider, PackageOffer{
		RequestID:      "req_1",
		ExperienceID:   "exp_1",
		PackageHash:    "sha256:abc",
		ProviderPeerID: "peer_provider",
		ProviderAddrs: []Endpoint{{
			Network: "udp",
			Host:    "198.51.100.20",
			Port:    41020,
		}},
		AvailableTransports: []string{"ipv4_hole_punch", "dht_relay"},
		ReviewMaterials:     map[string]any{"schema_version": "ph01.experience.review_materials.v1"},
		Publisher:           map[string]any{"pubkey": "pub_provider"},
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("offer status=%d body=%s", resp.StatusCode, readBody(t, resp))
	}
	_ = resp.Body.Close()

	resp, err = http.Get(srv.URL + "/api/v1/package-requests/req_1/offers")
	if err != nil {
		t.Fatal(err)
	}
	var offers struct {
		Items []PackageOfferRecord `json:"items"`
		Total int                  `json:"total"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&offers); err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if offers.Total != 1 || offers.Items[0].ProviderPeerID != "peer_provider" {
		t.Fatalf("unexpected offers: %+v", offers)
	}
}

func TestExperienceDemandOfferRouting(t *testing.T) {
	cfg := testConfig(t)
	cfg.RelayPolicy = RelayPolicyPublic
	requester := testKey(t)
	provider := testKey(t)
	handler, _, _ := testHandler(t, cfg)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := postSigned(t, srv.URL+"/api/v1/experience-demands", requester, ExperienceDemand{
		RequestID:            "dem_1",
		NaturalLanguageQuery: "我想要一个能处理窗口自动化任务的经验",
		QueryLanguage:        "zh-CN",
		QueryKeywords:        []string{"窗口", "自动化"},
		RequesterPeerID:      "peer_requester",
		PreferredTransports:  []string{"dht_relay", "manager_seed"},
		HopLimit:             4,
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("demand status=%d body=%s", resp.StatusCode, readBody(t, resp))
	}
	var demand ExperienceDemandRecord
	if err := json.NewDecoder(resp.Body).Decode(&demand); err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if demand.SchemaVersion != ExperienceDemandSchema || demand.RequesterPubkeyHash == "" {
		t.Fatalf("unexpected demand: %+v", demand)
	}
	if len(demand.ReturnPath) != 1 || demand.ReturnPath[0].NodeID != cfg.NodeID {
		t.Fatalf("return path should contain local dht: %+v", demand.ReturnPath)
	}

	resp, err := http.Get(srv.URL + "/api/v1/experience-demands?q=" + url.QueryEscape("窗口"))
	if err != nil {
		t.Fatal(err)
	}
	var demands struct {
		Items []ExperienceDemandRecord `json:"items"`
		Total int                      `json:"total"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&demands); err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if demands.Total != 1 || demands.Items[0].RequestID != "dem_1" {
		t.Fatalf("unexpected demands: %+v", demands)
	}

	resp = postSigned(t, srv.URL+"/api/v1/experience-demands/dem_1/offers", provider, ExperienceDemandOffer{
		RequestID:      "dem_1",
		ExperienceID:   "exp_window_ops",
		PackageHash:    "sha256:abc",
		Title:          "窗口自动化经验",
		MatchedReason:  "关键词命中",
		ProviderPeerID: "peer_provider",
		ProviderAddrs: []Endpoint{{
			Network: "udp",
			Host:    "198.51.100.20",
			Port:    41020,
		}},
		AvailableTransports: []string{"dht_relay"},
		ReviewChain: []map[string]any{{
			"schema_version": "ph01.experience.ratings.v1",
			"type":           "root",
			"score":          1,
		}},
		ReturnPath: demand.ReturnPath,
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("demand offer status=%d body=%s", resp.StatusCode, readBody(t, resp))
	}
	var offer ExperienceDemandOfferRecord
	if err := json.NewDecoder(resp.Body).Decode(&offer); err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if offer.SchemaVersion != DemandOfferSchema || offer.ReviewChainLength != 1 || offer.ReviewChainDigest == "" {
		t.Fatalf("unexpected demand offer: %+v", offer)
	}

	resp, err = http.Get(srv.URL + "/api/v1/experience-demands/dem_1/offers")
	if err != nil {
		t.Fatal(err)
	}
	var offers struct {
		Items []ExperienceDemandOfferRecord `json:"items"`
		Total int                           `json:"total"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&offers); err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if offers.Total != 1 || offers.Items[0].ProviderPeerID != "peer_provider" {
		t.Fatalf("unexpected demand offers: %+v", offers)
	}

	resp, err = http.Get(srv.URL + "/api/v1/experience-demands/dem_1/offers?include_review_chain=false")
	if err != nil {
		t.Fatal(err)
	}
	var compactOffers struct {
		Items []ExperienceDemandOfferRecord `json:"items"`
		Total int                           `json:"total"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&compactOffers); err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if compactOffers.Total != 1 || len(compactOffers.Items[0].ReviewChain) != 0 ||
		compactOffers.Items[0].ReviewChainRef == nil ||
		compactOffers.Items[0].ReviewChainRef.Digest == "" {
		t.Fatalf("unexpected compact demand offers: %+v", compactOffers)
	}
	reviewChainURL := srv.URL + compactOffers.Items[0].ReviewChainRef.URL
	resp, err = http.Get(reviewChainURL)
	if err != nil {
		t.Fatal(err)
	}
	var chain ReviewChainPayload
	if err := json.NewDecoder(resp.Body).Decode(&chain); err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK || chain.Length != 1 || chain.Digest != compactOffers.Items[0].ReviewChainRef.Digest {
		t.Fatalf("unexpected review chain payload: status=%d chain=%+v", resp.StatusCode, chain)
	}
}

func TestExperienceDemandWriteRateLimit(t *testing.T) {
	cfg := testConfig(t)
	cfg.RelayPolicy = RelayPolicyPublic
	requester := testKey(t)
	handler, _, _ := testHandler(t, cfg)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	for i := 0; i < maxExperienceDemandWritesPerWindow; i++ {
		resp := postSigned(t, srv.URL+"/api/v1/experience-demands", requester, ExperienceDemand{
			RequestID:            "dem_rate_" + strconv.Itoa(i),
			NaturalLanguageQuery: "限流测试需求 " + strconv.Itoa(i),
			RequesterPeerID:      "peer_requester",
		})
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("demand %d status=%d body=%s", i, resp.StatusCode, readBody(t, resp))
		}
		_ = resp.Body.Close()
	}

	resp := postSigned(t, srv.URL+"/api/v1/experience-demands", requester, ExperienceDemand{
		RequestID:            "dem_rate_blocked",
		NaturalLanguageQuery: "限流测试需求 blocked",
		RequesterPeerID:      "peer_requester",
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("expected rate limit, got status=%d body=%s", resp.StatusCode, readBody(t, resp))
	}
	if resp.Header.Get("Retry-After") == "" {
		t.Fatalf("missing Retry-After header")
	}
}

func TestExperienceDemandLookupIncludesFederatedUpstream(t *testing.T) {
	remoteHandler, _, _ := testHandler(t, testConfig(t))
	remoteSrv := httptest.NewServer(remoteHandler)
	defer remoteSrv.Close()

	requester := testKey(t)
	resp := postSigned(t, remoteSrv.URL+"/api/v1/experience-demands", requester, ExperienceDemand{
		RequestID:            "dem_fed",
		NaturalLanguageQuery: "自然语言经验需求",
		RequesterPeerID:      "peer_requester",
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("remote demand status=%d body=%s", resp.StatusCode, readBody(t, resp))
	}
	_ = resp.Body.Close()

	localCfg := testConfig(t)
	localCfg.NodeID = "dht_local_demand_federated"
	localHandler, _, _ := testHandler(t, localCfg)
	localHandler.setUpstreams([]NodeDescriptor{testServerNode(t, "dht_remote_demand_federated", remoteSrv.URL)})
	localSrv := httptest.NewServer(localHandler)
	defer localSrv.Close()

	resp, err := http.Get(localSrv.URL + "/api/v1/experience-demands?q=" + url.QueryEscape("自然语言"))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out struct {
		Items []ExperienceDemandRecord `json:"items"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if len(out.Items) != 1 || out.Items[0].RequestID != "dem_fed" {
		t.Fatalf("unexpected federated demands: %+v", out.Items)
	}
}

func TestExperienceDemandOffersFallbackToManagerSeed(t *testing.T) {
	cfg := testConfig(t)
	handler, store, _ := testHandler(t, cfg)
	requester := testKey(t)

	managerSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/dht/experience-demands/resolve" {
			t.Fatalf("unexpected manager path: %s", r.URL.Path)
		}
		if r.URL.Query().Get("request_id") != "dem_manager" || !strings.Contains(r.URL.Query().Get("q"), "窗口") {
			t.Fatalf("unexpected manager query: %s", r.URL.RawQuery)
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"items": []ExperienceDemandOfferRecord{{
				ExperienceDemandOffer: ExperienceDemandOffer{
					SchemaVersion:       DemandOfferSchema,
					RequestID:           "dem_manager",
					ExperienceID:        "exp_manager_1",
					PackageHash:         "sha256:manager",
					Title:               "管理端兜底经验",
					ReviewChain:         []map[string]any{{"type": "root", "score": 1}},
					ReviewChainDigest:   "sha256:chain",
					ReviewChainLength:   1,
					ProviderPeerID:      "experience-manager",
					AvailableTransports: []string{"manager_seed"},
					Timestamp:           "2026-05-14T00:00:00Z",
				},
				OfferedAt: "2026-05-14T00:00:00Z",
			}},
			"total": 1,
		})
	}))
	defer managerSrv.Close()

	if _, err := store.SetBootstrapManager(managerSrv.URL); err != nil {
		t.Fatalf("set bootstrap manager: %v", err)
	}
	handler.Manager = HTTPManagerClient{
		BaseURL: managerSrv.URL,
		Client:  managerSrv.Client(),
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := postSigned(t, srv.URL+"/api/v1/experience-demands", requester, ExperienceDemand{
		RequestID:            "dem_manager",
		NaturalLanguageQuery: "我想要窗口识别经验",
		RequesterPeerID:      "peer_requester",
		PreferredTransports:  []string{"dht_relay", "manager_seed"},
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("unexpected demand status: %d", resp.StatusCode)
	}
	_ = resp.Body.Close()

	resp, err := http.Get(srv.URL + "/api/v1/experience-demands/dem_manager/offers")
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Items []ExperienceDemandOfferRecord `json:"items"`
		Total int                           `json:"total"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK || got.Total != 1 {
		t.Fatalf("unexpected manager fallback response status=%d body=%+v", resp.StatusCode, got)
	}
	if got.Items[0].ProviderPeerID != "experience-manager" ||
		!containsString(got.Items[0].AvailableTransports, "manager_seed") ||
		got.Items[0].ReviewChainLength != 1 {
		t.Fatalf("unexpected manager fallback offer: %+v", got.Items[0])
	}
}

func TestOwnerOnlyPackageRequestRejectsUnrelatedRequester(t *testing.T) {
	cfg := testConfig(t)
	cfg.RelayPolicy = RelayPolicyOwnerOnly
	owner := testKey(t)
	other := testKey(t)
	handler, store, _ := testHandler(t, cfg)
	if _, err := store.Bind(cfg, pubHex(owner), "secret"); err != nil {
		t.Fatalf("bind: %v", err)
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := postSigned(t, srv.URL+"/api/v1/package-requests", other, PackageRequest{
		RequestID:       "req_1",
		PackageHash:     "sha256:abc",
		RequesterPeerID: "peer_requester",
	})
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("expected forbidden, got %d body=%s", resp.StatusCode, readBody(t, resp))
	}
}

func TestOwnerOnlyPackageOfferAllowsOwnerRequest(t *testing.T) {
	cfg := testConfig(t)
	cfg.RelayPolicy = RelayPolicyOwnerOnly
	owner := testKey(t)
	provider := testKey(t)
	handler, store, _ := testHandler(t, cfg)
	ownerPeer := pubHex(owner)
	if _, err := store.Bind(cfg, ownerPeer, "secret"); err != nil {
		t.Fatalf("bind: %v", err)
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := postSigned(t, srv.URL+"/api/v1/package-requests", provider, PackageRequest{
		RequestID:            "req_1",
		PackageHash:          "sha256:abc",
		RequesterPeerID:      "peer_requester_device",
		RequesterOwnerPeerID: ownerPeer,
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("owner request status=%d body=%s", resp.StatusCode, readBody(t, resp))
	}
	_ = resp.Body.Close()
	resp = postSigned(t, srv.URL+"/api/v1/package-requests/req_1/offers", provider, PackageOffer{
		RequestID:      "req_1",
		PackageHash:    "sha256:abc",
		ProviderPeerID: "peer_provider",
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("owner offer status=%d body=%s", resp.StatusCode, readBody(t, resp))
	}
	_ = resp.Body.Close()
}

func testConfig(t *testing.T) Config {
	t.Helper()
	return Config{
		StatePath:         filepath.Join(t.TempDir(), "state.json"),
		NodeID:            "dht_test",
		InitPassword:      "secret",
		AllowReinitialize: true,
		ManagerBaseURL:    "https://experience.test",
		PublicNetwork:     "udp",
		PublicAPIBaseURL:  "http://203.0.113.10:8091",
		PublicHost:        "203.0.113.10",
		PublicPort:        41001,
		OwnerKind:         OwnerKindUser,
		RelayPolicy:       RelayPolicyPublic,
		RelayCapacity:     10,
		PeerTTLSeconds:    60,
		Capabilities: map[string]bool{
			"relay":      true,
			"hole_punch": true,
		},
	}
}

func testStore(t *testing.T, cfg Config) *StateStore {
	t.Helper()
	store := NewStateStore(cfg.StatePath)
	if err := store.Init(cfg.NodeID); err != nil {
		t.Fatalf("init store: %v", err)
	}
	return store
}

func testHandler(t *testing.T, cfg Config) (*Handler, *StateStore, *fakeManager) {
	t.Helper()
	store := testStore(t, cfg)
	manager := &fakeManager{}
	return NewHandler(cfg, store, manager), store, manager
}

func freeUDPAddr(t *testing.T) string {
	t.Helper()
	conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		t.Fatalf("listen udp: %v", err)
	}
	addr := conn.LocalAddr().String()
	if err := conn.Close(); err != nil {
		t.Fatalf("close udp: %v", err)
	}
	return addr
}

func testKey(t *testing.T) *secp.PrivateKey {
	t.Helper()
	priv, err := secp.GeneratePrivateKey()
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	return priv
}

func pubHex(priv *secp.PrivateKey) string {
	return hex.EncodeToString(priv.PubKey().SerializeUncompressed())
}

func postSigned(t *testing.T, url string, priv *secp.PrivateKey, payload any) *http.Response {
	t.Helper()
	req := signRequest(t, priv, payload)
	body, _ := json.Marshal(req)
	resp, err := http.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func createRelaySession(t *testing.T, baseURL string, priv *secp.PrivateKey, payload RelaySessionRequest) RelaySession {
	t.Helper()
	resp := postSigned(t, baseURL+"/api/v1/relay/sessions", priv, payload)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		buf := new(bytes.Buffer)
		_, _ = buf.ReadFrom(resp.Body)
		t.Fatalf("create relay session status=%d body=%s", resp.StatusCode, buf.String())
	}
	var session RelaySession
	if err := json.NewDecoder(resp.Body).Decode(&session); err != nil {
		t.Fatal(err)
	}
	return session
}

func createHolePunchSession(t *testing.T, baseURL string, priv *secp.PrivateKey, payload HolePunchSessionRequest) HolePunchSession {
	t.Helper()
	resp := postSigned(t, baseURL+"/api/v1/hole-punch/sessions", priv, payload)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		buf := new(bytes.Buffer)
		_, _ = buf.ReadFrom(resp.Body)
		t.Fatalf("create hole punch session status=%d body=%s", resp.StatusCode, buf.String())
	}
	var session HolePunchSession
	if err := json.NewDecoder(resp.Body).Decode(&session); err != nil {
		t.Fatal(err)
	}
	return session
}

func fetchProviders(t *testing.T, baseURL, packageHash string) []ProviderRecord {
	t.Helper()
	resp, err := http.Get(baseURL + "/api/v1/providers?package_hash=" + url.QueryEscape(packageHash))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("providers status=%d body=%s", resp.StatusCode, readBody(t, resp))
	}
	var out struct {
		Items []ProviderRecord `json:"items"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	return out.Items
}

func testServerNode(t *testing.T, nodeID, baseURL string) NodeDescriptor {
	t.Helper()
	parsed, err := url.Parse(baseURL)
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(parsed.Port())
	if err != nil {
		t.Fatal(err)
	}
	return NodeDescriptor{
		NodeID: nodeID,
		Endpoints: []Endpoint{{
			Network: parsed.Scheme,
			Host:    parsed.Hostname(),
			Port:    port,
		}},
		HealthStatus: HealthHealthy,
		ExpiresAt:    time.Now().UTC().Add(time.Minute).Format(time.RFC3339),
	}
}

func signRequest(t *testing.T, priv *secp.PrivateKey, payload any) SignedRequest {
	t.Helper()
	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	ts := time.Now().UTC().Unix()
	nonce := strconv.FormatInt(time.Now().UnixNano(), 16) + "-" + strconv.FormatUint(atomic.AddUint64(&signedRequestNonceCounter, 1), 16)
	pub := pubHex(priv)
	message := string(payloadBytes) + "\n" + pub + "\n" + strconv.FormatInt(ts, 10) + "\n" + nonce
	sig := ecdsa.Sign(priv, sha256Bytes([]byte(message)))
	rScalar := sig.R()
	sScalar := sig.S()
	r := rScalar.Bytes()
	s := sScalar.Bytes()
	out := make([]byte, signatureLength)
	copy(out[:32], r[:])
	copy(out[32:], s[:])
	return SignedRequest{
		Payload:      string(payloadBytes),
		PubkeyHex:    pub,
		SignatureHex: hex.EncodeToString(out),
		Timestamp:    ts,
		Nonce:        nonce,
	}
}

func sha256Bytes(data []byte) []byte {
	sum := sha256.Sum256(data)
	return sum[:]
}

func mustRequest(t *testing.T, method, url string, body []byte) *http.Request {
	t.Helper()
	req, err := http.NewRequest(method, url, bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	return req
}

func readBody(t *testing.T, resp *http.Response) string {
	t.Helper()
	defer resp.Body.Close()
	buf := new(bytes.Buffer)
	_, _ = buf.ReadFrom(resp.Body)
	return buf.String()
}

func containsString(items []string, expected string) bool {
	for _, item := range items {
		if item == expected {
			return true
		}
	}
	return false
}
