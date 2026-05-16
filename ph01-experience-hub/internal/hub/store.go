package hub

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
)

var (
	ErrInvalidID     = errors.New("invalid experience id")
	ErrNotFound      = errors.New("experience not found")
	ErrInvalidStatus = errors.New("invalid experience status")
	ErrInvalidQuery  = errors.New("invalid search query")
)

var idPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$`)

type Store struct {
	root string
	mu   sync.Mutex
}

func NewStore(root string) *Store {
	return &Store{root: root}
}

func (s *Store) Init() error {
	for _, dir := range []string{
		s.root,
		s.statusDir(StatusInbox),
		s.statusDir(StatusNetwork),
		s.statusDir(StatusRejected),
		s.statusDir(StatusCache),
		filepath.Join(s.root, "packages"),
	} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	if _, err := os.Stat(s.indexPath()); os.IsNotExist(err) {
		if err := s.writeIndex(Index{UpdatedAt: nowRFC3339(), Items: []IndexEntry{}}); err != nil {
			return err
		}
	}
	if err := s.initDHTIndex(); err != nil {
		return err
	}
	return s.initDHTTrustIndexes()
}

func (s *Store) ImportZip(zipData []byte, status string) (IndexEntry, error) {
	if status == "" {
		status = StatusInbox
	}
	if !validStatus(status) || status == StatusCache {
		return IndexEntry{}, ErrInvalidStatus
	}
	info, err := ReadPackageInfo(zipData)
	if err != nil {
		return IndexEntry{}, err
	}
	manifest := info.Manifest
	if !idPattern.MatchString(manifest.ExperienceID) {
		return IndexEntry{}, ErrInvalidID
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	idx, err := s.readIndex()
	if err != nil {
		return IndexEntry{}, err
	}
	if _, found := findEntry(idx.Items, manifest.ExperienceID); found {
		return IndexEntry{}, errors.New("duplicate experience id")
	}

	packagePath := s.packagePath(manifest.ExperienceID)
	if err := os.WriteFile(packagePath, zipData, 0o644); err != nil {
		return IndexEntry{}, err
	}
	itemDir := s.itemDir(status, manifest.ExperienceID)
	if err := os.RemoveAll(itemDir); err != nil {
		return IndexEntry{}, err
	}
	if err := ExtractZip(zipData, itemDir); err != nil {
		return IndexEntry{}, err
	}
	if err := ExtractZip(info.PackageData, filepath.Join(itemDir, "content")); err != nil {
		return IndexEntry{}, err
	}

	entry := IndexEntry{
		ExperienceID: manifest.ExperienceID,
		Title:        manifest.Title,
		Brief:        strings.TrimSpace(manifest.Brief),
		Keywords:     normalizeKeywords(manifest.Keywords),
		Status:       status,
		Path:         filepath.ToSlash(filepath.Join(status, manifest.ExperienceID)),
		PackagePath:  filepath.ToSlash(filepath.Join("packages", manifest.ExperienceID+".hxp")),
		RawPath:      info.RawPath,
		ContentHash:  manifest.ContentHash,
		CreatedAt:    manifest.CreatedAt,
		UpdatedAt:    nowRFC3339(),
	}
	idx.Items = append(idx.Items, entry)
	idx.UpdatedAt = nowRFC3339()
	if err := s.writeIndex(idx); err != nil {
		return IndexEntry{}, err
	}
	return entry, nil
}

func (s *Store) List(filter ListFilter) ([]IndexEntry, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	idx, err := s.readIndex()
	if err != nil {
		return nil, err
	}
	status := strings.TrimSpace(filter.Status)
	keyword := strings.ToLower(strings.TrimSpace(filter.Keyword))
	query := strings.ToLower(strings.TrimSpace(filter.Query))
	out := make([]IndexEntry, 0, len(idx.Items))
	for _, item := range idx.Items {
		if status != "" && item.Status != status {
			continue
		}
		if keyword != "" && !hasKeyword(item.Keywords, keyword) {
			continue
		}
		if query != "" && !strings.Contains(strings.ToLower(item.Title+" "+item.Brief+" "+strings.Join(item.Keywords, " ")), query) {
			continue
		}
		out = append(out, item)
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].UpdatedAt > out[j].UpdatedAt
	})
	return out, nil
}

func (s *Store) Get(id string) (IndexEntry, error) {
	if !idPattern.MatchString(id) {
		return IndexEntry{}, ErrInvalidID
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	idx, err := s.readIndex()
	if err != nil {
		return IndexEntry{}, err
	}
	item, found := findEntry(idx.Items, id)
	if !found {
		return IndexEntry{}, ErrNotFound
	}
	return item, nil
}

func (s *Store) SearchContent(filter SearchFilter) ([]SearchResult, error) {
	query := strings.TrimSpace(filter.Query)
	if query == "" {
		return nil, ErrInvalidQuery
	}
	limit := filter.Limit
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	status := strings.TrimSpace(filter.Status)
	if status != "" && !validStatus(status) {
		return nil, ErrInvalidStatus
	}

	s.mu.Lock()
	idx, err := s.readIndex()
	s.mu.Unlock()
	if err != nil {
		return nil, err
	}

	queryLower := strings.ToLower(query)
	results := make([]SearchResult, 0, limit)
	for _, item := range idx.Items {
		if status != "" && item.Status != status {
			continue
		}
		itemBase := filepath.Join(s.root, filepath.FromSlash(item.Path))
		contentRoot := filepath.Join(itemBase, "content")
		if err := filepath.WalkDir(contentRoot, func(path string, d os.DirEntry, walkErr error) error {
			if walkErr != nil {
				return nil
			}
			if len(results) >= limit {
				return filepath.SkipAll
			}
			if d.IsDir() {
				return nil
			}
			if d.Type()&os.ModeSymlink != 0 || !searchableTextPath(path) {
				return nil
			}
			rel, err := filepath.Rel(itemBase, path)
			if err != nil {
				return nil
			}
			rel = filepath.ToSlash(rel)
			matches, err := searchFile(path, queryLower, item, rel, limit-len(results))
			if err != nil {
				return nil
			}
			results = append(results, matches...)
			return nil
		}); err != nil {
			return nil, err
		}
		if len(results) >= limit {
			break
		}
	}
	return results, nil
}

func (s *Store) ReadFile(id, relPath string) ([]byte, string, error) {
	item, err := s.Get(id)
	if err != nil {
		return nil, "", err
	}
	clean, err := cleanRelativePath(relPath, item.RawPath)
	if err != nil {
		return nil, "", err
	}
	full := filepath.Join(s.root, filepath.FromSlash(item.Path), filepath.FromSlash(clean))
	base := filepath.Join(s.root, filepath.FromSlash(item.Path))
	if !pathInside(base, full) {
		return nil, "", errors.New("path escapes experience")
	}
	data, err := os.ReadFile(full)
	if err != nil {
		return nil, "", err
	}
	return data, clean, nil
}

func (s *Store) PackageBytes(id string) ([]byte, error) {
	if !idPattern.MatchString(id) {
		return nil, ErrInvalidID
	}
	return os.ReadFile(s.packagePath(id))
}

func (s *Store) ReviewedPackageBytes(id string) ([]byte, error) {
	item, err := s.Get(id)
	if err != nil {
		return nil, err
	}
	data, err := s.PackageBytes(id)
	if err != nil {
		return nil, err
	}
	if item.Status != StatusNetwork {
		return data, nil
	}
	materials, err := s.ReviewMaterials(id)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return data, nil
		}
		return nil, err
	}
	return AddReviewMaterials(data, materials)
}

func (s *Store) PackageInfo(id string) (*PackageInfo, error) {
	data, err := s.PackageBytes(id)
	if err != nil {
		return nil, err
	}
	return ReadPackageInfo(data)
}

func (s *Store) ReviewMaterials(id string) ([]byte, error) {
	item, err := s.Get(id)
	if err != nil {
		return nil, err
	}
	if item.Status != StatusNetwork {
		return nil, ErrNotFound
	}
	data, err := os.ReadFile(filepath.Join(s.root, filepath.FromSlash(item.Path), "review", "review-materials.json"))
	if os.IsNotExist(err) {
		return nil, ErrNotFound
	}
	return data, err
}

func (s *Store) Review(id string, req ReviewRequest, reviewMaterials []byte) (IndexEntry, error) {
	if !idPattern.MatchString(id) {
		return IndexEntry{}, ErrInvalidID
	}
	targetStatus := strings.TrimSpace(req.Status)
	if targetStatus != StatusNetwork && targetStatus != StatusRejected && targetStatus != StatusInbox {
		return IndexEntry{}, ErrInvalidStatus
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	idx, err := s.readIndex()
	if err != nil {
		return IndexEntry{}, err
	}
	pos := -1
	var item IndexEntry
	for i, candidate := range idx.Items {
		if candidate.ExperienceID == id {
			pos = i
			item = candidate
			break
		}
	}
	if pos < 0 {
		return IndexEntry{}, ErrNotFound
	}
	oldDir := filepath.Join(s.root, filepath.FromSlash(item.Path))
	newRel := filepath.ToSlash(filepath.Join(targetStatus, id))
	newDir := filepath.Join(s.root, filepath.FromSlash(newRel))
	if item.Status != targetStatus {
		if err := os.RemoveAll(newDir); err != nil {
			return IndexEntry{}, err
		}
		if err := os.MkdirAll(filepath.Dir(newDir), 0o755); err != nil {
			return IndexEntry{}, err
		}
		if err := os.Rename(oldDir, newDir); err != nil {
			return IndexEntry{}, err
		}
	}
	item.Status = targetStatus
	item.Path = newRel
	item.ReviewReason = strings.TrimSpace(req.Reason)
	item.UpdatedAt = nowRFC3339()
	idx.Items[pos] = item
	idx.UpdatedAt = nowRFC3339()
	if err := s.writeReviewFile(newDir, req); err != nil {
		return IndexEntry{}, err
	}
	if targetStatus == StatusNetwork && len(reviewMaterials) > 0 {
		if err := s.writeReviewMaterialsFile(newDir, reviewMaterials); err != nil {
			return IndexEntry{}, err
		}
	}
	if err := s.writeIndex(idx); err != nil {
		return IndexEntry{}, err
	}
	return item, nil
}

func (s *Store) VirtualIndex() (string, error) {
	items, err := s.List(ListFilter{})
	if err != nil {
		return "", err
	}
	var b strings.Builder
	b.WriteString("# PH01 Experience VFS\n\n")
	b.WriteString("此索引是给主脑读取的虚拟文件系统视图。经验本体是 `package.zip` 内的原始对话转储；`content/` 只是为读取方便解开的只读投影。\n\n")
	for _, status := range []string{StatusInbox, StatusNetwork, StatusRejected} {
		b.WriteString("## /experience/")
		b.WriteString(status)
		b.WriteString("\n\n")
		count := 0
		for _, item := range items {
			if item.Status != status {
				continue
			}
			count++
			b.WriteString("- `")
			b.WriteString(item.ExperienceID)
			b.WriteString("` ")
			b.WriteString(item.Title)
			if item.Brief != "" {
				b.WriteString(" - ")
				b.WriteString(item.Brief)
			}
			if len(item.Keywords) > 0 {
				b.WriteString(" [")
				b.WriteString(strings.Join(item.Keywords, ", "))
				b.WriteString("]")
			}
			if item.RawPath != "" {
				b.WriteString(" raw=`")
				b.WriteString(item.RawPath)
				b.WriteString("`")
			}
			b.WriteString("\n")
		}
		if count == 0 {
			b.WriteString("- 空\n")
		}
		b.WriteString("\n")
	}
	return b.String(), nil
}

