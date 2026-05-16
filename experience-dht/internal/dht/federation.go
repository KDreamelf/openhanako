package dht

import (
	"bytes"
	"context"
	"encoding/json"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	federationHeader         = "X-PH01-DHT-Federated"
	demandReturnPathHeader   = "X-PH01-DHT-Return-Path"
	maxFederationPeers       = 8
	maxDemandReturnPathHops  = 16
	federationRequestTimeout = 2 * time.Second
)

func (h *Handler) RunPeerBootstrap(ctx context.Context) {
	ticker := time.NewTicker(h.peerBootstrapInterval())
	defer ticker.Stop()
	h.bootstrapPeers(ctx)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			h.bootstrapPeers(ctx)
		}
	}
}

func (h *Handler) peerBootstrapInterval() time.Duration {
	interval := h.Config.HeartbeatInterval()
	if interval <= 0 {
		return time.Minute
	}
	return interval
}

func (h *Handler) bootstrapPeers(ctx context.Context) {
	state, err := h.Store.Get()
	if err != nil {
		log.Printf("[warn] dht bootstrap read state: %v", err)
		return
	}
	managerBaseURL, err := h.bootstrapManagerBaseURL("", state)
	if err != nil {
		log.Printf("[warn] dht bootstrap skipped: invalid manager_base_url: %v", err)
		return
	}
	if strings.TrimSpace(managerBaseURL) == "" {
		return
	}
	requestCtx, cancel := context.WithTimeout(ctx, federationRequestTimeout)
	defer cancel()
	nodes, err := h.managerForBaseURL(managerBaseURL).ListDHTNodes(requestCtx)
	if err != nil {
		log.Printf("[warn] dht bootstrap list failed: %v", err)
		return
	}
	h.setUpstreamsForSelf(nodes, state.NodeID)
}

func (h *Handler) setUpstreams(nodes []NodeDescriptor) {
	h.setUpstreamsForSelf(nodes, h.Config.NodeID)
}

func (h *Handler) setUpstreamsForSelf(nodes []NodeDescriptor, selfNodeID string) {
	now := time.Now().UTC()
	seen := map[string]bool{}
	out := map[string]NodeDescriptor{}
	for _, node := range nodes {
		nodeID := strings.TrimSpace(node.NodeID)
		if nodeID == "" || seen[nodeID] {
			continue
		}
		if !usableUpstreamNode(node, selfNodeID, now) {
			continue
		}
		seen[nodeID] = true
		out[nodeID] = node
		if len(out) >= maxFederationPeers {
			break
		}
	}
	h.upstreamMu.Lock()
	h.upstreams = out
	h.upstreamMu.Unlock()
}

func usableUpstreamNode(node NodeDescriptor, selfNodeID string, now time.Time) bool {
	if strings.EqualFold(strings.TrimSpace(node.NodeID), strings.TrimSpace(selfNodeID)) {
		return false
	}
	health := strings.TrimSpace(node.HealthStatus)
	if health != "" && health != HealthHealthy {
		return false
	}
	if strings.TrimSpace(node.ExpiresAt) != "" {
		expiresAt, err := time.Parse(time.RFC3339, node.ExpiresAt)
		if err != nil || !expiresAt.After(now) {
			return false
		}
	}
	_, ok := apiBaseURLFromNode(node)
	return ok
}

func (h *Handler) upstreamNodes() []NodeDescriptor {
	h.upstreamMu.RLock()
	defer h.upstreamMu.RUnlock()
	out := make([]NodeDescriptor, 0, len(h.upstreams))
	for _, node := range h.upstreams {
		out = append(out, node)
	}
	return out
}

func (h *Handler) handleFederationProviders(w http.ResponseWriter, r *http.Request) {
	hash := strings.TrimSpace(r.URL.Query().Get("package_hash"))
	if hash == "" {
		writeError(w, http.StatusBadRequest, "invalid_payload", "package_hash required")
		return
	}
	items := h.localProviders(hash, time.Now().UTC())
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "total": len(items)})
}

func (h *Handler) handleFederationPackageRequests(w http.ResponseWriter, r *http.Request) {
	hash := strings.TrimSpace(r.URL.Query().Get("package_hash"))
	if hash == "" {
		writeError(w, http.StatusBadRequest, "invalid_payload", "package_hash required")
		return
	}
	items := h.localPackageRequests(hash, time.Now().UTC())
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "total": len(items)})
}

