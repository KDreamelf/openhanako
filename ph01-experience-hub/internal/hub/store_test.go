package hub

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
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
	})
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
		Store:      store,
		AdminToken: "test-token",
	}
	srv := httptest.NewServer(handler)
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/v1/experiences", bytes.NewReader(zipData))
	req.Header.Set("Authorization", "Bearer test-token")
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