func (s *Store) indexPath() string {
	return filepath.Join(s.root, "index.json")
}

func (s *Store) statusDir(status string) string {
	return filepath.Join(s.root, status)
}

func (s *Store) packagePath(id string) string {
	return filepath.Join(s.root, "packages", id+".hxp")
}

func (s *Store) itemDir(status, id string) string {
	return filepath.Join(s.statusDir(status), id)
}

func (s *Store) readIndex() (Index, error) {
	data, err := os.ReadFile(s.indexPath())
	if err != nil {
		return Index{}, err
	}
	var idx Index
	if err := json.Unmarshal(data, &idx); err != nil {
		return Index{}, err
	}
	if idx.Items == nil {
		idx.Items = []IndexEntry{}
	}
	return idx, nil
}

func (s *Store) writeIndex(idx Index) error {
	if err := os.MkdirAll(s.root, 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(idx, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(s.indexPath(), data, 0o644)
}

func (s *Store) writeReviewFile(dir string, req ReviewRequest) error {
	reviewDir := filepath.Join(dir, "review")
	if err := os.MkdirAll(reviewDir, 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(struct {
		Status       string `json:"status"`
		Reason       string `json:"reason,omitempty"`
		ReviewMode   string `json:"review_mode,omitempty"`
		ReviewedBy   string `json:"reviewed_by,omitempty"`
		ReviewedRole string `json:"reviewed_role,omitempty"`
		UpdatedAt    string `json:"updated_at"`
	}{
		Status:       req.Status,
		Reason:       req.Reason,
		ReviewMode:   req.ReviewMode,
		ReviewedBy:   req.ReviewedBy,
		ReviewedRole: req.ReviewedRole,
		UpdatedAt:    nowRFC3339(),
	}, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(reviewDir, "local-review.json"), data, 0o644)
}

func (s *Store) writeReviewMaterialsFile(dir string, data []byte) error {
	reviewDir := filepath.Join(dir, "review")
	if err := os.MkdirAll(reviewDir, 0o755); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(reviewDir, "review-materials.json"), data, 0o644)
}

func findEntry(items []IndexEntry, id string) (IndexEntry, bool) {
	for _, item := range items {
		if item.ExperienceID == id {
			return item, true
		}
	}
	return IndexEntry{}, false
}

func validStatus(status string) bool {
	switch status {
	case StatusInbox, StatusNetwork, StatusRejected, StatusCache:
		return true
	default:
		return false
	}
}

func normalizeKeywords(in []string) []string {
	seen := map[string]bool{}
	out := make([]string, 0, len(in))
	for _, kw := range in {
		kw = strings.ToLower(strings.TrimSpace(kw))
		if kw == "" || seen[kw] {
			continue
		}
		seen[kw] = true
		out = append(out, kw)
	}
	sort.Strings(out)
	return out
}

func hasKeyword(keywords []string, keyword string) bool {
	for _, kw := range keywords {
		if strings.EqualFold(kw, keyword) {
			return true
		}
	}
	return false
}

func searchableTextPath(path string) bool {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".md", ".txt", ".json", ".jsonl", ".dat", ".log", ".yaml", ".yml", ".csv":
		return true
	default:
		return false
	}
}

func searchFile(path, queryLower string, item IndexEntry, rel string, remaining int) ([]SearchResult, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	out := make([]SearchResult, 0, remaining)
	reader := bufio.NewReader(f)
	lineNo := 0
	for remaining > 0 {
		line, err := reader.ReadString('\n')
		if len(line) > 0 {
			lineNo++
			line = strings.TrimRight(line, "\r\n")
			lineLower := strings.ToLower(line)
			if idx := strings.Index(lineLower, queryLower); idx >= 0 {
				out = append(out, SearchResult{
					ExperienceID: item.ExperienceID,
					Title:        item.Title,
					Status:       item.Status,
					Path:         rel,
					Line:         lineNo,
					Column:       runeColumn(lineLower, idx),
					Snippet:      snippet(line, idx, len(queryLower)),
				})
				remaining--
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return out, err
		}
	}
	return out, nil
}

func runeColumn(s string, byteIdx int) int {
	return len([]rune(s[:byteIdx])) + 1
}

func snippet(line string, byteIdx, matchBytes int) string {
	runes := []rune(line)
	matchStart := len([]rune(line[:byteIdx]))
	matchEnd := matchStart + len([]rune(line[byteIdx:byteIdx+matchBytes]))
	start := matchStart - 60
	if start < 0 {
		start = 0
	}
	end := matchEnd + 60
	if end > len(runes) {
		end = len(runes)
	}
	text := string(runes[start:end])
	if start > 0 {
		text = "..." + text
	}
	if end < len(runes) {
		text += "..."
	}
	return text
}

func cleanRelativePath(rel, fallback string) (string, error) {
	rel = filepath.ToSlash(strings.TrimSpace(rel))
	if rel == "" {
		rel = strings.TrimSpace(fallback)
	}
	if rel == "" {
		rel = "package.zip"
	}
	rel = strings.TrimPrefix(rel, "/")
	clean := filepath.ToSlash(filepath.Clean(rel))
	if clean == "." || clean == ".." || strings.HasPrefix(clean, "../") {
		return "", errors.New("invalid relative path")
	}
	return clean, nil
}
