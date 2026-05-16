package hub

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"strconv"
	"strings"
	"time"

	"ph01-experience-hub/internal/governance"
)

type Handler struct {
	Store          *Store
	Governance     *governance.Service
	DHTHealth      DHTHealthChecker
	AuthCenter     AuthCenterConfig
	Review         ReviewConfig
	AdminVerifier  AuthCenterAdminVerifier
	DelegatedPow   DelegatedPowClient
	AdminToken     string
	CORSOrigins    []string
	MaxUploadBytes int64
}

type uploadPrincipal struct {
	AuthorizedHubAdmin bool
	TrustedAdmin       bool
	ReviewedBy         string
	ReviewedRole       string
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h.writeCORS(w)
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.URL.Path == "/healthz" {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "service": "experience-network-manager"})
		return
	}
	if h.handlePublicGovernance(w, r) {
		return
	}
	if strings.HasPrefix(r.URL.Path, "/api/v1/dht/trust") || strings.HasPrefix(r.URL.Path, "/api/v1/dht/flowers") || strings.HasPrefix(r.URL.Path, "/api/v1/dht/wreaths") {
		h.handleDHTTrust(w, r)
		return
	}
	if strings.HasPrefix(r.URL.Path, "/api/v1/dht/review-chain") {
		h.handleDHTReviewChain(w, r)
		return
	}
	if strings.HasPrefix(r.URL.Path, "/api/v1/dht/experience-demands") {
		h.handleDHTExperienceDemands(w, r)
		return
	}
	if strings.HasPrefix(r.URL.Path, "/api/v1/dht/nodes") {
		h.handleDHTNodes(w, r)
		return
	}
	if r.URL.Path == "/api/v1/experiences/package-pow/challenge" && r.Method == http.MethodPost {
		h.handleExperiencePackagePowChallenge(w, r)
		return
	}
	if r.URL.Path == "/api/v1/experiences" && r.Method == http.MethodPost {
		h.handleExperienceUpload(w, r)
		return
	}
	if h.handlePublicReviewedExperienceAsset(w, r) {
		return
	}
	if !h.authorized(r) {
		writeError(w, http.StatusUnauthorized, "invalid_admin_token", "")
		return
	}

	switch {
	case r.URL.Path == "/api/v1/experiences":
		h.handleExperiences(w, r)
	case r.URL.Path == "/api/v1/search":
		h.handleSearch(w, r)
	case strings.HasPrefix(r.URL.Path, "/api/v1/experiences/"):
		h.handleExperienceByID(w, r)
	case r.URL.Path == "/api/v1/vfs/index":
		h.handleVFSIndex(w, r)
	case r.URL.Path == "/api/v1/governance/veto_blocks/sign" || r.URL.Path == "/api/v1/veto_blocks/sign":
		h.handleSignVetoBlock(w, r)
	default:
		writeError(w, http.StatusNotFound, "not_found", "")
	}
}

func (h *Handler) handlePublicReviewedExperienceAsset(w http.ResponseWriter, r *http.Request) bool {
	if !strings.HasPrefix(r.URL.Path, "/api/v1/experiences/") {
		return false
	}
	rest := strings.TrimPrefix(r.URL.Path, "/api/v1/experiences/")
	parts := strings.Split(rest, "/")
	if len(parts) < 2 || parts[0] == "" {
		return false
	}
	action := parts[1]
	if action != "package" && action != "review-materials" && action != "review-chain" {
		return false
	}
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "")
		return true
	}
	id := parts[0]
	entry, err := h.Store.Get(id)
	if err != nil {
		status, code := classifyStoreErr(err)
		writeError(w, status, code, err.Error())
		return true
	}
	if entry.Status != StatusNetwork {
		writeError(w, http.StatusNotFound, "not_found", "")
		return true
	}
	switch action {
	case "package":
		data, err := h.Store.ReviewedPackageBytes(id)
		if err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return true
		}
		w.Header().Set("Content-Type", "application/zip")
		w.Header().Set("Content-Disposition", `attachment; filename="`+id+`.hxp"`)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(data)
	case "review-materials":
		data, err := h.Store.ReviewMaterials(id)
		if err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return true
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(data)
	case "review-chain":
		chain, err := h.Store.ReviewChain(id)
		if err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return true
		}
		writeJSON(w, http.StatusOK, chain)
	}
	return true
}

