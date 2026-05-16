package dht

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Handler struct {
	Config  Config
	Store   *StateStore
	Manager ManagerClient

	mu           sync.Mutex
	nonces       map[string]time.Time
	providers    map[string]ProviderRecord
	relay        map[string]relaySessionRecord
	holePunch    map[string]holePunchSessionRecord
	requests     map[string]PackageRequestRecord
	offers       map[string][]PackageOfferRecord
	demands      map[string]ExperienceDemandRecord
	demandOffers map[string][]ExperienceDemandOfferRecord
	reviewChains map[string]reviewChainRecord
	rateWindows  map[string]rateWindow
	flowers      []DHTServiceFlower
	wreaths      []DHTServiceWreath

	upstreamMu sync.RWMutex
	upstreams  map[string]NodeDescriptor
}

func NewHandler(cfg Config, store *StateStore, manager ManagerClient) *Handler {
	if manager == nil {
		manager = HTTPManagerClient{
			BaseURL: cfg.ManagerBaseURL,
		}
	}
	return &Handler{
		Config:       cfg,
		Store:        store,
		Manager:      manager,
		nonces:       map[string]time.Time{},
		providers:    map[string]ProviderRecord{},
		relay:        map[string]relaySessionRecord{},
		holePunch:    map[string]holePunchSessionRecord{},
		requests:     map[string]PackageRequestRecord{},
		offers:       map[string][]PackageOfferRecord{},
		demands:      map[string]ExperienceDemandRecord{},
		demandOffers: map[string][]ExperienceDemandOfferRecord{},
		reviewChains: map[string]reviewChainRecord{},
		rateWindows:  map[string]rateWindow{},
		upstreams:    map[string]NodeDescriptor{},
	}
}

type reviewChainRecord struct {
	Digest      string
	Length      int
	ReviewChain []map[string]any
	UpdatedAt   string
}

const (
	demandWriteRateWindow              = time.Minute
	maxExperienceDemandWritesPerWindow = 30
	maxDemandOfferWritesPerWindow      = 120
)

type rateWindow struct {
	StartedAt time.Time
	Count     int
}

type relaySessionRecord struct {
	session RelaySession
	payload []byte
}

type holePunchSessionRecord struct {
	session HolePunchSession
}

var (
	errRelayForbidden   = errors.New("relay forbidden")
	errRelayUnavailable = errors.New("relay unavailable")
	errRelayNotFound    = errors.New("relay session not found")
	errRelayExpired     = errors.New("relay session expired")
	errRelayNotReady    = errors.New("relay payload not ready")

	errHolePunchForbidden   = errors.New("hole punch forbidden")
	errHolePunchUnavailable = errors.New("hole punch unavailable")
	errHolePunchNotFound    = errors.New("hole punch session not found")
	errHolePunchExpired     = errors.New("hole punch session expired")
)

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/healthz" && r.Method == http.MethodGet:
		h.handleHealthz(w, r)
	case r.URL.Path == "/api/v1/admin/bind" && r.Method == http.MethodPost:
		h.handleBind(w, r)
	case r.URL.Path == "/api/v1/admin/status" && r.Method == http.MethodPost:
		h.handleSignedAdmin(w, r, h.adminStatus)
	case r.URL.Path == "/api/v1/admin/bootstrap" && r.Method == http.MethodPost:
		h.handleSignedAdmin(w, r, h.setBootstrapManager)
	case r.URL.Path == "/api/v1/admin/config" && r.Method == http.MethodPost:
		h.handleSignedAdmin(w, r, h.setRuntimeConfig)
	case r.URL.Path == "/api/v1/admin/public" && r.Method == http.MethodPost:
		h.handleSignedAdmin(w, r, h.setPublicMode)
	case r.URL.Path == "/api/v1/federation/providers" && r.Method == http.MethodGet:
		h.handleFederationProviders(w, r)
	case r.URL.Path == "/api/v1/federation/package-requests" && r.Method == http.MethodGet:
		h.handleFederationPackageRequests(w, r)
	case strings.HasPrefix(r.URL.Path, "/api/v1/federation/package-requests/") && strings.HasSuffix(r.URL.Path, "/offers") && r.Method == http.MethodGet:
		h.handleFederationPackageOffers(w, r)
	case r.URL.Path == "/api/v1/federation/experience-demands" && r.Method == http.MethodGet:
		h.handleFederationExperienceDemands(w, r)
	case strings.HasPrefix(r.URL.Path, "/api/v1/federation/experience-demands/") && strings.HasSuffix(r.URL.Path, "/offers") && r.Method == http.MethodGet:
		h.handleFederationExperienceDemandOffers(w, r)
	case strings.HasPrefix(r.URL.Path, "/api/v1/cache/packages/") && r.Method == http.MethodPut:
		h.handleCachePackageUpload(w, r)
	case strings.HasPrefix(r.URL.Path, "/api/v1/cache/packages/") && r.Method == http.MethodGet:
		h.handleCachePackageDownload(w, r)
	case strings.HasPrefix(r.URL.Path, "/api/v1/review-chains/") && r.Method == http.MethodGet:
		h.handleReviewChainDownload(w, r)
	case r.URL.Path == "/api/v1/trust/flowers" && r.Method == http.MethodPost:
		h.handleTrustFlower(w, r)
	case r.URL.Path == "/api/v1/trust/wreaths/aggregate" && r.Method == http.MethodPost:
		h.handleTrustWreathAggregate(w, r)
	case r.URL.Path == "/api/v1/trust/bundle" && r.Method == http.MethodGet:
		h.handleTrustBundle(w, r)
	case r.URL.Path == "/api/v1/peers/presence" && r.Method == http.MethodPost:
		h.handlePresence(w, r)
	case r.URL.Path == "/api/v1/providers" && r.Method == http.MethodGet:
		h.handleProviders(w, r)
	case r.URL.Path == "/api/v1/package-requests" && r.Method == http.MethodPost:
		h.handlePackageRequest(w, r)
	case r.URL.Path == "/api/v1/package-requests" && r.Method == http.MethodGet:
		h.handlePackageRequests(w, r)
	case strings.HasPrefix(r.URL.Path, "/api/v1/package-requests/") && strings.HasSuffix(r.URL.Path, "/offers") && r.Method == http.MethodPost:
		h.handlePackageOffer(w, r)
	case strings.HasPrefix(r.URL.Path, "/api/v1/package-requests/") && strings.HasSuffix(r.URL.Path, "/offers") && r.Method == http.MethodGet:
		h.handlePackageOffers(w, r)
	case r.URL.Path == "/api/v1/experience-demands" && r.Method == http.MethodPost:
		h.handleExperienceDemand(w, r)
	case r.URL.Path == "/api/v1/experience-demands" && r.Method == http.MethodGet:
		h.handleExperienceDemands(w, r)
	case strings.HasPrefix(r.URL.Path, "/api/v1/experience-demands/") && strings.HasSuffix(r.URL.Path, "/offers") && r.Method == http.MethodPost:
		h.handleExperienceDemandOffer(w, r)
	case strings.HasPrefix(r.URL.Path, "/api/v1/experience-demands/") && strings.HasSuffix(r.URL.Path, "/offers") && r.Method == http.MethodGet:
		h.handleExperienceDemandOffers(w, r)
	case r.URL.Path == "/api/v1/relay/sessions" && r.Method == http.MethodPost:
		h.handleRelaySession(w, r)
	case strings.HasPrefix(r.URL.Path, "/api/v1/relay/sessions/") && strings.HasSuffix(r.URL.Path, "/package") && r.Method == http.MethodPut:
		h.handleRelayUpload(w, r)
	case strings.HasPrefix(r.URL.Path, "/api/v1/relay/sessions/") && strings.HasSuffix(r.URL.Path, "/package") && r.Method == http.MethodGet:
		h.handleRelayDownload(w, r)
	case r.URL.Path == "/api/v1/hole-punch/sessions" && r.Method == http.MethodPost:
		h.handleHolePunchSession(w, r)
	case strings.HasPrefix(r.URL.Path, "/api/v1/hole-punch/sessions/") && strings.HasSuffix(r.URL.Path, "/reports") && r.Method == http.MethodPost:
		h.handleHolePunchReport(w, r)
	case strings.HasPrefix(r.URL.Path, "/api/v1/hole-punch/sessions/") && r.Method == http.MethodGet:
		h.handleHolePunchStatus(w, r)
	default:
		writeError(w, http.StatusNotFound, "not_found", "")
	}
}

func (h *Handler) handleHealthz(w http.ResponseWriter, r *http.Request) {
	state, _ := h.Store.Get()
	cfg := h.effectiveConfig(state)
	endpoint := ""
	candidateEndpoints := candidateEndpointsFromConfig(cfg)
	if len(candidateEndpoints) > 0 {
		endpoint = endpointAddr(candidateEndpoints[0])
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":                  true,
		"service":             "experience-dht",
		"node_id":             h.nodeID(state),
		"bound":               strings.TrimSpace(state.BoundPubkeyHex) != "",
		"public":              state.PublicEnabled,
		"endpoint":            endpoint,
		"candidate_endpoints": candidateEndpoints,
		"public_api_base_url": strings.TrimSpace(cfg.PublicAPIBaseURL),
	})
}

