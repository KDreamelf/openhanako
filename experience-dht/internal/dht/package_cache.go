package dht

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const packageCacheTTL = 7 * 24 * time.Hour

var errPackageCacheNotFound = errors.New("package cache not found")

func (h *Handler) handleCachePackageUpload(w http.ResponseWriter, r *http.Request) {
	packageHash := cachePackageHashFromPath(r.URL.Path)
	if packageHash == "" {
		writeError(w, http.StatusNotFound, "not_found", "")
		return
	}
	state, err := h.Store.Get()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "state_load_failed", err.Error())
		return
	}
	maxBytes := h.effectiveConfig(state).MaxRelayBytes()
	if r.ContentLength > maxBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "cache_payload_too_large", "")
		return
	}
	reader := http.MaxBytesReader(w, r.Body, maxBytes+1)
	payload, err := io.ReadAll(reader)
	if err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "cache_payload_too_large", err.Error())
		return
	}
	if int64(len(payload)) > maxBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "cache_payload_too_large", "")
		return
	}
	record, err := h.storeCachedPackage(packageHash, strings.TrimSpace(r.Header.Get("X-PH01-Experience-ID")), payload, time.Now().UTC())
	if err != nil {
		writeError(w, http.StatusBadRequest, "cache_store_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, record)
}

func (h *Handler) handleCachePackageDownload(w http.ResponseWriter, r *http.Request) {
	packageHash := cachePackageHashFromPath(r.URL.Path)
	if packageHash == "" {
		writeError(w, http.StatusNotFound, "not_found", "")
		return
	}
	record, payload, err := h.cachedPackage(packageHash, time.Now().UTC())
	if err != nil {
		writeError(w, http.StatusNotFound, "cache_package_not_found", err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-PH01-Package-Hash", record.PackageHash)
	w.Header().Set("X-PH01-Payload-SHA256", record.PayloadSHA256)
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(payload)
}

func (h *Handler) handleReviewChainDownload(w http.ResponseWriter, r *http.Request) {
	digest := reviewChainDigestFromPath(r.URL.Path)
	if digest == "" {
		writeError(w, http.StatusNotFound, "not_found", "")
		return
	}
	h.mu.Lock()
	record, ok := h.reviewChains[digest]
	h.mu.Unlock()
	if !ok {
		writeError(w, http.StatusNotFound, "review_chain_not_found", "")
		return
	}
	writeJSON(w, http.StatusOK, ReviewChainPayload{
		SchemaVersion: "ph01.experience.review_chain_payload.v1",
		Digest:        record.Digest,
		Length:        record.Length,
		ReviewChain:   record.ReviewChain,
		UpdatedAt:     record.UpdatedAt,
	})
}

func (h *Handler) storeCachedPackage(packageHash, experienceID string, payload []byte, now time.Time) (PackageCacheRecord, error) {
	normalizedHash := normalizeCachePackageHash(packageHash)
	if normalizedHash == "" {
		return PackageCacheRecord{}, errors.New("package_hash required")
	}
	if len(payload) == 0 {
		return PackageCacheRecord{}, errors.New("payload required")
	}
	sum := sha256.Sum256(payload)
	record := PackageCacheRecord{
		PackageHash:   normalizedHash,
		ExperienceID:  strings.TrimSpace(experienceID),
		Bytes:         int64(len(payload)),
		PayloadSHA256: hex.EncodeToString(sum[:]),
		StoredAt:      now.Format(time.RFC3339),
		ExpiresAt:     now.Add(packageCacheTTL).Format(time.RFC3339),
	}
	if err := os.MkdirAll(h.Store.CacheDir(), 0o755); err != nil {
		return PackageCacheRecord{}, err
	}
	dataPath, metaPath := h.cachePackagePaths(normalizedHash)
	if err := os.WriteFile(dataPath, payload, 0o600); err != nil {
		return PackageCacheRecord{}, err
	}
	meta, err := json.MarshalIndent(record, "", "  ")
	if err != nil {
		return PackageCacheRecord{}, err
	}
	if err := os.WriteFile(metaPath, meta, 0o600); err != nil {
		return PackageCacheRecord{}, err
	}
	return record, nil
}

func (h *Handler) cachedPackage(packageHash string, now time.Time) (PackageCacheRecord, []byte, error) {
	normalizedHash := normalizeCachePackageHash(packageHash)
	if normalizedHash == "" {
		return PackageCacheRecord{}, nil, errPackageCacheNotFound
	}
	dataPath, metaPath := h.cachePackagePaths(normalizedHash)
	meta, err := os.ReadFile(metaPath)
	if err != nil {
		return PackageCacheRecord{}, nil, errPackageCacheNotFound
	}
	var record PackageCacheRecord
	if err := json.Unmarshal(meta, &record); err != nil {
		return PackageCacheRecord{}, nil, err
	}
	expiresAt, err := time.Parse(time.RFC3339, record.ExpiresAt)
	if err != nil || !expiresAt.After(now) {
		_ = os.Remove(metaPath)
		_ = os.Remove(dataPath)
		return PackageCacheRecord{}, nil, errPackageCacheNotFound
	}
	payload, err := os.ReadFile(dataPath)
	if err != nil {
		return PackageCacheRecord{}, nil, errPackageCacheNotFound
	}
	return record, payload, nil
}

func (h *Handler) cachePackagePaths(packageHash string) (string, string) {
	sum := sha256.Sum256([]byte(packageHash))
	name := hex.EncodeToString(sum[:])
	return filepath.Join(h.Store.CacheDir(), name+".hxp"), filepath.Join(h.Store.CacheDir(), name+".json")
}

func cachePackageHashFromPath(path string) string {
	rest := strings.TrimPrefix(path, "/api/v1/cache/packages/")
	rest = strings.Trim(rest, "/")
	if strings.Contains(rest, "/") {
		return ""
	}
	decoded, err := url.PathUnescape(rest)
	if err == nil {
		rest = decoded
	}
	return normalizeCachePackageHash(rest)
}

func reviewChainDigestFromPath(path string) string {
	rest := strings.TrimPrefix(path, "/api/v1/review-chains/")
	rest = strings.Trim(rest, "/")
	if strings.Contains(rest, "/") {
		return ""
	}
	decoded, err := url.PathUnescape(rest)
	if err == nil {
		rest = decoded
	}
	return normalizeCachePackageHash(rest)
}

func normalizeCachePackageHash(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	value = strings.TrimPrefix(value, "sha256:")
	if value == "" {
		return ""
	}
	return "sha256:" + value
}