func (h *Handler) handleFederationPackageOffers(w http.ResponseWriter, r *http.Request) {
	requestID := federationPackageRequestIDFromPath(r.URL.Path, "/offers")
	if requestID == "" {
		writeError(w, http.StatusNotFound, "not_found", "")
		return
	}
	items, exists := h.localPackageOffers(requestID, time.Now().UTC())
	if !exists {
		writeError(w, http.StatusNotFound, "package_request_not_found", "")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "total": len(items)})
}

func (h *Handler) handleFederationExperienceDemands(w http.ResponseWriter, r *http.Request) {
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	requestID := strings.TrimSpace(r.URL.Query().Get("request_id"))
	limit := intQuery(r, "limit", 100)
	items := h.localExperienceDemands(query, requestID, time.Now().UTC(), limit)
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "total": len(items)})
}

func (h *Handler) handleFederationExperienceDemandOffers(w http.ResponseWriter, r *http.Request) {
	requestID := federationExperienceDemandIDFromPath(r.URL.Path, "/offers")
	if requestID == "" {
		writeError(w, http.StatusNotFound, "not_found", "")
		return
	}
	items, exists := h.localExperienceDemandOffers(requestID, time.Now().UTC())
	if !exists {
		writeError(w, http.StatusNotFound, "experience_demand_not_found", "")
		return
	}
	if strings.EqualFold(strings.TrimSpace(r.URL.Query().Get("include_review_chain")), "false") {
		items = h.withoutInlineReviewChains(items)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "total": len(items)})
}

func (h *Handler) localProviders(hash string, now time.Time) []ProviderRecord {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := make([]ProviderRecord, 0)
	for key, record := range h.providers {
		expiresAt, err := time.Parse(time.RFC3339, record.ExpiresAt)
		if err != nil || !expiresAt.After(now) {
			delete(h.providers, key)
			continue
		}
		if hasString(record.PackageHashes, hash) {
			out = append(out, record)
		}
	}
	return out
}

func (h *Handler) localPackageRequests(hash string, now time.Time) []PackageRequestRecord {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.cleanupPackageRequestsLocked(now)
	out := make([]PackageRequestRecord, 0)
	for _, record := range h.requests {
		if record.PackageHash == hash {
			out = append(out, record)
		}
	}
	return out
}

func (h *Handler) localPackageOffers(requestID string, now time.Time) ([]PackageOfferRecord, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.cleanupPackageRequestsLocked(now)
	if _, exists := h.requests[requestID]; !exists {
		return nil, false
	}
	return append([]PackageOfferRecord(nil), h.offers[requestID]...), true
}

func (h *Handler) localExperienceDemands(query, requestID string, now time.Time, limit int) []ExperienceDemandRecord {
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.cleanupExperienceDemandsLocked(now)
	out := make([]ExperienceDemandRecord, 0)
	for _, record := range h.demands {
		if requestID != "" && record.RequestID != requestID {
			continue
		}
		if query != "" && !experienceDemandMatches(record, query) {
			continue
		}
		out = append(out, record)
		if len(out) >= limit {
			break
		}
	}
	return out
}

func (h *Handler) localExperienceDemandOffers(requestID string, now time.Time) ([]ExperienceDemandOfferRecord, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.cleanupExperienceDemandsLocked(now)
	if _, exists := h.demands[requestID]; !exists {
		return nil, false
	}
	return append([]ExperienceDemandOfferRecord(nil), h.demandOffers[requestID]...), true
}

func (h *Handler) localExperienceDemand(requestID string, now time.Time) (ExperienceDemandRecord, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.cleanupExperienceDemandsLocked(now)
	record, exists := h.demands[requestID]
	return record, exists
}

func (h *Handler) fetchFederatedProviders(ctx context.Context, hash string) []ProviderRecord {
	var out []ProviderRecord
	for _, node := range h.upstreamNodes() {
		var resp struct {
			Items []ProviderRecord `json:"items"`
		}
		if !h.getFromUpstream(ctx, node, "/api/v1/federation/providers", url.Values{"package_hash": []string{hash}}, &resp) {
			continue
		}
		out = append(out, resp.Items...)
	}
	return out
}

func (h *Handler) fetchFederatedPackageRequests(ctx context.Context, hash string) []PackageRequestRecord {
	var out []PackageRequestRecord
	for _, node := range h.upstreamNodes() {
		var resp struct {
			Items []PackageRequestRecord `json:"items"`
		}
		if !h.getFromUpstream(ctx, node, "/api/v1/federation/package-requests", url.Values{"package_hash": []string{hash}}, &resp) {
			continue
		}
		out = append(out, resp.Items...)
	}
	return out
}