func (h *Handler) handleDHTReviewChain(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/api/v1/dht/review-chain/plan" && r.Method == http.MethodGet:
		limit := 1
		if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
			parsed, err := strconv.Atoi(raw)
			if err != nil {
				writeError(w, http.StatusBadRequest, "invalid_payload", "invalid limit")
				return
			}
			limit = parsed
		}
		plan, err := h.Store.ReviewChainRefreshPlan(timeNowUTC(), limit)
		if err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, plan)
	case r.URL.Path == "/api/v1/dht/review-chain/candidates" && r.Method == http.MethodPost:
		var candidate ExperienceReviewChain
		if err := json.NewDecoder(r.Body).Decode(&candidate); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
			return
		}
		stored, err := h.Store.AcceptReviewChainCandidate(candidate)
		if err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, stored)
	default:
		writeError(w, http.StatusNotFound, "not_found", "")
	}
}

func (h *Handler) handleDHTExperienceDemands(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/api/v1/dht/experience-demands/resolve" && r.Method == http.MethodGet:
		limit := 5
		if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
			parsed, err := strconv.Atoi(raw)
			if err != nil {
				writeError(w, http.StatusBadRequest, "invalid_payload", "invalid limit")
				return
			}
			limit = parsed
		}
		items, err := h.Store.ResolveExperienceDemandOffers(
			r.URL.Query().Get("request_id"),
			r.URL.Query().Get("q"),
			limit,
			timeNowUTC(),
		)
		if err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"items": items, "total": len(items)})
	default:
		writeError(w, http.StatusNotFound, "not_found", "")
	}
}

func (h *Handler) handleDHTNodes(w http.ResponseWriter, r *http.Request) {
	const basePath = "/api/v1/dht/nodes"
	switch {
	case r.URL.Path == basePath && r.Method == http.MethodGet:
		items, err := h.Store.ListDHTNodes(timeNowUTC())
		if err != nil {
			writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"items": items, "total": len(items)})
	case r.URL.Path == basePath+"/register" && r.Method == http.MethodPost:
		var req DHTRegisterRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
			return
		}
		now := timeNowUTC()
		node, err := NewDHTNodeFromRegister(req, now, h.authorized(r))
		if err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return
		}
		if node.OwnerKind != DHTOwnerKindOfficial {
			if err := validateDHTOwnershipProof(node, req.AdminSignedRequest); err != nil {
				writeError(w, http.StatusUnauthorized, "invalid_dht_ownership_proof", err.Error())
				return
			}
		}
		health := h.dhtHealthChecker().CheckDHTNode(r.Context(), node)
		node.HealthStatus = normalizeDHTHealthStatus(health.Status)
		node.LastHealthCheckAt = now.Format(time.RFC3339)
		stored, err := h.Store.UpsertDHTNode(node)
		if err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, stored)
	case r.URL.Path == basePath+"/register":
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "")
	case strings.HasPrefix(r.URL.Path, basePath+"/") && r.Method == http.MethodDelete:
		nodeID := strings.TrimPrefix(r.URL.Path, basePath+"/")
		if strings.Contains(nodeID, "/") || nodeID == "" {
			writeError(w, http.StatusNotFound, "not_found", "")
			return
		}
		var proof SignedRequest
		if err := json.NewDecoder(r.Body).Decode(&proof); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
			return
		}
		node, err := h.Store.GetDHTNode(nodeID)
		if err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return
		}
		if node.OwnerKind != DHTOwnerKindOfficial {
			if err := validateDHTOwnershipProof(node, &proof); err != nil {
				writeError(w, http.StatusUnauthorized, "invalid_dht_ownership_proof", err.Error())
				return
			}
		}
		if err := h.Store.DeleteDHTNode(nodeID); err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "node_id": nodeID})
	case r.URL.Path == basePath || strings.HasPrefix(r.URL.Path, basePath+"/"):
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "")
	default:
		writeError(w, http.StatusNotFound, "not_found", "")
	}
}

