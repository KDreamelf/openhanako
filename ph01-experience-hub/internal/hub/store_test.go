package hub

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"ph01-experience-hub/internal/governance"
)

func TestStoreImportReadReviewAndVFS(t *testing.T) {
	root := t.TempDir()
	src := sampleRawDumpDir(t)
	zipData, err := PackExperiencePackage(src, nil, nil)
	if err != nil {
		t.Fatalf("pack: %v", err)
	}

	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	entry, err := store.ImportZip(zipData, StatusInbox)
	if err != nil {
		t.Fatalf("import: %v", err)
	}
	if entry.ExperienceID != "exp_test_001" {
		t.Fatalf("unexpected id: %s", entry.ExperienceID)
	}
	if entry.Status != StatusInbox {
		t.Fatalf("unexpected status: %s", entry.Status)
	}
	if entry.RawPath != "content/raw/conversation.md" {
		t.Fatalf("unexpected raw path: %s", entry.RawPath)
	}

	data, _, err := store.ReadFile("exp_test_001", "")
	if err != nil {
		t.Fatalf("read default raw record: %v", err)
	}
	if !strings.Contains(string(data), "工具调用") || !strings.Contains(string(data), "原始记录") {
		t.Fatalf("raw conversation should be preserved, got %s", data)
	}

	reviewed, err := store.Review("exp_test_001", ReviewRequest{
		Status: StatusNetwork,
		Reason: "测试通过",
	}, nil)
	if err != nil {
		t.Fatalf("review: %v", err)
	}
	if reviewed.Status != StatusNetwork {
		t.Fatalf("unexpected reviewed status: %s", reviewed.Status)
	}
	if _, err := os.Stat(filepath.Join(root, StatusNetwork, "exp_test_001", "content", "raw", "conversation.md")); err != nil {
		t.Fatalf("network raw record missing: %v", err)
	}

	vfs, err := store.VirtualIndex()
	if err != nil {
		t.Fatalf("vfs: %v", err)
	}
	if !strings.Contains(vfs, "/experience/network") || !strings.Contains(vfs, "exp_test_001") {
		t.Fatalf("unexpected vfs index: %s", vfs)
	}

	results, err := store.SearchContent(SearchFilter{Query: "无损保存"})
	if err != nil {
		t.Fatalf("search content: %v", err)
	}
	if len(results) != 1 {
		t.Fatalf("expected one search result, got %d", len(results))
	}
	if results[0].ExperienceID != "exp_test_001" || results[0].Path != "content/raw/conversation.md" {
		t.Fatalf("unexpected search result: %+v", results[0])
	}
}

func TestReviewChainPlanAndCandidateArchive(t *testing.T) {
	root := t.TempDir()
	ratings := []byte(`{"schema_version":"ph01.experience.ratings.v1","type":"root","score":1}` + "\n")
	zipData, err := PackExperiencePackage(sampleRawDumpDir(t), nil, ratings)
	if err != nil {
		t.Fatalf("pack: %v", err)
	}
	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	if _, err := store.ImportZip(zipData, StatusNetwork); err != nil {
		t.Fatalf("import: %v", err)
	}

	chain, err := store.ReviewChain("exp_test_001")
	if err != nil {
		t.Fatalf("review chain: %v", err)
	}
	if chain.ReviewChainLength != 1 || chain.ReviewChainDigest == "" {
		t.Fatalf("unexpected chain: %+v", chain)
	}

	plan, err := store.ReviewChainRefreshPlan(time.Date(2026, 5, 14, 1, 2, 0, 0, time.UTC), 1)
	if err != nil {
		t.Fatalf("plan: %v", err)
	}
	if plan.NetworkPackageCount != 1 || len(plan.Items) != 1 || plan.Items[0].ExperienceID != "exp_test_001" {
		t.Fatalf("unexpected plan: %+v", plan)
	}

	longer := chain
	longer.ReviewChain = append(longer.ReviewChain, map[string]any{"type": "review", "score": 2})
	stored, err := store.AcceptReviewChainCandidate(longer)
	if err != nil {
		t.Fatalf("candidate: %v", err)
	}
	if stored.ReviewChainLength != 2 {
		t.Fatalf("longer candidate not stored: %+v", stored)
	}
	stored, err = store.AcceptReviewChainCandidate(chain)
	if err != nil {
		t.Fatalf("short candidate: %v", err)
	}
	if stored.ReviewChainLength != 2 {
		t.Fatalf("shorter candidate should not replace longer one: %+v", stored)
	}
}

