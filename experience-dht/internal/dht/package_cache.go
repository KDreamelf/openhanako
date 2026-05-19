package dht

import (
	"net/http"
	"net/url"
	"strings"
)

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
	return normalizeReviewChainDigest(rest)
}

func normalizeReviewChainDigest(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	value = strings.TrimPrefix(value, "sha256:")
	if value == "" {
		return ""
	}
	return "sha256:" + value
}