func (h *Handler) handleTrustFlower(w http.ResponseWriter, r *http.Request) {
	var flower DHTServiceFlower
	if err := json.NewDecoder(r.Body).Decode(&flower); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
		return
	}
	state, err := h.Store.Get()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	if flower.NodeID != "" && flower.NodeID != h.nodeID(state) {
		writeError(w, http.StatusBadRequest, "invalid_payload", "flower node_id mismatch")
		return
	}
	flower.NodeID = h.nodeID(state)
	validated, err := ValidateDHTServiceFlower(flower)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, item := range h.flowers {
		if item.FlowerID == validated.FlowerID {
			writeJSON(w, http.StatusOK, item)
			return
		}
	}
	h.flowers = append(h.flowers, validated)
	writeJSON(w, http.StatusOK, validated)
}

func (h *Handler) handleTrustWreathAggregate(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Limit int `json:"limit,omitempty"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	state, err := h.Store.Get()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	nodeID := h.nodeID(state)
	h.mu.Lock()
	wreath, ok := AggregateFlowers(nodeID, h.flowers, req.Limit)
	if ok {
		exists := false
		for _, item := range h.wreaths {
			if item.WreathID == wreath.WreathID {
				wreath = item
				exists = true
				break
			}
		}
		if !exists {
			h.wreaths = append(h.wreaths, wreath)
		}
	}
	h.mu.Unlock()
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_payload", "no flowers to aggregate")
		return
	}
	writeJSON(w, http.StatusOK, wreath)
}

func (h *Handler) handleTrustBundle(w http.ResponseWriter, r *http.Request) {
	state, err := h.Store.Get()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	nodeID := h.nodeID(state)
	h.mu.Lock()
	flowers := make([]DHTServiceFlower, 0, 100)
	for i := len(h.flowers) - 1; i >= 0 && len(flowers) < 100; i-- {
		if h.flowers[i].NodeID == nodeID {
			flowers = append(flowers, h.flowers[i])
		}
	}
	wreaths := make([]DHTServiceWreath, 0, 10)
	for i := len(h.wreaths) - 1; i >= 0 && len(wreaths) < 10; i-- {
		if h.wreaths[i].NodeID == nodeID {
			wreaths = append(wreaths, h.wreaths[i])
		}
	}
	h.mu.Unlock()
	writeJSON(w, http.StatusOK, DHTTrustBundle{
		SchemaVersion: TrustSchemaVersion,
		NodeID:        nodeID,
		NodePow:       state.NodePow,
		Wreaths:       wreaths,
		Flowers:       flowers,
		UpdatedAt:     nowRFC3339(),
	})
}

func (h *Handler) handleBind(w http.ResponseWriter, r *http.Request) {
	var req BindRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
		return
	}
	state, err := h.Store.Bind(h.Config, req.PubkeyHex, req.InitPassword)
	if err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, ErrAlreadyBound) {
			status = http.StatusConflict
		} else if errors.Is(err, ErrInvalidPassword) {
			status = http.StatusUnauthorized
		}
		writeError(w, status, "bind_failed", err.Error())
		return
	}
	if strings.TrimSpace(req.ManagerBaseURL) != "" {
		managerBaseURL, err := normalizeManagerBaseURL(req.ManagerBaseURL)
		if err != nil {
			writeError(w, http.StatusBadRequest, "bind_failed", err.Error())
			return
		}
		state, err = h.Store.SetBootstrapManager(managerBaseURL)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "bind_failed", err.Error())
			return
		}
	}
	runtime, err := h.normalizeRuntimeConfig(req.RuntimeConfig)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bind_failed", err.Error())
		return
	}
	if !runtimeConfigEmpty(runtime) {
		state, err = h.Store.SetRuntimeConfig(runtime)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "bind_failed", err.Error())
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"state": state})
}

type signedAdminHandler func(context.Context, State, SignedRequest, json.RawMessage) (any, error)

func (h *Handler) handleSignedAdmin(w http.ResponseWriter, r *http.Request, fn signedAdminHandler) {
	state, signed, payload, ok := h.verifySignedRequest(w, r)
	if !ok {
		return
	}
	if strings.TrimSpace(state.BoundPubkeyHex) == "" {
		writeError(w, http.StatusUnauthorized, "dht_not_bound", "")
		return
	}
	if !strings.EqualFold(signed.PubkeyHex, state.BoundPubkeyHex) {
		writeError(w, http.StatusForbidden, "pubkey_not_bound", "")
		return
	}
	resp, err := fn(r.Context(), state, signed, payload)
	if err != nil {
		writeError(w, http.StatusBadRequest, "admin_action_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func (h *Handler) adminStatus(context.Context, State, SignedRequest, json.RawMessage) (any, error) {
	state, err := h.Store.Get()
	if err != nil {
		return nil, err
	}
	hash, _ := PubkeyHash(state.BoundPubkeyHex)
	return map[string]any{
		"state":         state,
		"bound_pubkey":  state.BoundPubkeyHex,
		"bound_hash":    hash,
		"public_config": h.publicDescriptor(state),
	}, nil
}

func (h *Handler) setBootstrapManager(_ context.Context, _ State, _ SignedRequest, payload json.RawMessage) (any, error) {
	var req BootstrapManagerRequest
	if len(payload) > 0 {
		if err := json.Unmarshal(payload, &req); err != nil {
			return nil, err
		}
	}
	managerBaseURL, err := normalizeManagerBaseURL(req.ManagerBaseURL)
	if err != nil {
		return nil, err
	}
	state, err := h.Store.SetBootstrapManager(managerBaseURL)
	if err != nil {
		return nil, err
	}
	return map[string]any{"state": state}, nil
}

func (h *Handler) setRuntimeConfig(_ context.Context, _ State, _ SignedRequest, payload json.RawMessage) (any, error) {
	var req RuntimeConfigRequest
	if len(payload) > 0 {
		if err := json.Unmarshal(payload, &req); err != nil {
			return nil, err
		}
	}
	runtime, err := h.normalizeRuntimeConfig(req.RuntimeConfig)
	if err != nil {
		return nil, err
	}
	state, err := h.Store.SetRuntimeConfig(runtime)
	if err != nil {
		return nil, err
	}
	return map[string]any{"state": state}, nil
}

func (h *Handler) setPublicMode(ctx context.Context, state State, signed SignedRequest, payload json.RawMessage) (any, error) {
	var req PublicModeRequest
	if len(payload) > 0 {
		if err := json.Unmarshal(payload, &req); err != nil {
			return nil, err
		}
	}
	if req.Enabled {
		managerBaseURL, err := h.publicManagerBaseURL(req.ManagerBaseURL, state)
		if err != nil {
			return nil, err
		}
		if managerBaseURL == "" {
			return nil, errors.New("manager_base_url is required to enable public registration")
		}
		freshState, err := h.Store.Get()
		if err == nil {
			state = freshState
		}
		node := h.publicDescriptor(state)
		if len(node.Endpoints) == 0 {
			return nil, errors.New("public endpoint is required")
		}
		for _, endpoint := range node.Endpoints {
			if !validEndpoint(endpoint) {
				return nil, errors.New("public endpoint is invalid")
			}
		}
		if err := h.managerForBaseURL(managerBaseURL).Register(ctx, node, &signed); err != nil {
			return nil, err
		}
		updated, err := h.Store.SetPublic(true, true, managerBaseURL, &signed)
		if err != nil {
			return nil, err
		}
		return map[string]any{"state": updated, "node": node}, nil
	}
	managerBaseURL, err := h.publicManagerBaseURL(req.ManagerBaseURL, state)
	if err != nil {
		return nil, err
	}
	if err := h.managerForBaseURL(managerBaseURL).Unregister(ctx, h.nodeID(state), state.PublicRegistrationProof); err != nil {
		return nil, err
	}
	updated, err := h.Store.SetPublic(false, false, "", nil)
	if err != nil {
		return nil, err
	}
	return map[string]any{"state": updated}, nil
}

func (h *Handler) publicManagerBaseURL(requested string, state State) (string, error) {
	for _, candidate := range []string{
		requested,
		state.PublicManagerURL,
		state.BootstrapManagerURL,
		h.Config.ManagerBaseURL,
	} {
		normalized, err := normalizeManagerBaseURL(candidate)
		if err != nil {
			return "", err
		}
		if normalized != "" {
			return normalized, nil
		}
	}
	return "", nil
}

func (h *Handler) bootstrapManagerBaseURL(requested string, state State) (string, error) {
	for _, candidate := range []string{
		requested,
		state.BootstrapManagerURL,
		state.PublicManagerURL,
		h.Config.ManagerBaseURL,
	} {
		normalized, err := normalizeManagerBaseURL(candidate)
		if err != nil {
			return "", err
		}
		if normalized != "" {
			return normalized, nil
		}
	}
	return "", nil
}

func (h *Handler) managerForBaseURL(baseURL string) ManagerClient {
	if manager, ok := h.Manager.(HTTPManagerClient); ok {
		manager.BaseURL = baseURL
		return manager
	}
	if manager, ok := h.Manager.(*HTTPManagerClient); ok {
		copied := *manager
		copied.BaseURL = baseURL
		return copied
	}
	return h.Manager
}

func (h *Handler) handlePresence(w http.ResponseWriter, r *http.Request) {
	state, signed, payload, ok := h.verifySignedRequest(w, r)
	if !ok {
		return
	}
	var req PresenceRequest
	if err := json.Unmarshal(payload, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
		return
	}
	if h.effectiveConfig(state).RelayPolicy == RelayPolicyOwnerOnly &&
		strings.TrimSpace(state.BoundPubkeyHex) != "" &&
		!strings.EqualFold(signed.PubkeyHex, state.BoundPubkeyHex) {
		writeError(w, http.StatusForbidden, "pubkey_not_bound", "")
		return
	}
	record, err := h.recordPresence(req)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
		return
	}
	if !h.isFederatedRequest(r) {
		h.fanoutSignedRequest("/api/v1/peers/presence", signed)
	}
	writeJSON(w, http.StatusOK, record)
}

func (h *Handler) handleProviders(w http.ResponseWriter, r *http.Request) {
	hash := strings.TrimSpace(r.URL.Query().Get("package_hash"))
	if hash == "" {
		writeError(w, http.StatusBadRequest, "invalid_payload", "package_hash required")
		return
	}
	now := time.Now().UTC()
	out := h.localProviders(hash, now)
	out = dedupeProviders(append(out, h.fetchFederatedProviders(r.Context(), hash)...))
	writeJSON(w, http.StatusOK, map[string]any{"items": out, "total": len(out)})
}

func (h *Handler) handlePackageRequest(w http.ResponseWriter, r *http.Request) {
	state, signed, payload, ok := h.verifySignedRequest(w, r)
	if !ok {
		return
	}
	var req PackageRequest
	if err := json.Unmarshal(payload, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
		return
	}
	record, err := h.recordPackageRequest(state, signed, req)
	if err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, errRelayForbidden) {
			status = http.StatusForbidden
		}
		writeError(w, status, "package_request_failed", err.Error())
		return
	}
	if !h.isFederatedRequest(r) {
		h.fanoutSignedRequest("/api/v1/package-requests", signed)
	}
	writeJSON(w, http.StatusOK, record)
}

func (h *Handler) handlePackageRequests(w http.ResponseWriter, r *http.Request) {
	hash := strings.TrimSpace(r.URL.Query().Get("package_hash"))
	if hash == "" {
		writeError(w, http.StatusBadRequest, "invalid_payload", "package_hash required")
		return
	}
	now := time.Now().UTC()
	out := h.localPackageRequests(hash, now)
	out = dedupePackageRequests(append(out, h.fetchFederatedPackageRequests(r.Context(), hash)...))
	writeJSON(w, http.StatusOK, map[string]any{"items": out, "total": len(out)})
}

func (h *Handler) handlePackageOffer(w http.ResponseWriter, r *http.Request) {
	state, signed, payload, ok := h.verifySignedRequest(w, r)
	if !ok {
		return
	}
	requestID := packageRequestIDFromPath(r.URL.Path, "/offers")
	if requestID == "" {
		writeError(w, http.StatusNotFound, "not_found", "")
		return
	}
	var offer PackageOffer
	if err := json.Unmarshal(payload, &offer); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
		return
	}
	record, err := h.recordPackageOffer(state, signed, requestID, offer)
	if err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, errRelayForbidden) {
			status = http.StatusForbidden
		} else if errors.Is(err, errRelayNotFound) || errors.Is(err, errRelayExpired) {
			status = http.StatusNotFound
		}
		writeError(w, status, "package_offer_failed", err.Error())
		return
	}
	if !h.isFederatedRequest(r) {
		h.fanoutSignedRequest("/api/v1/package-requests/"+requestID+"/offers", signed)
	}
	writeJSON(w, http.StatusOK, record)
}

func (h *Handler) handlePackageOffers(w http.ResponseWriter, r *http.Request) {
	requestID := packageRequestIDFromPath(r.URL.Path, "/offers")
	if requestID == "" {
		writeError(w, http.StatusNotFound, "not_found", "")
		return
	}
	now := time.Now().UTC()
	items, exists := h.localPackageOffers(requestID, now)
	if !exists {
		writeError(w, http.StatusNotFound, "package_request_not_found", "")
		return
	}
	items = dedupePackageOffers(append(items, h.fetchFederatedPackageOffers(r.Context(), requestID)...))
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "total": len(items)})
}

func (h *Handler) handleExperienceDemand(w http.ResponseWriter, r *http.Request) {
	state, signed, payload, ok := h.verifySignedRequest(w, r)
	if !ok {
		return
	}
	if !h.allowWriteWithinWindow("experience_demand", signed.PubkeyHex, time.Now().UTC(), maxExperienceDemandWritesPerWindow) {
		writeRateLimitError(w)
		return
	}
	var demand ExperienceDemand
	if err := json.Unmarshal(payload, &demand); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
		return
	}
	record, err := h.recordExperienceDemand(state, signed, demand, h.returnPathForRequest(r, state))
	if err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, errRelayForbidden) {
			status = http.StatusForbidden
		}
		writeError(w, status, "experience_demand_failed", err.Error())
		return
	}
	if !h.isFederatedRequest(r) {
		h.fanoutSignedRequestWithReturnPath("/api/v1/experience-demands", signed, record.ReturnPath)
	}
	writeJSON(w, http.StatusOK, record)
}

func (h *Handler) handleExperienceDemands(w http.ResponseWriter, r *http.Request) {
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	requestID := strings.TrimSpace(r.URL.Query().Get("request_id"))
	limit := intQuery(r, "limit", 100)
	now := time.Now().UTC()
	out := h.localExperienceDemands(query, requestID, now, limit)
	out = dedupeExperienceDemands(append(out, h.fetchFederatedExperienceDemands(r.Context(), query, requestID, limit)...))
	if len(out) > limit && limit > 0 {
		out = out[:limit]
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": out, "total": len(out)})
}

func (h *Handler) handleExperienceDemandOffer(w http.ResponseWriter, r *http.Request) {
	state, signed, payload, ok := h.verifySignedRequest(w, r)
	if !ok {
		return
	}
	if !h.allowWriteWithinWindow("experience_demand_offer", signed.PubkeyHex, time.Now().UTC(), maxDemandOfferWritesPerWindow) {
		writeRateLimitError(w)
		return
	}
	requestID := experienceDemandIDFromPath(r.URL.Path, "/offers")
	if requestID == "" {
		writeError(w, http.StatusNotFound, "not_found", "")
		return
	}
	var offer ExperienceDemandOffer
	if err := json.Unmarshal(payload, &offer); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
		return
	}
	record, err := h.recordExperienceDemandOffer(state, signed, requestID, offer)
	if err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, errRelayForbidden) {
			status = http.StatusForbidden
		} else if errors.Is(err, errRelayNotFound) || errors.Is(err, errRelayExpired) {
			status = http.StatusNotFound
		}
		writeError(w, status, "experience_demand_offer_failed", err.Error())
		return
	}
	if !h.isFederatedRequest(r) {
		h.fanoutSignedRequestWithReturnPath("/api/v1/experience-demands/"+requestID+"/offers", signed, record.ReturnPath)
	}
	writeJSON(w, http.StatusOK, record)
}

func (h *Handler) handleExperienceDemandOffers(w http.ResponseWriter, r *http.Request) {
	requestID := experienceDemandIDFromPath(r.URL.Path, "/offers")
	if requestID == "" {
		writeError(w, http.StatusNotFound, "not_found", "")
		return
	}
	now := time.Now().UTC()
	items, exists := h.localExperienceDemandOffers(requestID, now)
	if !exists {
		writeError(w, http.StatusNotFound, "experience_demand_not_found", "")
		return
	}
	items = dedupeExperienceDemandOffers(append(items, h.fetchFederatedExperienceDemandOffers(r.Context(), requestID)...))
	if len(items) == 0 {
		if demand, ok := h.localExperienceDemand(requestID, now); ok {
			items = dedupeExperienceDemandOffers(append(items, h.fetchManagerExperienceDemandOffers(r.Context(), requestID, demand, 5)...))
		}
	}
	if strings.EqualFold(strings.TrimSpace(r.URL.Query().Get("include_review_chain")), "false") {
		items = h.withoutInlineReviewChains(items)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "total": len(items)})
}

func (h *Handler) handleRelaySession(w http.ResponseWriter, r *http.Request) {
	state, signed, payload, ok := h.verifySignedRequest(w, r)
	if !ok {
		return
	}
	var req RelaySessionRequest
	if err := json.Unmarshal(payload, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
		return
	}
	session, err := h.createRelaySession(state, signed, req)
	if err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, errRelayForbidden) {
			status = http.StatusForbidden
		} else if errors.Is(err, errRelayUnavailable) {
			status = http.StatusServiceUnavailable
		}
		writeError(w, status, "relay_session_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, session)
}

func (h *Handler) handleRelayUpload(w http.ResponseWriter, r *http.Request) {
	sessionID := relaySessionIDFromPath(r.URL.Path)
	if sessionID == "" {
		writeError(w, http.StatusNotFound, "not_found", "")
		return
	}
	session, err := h.relaySessionForWrite(sessionID, time.Now().UTC())
	if err != nil {
		writeRelaySessionError(w, err)
		return
	}
	if r.ContentLength > session.MaxBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "relay_payload_too_large", "")
		return
	}
	reader := http.MaxBytesReader(w, r.Body, session.MaxBytes+1)
	payload, err := io.ReadAll(reader)
	if err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "relay_payload_too_large", err.Error())
		return
	}
	if int64(len(payload)) > session.MaxBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "relay_payload_too_large", "")
		return
	}
	updated, err := h.storeRelayPayload(sessionID, payload, time.Now().UTC())
	if err != nil {
		writeRelaySessionError(w, err)
		return
	}
	_, _ = h.storeCachedPackage(updated.PackageHash, updated.ExperienceID, payload, time.Now().UTC())
	writeJSON(w, http.StatusOK, updated)
}

func (h *Handler) handleRelayDownload(w http.ResponseWriter, r *http.Request) {
	sessionID := relaySessionIDFromPath(r.URL.Path)
	if sessionID == "" {
		writeError(w, http.StatusNotFound, "not_found", "")
		return
	}
	session, payload, err := h.relayPayload(sessionID, time.Now().UTC())
	if err != nil {
		writeRelaySessionError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-PH01-Relay-Session-ID", session.SessionID)
	w.Header().Set("X-PH01-Relay-Package-Hash", session.PackageHash)
	w.Header().Set("X-PH01-Relay-Payload-SHA256", session.PayloadSHA256)
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(payload)
}

func (h *Handler) handleHolePunchSession(w http.ResponseWriter, r *http.Request) {
	state, signed, payload, ok := h.verifySignedRequest(w, r)
	if !ok {
		return
	}
	var req HolePunchSessionRequest
	if err := json.Unmarshal(payload, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
		return
	}
	session, err := h.createHolePunchSession(state, signed, req)
	if err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, errHolePunchForbidden) {
			status = http.StatusForbidden
		} else if errors.Is(err, errHolePunchUnavailable) {
			status = http.StatusServiceUnavailable
		}
		writeError(w, status, "hole_punch_session_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, session)
}

func (h *Handler) handleHolePunchReport(w http.ResponseWriter, r *http.Request) {
	_, _, payload, ok := h.verifySignedRequest(w, r)
	if !ok {
		return
	}
	sessionID := holePunchSessionIDFromPath(r.URL.Path, "/reports")
	if sessionID == "" {
		writeError(w, http.StatusNotFound, "not_found", "")
		return
	}
	var report HolePunchReport
	if err := json.Unmarshal(payload, &report); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
		return
	}
	session, err := h.storeHolePunchReport(sessionID, report, time.Now().UTC())
	if err != nil {
		writeHolePunchError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, session)
}

func (h *Handler) handleHolePunchStatus(w http.ResponseWriter, r *http.Request) {
	sessionID := holePunchSessionIDFromPath(r.URL.Path, "")
	if sessionID == "" {
		writeError(w, http.StatusNotFound, "not_found", "")
		return
	}
	session, err := h.holePunchSession(sessionID, time.Now().UTC())
	if err != nil {
		writeHolePunchError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, session)
}

func (h *Handler) verifySignedRequest(w http.ResponseWriter, r *http.Request) (State, SignedRequest, json.RawMessage, bool) {
	var signed SignedRequest
	if err := json.NewDecoder(r.Body).Decode(&signed); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
		return State{}, SignedRequest{}, nil, false
	}
	now := time.Now().UTC()
	if err := VerifySignedRequest(signed, now); err != nil {
		writeError(w, http.StatusUnauthorized, "invalid_signature", err.Error())
		return State{}, SignedRequest{}, nil, false
	}
	if !h.acceptNonce(signed.PubkeyHex, signed.Nonce, now) {
		writeError(w, http.StatusUnauthorized, "nonce_replayed", "")
		return State{}, SignedRequest{}, nil, false
	}
	state, err := h.Store.Get()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return State{}, SignedRequest{}, nil, false
	}
	return state, signed, json.RawMessage(signed.Payload), true
}

func (h *Handler) acceptNonce(pubkeyHex, nonce string, now time.Time) bool {
	key := strings.ToLower(strings.TrimSpace(pubkeyHex)) + ":" + strings.TrimSpace(nonce)
	h.mu.Lock()
	defer h.mu.Unlock()
	for item, expiresAt := range h.nonces {
		if !expiresAt.After(now) {
			delete(h.nonces, item)
		}
	}
	if _, exists := h.nonces[key]; exists {
		return false
	}
	h.nonces[key] = now.Add(5 * time.Minute)
	return true
}

func (h *Handler) recordPresence(req PresenceRequest) (ProviderRecord, error) {
	if strings.TrimSpace(req.PeerID) == "" {
		return ProviderRecord{}, errors.New("peer_id required")
	}
	if len(req.Endpoints) == 0 {
		return ProviderRecord{}, errors.New("endpoints required")
	}
	for _, endpoint := range req.Endpoints {
		if !validEndpoint(endpoint) {
			return ProviderRecord{}, errors.New("endpoint invalid")
		}
	}
	ttl := h.Config.PeerTTL()
	if req.TTLSeconds > 0 {
		ttl = time.Duration(req.TTLSeconds) * time.Second
	}
	now := time.Now().UTC()
	record := ProviderRecord{
		PeerID:        strings.TrimSpace(req.PeerID),
		OwnerPeerID:   strings.TrimSpace(req.OwnerPeerID),
		Endpoints:     req.Endpoints,
		PackageHashes: normalizeStrings(req.PackageHashes),
		ExpiresAt:     now.Add(ttl).Format(time.RFC3339),
		UpdatedAt:     now.Format(time.RFC3339),
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.providers[record.PeerID] = record
	return record, nil
}

func (h *Handler) createRelaySession(state State, signed SignedRequest, req RelaySessionRequest) (RelaySession, error) {
	cfg := h.effectiveConfig(state)
	if !relayEnabled(cfg) {
		return RelaySession{}, errRelayUnavailable
	}
	if strings.TrimSpace(req.RequestID) == "" {
		return RelaySession{}, errors.New("request_id required")
	}
	if strings.TrimSpace(req.PackageHash) == "" {
		return RelaySession{}, errors.New("package_hash required")
	}
	if strings.TrimSpace(req.RequesterPeerID) == "" || strings.TrimSpace(req.ProviderPeerID) == "" {
		return RelaySession{}, errors.New("requester_peer_id and provider_peer_id required")
	}
	if err := h.authorizeRelay(state, signed, req); err != nil {
		return RelaySession{}, err
	}
	sessionID, err := randomSessionID()
	if err != nil {
		return RelaySession{}, err
	}
	ttl := h.Config.PeerTTL()
	if req.TTLSeconds > 0 {
		ttl = time.Duration(req.TTLSeconds) * time.Second
	}
	maxBytes := cfg.MaxRelayBytes()
	if req.MaxBytes > 0 && req.MaxBytes < maxBytes {
		maxBytes = req.MaxBytes
	}
	now := time.Now().UTC()
	session := RelaySession{
		SchemaVersion:   RelaySessionSchema,
		SessionID:       sessionID,
		RequestID:       strings.TrimSpace(req.RequestID),
		ExperienceID:    strings.TrimSpace(req.ExperienceID),
		PackageHash:     strings.TrimSpace(req.PackageHash),
		RequesterPeerID: strings.TrimSpace(req.RequesterPeerID),
		ProviderPeerID:  strings.TrimSpace(req.ProviderPeerID),
		ExpiresAt:       now.Add(ttl).Format(time.RFC3339),
		MaxBytes:        maxBytes,
		Status:          "open",
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.cleanupRelaySessionsLocked(now)
	if cfg.RelayCapacity > 0 && len(h.relay) >= cfg.RelayCapacity {
		return RelaySession{}, errRelayUnavailable
	}
	h.relay[sessionID] = relaySessionRecord{session: session}
	return session, nil
}

func relayEnabled(cfg Config) bool {
	if strings.TrimSpace(cfg.RelayPolicy) == RelayPolicyDisabled {
		return false
	}
	if cfg.Capabilities == nil {
		return true
	}
	enabled, ok := cfg.Capabilities["relay"]
	return !ok || enabled
}

func (h *Handler) authorizeRelay(state State, signed SignedRequest, req RelaySessionRequest) error {
	if strings.TrimSpace(h.effectiveConfig(state).RelayPolicy) != RelayPolicyOwnerOnly {
		return nil
	}
	if h.authorizeOwnerOnly(
		state,
		signed,
		req.RequesterPeerID,
		req.RequesterOwnerPeerID,
		req.ProviderPeerID,
		req.ProviderOwnerPeerID,
	) {
		return nil
	}
	return errRelayForbidden
}

func (h *Handler) authorizeOwnerOnly(
	state State,
	signed SignedRequest,
	requesterPeerID string,
	requesterOwnerPeerID string,
	providerPeerID string,
	providerOwnerPeerID string,
) bool {
	owner := strings.ToLower(strings.TrimSpace(state.BoundPubkeyHex))
	if owner == "" {
		return false
	}
	if strings.EqualFold(signed.PubkeyHex, owner) {
		return true
	}
	dhtPeer := h.nodeID(state)
	for _, peer := range []string{
		requesterPeerID,
		requesterOwnerPeerID,
		providerPeerID,
		providerOwnerPeerID,
	} {
		normalized := strings.TrimSpace(peer)
		if normalized == "" {
			continue
		}
		if strings.EqualFold(normalized, owner) || normalized == dhtPeer {
			return true
		}
	}
	return false
}

func (h *Handler) relaySessionForWrite(sessionID string, now time.Time) (RelaySession, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.cleanupRelaySessionsLocked(now)
	record, ok := h.relay[sessionID]
	if !ok {
		return RelaySession{}, errRelayNotFound
	}
	if relaySessionExpired(record.session, now) {
		delete(h.relay, sessionID)
		return RelaySession{}, errRelayExpired
	}
	return record.session, nil
}

func (h *Handler) storeRelayPayload(sessionID string, payload []byte, now time.Time) (RelaySession, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.cleanupRelaySessionsLocked(now)
	record, ok := h.relay[sessionID]
	if !ok {
		return RelaySession{}, errRelayNotFound
	}
	if relaySessionExpired(record.session, now) {
		delete(h.relay, sessionID)
		return RelaySession{}, errRelayExpired
	}
	copied := append([]byte(nil), payload...)
	sum := sha256.Sum256(copied)
	record.payload = copied
	record.session.Status = "uploaded"
	record.session.Bytes = int64(len(copied))
	record.session.PayloadSHA256 = hex.EncodeToString(sum[:])
	h.relay[sessionID] = record
	return record.session, nil
}

func (h *Handler) relayPayload(sessionID string, now time.Time) (RelaySession, []byte, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.cleanupRelaySessionsLocked(now)
	record, ok := h.relay[sessionID]
	if !ok {
		return RelaySession{}, nil, errRelayNotFound
	}
	if relaySessionExpired(record.session, now) {
		delete(h.relay, sessionID)
		return RelaySession{}, nil, errRelayExpired
	}
	if record.session.Status != "uploaded" {
		return RelaySession{}, nil, errRelayNotReady
	}
	return record.session, append([]byte(nil), record.payload...), nil
}

func (h *Handler) cleanupRelaySessionsLocked(now time.Time) {
	for id, record := range h.relay {
		if relaySessionExpired(record.session, now) {
			delete(h.relay, id)
		}
	}
}

func relaySessionExpired(session RelaySession, now time.Time) bool {
	expiresAt, err := time.Parse(time.RFC3339, session.ExpiresAt)
	return err != nil || !expiresAt.After(now)
}

func relaySessionIDFromPath(path string) string {
	rest := strings.TrimPrefix(path, "/api/v1/relay/sessions/")
	rest = strings.TrimSuffix(rest, "/package")
	rest = strings.Trim(rest, "/")
	if strings.Contains(rest, "/") {
		return ""
	}
	return rest
}

func randomSessionID() (string, error) {
	return randomSessionIDWithPrefix("relay_")
}

func randomSessionIDWithPrefix(prefix string) (string, error) {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return prefix + hex.EncodeToString(raw), nil
}

func writeRelaySessionError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, errRelayNotFound):
		writeError(w, http.StatusNotFound, "relay_session_not_found", err.Error())
	case errors.Is(err, errRelayExpired):
		writeError(w, http.StatusGone, "relay_session_expired", err.Error())
	case errors.Is(err, errRelayNotReady):
		writeError(w, http.StatusConflict, "relay_payload_not_ready", err.Error())
	default:
		writeError(w, http.StatusBadRequest, "relay_failed", err.Error())
	}
}

func (h *Handler) createHolePunchSession(state State, signed SignedRequest, req HolePunchSessionRequest) (HolePunchSession, error) {
	cfg := h.effectiveConfig(state)
	if !holePunchEnabled(cfg) {
		return HolePunchSession{}, errHolePunchUnavailable
	}
	if strings.TrimSpace(req.RequestID) == "" {
		return HolePunchSession{}, errors.New("request_id required")
	}
	if strings.TrimSpace(req.PackageHash) == "" {
		return HolePunchSession{}, errors.New("package_hash required")
	}
	if strings.TrimSpace(req.RequesterPeerID) == "" || strings.TrimSpace(req.ProviderPeerID) == "" {
		return HolePunchSession{}, errors.New("requester_peer_id and provider_peer_id required")
	}
	if err := validateEndpoints(req.RequesterAddrs); err != nil {
		return HolePunchSession{}, err
	}
	if err := validateEndpoints(req.ProviderAddrs); err != nil {
		return HolePunchSession{}, err
	}
	if strings.TrimSpace(cfg.RelayPolicy) == RelayPolicyOwnerOnly &&
		!h.authorizeOwnerOnly(
			state,
			signed,
			req.RequesterPeerID,
			req.RequesterOwnerPeerID,
			req.ProviderPeerID,
			req.ProviderOwnerPeerID,
		) {
		return HolePunchSession{}, errHolePunchForbidden
	}
	sessionID, err := randomSessionIDWithPrefix("hp_")
	if err != nil {
		return HolePunchSession{}, err
	}
	token, err := randomSessionIDWithPrefix("hp_token_")
	if err != nil {
		return HolePunchSession{}, err
	}
	ttl := h.Config.PeerTTL()
	if req.TTLSeconds > 0 {
		ttl = time.Duration(req.TTLSeconds) * time.Second
	}
	now := time.Now().UTC()
	session := HolePunchSession{
		SchemaVersion:   HolePunchSessionSchema,
		SessionID:       sessionID,
		RequestID:       strings.TrimSpace(req.RequestID),
		ExperienceID:    strings.TrimSpace(req.ExperienceID),
		PackageHash:     strings.TrimSpace(req.PackageHash),
		RequesterPeerID: strings.TrimSpace(req.RequesterPeerID),
		RequesterAddrs:  append([]Endpoint(nil), req.RequesterAddrs...),
		ProviderPeerID:  strings.TrimSpace(req.ProviderPeerID),
		ProviderAddrs:   append([]Endpoint(nil), req.ProviderAddrs...),
		PunchToken:      token,
		ExpiresAt:       now.Add(ttl).Format(time.RFC3339),
		Status:          "open",
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.cleanupHolePunchSessionsLocked(now)
	h.holePunch[sessionID] = holePunchSessionRecord{session: session}
	return session, nil
}

func holePunchEnabled(cfg Config) bool {
	if cfg.Capabilities == nil {
		return true
	}
	enabled, ok := cfg.Capabilities["hole_punch"]
	return !ok || enabled
}

func (h *Handler) storeHolePunchReport(sessionID string, report HolePunchReport, now time.Time) (HolePunchSession, error) {
	if err := validateHolePunchReport(report); err != nil {
		return HolePunchSession{}, err
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.cleanupHolePunchSessionsLocked(now)
	record, ok := h.holePunch[sessionID]
	if !ok {
		return HolePunchSession{}, errHolePunchNotFound
	}
	if holePunchSessionExpired(record.session, now) {
		delete(h.holePunch, sessionID)
		return HolePunchSession{}, errHolePunchExpired
	}
	normalized := report
	normalized.PeerID = strings.TrimSpace(report.PeerID)
	normalized.Role = strings.TrimSpace(report.Role)
	normalized.Result = strings.TrimSpace(report.Result)
	normalized.UpdatedAt = now.Format(time.RFC3339)
	switch normalized.Role {
	case "requester":
		if normalized.PeerID != record.session.RequesterPeerID {
			return HolePunchSession{}, errors.New("requester report peer mismatch")
		}
		record.session.RequesterReport = &normalized
	case "provider":
		if normalized.PeerID != record.session.ProviderPeerID {
			return HolePunchSession{}, errors.New("provider report peer mismatch")
		}
		record.session.ProviderReport = &normalized
	default:
		return HolePunchSession{}, errors.New("role must be requester or provider")
	}
	record.session.Status = mergeHolePunchStatus(record.session)
	h.holePunch[sessionID] = record
	return record.session, nil
}

func (h *Handler) holePunchSession(sessionID string, now time.Time) (HolePunchSession, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.cleanupHolePunchSessionsLocked(now)
	record, ok := h.holePunch[sessionID]
	if !ok {
		return HolePunchSession{}, errHolePunchNotFound
	}
	if holePunchSessionExpired(record.session, now) {
		delete(h.holePunch, sessionID)
		return HolePunchSession{}, errHolePunchExpired
	}
	return record.session, nil
}

func (h *Handler) cleanupHolePunchSessionsLocked(now time.Time) {
	for id, record := range h.holePunch {
		if holePunchSessionExpired(record.session, now) {
			delete(h.holePunch, id)
		}
	}
}

func validateHolePunchReport(report HolePunchReport) error {
	if strings.TrimSpace(report.PeerID) == "" {
		return errors.New("peer_id required")
	}
	result := strings.TrimSpace(report.Result)
	if result == "" {
		return errors.New("result required")
	}
	switch result {
	case "attempting", "succeeded", "failed":
	default:
		return errors.New("result must be attempting, succeeded, or failed")
	}
	if report.ObservedEndpoint != nil && !validEndpoint(*report.ObservedEndpoint) {
		return errors.New("observed_endpoint invalid")
	}
	return validateEndpoints(report.LocalEndpoints)
}

func validateEndpoints(endpoints []Endpoint) error {
	for _, endpoint := range endpoints {
		if !validEndpoint(endpoint) {
			return errors.New("endpoint invalid")
		}
	}
	return nil
}

func mergeHolePunchStatus(session HolePunchSession) string {
	reports := []*HolePunchReport{session.RequesterReport, session.ProviderReport}
	sawAttempt := false
	sawFailure := false
	for _, report := range reports {
		if report == nil {
			continue
		}
		switch report.Result {
		case "succeeded":
			return "succeeded"
		case "failed":
			sawFailure = true
		case "attempting":
			sawAttempt = true
		}
	}
	if sawFailure {
		return "failed"
	}
	if sawAttempt {
		return "attempting"
	}
	return "open"
}

func holePunchSessionExpired(session HolePunchSession, now time.Time) bool {
	expiresAt, err := time.Parse(time.RFC3339, session.ExpiresAt)
	return err != nil || !expiresAt.After(now)
}

func holePunchSessionIDFromPath(path string, suffix string) string {
	rest := strings.TrimPrefix(path, "/api/v1/hole-punch/sessions/")
	if suffix != "" {
		rest = strings.TrimSuffix(rest, suffix)
	}
	rest = strings.Trim(rest, "/")
	if strings.Contains(rest, "/") {
		return ""
	}
	return rest
}

func writeHolePunchError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, errHolePunchNotFound):
		writeError(w, http.StatusNotFound, "hole_punch_session_not_found", err.Error())
	case errors.Is(err, errHolePunchExpired):
		writeError(w, http.StatusGone, "hole_punch_session_expired", err.Error())
	default:
		writeError(w, http.StatusBadRequest, "hole_punch_failed", err.Error())
	}
}

func (h *Handler) recordPackageRequest(state State, signed SignedRequest, req PackageRequest) (PackageRequestRecord, error) {
	if strings.TrimSpace(req.RequestID) == "" {
		return PackageRequestRecord{}, errors.New("request_id required")
	}
	if strings.TrimSpace(req.PackageHash) == "" {
		return PackageRequestRecord{}, errors.New("package_hash required")
	}
	if strings.TrimSpace(req.RequesterPeerID) == "" {
		return PackageRequestRecord{}, errors.New("requester_peer_id required")
	}
	if err := validateEndpoints(req.RequesterAddrs); err != nil {
		return PackageRequestRecord{}, err
	}
	if strings.TrimSpace(h.effectiveConfig(state).RelayPolicy) == RelayPolicyOwnerOnly &&
		!h.authorizeOwnerOnly(
			state,
			signed,
			req.RequesterPeerID,
			req.RequesterOwnerPeerID,
			"",
			"",
		) {
		return PackageRequestRecord{}, errRelayForbidden
	}
	ttl := h.Config.PeerTTL()
	if req.TTLSeconds > 0 {
		ttl = time.Duration(req.TTLSeconds) * time.Second
	}
	now := time.Now().UTC()
	normalized := req
	normalized.SchemaVersion = nonEmpty(normalized.SchemaVersion, PackageRequestSchema)
	normalized.RequestID = strings.TrimSpace(req.RequestID)
	normalized.ExperienceID = strings.TrimSpace(req.ExperienceID)
	normalized.PackageHash = strings.TrimSpace(req.PackageHash)
	normalized.RequesterPeerID = strings.TrimSpace(req.RequesterPeerID)
	normalized.RequesterOwnerPeerID = strings.TrimSpace(req.RequesterOwnerPeerID)
	record := PackageRequestRecord{
		PackageRequest: normalized,
		ExpiresAt:      now.Add(ttl).Format(time.RFC3339),
		UpdatedAt:      now.Format(time.RFC3339),
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.cleanupPackageRequestsLocked(now)
	h.requests[record.RequestID] = record
	return record, nil
}

func (h *Handler) recordPackageOffer(state State, signed SignedRequest, requestID string, offer PackageOffer) (PackageOfferRecord, error) {
	if strings.TrimSpace(offer.ProviderPeerID) == "" {
		return PackageOfferRecord{}, errors.New("provider_peer_id required")
	}
	if err := validateEndpoints(offer.ProviderAddrs); err != nil {
		return PackageOfferRecord{}, err
	}
	now := time.Now().UTC()
	h.mu.Lock()
	defer h.mu.Unlock()
	h.cleanupPackageRequestsLocked(now)
	request, exists := h.requests[requestID]
	if !exists {
		return PackageOfferRecord{}, errRelayNotFound
	}
	if packageRequestExpired(request, now) {
		delete(h.requests, requestID)
		delete(h.offers, requestID)
		return PackageOfferRecord{}, errRelayExpired
	}
	if strings.TrimSpace(h.effectiveConfig(state).RelayPolicy) == RelayPolicyOwnerOnly &&
		!h.authorizeOwnerOnly(
			state,
			signed,
			request.RequesterPeerID,
			request.RequesterOwnerPeerID,
			offer.ProviderPeerID,
			offer.ProviderOwnerPeerID,
		) {
		return PackageOfferRecord{}, errRelayForbidden
	}
	normalized := offer
	normalized.SchemaVersion = nonEmpty(normalized.SchemaVersion, PackageOfferSchema)
	normalized.RequestID = request.RequestID
	normalized.ExperienceID = nonEmpty(strings.TrimSpace(offer.ExperienceID), request.ExperienceID)
	normalized.PackageHash = nonEmpty(strings.TrimSpace(offer.PackageHash), request.PackageHash)
	normalized.ProviderPeerID = strings.TrimSpace(offer.ProviderPeerID)
	normalized.ProviderOwnerPeerID = strings.TrimSpace(offer.ProviderOwnerPeerID)
	if normalized.PackageHash != request.PackageHash {
		return PackageOfferRecord{}, errors.New("package_hash mismatch")
	}
	record := PackageOfferRecord{
		PackageOffer: normalized,
		OfferedAt:    now.Format(time.RFC3339),
	}
	h.offers[requestID] = append(h.offers[requestID], record)
	return record, nil
}

func (h *Handler) recordExperienceDemand(state State, signed SignedRequest, demand ExperienceDemand, returnPath []DemandReturnHop) (ExperienceDemandRecord, error) {
	if strings.TrimSpace(demand.RequestID) == "" {
		return ExperienceDemandRecord{}, errors.New("request_id required")
	}
	if strings.TrimSpace(demand.NaturalLanguageQuery) == "" {
		return ExperienceDemandRecord{}, errors.New("natural_language_query required")
	}
	if strings.TrimSpace(demand.RequesterPeerID) == "" {
		return ExperienceDemandRecord{}, errors.New("requester_peer_id required")
	}
	if strings.TrimSpace(h.effectiveConfig(state).RelayPolicy) == RelayPolicyOwnerOnly &&
		!h.authorizeOwnerOnly(
			state,
			signed,
			demand.RequesterPeerID,
			demand.RequesterOwnerPeerID,
			"",
			"",
		) {
		return ExperienceDemandRecord{}, errRelayForbidden
	}
	ttl := h.Config.PeerTTL()
	if demand.TTLSeconds > 0 {
		ttl = time.Duration(demand.TTLSeconds) * time.Second
	}
	now := time.Now().UTC()
	requesterHash := strings.ToLower(strings.TrimSpace(demand.RequesterPubkeyHash))
	if requesterHash == "" {
		if hash, err := PubkeyHash(signed.PubkeyHex); err == nil {
			requesterHash = hash
		}
	}
	normalized := demand
	normalized.SchemaVersion = nonEmpty(normalized.SchemaVersion, ExperienceDemandSchema)
	normalized.RequestID = strings.TrimSpace(demand.RequestID)
	normalized.NaturalLanguageQuery = strings.TrimSpace(demand.NaturalLanguageQuery)
	normalized.QueryLanguage = strings.TrimSpace(demand.QueryLanguage)
	normalized.QueryKeywords = normalizeStrings(demand.QueryKeywords)
	normalized.RequesterPeerID = strings.TrimSpace(demand.RequesterPeerID)
	normalized.RequesterOwnerPeerID = strings.TrimSpace(demand.RequesterOwnerPeerID)
	normalized.RequesterPubkeyHash = requesterHash
	normalized.PreferredTransports = normalizeStrings(demand.PreferredTransports)
	normalized.HopLimit = normalizeDemandHopLimit(demand.HopLimit)
	normalized.ReturnPath = normalizeDemandReturnPath(returnPath)
	if len(normalized.ReturnPath) == 0 {
		normalized.ReturnPath = normalizeDemandReturnPath(demand.ReturnPath)
	}
	normalized.CreatedAt = strings.TrimSpace(demand.CreatedAt)
	if normalized.CreatedAt == "" {
		normalized.CreatedAt = now.Format(time.RFC3339)
	}
	record := ExperienceDemandRecord{
		ExperienceDemand: normalized,
		ExpiresAt:        now.Add(ttl).Format(time.RFC3339),
		UpdatedAt:        now.Format(time.RFC3339),
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.cleanupExperienceDemandsLocked(now)
	h.demands[record.RequestID] = record
	return record, nil
}

func (h *Handler) recordExperienceDemandOffer(state State, signed SignedRequest, requestID string, offer ExperienceDemandOffer) (ExperienceDemandOfferRecord, error) {
	if strings.TrimSpace(offer.ProviderPeerID) == "" {
		return ExperienceDemandOfferRecord{}, errors.New("provider_peer_id required")
	}
	if strings.TrimSpace(offer.ExperienceID) == "" {
		return ExperienceDemandOfferRecord{}, errors.New("experience_id required")
	}
	if strings.TrimSpace(offer.PackageHash) == "" {
		return ExperienceDemandOfferRecord{}, errors.New("package_hash required")
	}
	if len(offer.ReviewChain) == 0 {
		return ExperienceDemandOfferRecord{}, errors.New("review_chain required")
	}
	if err := validateEndpoints(offer.ProviderAddrs); err != nil {
		return ExperienceDemandOfferRecord{}, err
	}
	now := time.Now().UTC()
	h.mu.Lock()
	defer h.mu.Unlock()
	h.cleanupExperienceDemandsLocked(now)
	demand, exists := h.demands[requestID]
	if !exists {
		return ExperienceDemandOfferRecord{}, errRelayNotFound
	}
	if experienceDemandExpired(demand, now) {
		delete(h.demands, requestID)
		delete(h.demandOffers, requestID)
		return ExperienceDemandOfferRecord{}, errRelayExpired
	}
	if strings.TrimSpace(h.effectiveConfig(state).RelayPolicy) == RelayPolicyOwnerOnly &&
		!h.authorizeOwnerOnly(
			state,
			signed,
			demand.RequesterPeerID,
			demand.RequesterOwnerPeerID,
			offer.ProviderPeerID,
			offer.ProviderOwnerPeerID,
		) {
		return ExperienceDemandOfferRecord{}, errRelayForbidden
	}
	normalized := offer
	normalized.SchemaVersion = nonEmpty(normalized.SchemaVersion, DemandOfferSchema)
	normalized.RequestID = demand.RequestID
	normalized.ExperienceID = strings.TrimSpace(offer.ExperienceID)
	normalized.PackageHash = strings.TrimSpace(offer.PackageHash)
	normalized.Title = strings.TrimSpace(offer.Title)
	normalized.Brief = strings.TrimSpace(offer.Brief)
	normalized.Keywords = normalizeStrings(offer.Keywords)
	normalized.MatchedReason = strings.TrimSpace(offer.MatchedReason)
	normalized.ProviderPeerID = strings.TrimSpace(offer.ProviderPeerID)
	normalized.ProviderOwnerPeerID = strings.TrimSpace(offer.ProviderOwnerPeerID)
	normalized.ProviderAddrs = append([]Endpoint(nil), offer.ProviderAddrs...)
	normalized.AvailableTransports = normalizeStrings(offer.AvailableTransports)
	normalized.ReturnPath = normalizeDemandReturnPath(offer.ReturnPath)
	if len(normalized.ReturnPath) == 0 {
		normalized.ReturnPath = append([]DemandReturnHop(nil), demand.ReturnPath...)
	}
	normalized.RelaySessionID = strings.TrimSpace(offer.RelaySessionID)
	if normalized.ReviewChainLength <= 0 {
		normalized.ReviewChainLength = len(normalized.ReviewChain)
	}
	if strings.TrimSpace(normalized.ReviewChainDigest) == "" {
		normalized.ReviewChainDigest = digestReviewChain(normalized.ReviewChain)
	}
	if strings.TrimSpace(normalized.ReviewChainDigest) != "" {
		normalized.ReviewChainRef = &ReviewChainRef{
			Digest: normalized.ReviewChainDigest,
			Length: normalized.ReviewChainLength,
			URL:    "/api/v1/review-chains/" + strings.TrimPrefix(normalized.ReviewChainDigest, "sha256:"),
		}
		h.reviewChains[normalized.ReviewChainDigest] = reviewChainRecord{
			Digest:      normalized.ReviewChainDigest,
			Length:      normalized.ReviewChainLength,
			ReviewChain: append([]map[string]any(nil), normalized.ReviewChain...),
			UpdatedAt:   now.Format(time.RFC3339),
		}
	}
	record := ExperienceDemandOfferRecord{
		ExperienceDemandOffer: normalized,
		OfferedAt:             now.Format(time.RFC3339),
	}
	h.demandOffers[requestID] = append(h.demandOffers[requestID], record)
	return record, nil
}

func (h *Handler) withoutInlineReviewChains(items []ExperienceDemandOfferRecord) []ExperienceDemandOfferRecord {
	out := make([]ExperienceDemandOfferRecord, 0, len(items))
	now := time.Now().UTC().Format(time.RFC3339)
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, item := range items {
		if strings.TrimSpace(item.ReviewChainDigest) == "" && len(item.ReviewChain) > 0 {
			item.ReviewChainDigest = digestReviewChain(item.ReviewChain)
		}
		if item.ReviewChainLength <= 0 {
			item.ReviewChainLength = len(item.ReviewChain)
		}
		if strings.TrimSpace(item.ReviewChainDigest) != "" && len(item.ReviewChain) > 0 {
			h.reviewChains[item.ReviewChainDigest] = reviewChainRecord{
				Digest:      item.ReviewChainDigest,
				Length:      item.ReviewChainLength,
				ReviewChain: append([]map[string]any(nil), item.ReviewChain...),
				UpdatedAt:   now,
			}
		}
		if strings.TrimSpace(item.ReviewChainDigest) != "" && item.ReviewChainRef == nil {
			item.ReviewChainRef = &ReviewChainRef{
				Digest: item.ReviewChainDigest,
				Length: item.ReviewChainLength,
				URL:    "/api/v1/review-chains/" + strings.TrimPrefix(item.ReviewChainDigest, "sha256:"),
			}
		}
		item.ReviewChain = nil
		out = append(out, item)
	}
	return out
}

func (h *Handler) cleanupExperienceDemandsLocked(now time.Time) {
	for id, record := range h.demands {
		if experienceDemandExpired(record, now) {
			delete(h.demands, id)
			delete(h.demandOffers, id)
		}
	}
}

func experienceDemandExpired(record ExperienceDemandRecord, now time.Time) bool {
	expiresAt, err := time.Parse(time.RFC3339, record.ExpiresAt)
	return err != nil || !expiresAt.After(now)
}

func experienceDemandIDFromPath(path string, suffix string) string {
	rest := strings.TrimPrefix(path, "/api/v1/experience-demands/")
	if suffix != "" {
		rest = strings.TrimSuffix(rest, suffix)
	}
	rest = strings.Trim(rest, "/")
	if strings.Contains(rest, "/") {
		return ""
	}
	return rest
}

func normalizeDemandHopLimit(value int) int {
	if value <= 0 {
		return 8
	}
	if value > 32 {
		return 32
	}
	return value
}

func normalizeDemandReturnPath(hops []DemandReturnHop) []DemandReturnHop {
	out := make([]DemandReturnHop, 0, len(hops))
	seen := map[string]bool{}
	for _, hop := range hops {
		nodeID := strings.TrimSpace(hop.NodeID)
		if nodeID == "" {
			continue
		}
		apiBaseURL := strings.TrimSpace(hop.APIBaseURL)
		key := nodeID + "|" + apiBaseURL
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, DemandReturnHop{
			NodeID:     nodeID,
			APIBaseURL: apiBaseURL,
			SeenAt:     strings.TrimSpace(hop.SeenAt),
		})
		if len(out) >= maxDemandReturnPathHops {
			break
		}
	}
	return out
}

func appendDemandReturnHop(hops []DemandReturnHop, hop DemandReturnHop) []DemandReturnHop {
	hops = normalizeDemandReturnPath(hops)
	if strings.TrimSpace(hop.NodeID) == "" {
		return hops
	}
	for _, existing := range hops {
		if strings.EqualFold(existing.NodeID, hop.NodeID) {
			return hops
		}
	}
	return normalizeDemandReturnPath(append(hops, hop))
}

func (h *Handler) returnPathForRequest(r *http.Request, state State) []DemandReturnHop {
	var hops []DemandReturnHop
	if raw := strings.TrimSpace(r.Header.Get(demandReturnPathHeader)); raw != "" {
		_ = json.Unmarshal([]byte(raw), &hops)
	}
	return appendDemandReturnHop(hops, h.returnPathHop(state))
}

func (h *Handler) returnPathHop(state State) DemandReturnHop {
	node := h.publicDescriptor(state)
	apiBaseURL, _ := apiBaseURLFromNode(node)
	return DemandReturnHop{
		NodeID:     h.nodeID(state),
		APIBaseURL: apiBaseURL,
		SeenAt:     nowRFC3339(),
	}
}

func digestReviewChain(chain []map[string]any) string {
	data, err := json.Marshal(chain)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(data)
	return "sha256:" + hex.EncodeToString(sum[:])
}

func (h *Handler) cleanupPackageRequestsLocked(now time.Time) {
	for id, record := range h.requests {
		if packageRequestExpired(record, now) {
			delete(h.requests, id)
			delete(h.offers, id)
		}
	}
}

func (h *Handler) allowWriteWithinWindow(scope, pubkeyHex string, now time.Time, limit int) bool {
	if limit <= 0 {
		return true
	}
	identity := strings.ToLower(strings.TrimSpace(pubkeyHex))
	if hash, err := PubkeyHash(pubkeyHex); err == nil {
		identity = hash
	}
	if identity == "" {
		return false
	}
	key := scope + "|" + identity
	h.mu.Lock()
	defer h.mu.Unlock()
	window := h.rateWindows[key]
	if window.StartedAt.IsZero() || !window.StartedAt.Add(demandWriteRateWindow).After(now) {
		window = rateWindow{StartedAt: now}
	}
	if window.Count >= limit {
		h.rateWindows[key] = window
		return false
	}
	window.Count++
	h.rateWindows[key] = window
	h.cleanupRateWindowsLocked(now)
	return true
}

func (h *Handler) cleanupRateWindowsLocked(now time.Time) {
	if len(h.rateWindows) < 4096 {
		return
	}
	cutoff := now.Add(-2 * demandWriteRateWindow)
	for key, window := range h.rateWindows {
		if window.StartedAt.Before(cutoff) {
			delete(h.rateWindows, key)
		}
	}
}

func packageRequestExpired(record PackageRequestRecord, now time.Time) bool {
	expiresAt, err := time.Parse(time.RFC3339, record.ExpiresAt)
	return err != nil || !expiresAt.After(now)
}

func packageRequestIDFromPath(path string, suffix string) string {
	rest := strings.TrimPrefix(path, "/api/v1/package-requests/")
	if suffix != "" {
		rest = strings.TrimSuffix(rest, suffix)
	}
	rest = strings.Trim(rest, "/")
	if strings.Contains(rest, "/") {
		return ""
	}
	return rest
}

func nonEmpty(value string, fallback string) string {
	if strings.TrimSpace(value) != "" {
		return strings.TrimSpace(value)
	}
	return fallback
}

func (h *Handler) publicDescriptor(state State) NodeDescriptor {
	return NodeDescriptorFromConfig(h.effectiveConfig(state), state)
}

func (h *Handler) nodeID(state State) string {
	if strings.TrimSpace(state.NodeID) != "" {
		return strings.TrimSpace(state.NodeID)
	}
	return strings.TrimSpace(h.Config.NodeID)
}

func (h *Handler) effectiveConfig(state State) Config {
	cfg := h.Config
	cfg.NodeID = h.nodeID(state)
	runtime := state.RuntimeConfig
	if strings.TrimSpace(runtime.PublicAPIBaseURL) != "" {
		cfg.PublicAPIBaseURL = strings.TrimSpace(runtime.PublicAPIBaseURL)
	}
	if strings.TrimSpace(runtime.PublicNetwork) != "" {
		cfg.PublicNetwork = strings.TrimSpace(runtime.PublicNetwork)
	}
	if strings.TrimSpace(runtime.PublicHost) != "" {
		cfg.PublicHost = strings.TrimSpace(runtime.PublicHost)
	}
	if runtime.PublicPort > 0 {
		cfg.PublicPort = runtime.PublicPort
	}
	if len(runtime.CandidateEndpoints) > 0 {
		cfg.CandidateEndpoints = append([]Endpoint(nil), runtime.CandidateEndpoints...)
	}
	if strings.TrimSpace(runtime.OwnerKind) != "" {
		cfg.OwnerKind = strings.TrimSpace(runtime.OwnerKind)
	}
	if strings.TrimSpace(runtime.Region) != "" {
		cfg.Region = strings.TrimSpace(runtime.Region)
	}
	if strings.TrimSpace(runtime.RelayPolicy) != "" {
		cfg.RelayPolicy = strings.TrimSpace(runtime.RelayPolicy)
	}
	if runtime.RelayCapacity > 0 {
		cfg.RelayCapacity = runtime.RelayCapacity
	}
	if runtime.Capabilities != nil {
		cfg.Capabilities = runtime.Capabilities
	}
	if cfg.Capabilities == nil {
		cfg.Capabilities = defaultCapabilities()
	}
	if strings.TrimSpace(cfg.PublicNetwork) == "" {
		cfg.PublicNetwork = "udp"
	}
	if strings.TrimSpace(cfg.OwnerKind) == "" {
		cfg.OwnerKind = OwnerKindUser
	}
	if strings.TrimSpace(cfg.RelayPolicy) == "" {
		cfg.RelayPolicy = RelayPolicyOwnerOnly
	}
	return cfg
}

func (h *Handler) normalizeRuntimeConfig(runtime RuntimeConfig) (RuntimeConfig, error) {
	out := RuntimeConfig{
		PublicAPIBaseURL:   strings.TrimSpace(runtime.PublicAPIBaseURL),
		PublicNetwork:      strings.TrimSpace(runtime.PublicNetwork),
		PublicHost:         strings.TrimSpace(runtime.PublicHost),
		PublicPort:         runtime.PublicPort,
		CandidateEndpoints: append([]Endpoint(nil), runtime.CandidateEndpoints...),
		OwnerKind:          strings.TrimSpace(runtime.OwnerKind),
		Region:             strings.TrimSpace(runtime.Region),
		RelayPolicy:        strings.TrimSpace(runtime.RelayPolicy),
		RelayCapacity:      runtime.RelayCapacity,
		Capabilities:       runtime.Capabilities,
	}
	if out.PublicAPIBaseURL != "" {
		cfg := Config{PublicAPIBaseURL: out.PublicAPIBaseURL}
		if _, ok := publicAPIEndpointFromConfig(cfg); !ok {
			return RuntimeConfig{}, errors.New("public_api_base_url must be http or https URL")
		}
	}
	if out.PublicNetwork == "" && out.PublicHost != "" {
		out.PublicNetwork = "udp"
	}
	if out.PublicHost != "" || out.PublicPort > 0 {
		legacyEndpoint := normalizeEndpoint(Endpoint{Network: nonEmpty(out.PublicNetwork, "udp"), Host: out.PublicHost, Port: out.PublicPort})
		if !validEndpoint(legacyEndpoint) {
			return RuntimeConfig{}, errors.New("public endpoint is invalid")
		}
		if len(out.CandidateEndpoints) == 0 {
			out.CandidateEndpoints = []Endpoint{legacyEndpoint}
		}
	}
	if len(out.CandidateEndpoints) > 0 {
		normalizedEndpoints, err := normalizeRuntimeCandidateEndpoints(out.CandidateEndpoints)
		if err != nil {
			return RuntimeConfig{}, err
		}
		out.CandidateEndpoints = normalizedEndpoints
	}
	if out.OwnerKind != "" && out.OwnerKind != OwnerKindUser && out.OwnerKind != OwnerKindOfficial {
		return RuntimeConfig{}, errors.New("owner_kind must be user or official")
	}
	if out.RelayPolicy != "" && out.RelayPolicy != RelayPolicyOwnerOnly && out.RelayPolicy != RelayPolicyPublic && out.RelayPolicy != RelayPolicyDisabled {
		return RuntimeConfig{}, errors.New("relay_policy must be owner_only, public, or disabled")
	}
	if out.RelayCapacity < 0 {
		return RuntimeConfig{}, errors.New("relay_capacity must be non-negative")
	}
	if out.Capabilities == nil && !runtimeConfigEmpty(out) {
		out.Capabilities = defaultCapabilities()
	}
	return out, nil
}

func runtimeConfigEmpty(runtime RuntimeConfig) bool {
	return strings.TrimSpace(runtime.PublicAPIBaseURL) == "" &&
		strings.TrimSpace(runtime.PublicNetwork) == "" &&
		strings.TrimSpace(runtime.PublicHost) == "" &&
		runtime.PublicPort == 0 &&
		len(runtime.CandidateEndpoints) == 0 &&
		strings.TrimSpace(runtime.OwnerKind) == "" &&
		strings.TrimSpace(runtime.Region) == "" &&
		strings.TrimSpace(runtime.RelayPolicy) == "" &&
		runtime.RelayCapacity == 0 &&
		len(runtime.Capabilities) == 0
}

func normalizeRuntimeCandidateEndpoints(endpoints []Endpoint) ([]Endpoint, error) {
	out := make([]Endpoint, 0, len(endpoints))
	seen := map[string]bool{}
	for _, endpoint := range endpoints {
		normalized := normalizeEndpoint(endpoint)
		if !validEndpoint(normalized) {
			return nil, errors.New("candidate endpoint is invalid")
		}
		switch normalized.Network {
		case "udp", "udp4", "udp6", "quic":
		default:
			return nil, errors.New("candidate endpoint network must be udp, udp4, udp6, or quic")
		}
		key := normalized.Network + "|" + strings.ToLower(normalized.Host) + "|" + strconv.Itoa(normalized.Port)
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, normalized)
	}
	return out, nil
}

func defaultCapabilities() map[string]bool {
	return map[string]bool{
		"peer_discovery":         true,
		"hole_punch":             true,
		"quic":                   true,
		"relay":                  true,
		"package_provider_index": true,
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, ErrorResponse{Error: code, Message: message})
}

func writeRateLimitError(w http.ResponseWriter) {
	w.Header().Set("Retry-After", strconv.Itoa(int(demandWriteRateWindow.Seconds())))
	writeError(w, http.StatusTooManyRequests, "rate_limited", "experience demand write rate limit exceeded")
}

func normalizeStrings(in []string) []string {
	out := make([]string, 0, len(in))
	seen := map[string]bool{}
	for _, item := range in {
		item = strings.TrimSpace(item)
		if item == "" || seen[item] {
			continue
		}
		seen[item] = true
		out = append(out, item)
	}
	return out
}

func hasString(items []string, target string) bool {
	for _, item := range items {
		if item == target {
			return true
		}
	}
	return false
}