func TestHandlerReviewChainEndpoints(t *testing.T) {
	root := t.TempDir()
	ratings := []byte(`{"schema_version":"ph01.experience.ratings.v1","type":"root","score":1}` + "\n")
	zipData, err := PackExperiencePackage(sampleRawDumpDir(t), nil, ratings)
	if err != nil {
		t.Fatalf("pack: %v", err)
	}
	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	if _, err := store.ImportZip(zipData, StatusNetwork); err != nil {
		t.Fatalf("import: %v", err)
	}
	srv := httptest.NewServer(&Handler{Store: store, AdminToken: "test-token"})
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/api/v1/experiences/exp_test_001/review-chain", nil)
	req.Header.Set("Authorization", "Bearer test-token")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var chain ExperienceReviewChain
	if err := json.NewDecoder(resp.Body).Decode(&chain); err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK || chain.ReviewChainLength != 1 {
		t.Fatalf("unexpected review chain response status=%d chain=%+v", resp.StatusCode, chain)
	}

	resp, err = http.Get(srv.URL + "/api/v1/dht/review-chain/plan?limit=1")
	if err != nil {
		t.Fatal(err)
	}
	var plan ReviewChainRefreshPlan
	if err := json.NewDecoder(resp.Body).Decode(&plan); err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK || len(plan.Items) != 1 {
		t.Fatalf("unexpected plan response status=%d plan=%+v", resp.StatusCode, plan)
	}

	resp, err = http.Get(srv.URL + "/api/v1/dht/experience-demands/resolve?request_id=dem_1&q=" + url.QueryEscape("原始经验"))
	if err != nil {
		t.Fatal(err)
	}
	var resolved struct {
		Items []ExperienceDemandOfferRecord `json:"items"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&resolved); err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK || len(resolved.Items) != 1 {
		t.Fatalf("unexpected demand resolve status=%d items=%+v", resp.StatusCode, resolved.Items)
	}
	if resolved.Items[0].RequestID != "dem_1" || resolved.Items[0].ReviewChainLength != 1 ||
		!stringSliceContains(resolved.Items[0].AvailableTransports, "manager_seed") {
		t.Fatalf("unexpected manager fallback offer: %+v", resolved.Items[0])
	}

	resp, err = http.Get(srv.URL + "/api/v1/experiences/exp_test_001/package")
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("public reviewed package should be downloadable, status=%d", resp.StatusCode)
	}
	_ = resp.Body.Close()

	chain.ReviewChain = append(chain.ReviewChain, map[string]any{"type": "review", "score": 2})
	body, _ := json.Marshal(chain)
	resp, err = http.Post(srv.URL+"/api/v1/dht/review-chain/candidates", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	var stored ExperienceReviewChain
	if err := json.NewDecoder(resp.Body).Decode(&stored); err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK || stored.ReviewChainLength != 2 {
		t.Fatalf("unexpected candidate response status=%d chain=%+v", resp.StatusCode, stored)
	}
}

func TestReviewChainSchedulerPublishesDemandAndArchivesOffer(t *testing.T) {
	root := t.TempDir()
	ratings := []byte(`{"schema_version":"ph01.experience.ratings.v1","type":"root","score":1}` + "\n")
	zipData, err := PackExperiencePackage(sampleRawDumpDir(t), nil, ratings)
	if err != nil {
		t.Fatalf("pack: %v", err)
	}
	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	if _, err := store.ImportZip(zipData, StatusNetwork); err != nil {
		t.Fatalf("import: %v", err)
	}

	var postedDemand ExperienceDemand
	dhtSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/api/v1/experience-demands":
			var signed SignedRequest
			if err := json.NewDecoder(r.Body).Decode(&signed); err != nil {
				t.Fatalf("decode signed demand: %v", err)
			}
			if err := verifySignedRequest(signed, time.Now().UTC()); err != nil {
				t.Fatalf("verify signed demand: %v", err)
			}
			if err := json.Unmarshal([]byte(signed.Payload), &postedDemand); err != nil {
				t.Fatalf("decode demand payload: %v", err)
			}
			_ = json.NewEncoder(w).Encode(postedDemand)
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/api/v1/experience-demands/") &&
			strings.HasSuffix(r.URL.Path, "/offers"):
			if r.URL.Query().Get("include_review_chain") != "false" {
				t.Fatalf("scheduler should request compact offers, got %s", r.URL.RawQuery)
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"items": []ExperienceDemandOfferRecord{{
					ExperienceDemandOffer: ExperienceDemandOffer{
						SchemaVersion:     DemandOfferSchemaVersion,
						RequestID:         postedDemand.RequestID,
						ExperienceID:      "exp_test_001",
						PackageHash:       "sha256:pkg",
						ReviewChainDigest: "sha256:chain",
						ReviewChainLength: 2,
						ReviewChainRef: &ReviewChainRef{
							Digest: "sha256:chain",
							Length: 2,
							URL:    "/api/v1/review-chains/chain",
						},
						ProviderPeerID: "peer_provider",
					},
					OfferedAt: time.Now().UTC().Format(time.RFC3339),
				}},
			})
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/review-chains/chain":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"review_chain": []map[string]any{
					{"type": "root", "score": 1},
					{"type": "review", "score": 2},
				},
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer dhtSrv.Close()
	dhtURL, err := url.Parse(dhtSrv.URL)
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(dhtURL.Port())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.UpsertDHTNode(DHTNode{
		SchemaVersion: DHTNodeSchemaVersion,
		NodeID:        "dht_test_01",
		OwnerKind:     DHTOwnerKindUser,
		Endpoints: []DHTEndpoint{{
			Network: "http",
			Host:    dhtURL.Hostname(),
			Port:    port,
		}},
		Capabilities:      map[string]bool{"relay": true},
		RelayPolicy:       DHTRelayPolicyPublic,
		Load:              DHTLoad{RelayCapacity: 10},
		HealthStatus:      DHTHealthHealthy,
		LastHealthCheckAt: time.Now().UTC().Format(time.RFC3339),
		ExpiresAt:         time.Now().UTC().Add(time.Hour).Format(time.RFC3339),
	}); err != nil {
		t.Fatalf("upsert dht: %v", err)
	}

	scheduler := &ReviewChainScheduler{
		Store:      store,
		Governance: testGovernanceService(t),
		Config: ReviewChainSchedulerConfig{
			Limit:          1,
			DHTFanoutLimit: 1,
		},
		Client: dhtSrv.Client(),
	}
	if err := scheduler.RunOnce(context.Background(), time.Now().UTC()); err != nil {
		t.Fatalf("run scheduler: %v", err)
	}
	if postedDemand.SchemaVersion != ExperienceDemandSchemaVersion ||
		postedDemand.RequestID == "" ||
		!strings.Contains(postedDemand.NaturalLanguageQuery, "评价链") {
		t.Fatalf("unexpected posted demand: %+v", postedDemand)
	}
	idx, err := store.readReviewChainCandidates()
	if err != nil {
		t.Fatalf("read candidates: %v", err)
	}
	if len(idx.Items) != 1 || idx.Items[0].ReviewChainLength != 2 {
		t.Fatalf("scheduler did not archive longer candidate: %+v", idx)
	}
}

func TestHandlerUploadListReadReview(t *testing.T) {
	root := t.TempDir()
	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	zipData, err := PackExperiencePackage(sampleRawDumpDir(t), nil, nil)
	if err != nil {
		t.Fatalf("pack: %v", err)
	}
	handler := &Handler{
		Store:        store,
		AdminToken:   "test-token",
		DelegatedPow: fakeDelegatedPow{},
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/v1/experiences", bytes.NewReader(zipData))
	req.Header.Set("Authorization", "Bearer test-token")
	addPackagePowHeaders(t, req, zipData)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("upload status=%d", resp.StatusCode)
	}
	resp.Body.Close()

	req, _ = http.NewRequest(http.MethodGet, srv.URL+"/api/v1/experiences?status=inbox", nil)
	req.Header.Set("Authorization", "Bearer test-token")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var list struct {
		Items []IndexEntry `json:"items"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&list); err != nil {
		t.Fatal(err)
	}
	if len(list.Items) != 1 {
		t.Fatalf("expected one item, got %d", len(list.Items))
	}

	reviewBody, _ := json.Marshal(ReviewRequest{Status: StatusNetwork, Reason: "ok"})
	req, _ = http.NewRequest(http.MethodPost, srv.URL+"/api/v1/experiences/exp_test_001/review", bytes.NewReader(reviewBody))
	req.Header.Set("Authorization", "Bearer test-token")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("review status=%d", resp.StatusCode)
	}
	resp.Body.Close()

	req, _ = http.NewRequest(http.MethodGet, srv.URL+"/api/v1/experiences/exp_test_001/file", nil)
	req.Header.Set("Authorization", "Bearer test-token")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	buf := new(bytes.Buffer)
	buf.ReadFrom(resp.Body)
	if !strings.Contains(buf.String(), "原始记录") {
		t.Fatalf("unexpected raw record: %s", buf.String())
	}

	req, _ = http.NewRequest(http.MethodGet, srv.URL+"/api/v1/search?q=%E5%B7%A5%E5%85%B7%E8%B0%83%E7%94%A8", nil)
	req.Header.Set("Authorization", "Bearer test-token")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var search struct {
		Items []SearchResult `json:"items"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&search); err != nil {
		t.Fatal(err)
	}
	if len(search.Items) == 0 {
		t.Fatalf("expected search results")
	}
}

func TestHandlerUploadRejectsMissingPackagePow(t *testing.T) {
	root := t.TempDir()
	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	zipData, err := PackDir(sampleRawDumpDir(t))
	if err != nil {
		t.Fatalf("pack: %v", err)
	}
	handler := &Handler{
		Store:        store,
		AdminToken:   "test-token",
		DelegatedPow: fakeDelegatedPow{},
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/v1/experiences", bytes.NewReader(zipData))
	req.Header.Set("Authorization", "Bearer test-token")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("missing pow status=%d", resp.StatusCode)
	}
	var out ErrorResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if out.Error != "experience_pow_required" {
		t.Fatalf("unexpected error response: %+v", out)
	}
}

func TestHandlerCreatesPackagePowChallengeThroughAuthCenter(t *testing.T) {
	root := t.TempDir()
	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	handler := &Handler{
		Store:        store,
		DelegatedPow: fakeDelegatedPow{},
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	packageHash := strings.Repeat("a", 64)
	pubkeyHash, err := dhtPubkeyHash(governancePublicKeyOne)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(ExperiencePackagePowChallengeRequest{
		ExperienceID:  "exp_pow_test",
		PackageSHA256: packageHash,
		PubkeyHash:    pubkeyHash,
	})
	resp, err := http.Post(srv.URL+"/api/v1/experiences/package-pow/challenge", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		buf := new(bytes.Buffer)
		buf.ReadFrom(resp.Body)
		t.Fatalf("challenge status=%d body=%s", resp.StatusCode, buf.String())
	}
	var out ExperiencePackagePowChallengeResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if out.ChallengeID != "pow_test" {
		t.Fatalf("unexpected challenge response: %+v", out)
	}
}

func TestPackagePowChallengeRejectsDuplicateBeforeAuthCenter(t *testing.T) {
	root := t.TempDir()
	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	zipData := signedExperiencePackage(t, sampleRawDumpDir(t))
	if _, err := store.ImportZip(zipData, StatusInbox); err != nil {
		t.Fatalf("seed inbox: %v", err)
	}
	handler := &Handler{
		Store:        store,
		DelegatedPow: fakeDelegatedPow{err: fmt.Errorf("delegated pow should not be called")},
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	sum := sha256.Sum256(zipData)
	pubkeyHash, err := dhtPubkeyHash(governancePublicKeyOne)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(ExperiencePackagePowChallengeRequest{
		ExperienceID:  "exp_test_001",
		PackageSHA256: fmt.Sprintf("%x", sum[:]),
		PubkeyHash:    pubkeyHash,
	})
	resp, err := http.Post(srv.URL+"/api/v1/experiences/package-pow/challenge", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusConflict {
		buf := new(bytes.Buffer)
		buf.ReadFrom(resp.Body)
		t.Fatalf("duplicate challenge status=%d body=%s", resp.StatusCode, buf.String())
	}
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if out["error"] != "experience_already_submitted" ||
		out["experience_id"] != "exp_test_001" ||
		out["status"] != StatusInbox {
		t.Fatalf("unexpected duplicate challenge response: %+v", out)
	}
}

func TestHandlerUploadChecksPackagePowBeforeAuthCenterBypass(t *testing.T) {
	root := t.TempDir()
	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	zipData, err := PackDir(sampleRawDumpDir(t))
	if err != nil {
		t.Fatalf("pack: %v", err)
	}
	handler := &Handler{
		Store:      store,
		AdminToken: "test-token",
		AdminVerifier: fakeAdminVerifier{
			err: fmt.Errorf("auth-center admin verifier should not run before package pow"),
		},
		DelegatedPow: fakeDelegatedPow{},
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/v1/experiences", bytes.NewReader(zipData))
	req.Header.Set("Authorization", "Bearer auth-center-admin-session")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("missing pow should be checked before auth-center admin, status=%d", resp.StatusCode)
	}
	var out ErrorResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if out.Error != "experience_pow_required" {
		t.Fatalf("unexpected error response: %+v", out)
	}
}

func TestHandlerUploadRejectsUnverifiedPackagePow(t *testing.T) {
	root := t.TempDir()
	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	zipData, err := PackDir(sampleRawDumpDir(t))
	if err != nil {
		t.Fatalf("pack: %v", err)
	}
	handler := &Handler{
		Store:      store,
		AdminToken: "test-token",
		DelegatedPow: fakeDelegatedPow{
			explicitVerified: true,
			verified:         false,
		},
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/v1/experiences", bytes.NewReader(zipData))
	req.Header.Set("Authorization", "Bearer test-token")
	addPackagePowHeaders(t, req, zipData)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("unverified pow status=%d", resp.StatusCode)
	}
	var out ErrorResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if out.Error != "experience_pow_incomplete" {
		t.Fatalf("unexpected error response: %+v", out)
	}
}

func TestSignedUserUploadEntersInbox(t *testing.T) {
	root := t.TempDir()
	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	handler := &Handler{
		Store:        store,
		AdminToken:   "hub-admin-token",
		DelegatedPow: fakeDelegatedPow{},
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	body := signedUploadBody(t, signedExperiencePackage(t, sampleRawDumpDir(t)), nil)
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/v1/experiences?status=network", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		buf := new(bytes.Buffer)
		buf.ReadFrom(resp.Body)
		t.Fatalf("signed upload status=%d body=%s", resp.StatusCode, buf.String())
	}
	var entry IndexEntry
	if err := json.NewDecoder(resp.Body).Decode(&entry); err != nil {
		t.Fatal(err)
	}
	if entry.Status != StatusInbox {
		t.Fatalf("signed user upload must enter inbox, got %+v", entry)
	}
	if _, err := os.Stat(filepath.Join(root, StatusInbox, "exp_test_001", "content", "raw", "conversation.md")); err != nil {
		t.Fatalf("inbox content missing: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, StatusNetwork, "exp_test_001")); !os.IsNotExist(err) {
		t.Fatalf("signed user upload must not enter network directly")
	}
}

func TestSignedUserUploadRejectsInvalidSignature(t *testing.T) {
	root := t.TempDir()
	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	handler := &Handler{
		Store:        store,
		AdminToken:   "hub-admin-token",
		DelegatedPow: fakeDelegatedPow{},
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	body := signedUploadBody(t, signedExperiencePackage(t, sampleRawDumpDir(t)), func(req *SignedRequest) {
		req.SignatureHex = strings.Repeat("0", 128)
	})
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/v1/experiences", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("invalid signed upload status=%d", resp.StatusCode)
	}
	var out ErrorResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if out.Error != "invalid_signature" {
		t.Fatalf("unexpected error response: %+v", out)
	}
}

func TestDuplicateSignedUploadReturnsConflictWithExistingStatus(t *testing.T) {
	root := t.TempDir()
	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	handler := &Handler{
		Store:        store,
		AdminToken:   "hub-admin-token",
		DelegatedPow: fakeDelegatedPow{},
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	body := signedUploadBody(t, signedExperiencePackage(t, sampleRawDumpDir(t)), nil)
	for i := 0; i < 2; i++ {
		req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/v1/experiences", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		if i == 0 {
			if resp.StatusCode != http.StatusOK {
				t.Fatalf("first upload status=%d", resp.StatusCode)
			}
			continue
		}
		if resp.StatusCode != http.StatusConflict {
			t.Fatalf("duplicate upload status=%d", resp.StatusCode)
		}
		var out map[string]any
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			t.Fatal(err)
		}
		if out["error"] != "experience_already_submitted" ||
			out["experience_id"] != "exp_test_001" ||
			out["status"] != StatusInbox ||
			out["already_submitted"] != true {
			t.Fatalf("unexpected duplicate response: %+v", out)
		}
	}
}

func TestHandlerReviewWritesAndReturnsReviewMaterials(t *testing.T) {
	root := t.TempDir()
	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	rawDir := sampleRawDumpDir(t)
	rawPackage, err := PackDir(rawDir)
	if err != nil {
		t.Fatalf("pack raw: %v", err)
	}
	sum := sha256.Sum256(rawPackage)
	publisherSig := signPublisherForTest(t, "exp_test_001", fmt.Sprintf("%x", sum[:]), governancePublicKeyOne, "2026-05-09T00:00:00Z")
	publisherJSON, _ := json.Marshal(map[string]string{
		"schema_version":         "ph01.experience.publisher.v1",
		"experience_id":          "exp_test_001",
		"package_hash_algorithm": "sha256",
		"package_hash":           fmt.Sprintf("%x", sum[:]),
		"publisher_pubkey":       governancePublicKeyOne,
		"signature_algorithm":    governance.Algorithm,
		"signature":              publisherSig,
		"created_at":             "2026-05-09T00:00:00Z",
	})
	zipData, err := PackExperiencePackage(rawDir, publisherJSON, nil)
	if err != nil {
		t.Fatalf("pack: %v", err)
	}
	cert := governance.SignedMasterCertificate{
		Certificate: governance.MasterCertificatePayload{
			CertificateID:   "test-master",
			Role:            "experience_review_master",
			IssuerRootKeyID: "test-root",
			Algorithm:       governance.Algorithm,
			PublicKeyHex:    governancePublicKeyOne,
		},
		SignatureAlgorithm: governance.Algorithm,
	}
	master, err := governance.LoadMasterKey(governancePrivateKeyOne, cert)
	if err != nil {
		t.Fatalf("load master key: %v", err)
	}
	handler := &Handler{
		Store:        store,
		AdminToken:   "test-token",
		DelegatedPow: fakeDelegatedPow{},
		Governance: &governance.Service{
			Master:               master,
			MasterCertificateRaw: json.RawMessage(`{"certificate":{"certificate_id":"test-master"}}`),
		},
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/v1/experiences", bytes.NewReader(zipData))
	req.Header.Set("Authorization", "Bearer test-token")
	addPackagePowHeaders(t, req, zipData)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("upload status=%d", resp.StatusCode)
	}

	reviewBody, _ := json.Marshal(ReviewRequest{Status: StatusNetwork, Reason: "ok"})
	req, _ = http.NewRequest(http.MethodPost, srv.URL+"/api/v1/experiences/exp_test_001/review", bytes.NewReader(reviewBody))
	req.Header.Set("Authorization", "Bearer test-token")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("review status=%d", resp.StatusCode)
	}

	req, _ = http.NewRequest(http.MethodGet, srv.URL+"/api/v1/experiences/exp_test_001/review-materials", nil)
	req.Header.Set("Authorization", "Bearer test-token")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var materials governance.ReviewMaterials
	if err := json.NewDecoder(resp.Body).Decode(&materials); err != nil {
		t.Fatal(err)
	}
	if materials.ManagerReviewSignature == "" {
		t.Fatalf("missing review signature: %+v", materials)
	}

	req, _ = http.NewRequest(http.MethodGet, srv.URL+"/api/v1/experiences/exp_test_001/package", nil)
	req.Header.Set("Authorization", "Bearer test-token")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	buf := new(bytes.Buffer)
	buf.ReadFrom(resp.Body)
	outer, err := zip.NewReader(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
	if err != nil {
		t.Fatal(err)
	}
	foundReviewMaterials := false
	for _, file := range outer.File {
		if file.Name == "review-materials.json" {
			foundReviewMaterials = true
		}
	}
	if !foundReviewMaterials {
		t.Fatalf("reviewed package should include review-materials.json")
	}
}

func TestTrustedAdminUploadBecomesNetworkWithAuditMarker(t *testing.T) {
	root := t.TempDir()
	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	zipData := signedExperiencePackage(t, sampleRawDumpDir(t))
	cert := governance.SignedMasterCertificate{
		Certificate: governance.MasterCertificatePayload{
			CertificateID:   "test-master",
			Role:            "experience_review_master",
			IssuerRootKeyID: "test-root",
			Algorithm:       governance.Algorithm,
			PublicKeyHex:    governancePublicKeyOne,
		},
		SignatureAlgorithm: governance.Algorithm,
	}
	master, err := governance.LoadMasterKey(governancePrivateKeyOne, cert)
	if err != nil {
		t.Fatalf("load master key: %v", err)
	}
	handler := &Handler{
		Store:        store,
		AdminToken:   "hub-admin-token",
		Review:       ReviewConfig{TrustAdminUploads: true},
		AuthCenter:   AuthCenterConfig{BaseURL: "https://auth.test"},
		DelegatedPow: fakeDelegatedPow{},
		AdminVerifier: fakeAdminVerifier{
			admin: AuthCenterAdmin{ID: 7, Username: "admin_alice", Role: "admin"},
		},
		Governance: &governance.Service{
			Master:               master,
			MasterCertificateRaw: json.RawMessage(`{"certificate":{"certificate_id":"test-master"}}`),
		},
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/v1/experiences", bytes.NewReader(zipData))
	req.Header.Set("Authorization", "Bearer auth-center-admin-session")
	addPackagePowHeaders(t, req, zipData)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("trusted upload status=%d", resp.StatusCode)
	}
	var entry IndexEntry
	if err := json.NewDecoder(resp.Body).Decode(&entry); err != nil {
		t.Fatal(err)
	}
	if entry.Status != StatusNetwork {
		t.Fatalf("trusted admin upload should enter network, got %+v", entry)
	}
	reviewFile := filepath.Join(root, StatusNetwork, "exp_test_001", "review", "local-review.json")
	reviewRaw, err := os.ReadFile(reviewFile)
	if err != nil {
		t.Fatalf("read review audit: %v", err)
	}
	if !strings.Contains(string(reviewRaw), "trusted_admin_upload") ||
		!strings.Contains(string(reviewRaw), "admin_alice") {
		t.Fatalf("trusted admin audit marker missing: %s", reviewRaw)
	}
	if _, err := os.Stat(filepath.Join(root, StatusNetwork, "exp_test_001", "review", "review-materials.json")); err != nil {
		t.Fatalf("review materials missing: %v", err)
	}
}

func TestSignedAdminUploadUsesAuthCenterPubkeyStatusForBypass(t *testing.T) {
	root := t.TempDir()
	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	zipData := signedExperiencePackage(t, sampleRawDumpDir(t))
	pubkeyHash, err := dhtPubkeyHash(governancePublicKeyOne)
	if err != nil {
		t.Fatalf("hash pubkey: %v", err)
	}
	authSrv := authCenterPubkeyStatusServer(t, []AuthCenterPubkeyStatus{{
		Valid:       true,
		UserID:      1,
		Username:    "root",
		Role:        "root",
		IsAdmin:     true,
		PubkeyHash:  pubkeyHash,
		PowVerified: true,
	}})
	defer authSrv.Close()
	handler := &Handler{
		Store:        store,
		AdminToken:   "hub-admin-token",
		Review:       ReviewConfig{TrustAdminUploads: true},
		AuthCenter:   AuthCenterConfig{BaseURL: authSrv.URL},
		DelegatedPow: fakeDelegatedPow{},
		Governance:   testGovernanceService(t),
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	body := signedUploadBody(t, zipData, nil)
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/v1/experiences", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		buf := new(bytes.Buffer)
		buf.ReadFrom(resp.Body)
		t.Fatalf("signed admin upload status=%d body=%s", resp.StatusCode, buf.String())
	}
	var entry IndexEntry
	if err := json.NewDecoder(resp.Body).Decode(&entry); err != nil {
		t.Fatal(err)
	}
	if entry.Status != StatusNetwork {
		t.Fatalf("signed root upload should enter network, got %+v", entry)
	}
	reviewRaw, err := os.ReadFile(filepath.Join(root, StatusNetwork, "exp_test_001", "review", "local-review.json"))
	if err != nil {
		t.Fatalf("read review audit: %v", err)
	}
	if !strings.Contains(string(reviewRaw), "trusted_admin_upload") ||
		!strings.Contains(string(reviewRaw), "root") {
		t.Fatalf("signed admin audit marker missing: %s", reviewRaw)
	}
}

func TestTrustedAdminUploadSwitchOffKeepsAuthCenterAdminInInbox(t *testing.T) {
	root := t.TempDir()
	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	handler := &Handler{
		Store:        store,
		AdminToken:   "hub-admin-token",
		Review:       ReviewConfig{TrustAdminUploads: false},
		DelegatedPow: fakeDelegatedPow{},
		AdminVerifier: fakeAdminVerifier{
			admin: AuthCenterAdmin{ID: 7, Username: "admin_alice", Role: "admin"},
		},
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	adminPackage := signedExperiencePackage(t, sampleRawDumpDir(t))
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/v1/experiences", bytes.NewReader(adminPackage))
	req.Header.Set("Authorization", "Bearer auth-center-admin-session")
	addPackagePowHeaders(t, req, adminPackage)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("upload status=%d", resp.StatusCode)
	}
	var entry IndexEntry
	if err := json.NewDecoder(resp.Body).Decode(&entry); err != nil {
		t.Fatal(err)
	}
	if entry.Status != StatusInbox {
		t.Fatalf("switch off should keep auth-center admin upload in inbox, got %+v", entry)
	}
}

func TestImportPreservesRawPackageBytes(t *testing.T) {
	root := t.TempDir()
	src := sampleRawDumpDir(t)
	rawPackage, err := PackDir(src)
	if err != nil {
		t.Fatalf("pack raw dir: %v", err)
	}
	outer, err := PackExperiencePackage(src, nil, nil)
	if err != nil {
		t.Fatalf("pack outer: %v", err)
	}
	info, err := ReadPackageInfo(outer)
	if err != nil {
		t.Fatalf("read package info: %v", err)
	}
	if !bytes.Equal(rawPackage, info.PackageData) {
		t.Fatalf("package.zip bytes must be preserved")
	}
	store := NewStore(root)
	if err := store.Init(); err != nil {
		t.Fatalf("init: %v", err)
	}
	if _, err := store.ImportZip(outer, StatusInbox); err != nil {
		t.Fatalf("import: %v", err)
	}
	stored, _, err := store.ReadFile("exp_test_001", "package.zip")
	if err != nil {
		t.Fatalf("read package.zip: %v", err)
	}
	if !bytes.Equal(rawPackage, stored) {
		t.Fatalf("stored package.zip must remain byte-for-byte identical")
	}
}

const governancePrivateKeyOne = "0000000000000000000000000000000000000000000000000000000000000001"
const governancePublicKeyOne = "0479be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8"

type fakeAdminVerifier struct {
	admin AuthCenterAdmin
	err   error
}

func (f fakeAdminVerifier) VerifyAdminSession(_ context.Context, _ AuthCenterConfig, _ string) (AuthCenterAdmin, error) {
	if f.err != nil {
		return AuthCenterAdmin{}, f.err
	}
	return f.admin, nil
}

func testGovernanceService(t *testing.T) *governance.Service {
	t.Helper()
	cert := governance.SignedMasterCertificate{
		Certificate: governance.MasterCertificatePayload{
			CertificateID:   "test-master",
			Role:            "experience_review_master",
			IssuerRootKeyID: "test-root",
			Algorithm:       governance.Algorithm,
			PublicKeyHex:    governancePublicKeyOne,
		},
		SignatureAlgorithm: governance.Algorithm,
	}
	key, err := governance.LoadMasterKey(governancePrivateKeyOne, cert)
	if err != nil {
		t.Fatalf("load governance key: %v", err)
	}
	raw, err := json.Marshal(cert)
	if err != nil {
		t.Fatalf("marshal governance cert: %v", err)
	}
	return &governance.Service{Master: key, MasterCertificateRaw: raw}
}

func authCenterPubkeyStatusServer(t *testing.T, items []AuthCenterPubkeyStatus) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/v1/auth/pubkeys/status" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(authCenterPubkeyStatusResponse{Items: items})
	}))
}

func signedExperiencePackage(t *testing.T, rawDir string) []byte {
	t.Helper()
	rawPackage, err := PackDir(rawDir)
	if err != nil {
		t.Fatalf("pack raw: %v", err)
	}
	sum := sha256.Sum256(rawPackage)
	createdAt := "2026-05-09T00:00:00Z"
	packageHash := fmt.Sprintf("%x", sum[:])
	publisherJSON, _ := json.Marshal(map[string]string{
		"schema_version":         "ph01.experience.publisher.v1",
		"experience_id":          "exp_test_001",
		"package_hash_algorithm": "sha256",
		"package_hash":           packageHash,
		"publisher_pubkey":       governancePublicKeyOne,
		"signature_algorithm":    governance.Algorithm,
		"signature":              signPublisherForTest(t, "exp_test_001", packageHash, governancePublicKeyOne, createdAt),
		"created_at":             createdAt,
	})
	zipData, err := PackExperiencePackage(rawDir, publisherJSON, nil)
	if err != nil {
		t.Fatalf("pack signed package: %v", err)
	}
	return zipData
}

func signedUploadBody(t *testing.T, zipData []byte, mutate func(*SignedRequest)) []byte {
	t.Helper()
	cert := governance.SignedMasterCertificate{
		Certificate: governance.MasterCertificatePayload{
			PublicKeyHex: governancePublicKeyOne,
		},
	}
	key, err := governance.LoadMasterKey(governancePrivateKeyOne, cert)
	if err != nil {
		t.Fatalf("load signed upload key: %v", err)
	}
	sum := sha256.Sum256(zipData)
	packageHash := fmt.Sprintf("%x", sum[:])
	pubkeyHash, err := dhtPubkeyHash(governancePublicKeyOne)
	if err != nil {
		t.Fatalf("hash signed upload pubkey: %v", err)
	}
	payload, err := json.Marshal(ExperienceUploadPayload{
		SchemaVersion: ExperienceUploadSchemaVersion,
		Filename:      "exp_test_001.hxp",
		PackageBase64: base64.StdEncoding.EncodeToString(zipData),
		PackageSHA256: packageHash,
		PackagePow: &ExperiencePackagePow{
			ChallengeID:   "pow_test",
			PackageSHA256: packageHash,
			PubkeyHash:    pubkeyHash,
		},
	})
	if err != nil {
		t.Fatalf("marshal signed upload payload: %v", err)
	}
	timestamp := time.Now().Unix()
	nonce := "0123456789abcdef"
	signed := fmt.Sprintf("%s\n%s\n%d\n%s", string(payload), governancePublicKeyOne, timestamp, nonce)
	signature, err := governance.Sign(key.PrivateKey, []byte(signed))
	if err != nil {
		t.Fatalf("sign upload request: %v", err)
	}
	req := SignedRequest{
		Payload:      string(payload),
		PubkeyHex:    governancePublicKeyOne,
		SignatureHex: signature,
		Timestamp:    timestamp,
		Nonce:        nonce,
	}
	if mutate != nil {
		mutate(&req)
	}
	body, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("marshal signed upload request: %v", err)
	}
	return body
}

type fakeDelegatedPow struct {
	verified         bool
	explicitVerified bool
	err              error
}

func (f fakeDelegatedPow) CreateDelegatedPowChallenge(_ context.Context, _ AuthCenterConfig, purpose, subjectHash, pubkeyHash string) (AuthCenterDelegatedPowChallenge, error) {
	if f.err != nil {
		return AuthCenterDelegatedPowChallenge{}, f.err
	}
	return AuthCenterDelegatedPowChallenge{
		ChallengeID: "pow_test",
		Purpose:     purpose,
		SubjectHash: subjectHash,
		PubkeyHash:  pubkeyHash,
		ExpiresAt:   time.Now().Add(10 * time.Minute).Unix(),
	}, nil
}

func (f fakeDelegatedPow) FetchDelegatedPowStatus(_ context.Context, _ AuthCenterConfig, challengeID, purpose, subjectHash, pubkeyHash string) (AuthCenterDelegatedPowStatus, error) {
	if f.err != nil {
		return AuthCenterDelegatedPowStatus{}, f.err
	}
	verified := true
	if f.explicitVerified {
		verified = f.verified
	}
	return AuthCenterDelegatedPowStatus{
		ChallengeID: challengeID,
		Purpose:     purpose,
		SubjectHash: subjectHash,
		PubkeyHash:  pubkeyHash,
		Verified:    verified,
		Algorithm:   "ph01.memory_pow.v1",
		Score:       24,
		VerifiedAt:  time.Now().Unix(),
		ExpiresAt:   time.Now().Add(10 * time.Minute).Unix(),
	}, nil
}

func addPackagePowHeaders(t *testing.T, req *http.Request, zipData []byte) {
	t.Helper()
	sum := sha256.Sum256(zipData)
	pubkeyHash, err := dhtPubkeyHash(governancePublicKeyOne)
	if err != nil {
		t.Fatalf("hash package pow pubkey: %v", err)
	}
	req.Header.Set("X-PH01-Experience-Pow-Challenge-Id", "pow_test")
	req.Header.Set("X-PH01-Experience-Pow-Package-SHA256", fmt.Sprintf("%x", sum[:]))
	req.Header.Set("X-PH01-Experience-Pow-Pubkey-Hash", pubkeyHash)
}

func signPublisherForTest(t *testing.T, experienceID, packageHash, pubkey, createdAt string) string {
	t.Helper()
	cert := governance.SignedMasterCertificate{
		Certificate: governance.MasterCertificatePayload{
			PublicKeyHex: pubkey,
		},
	}
	key, err := governance.LoadMasterKey(governancePrivateKeyOne, cert)
	if err != nil {
		t.Fatalf("load publisher key: %v", err)
	}
	payload := strings.Join([]string{
		"ph01.experience.publisher.v1",
		experienceID,
		packageHash,
		pubkey,
		createdAt,
	}, "\n")
	sig, err := governance.Sign(key.PrivateKey, []byte(payload))
	if err != nil {
		t.Fatalf("sign publisher: %v", err)
	}
	return sig
}

func sampleRawDumpDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	write := func(rel, body string) {
		t.Helper()
		path := filepath.Join(dir, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("metadata.json", `{
  "schema_version": "ph01.experience.v1",
  "experience_id": "exp_test_001",
  "title": "测试原始经验转储",
  "brief": "只用于索引，不替代原始记录",
  "keywords": ["test", "gpu"],
  "created_at": "2026-05-01T00:00:00Z"
}`)
	write("raw/conversation.md", "# 原始记录\n\n[用户] 这段内容要无损保存。\n[AI] 我会保留完整过程。\n[工具调用] exec_command: go test ./...\n")
	write("raw/events.md", "[2026-05-01 00:00:00] Codex: [工具调用] exec_command: go test ./...\n")
	write("tool-calls/run.txt", "ok\n")
	return dir
}

func stringSliceContains(items []string, expected string) bool {
	for _, item := range items {
		if item == expected {
			return true
		}
	}
	return false
}