func (h *Handler) fetchFederatedPackageOffers(ctx context.Context, requestID string) []PackageOfferRecord {
	var out []PackageOfferRecord
	for _, node := range h.upstreamNodes() {
		var resp struct {
			Items []PackageOfferRecord `json:"items"`
		}
		path := "/api/v1/federation/package-requests/" + url.PathEscape(requestID) + "/offers"
		if !h.getFromUpstream(ctx, node, path, nil, &resp) {
			continue
		}
		out = append(out, resp.Items...)
	}
	return out
}

func (h *Handler) fetchFederatedExperienceDemands(ctx context.Context, query, requestID string, limit int) []ExperienceDemandRecord {
	var out []ExperienceDemandRecord
	params := url.Values{}
	if strings.TrimSpace(query) != "" {
		params.Set("q", strings.TrimSpace(query))
	}
	if strings.TrimSpace(requestID) != "" {
		params.Set("request_id", strings.TrimSpace(requestID))
	}
	if limit > 0 {
		params.Set("limit", strconv.Itoa(limit))
	}
	for _, node := range h.upstreamNodes() {
		var resp struct {
			Items []ExperienceDemandRecord `json:"items"`
		}
		if !h.getFromUpstream(ctx, node, "/api/v1/federation/experience-demands", params, &resp) {
			continue
		}
		out = append(out, resp.Items...)
	}
	return out
}

func (h *Handler) fetchFederatedExperienceDemandOffers(ctx context.Context, requestID string) []ExperienceDemandOfferRecord {
	var out []ExperienceDemandOfferRecord
	for _, node := range h.upstreamNodes() {
		var resp struct {
			Items []ExperienceDemandOfferRecord `json:"items"`
		}
		path := "/api/v1/federation/experience-demands/" + url.PathEscape(requestID) + "/offers"
		if !h.getFromUpstream(ctx, node, path, url.Values{"include_review_chain": []string{"false"}}, &resp) {
			continue
		}
		out = append(out, resp.Items...)
	}
	return out
}

func (h *Handler) fetchManagerExperienceDemandOffers(ctx context.Context, requestID string, demand ExperienceDemandRecord, limit int) []ExperienceDemandOfferRecord {
	state, err := h.Store.Get()
	if err != nil {
		return nil
	}
	managerBaseURL, err := h.bootstrapManagerBaseURL("", state)
	if err != nil || strings.TrimSpace(managerBaseURL) == "" {
		return nil
	}
	resolver, ok := h.managerForBaseURL(managerBaseURL).(interface {
		ResolveExperienceDemandOffers(context.Context, string, string, int) ([]ExperienceDemandOfferRecord, error)
	})
	if !ok {
		return nil
	}
	requestCtx, cancel := context.WithTimeout(ctx, federationRequestTimeout)
	defer cancel()
	items, err := resolver.ResolveExperienceDemandOffers(
		requestCtx,
		requestID,
		demand.NaturalLanguageQuery,
		limit,
	)
	if err != nil {
		log.Printf("[warn] manager demand fallback failed: %v", err)
		return nil
	}
	return items
}

func (h *Handler) getFromUpstream(ctx context.Context, node NodeDescriptor, path string, query url.Values, out any) bool {
	baseURL, ok := apiBaseURLFromNode(node)
	if !ok {
		return false
	}
	parsed, err := url.Parse(baseURL + path)
	if err != nil {
		return false
	}
	if len(query) > 0 {
		parsed.RawQuery = query.Encode()
	}
	requestCtx, cancel := context.WithTimeout(ctx, federationRequestTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(requestCtx, http.MethodGet, parsed.String(), nil)
	if err != nil {
		return false
	}
	req.Header.Set(federationHeader, "1")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return false
	}
	return json.NewDecoder(resp.Body).Decode(out) == nil
}

func (h *Handler) fanoutSignedRequest(path string, signed SignedRequest) {
	h.fanoutSignedRequestWithReturnPath(path, signed, nil)
}

func (h *Handler) fanoutSignedRequestWithReturnPath(path string, signed SignedRequest, returnPath []DemandReturnHop) {
	nodes := h.upstreamNodes()
	if len(nodes) == 0 {
		return
	}
	data, err := json.Marshal(signed)
	if err != nil {
		return
	}
	go func() {
		for _, node := range nodes {
			h.postToUpstream(node, path, data, returnPath)
		}
	}()
}