func (h *Handler) dhtHealthChecker() DHTHealthChecker {
	if h.DHTHealth != nil {
		return h.DHTHealth
	}
	return DefaultDHTHealthChecker{}
}

func (h *Handler) handleDHTTrust(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/api/v1/dht/flowers" && r.Method == http.MethodPost:
		var flower DHTServiceFlower
		if err := json.NewDecoder(r.Body).Decode(&flower); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
			return
		}
		stored, err := h.Store.AppendDHTServiceFlower(flower)
		if err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, stored)
	case r.URL.Path == "/api/v1/dht/wreaths/aggregate" && r.Method == http.MethodPost:
		var req struct {
			NodeID string `json:"node_id"`
			Limit  int    `json:"limit,omitempty"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
			return
		}
		nodeID := strings.TrimSpace(req.NodeID)
		flowers, err := h.Store.ListDHTServiceFlowers(nodeID, req.Limit)
		if err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return
		}
		flowers, err = h.filterDHTFlowersByAuthCenter(r, flowers)
		if err != nil {
			writeError(w, http.StatusBadGateway, "auth_center_failed", err.Error())
			return
		}
		wreath, err := BuildDHTServiceWreath(nodeID, flowers, h.Governance)
		if err == nil {
			wreath, err = h.Store.AppendDHTServiceWreath(wreath)
		}
		if err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, wreath)
	case strings.HasPrefix(r.URL.Path, "/api/v1/dht/trust/") && r.Method == http.MethodGet:
		nodeID := strings.TrimPrefix(r.URL.Path, "/api/v1/dht/trust/")
		if strings.Contains(nodeID, "/") || nodeID == "" {
			writeError(w, http.StatusNotFound, "not_found", "")
			return
		}
		bundle, err := h.Store.DHTTrustBundle(nodeID)
		if err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, bundle)
	default:
		writeError(w, http.StatusNotFound, "not_found", "")
	}
}

func (h *Handler) filterDHTFlowersByAuthCenter(r *http.Request, flowers []DHTServiceFlower) ([]DHTServiceFlower, error) {
	if strings.TrimSpace(h.AuthCenter.BaseURL) == "" || len(flowers) == 0 {
		return flowers, nil
	}
	hashes := make([]string, 0, len(flowers))
	seen := map[string]struct{}{}
	for _, flower := range flowers {
		hash := strings.ToLower(strings.TrimSpace(flower.ClientPubkeyHash))
		if hash == "" {
			continue
		}
		if _, ok := seen[hash]; ok {
			continue
		}
		seen[hash] = struct{}{}
		hashes = append(hashes, hash)
	}
	statuses, err := FetchAuthCenterPubkeyStatuses(r.Context(), h.AuthCenter, hashes)
	if err != nil {
		return nil, err
	}
	out := make([]DHTServiceFlower, 0, len(flowers))
	for _, flower := range flowers {
		status := statuses[strings.ToLower(strings.TrimSpace(flower.ClientPubkeyHash))]
		if status.Valid && status.PowVerified {
			out = append(out, flower)
		}
	}
	return out, nil
}

func (h *Handler) handlePublicGovernance(w http.ResponseWriter, r *http.Request) bool {
	if h.Governance == nil {
		return false
	}
	switch r.URL.Path {
	case "/api/v1/governance/root/certificate", "/api/v1/root/certificate":
		if r.Method != http.MethodGet {
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "")
			return true
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(h.Governance.RootCertificateRaw)
		return true
	case "/api/v1/governance/master/certificate", "/api/v1/master/certificate":
		if r.Method != http.MethodGet {
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "")
			return true
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(h.Governance.MasterCertificateRaw)
		return true
	default:
		return false
	}
}

func (h *Handler) handleExperiences(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		items, err := h.Store.List(ListFilter{
			Status:  r.URL.Query().Get("status"),
			Keyword: r.URL.Query().Get("keyword"),
			Query:   r.URL.Query().Get("q"),
		})
		if err != nil {
			writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"items": items, "total": len(items)})
	case http.MethodPost:
		h.handleExperienceUpload(w, r)
	default:
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "")
	}
}

func (h *Handler) handleExperiencePackagePowChallenge(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "")
		return
	}
	var req ExperiencePackagePowChallengeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
		return
	}
	if experienceID := strings.TrimSpace(req.ExperienceID); experienceID != "" {
		if !idPattern.MatchString(experienceID) {
			writeError(w, http.StatusBadRequest, "invalid_payload", "experience_id invalid")
			return
		}
		if existing, err := h.Store.Get(experienceID); err == nil {
			writeDuplicateExperienceEntry(w, existing)
			return
		} else if !errors.Is(err, ErrNotFound) {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return
		}
	}
	packageSHA256, err := normalizeHex64(req.PackageSHA256)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_payload", "package_sha256 invalid")
		return
	}
	pubkeyHash, err := normalizeHex64(req.PubkeyHash)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_payload", "pubkey_hash invalid")
		return
	}
	subjectHash := ExperiencePackagePowSubjectHash(packageSHA256, pubkeyHash)
	client := h.delegatedPowClient()
	challenge, err := client.CreateDelegatedPowChallenge(r.Context(), h.AuthCenter, ExperiencePackagePowPurpose, subjectHash, pubkeyHash)
	if err != nil {
		writeError(w, http.StatusBadGateway, "experience_pow_challenge_failed", err.Error())
		return
	}
	if strings.TrimSpace(challenge.ChallengeID) == "" {
		writeError(w, http.StatusBadGateway, "experience_pow_challenge_failed", "auth-center did not return challenge_id")
		return
	}
	writeJSON(w, http.StatusOK, ExperiencePackagePowChallengeResponse{
		ChallengeID: challenge.ChallengeID,
		ExpiresAt:   challenge.ExpiresAt,
	})
}

func (h *Handler) handleExperienceUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "")
		return
	}
	hubAdminUpload := h.authorized(r)
	signedUpload := !hubAdminUpload && isJSONContentType(r.Header.Get("Content-Type"))
	hasBearer := bearerToken(r) != ""
	if !hubAdminUpload && !signedUpload && !hasBearer {
		writeError(w, http.StatusUnauthorized, "invalid_admin_token", "")
		return
	}
	limit := h.MaxUploadBytes
	if limit <= 0 {
		limit = 512 << 20
	}
	body := http.MaxBytesReader(w, r.Body, limit)
	data, err := io.ReadAll(body)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
		return
	}
	var packagePow *ExperiencePackagePow
	signedPubkeyHash := ""
	if signedUpload {
		decoded, err := decodeSignedExperienceUpload(data, timeNowUTC())
		if err != nil {
			statusCode, code := classifySignedUploadErr(err)
			writeError(w, statusCode, code, err.Error())
			return
		}
		data = decoded.PackageBytes
		packagePow = decoded.Payload.PackagePow
		signedPubkeyHash = decoded.PubkeyHash
	} else {
		packagePow = experiencePackagePowFromHeaders(r.Header)
	}
	if err := h.verifyUploadPackagePow(r, data, packagePow, signedPubkeyHash); err != nil {
		writeError(w, err.Status, err.Code, err.Message)
		return
	}
	principal := uploadPrincipal{AuthorizedHubAdmin: hubAdminUpload}
	if signedUpload {
		principal = h.signedUploadPrincipal(r, signedPubkeyHash)
	} else if !hubAdminUpload {
		var ok bool
		principal, ok = h.authCenterUploadPrincipal(r)
		if !ok {
			writeError(w, http.StatusUnauthorized, "invalid_admin_token", "")
			return
		}
	}

	status := strings.TrimSpace(r.URL.Query().Get("status"))
	if signedUpload {
		status = StatusInbox
	}
	if principal.TrustedAdmin {
		status = StatusNetwork
	}
	if status == StatusNetwork {
		if h.Governance == nil {
			writeError(w, http.StatusServiceUnavailable, "governance_not_configured", "network uploads require governance signing")
			return
		}
		entry, err := h.Store.ImportZip(data, StatusInbox)
		if err != nil {
			if writeDuplicateExperienceUpload(w, err) {
				return
			}
			statusCode, code := classifyStoreErr(err)
			writeError(w, statusCode, code, err.Error())
			return
		}
		reviewMode := "manual_review"
		reason := "approved on upload"
		if principal.TrustedAdmin {
			reviewMode = "trusted_admin_upload"
			reason = "trusted admin upload"
		}
		req := ReviewRequest{
			Status:       StatusNetwork,
			Reason:       reason,
			ReviewMode:   reviewMode,
			ReviewedBy:   principal.ReviewedBy,
			ReviewedRole: principal.ReviewedRole,
		}
		materials, err := h.reviewMaterialsFor(entry.ExperienceID, req)
		if err != nil {
			writeError(w, http.StatusBadRequest, "review_signing_failed", err.Error())
			return
		}
		entry, err = h.Store.Review(entry.ExperienceID, req, materials)
		if err != nil {
			statusCode, code := classifyStoreErr(err)
			writeError(w, statusCode, code, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, entry)
		return
	}

	entry, err := h.Store.ImportZip(data, status)
	if err != nil {
		if writeDuplicateExperienceUpload(w, err) {
			return
		}
		statusCode, code := classifyStoreErr(err)
		writeError(w, statusCode, code, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, entry)
}

type uploadPackagePowError struct {
	Status  int
	Code    string
	Message string
}

func (e uploadPackagePowError) Error() string {
	return e.Message
}

func experiencePackagePowFromHeaders(header http.Header) *ExperiencePackagePow {
	challengeID := strings.TrimSpace(header.Get("X-PH01-Experience-Pow-Challenge-Id"))
	if challengeID == "" {
		challengeID = strings.TrimSpace(header.Get("X-PH01-Experience-Pow-Id"))
	}
	pubkeyHash := strings.TrimSpace(header.Get("X-PH01-Experience-Pow-Pubkey-Hash"))
	packageSHA256 := strings.TrimSpace(header.Get("X-PH01-Experience-Pow-Package-SHA256"))
	if challengeID == "" && pubkeyHash == "" && packageSHA256 == "" {
		return nil
	}
	return &ExperiencePackagePow{
		ChallengeID:   challengeID,
		PackageSHA256: packageSHA256,
		PubkeyHash:    pubkeyHash,
	}
}

func (h *Handler) verifyUploadPackagePow(r *http.Request, packageBytes []byte, proof *ExperiencePackagePow, signedPubkeyHash string) *uploadPackagePowError {
	if proof == nil || strings.TrimSpace(proof.ChallengeID) == "" {
		return &uploadPackagePowError{Status: http.StatusBadRequest, Code: "experience_pow_required", Message: "experience package pow required"}
	}
	packageHash := sha256Hex(packageBytes)
	proof.PackageSHA256 = strings.ToLower(strings.TrimSpace(proof.PackageSHA256))
	if proof.PackageSHA256 == "" {
		proof.PackageSHA256 = packageHash
	}
	if !strings.EqualFold(proof.PackageSHA256, packageHash) {
		return &uploadPackagePowError{Status: http.StatusBadRequest, Code: "experience_pow_package_mismatch", Message: "experience package pow package_sha256 mismatch"}
	}
	proof.PubkeyHash = strings.ToLower(strings.TrimSpace(proof.PubkeyHash))
	if proof.PubkeyHash == "" {
		return &uploadPackagePowError{Status: http.StatusBadRequest, Code: "experience_pow_required", Message: "experience package pow pubkey_hash required"}
	}
	if signedPubkeyHash != "" && !strings.EqualFold(proof.PubkeyHash, signedPubkeyHash) {
		return &uploadPackagePowError{Status: http.StatusBadRequest, Code: "experience_pow_pubkey_mismatch", Message: "experience package pow pubkey_hash mismatch signed upload pubkey"}
	}
	subjectHash := ExperiencePackagePowSubjectHash(packageHash, proof.PubkeyHash)
	status, err := h.delegatedPowClient().FetchDelegatedPowStatus(
		r.Context(),
		h.AuthCenter,
		strings.TrimSpace(proof.ChallengeID),
		ExperiencePackagePowPurpose,
		subjectHash,
		proof.PubkeyHash,
	)
	if err != nil {
		return &uploadPackagePowError{Status: http.StatusBadGateway, Code: "experience_pow_status_failed", Message: err.Error()}
	}
	if !status.Verified {
		return &uploadPackagePowError{Status: http.StatusForbidden, Code: "experience_pow_incomplete", Message: "experience package pow is not verified"}
	}
	if !strings.EqualFold(status.SubjectHash, subjectHash) || !strings.EqualFold(status.PubkeyHash, proof.PubkeyHash) {
		return &uploadPackagePowError{Status: http.StatusForbidden, Code: "experience_pow_incomplete", Message: "experience package pow status does not match upload"}
	}
	return nil
}

func (h *Handler) handleSearch(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "")
		return
	}
	limit := 50
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid_payload", "invalid limit")
			return
		}
		limit = parsed
	}
	items, err := h.Store.SearchContent(SearchFilter{
		Status: r.URL.Query().Get("status"),
		Query:  r.URL.Query().Get("q"),
		Limit:  limit,
	})
	if err != nil {
		status, code := classifyStoreErr(err)
		writeError(w, status, code, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "total": len(items)})
}

func (h *Handler) handleExperienceByID(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/api/v1/experiences/")
	parts := strings.Split(rest, "/")
	if len(parts) == 0 || parts[0] == "" {
		writeError(w, http.StatusNotFound, "not_found", "")
		return
	}
	id := parts[0]
	action := ""
	if len(parts) > 1 {
		action = parts[1]
	}
	switch {
	case action == "" && r.Method == http.MethodGet:
		entry, err := h.Store.Get(id)
		if err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, entry)
	case action == "file" && r.Method == http.MethodGet:
		data, cleanPath, err := h.Store.ReadFile(id, r.URL.Query().Get("path"))
		if err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return
		}
		w.Header().Set("Content-Type", contentTypeFor(cleanPath))
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(data)
	case action == "package" && r.Method == http.MethodGet:
		data, err := h.Store.ReviewedPackageBytes(id)
		if err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return
		}
		w.Header().Set("Content-Type", "application/zip")
		w.Header().Set("Content-Disposition", `attachment; filename="`+id+`.hxp"`)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(data)
	case action == "review-materials" && r.Method == http.MethodGet:
		data, err := h.Store.ReviewMaterials(id)
		if err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(data)
	case action == "review-chain" && r.Method == http.MethodGet:
		chain, err := h.Store.ReviewChain(id)
		if err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, chain)
	case action == "review" && r.Method == http.MethodPost:
		var req ReviewRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
			return
		}
		materials, err := h.reviewMaterialsFor(id, req)
		if err != nil {
			writeError(w, http.StatusBadRequest, "review_signing_failed", err.Error())
			return
		}
		entry, err := h.Store.Review(id, req, materials)
		if err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, entry)
	default:
		writeError(w, http.StatusNotFound, "not_found", "")
	}
}

func (h *Handler) reviewMaterialsFor(id string, req ReviewRequest) ([]byte, error) {
	if strings.TrimSpace(req.Status) != StatusNetwork || h.Governance == nil {
		return nil, nil
	}
	info, err := h.Store.PackageInfo(id)
	if err != nil {
		return nil, err
	}
	publisher, err := DecodePublisherInfo(info.PublisherData)
	if err != nil {
		return nil, err
	}
	packageHash := strings.TrimSpace(publisher.PackageHash)
	if packageHash == "" {
		packageHash = info.Manifest.ContentHash
	}
	if packageHash != "" && !strings.EqualFold(packageHash, info.Manifest.ContentHash) {
		return nil, errors.New("publisher package_hash does not match package.zip hash")
	}
	if err := VerifyPublisherInfo(publisher, info.Manifest.ContentHash); err != nil {
		return nil, err
	}
	reviewMode := strings.TrimSpace(req.ReviewMode)
	if reviewMode == "" {
		reviewMode = "manual_review"
	}
	materials, err := h.Governance.SignReview(governance.ReviewSignRequest{
		ExperienceID:    id,
		PackageHash:     info.Manifest.ContentHash,
		PublisherPubkey: publisher.PublisherPubkey,
		ReviewMode:      reviewMode,
	})
	if err != nil {
		return nil, err
	}
	return json.MarshalIndent(materials, "", "  ")
}

func (h *Handler) handleVFSIndex(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "")
		return
	}
	data, err := h.Store.VirtualIndex()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	w.Header().Set("Content-Type", "text/markdown; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(data))
}

func (h *Handler) handleSignVetoBlock(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "")
		return
	}
	if h.Governance == nil {
		writeError(w, http.StatusServiceUnavailable, "governance_not_configured", "")
		return
	}
	var req governance.VetoSignRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
		return
	}
	resp, err := h.Governance.SignVetoBlock(req)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func (h *Handler) authorized(r *http.Request) bool {
	if h.AdminToken == "" {
		return true
	}
	const prefix = "Bearer "
	auth := r.Header.Get("Authorization")
	return strings.HasPrefix(auth, prefix) && strings.TrimPrefix(auth, prefix) == h.AdminToken
}

func (h *Handler) authCenterUploadPrincipal(r *http.Request) (uploadPrincipal, bool) {
	token := bearerToken(r)
	if token == "" {
		return uploadPrincipal{}, false
	}
	admin, err := h.adminVerifier().VerifyAdminSession(r.Context(), h.AuthCenter, token)
	if err != nil || !admin.IsAdmin() {
		return uploadPrincipal{}, false
	}
	reviewedBy := admin.Username
	if reviewedBy == "" && admin.ID > 0 {
		reviewedBy = strconv.FormatUint(admin.ID, 10)
	}
	return uploadPrincipal{
		TrustedAdmin: h.Review.TrustAdminUploads,
		ReviewedBy:   reviewedBy,
		ReviewedRole: strings.ToLower(strings.TrimSpace(admin.Role)),
	}, true
}

func (h *Handler) signedUploadPrincipal(r *http.Request, pubkeyHash string) uploadPrincipal {
	hash := strings.ToLower(strings.TrimSpace(pubkeyHash))
	if !h.Review.TrustAdminUploads || hash == "" {
		return uploadPrincipal{}
	}
	statuses, err := FetchAuthCenterPubkeyStatuses(r.Context(), h.AuthCenter, []string{hash})
	if err != nil {
		return uploadPrincipal{}
	}
	status, ok := statuses[hash]
	if !ok || !status.Valid || !status.HasAdminRole() {
		return uploadPrincipal{}
	}
	reviewedBy := strings.TrimSpace(status.Username)
	if reviewedBy == "" && status.UserID > 0 {
		reviewedBy = strconv.FormatUint(status.UserID, 10)
	}
	return uploadPrincipal{
		TrustedAdmin: h.Review.TrustAdminUploads,
		ReviewedBy:   reviewedBy,
		ReviewedRole: strings.ToLower(strings.TrimSpace(status.Role)),
	}
}

func (h *Handler) adminVerifier() AuthCenterAdminVerifier {
	if h.AdminVerifier != nil {
		return h.AdminVerifier
	}
	return HTTPAuthCenterAdminVerifier{}
}

func (h *Handler) delegatedPowClient() DelegatedPowClient {
	if h.DelegatedPow != nil {
		return h.DelegatedPow
	}
	return HTTPDelegatedPowClient{}
}

func bearerToken(r *http.Request) string {
	const prefix = "Bearer "
	auth := r.Header.Get("Authorization")
	if !strings.HasPrefix(auth, prefix) {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(auth, prefix))
}

func isJSONContentType(value string) bool {
	if value == "" {
		return false
	}
	contentType, _, err := mime.ParseMediaType(value)
	if err != nil {
		return strings.Contains(strings.ToLower(value), "json")
	}
	contentType = strings.ToLower(contentType)
	return contentType == "application/json" || strings.HasSuffix(contentType, "+json")
}

func normalizeHex64(value string) (string, error) {
	value = strings.ToLower(strings.TrimSpace(value))
	if len(value) != 64 {
		return "", errors.New("hex value must be 64 chars")
	}
	if _, err := hex.DecodeString(value); err != nil {
		return "", err
	}
	return value, nil
}

func (h *Handler) writeCORS(w http.ResponseWriter) {
	origin := "*"
	if len(h.CORSOrigins) > 0 {
		origin = h.CORSOrigins[0]
	}
	w.Header().Set("Access-Control-Allow-Origin", origin)
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
}

func classifyStoreErr(err error) (int, string) {
	switch {
	case errors.Is(err, ErrDuplicateExperience):
		return http.StatusConflict, "experience_already_submitted"
	case errors.Is(err, ErrNotFound):
		return http.StatusNotFound, "experience_not_found"
	case errors.Is(err, ErrInvalidID), errors.Is(err, ErrInvalidStatus),
		errors.Is(err, ErrMissingPackageZip), errors.Is(err, ErrMissingPublisherJSON),
		errors.Is(err, ErrMissingRatingsDat), errors.Is(err, ErrInvalidPackageZip),
		errors.Is(err, ErrInvalidQuery), errors.Is(err, ErrInvalidDHTNode),
		errors.Is(err, ErrInvalidDHTNodePow), errors.Is(err, ErrInvalidDHTFlower),
		errors.Is(err, ErrInvalidDHTWreath):
		return http.StatusBadRequest, "invalid_payload"
	default:
		return http.StatusInternalServerError, "internal_error"
	}
}

func classifySignedUploadErr(err error) (int, string) {
	switch {
	case errors.Is(err, errSignedUploadTimestampExpired):
		return http.StatusUnauthorized, "timestamp_expired"
	case errors.Is(err, errSignedUploadInvalidSignature):
		return http.StatusUnauthorized, "invalid_signature"
	case errors.Is(err, errSignedUploadPackageHashFailed):
		return http.StatusBadRequest, "invalid_payload"
	default:
		return http.StatusBadRequest, "invalid_payload"
	}
}

func timeNowUTC() time.Time {
	return time.Now().UTC()
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, ErrorResponse{Error: code, Message: message})
}

func writeDuplicateExperienceUpload(w http.ResponseWriter, err error) bool {
	var duplicate *DuplicateExperienceError
	if !errors.As(err, &duplicate) {
		return false
	}
	writeDuplicateExperienceEntry(w, duplicate.Entry)
	return true
}

func writeDuplicateExperienceEntry(w http.ResponseWriter, entry IndexEntry) {
	writeJSON(w, http.StatusConflict, map[string]any{
		"error":             "experience_already_submitted",
		"message":           "experience already submitted",
		"already_submitted": true,
		"experience_id":     entry.ExperienceID,
		"title":             entry.Title,
		"status":            entry.Status,
		"path":              entry.Path,
		"package_path":      entry.PackagePath,
		"content_hash":      entry.ContentHash,
		"review_reason":     entry.ReviewReason,
	})
}

func contentTypeFor(path string) string {
	if strings.HasSuffix(path, ".md") {
		return "text/markdown; charset=utf-8"
	}
	if strings.HasSuffix(path, ".json") {
		return "application/json; charset=utf-8"
	}
	if idx := strings.LastIndex(path, "."); idx >= 0 {
		if typ := mime.TypeByExtension(path[idx:]); typ != "" {
			return typ
		}
	}
	return "application/octet-stream"
}