func (h *Handler) postToUpstream(node NodeDescriptor, path string, data []byte, returnPath []DemandReturnHop) {
	baseURL, ok := apiBaseURLFromNode(node)
	if !ok {
		return
	}
	requestCtx, cancel := context.WithTimeout(context.Background(), federationRequestTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(requestCtx, http.MethodPost, baseURL+path, bytes.NewReader(data))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(federationHeader, "1")
	if len(returnPath) > 0 {
		if data, err := json.Marshal(normalizeDemandReturnPath(returnPath)); err == nil {
			req.Header.Set(demandReturnPathHeader, string(data))
		}
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return
	}
	_ = resp.Body.Close()
}

func (h *Handler) isFederatedRequest(r *http.Request) bool {
	return r.Header.Get(federationHeader) == "1"
}

func dedupeProviders(items []ProviderRecord) []ProviderRecord {
	seen := map[string]bool{}
	out := make([]ProviderRecord, 0, len(items))
	for _, item := range items {
		key := strings.TrimSpace(item.PeerID)
		if key == "" || seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, item)
	}
	return out
}

func dedupePackageRequests(items []PackageRequestRecord) []PackageRequestRecord {
	seen := map[string]bool{}
	out := make([]PackageRequestRecord, 0, len(items))
	for _, item := range items {
		key := strings.TrimSpace(item.RequestID)
		if key == "" || seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, item)
	}
	return out
}

func dedupePackageOffers(items []PackageOfferRecord) []PackageOfferRecord {
	seen := map[string]bool{}
	out := make([]PackageOfferRecord, 0, len(items))
	for _, item := range items {
		key := strings.TrimSpace(item.RequestID) + "|" + strings.TrimSpace(item.ProviderPeerID)
		if key == "|" || seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, item)
	}
	return out
}

func dedupeExperienceDemands(items []ExperienceDemandRecord) []ExperienceDemandRecord {
	seen := map[string]bool{}
	out := make([]ExperienceDemandRecord, 0, len(items))
	for _, item := range items {
		key := strings.TrimSpace(item.RequestID)
		if key == "" || seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, item)
	}
	return out
}

func dedupeExperienceDemandOffers(items []ExperienceDemandOfferRecord) []ExperienceDemandOfferRecord {
	seen := map[string]bool{}
	out := make([]ExperienceDemandOfferRecord, 0, len(items))
	for _, item := range items {
		key := strings.TrimSpace(item.RequestID) + "|" + strings.TrimSpace(item.ProviderPeerID) + "|" + strings.TrimSpace(item.ExperienceID) + "|" + strings.TrimSpace(item.PackageHash)
		if key == "|||" || seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, item)
	}
	return out
}

func experienceDemandMatches(record ExperienceDemandRecord, query string) bool {
	needle := strings.ToLower(strings.TrimSpace(query))
	if needle == "" {
		return true
	}
	haystack := strings.ToLower(strings.Join([]string{
		record.NaturalLanguageQuery,
		record.QueryLanguage,
		strings.Join(record.QueryKeywords, " "),
	}, " "))
	return strings.Contains(haystack, needle)
}

func apiBaseURLFromNode(node NodeDescriptor) (string, bool) {
	for _, endpoint := range node.Endpoints {
		baseURL, ok := apiBaseURLFromEndpoint(endpoint)
		if ok {
			return baseURL, true
		}
	}
	return "", false
}

func apiBaseURLFromEndpoint(endpoint Endpoint) (string, bool) {
	scheme := strings.ToLower(strings.TrimSpace(endpoint.Network))
	if scheme != "http" && scheme != "https" {
		return "", false
	}
	host := strings.TrimSpace(endpoint.Host)
	if host == "" || endpoint.Port <= 0 {
		return "", false
	}
	if strings.Contains(host, ":") && !strings.HasPrefix(host, "[") {
		host = "[" + host + "]"
	}
	return scheme + "://" + host + ":" + strconv.Itoa(endpoint.Port), true
}

func federationPackageRequestIDFromPath(path string, suffix string) string {
	rest := strings.TrimPrefix(path, "/api/v1/federation/package-requests/")
	if suffix != "" {
		rest = strings.TrimSuffix(rest, suffix)
	}
	rest = strings.Trim(rest, "/")
	if strings.Contains(rest, "/") {
		return ""
	}
	if decoded, err := url.PathUnescape(rest); err == nil {
		return decoded
	}
	return rest
}

func federationExperienceDemandIDFromPath(path string, suffix string) string {
	rest := strings.TrimPrefix(path, "/api/v1/federation/experience-demands/")
	if suffix != "" {
		rest = strings.TrimSuffix(rest, suffix)
	}
	rest = strings.Trim(rest, "/")
	if strings.Contains(rest, "/") {
		return ""
	}
	if decoded, err := url.PathUnescape(rest); err == nil {
		return decoded
	}
	return rest
}

func intQuery(r *http.Request, name string, fallback int) int {
	raw := strings.TrimSpace(r.URL.Query().Get(name))
	if raw == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(raw)
	if err != nil {
		return fallback
	}
	return parsed
}
