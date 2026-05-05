package hub

import (
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"strconv"
	"strings"

	"ph01-experience-hub/internal/governance"
)

type Handler struct {
	Store          *Store
	Governance     *governance.Service
	AdminToken     string
	CORSOrigins    []string
	MaxUploadBytes int64
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
		entry, err := h.Store.ImportZip(data, r.URL.Query().Get("status"))
		if err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, entry)
	default:
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "")
	}
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
		data, err := h.Store.PackageBytes(id)
		if err != nil {
			status, code := classifyStoreErr(err)
			writeError(w, status, code, err.Error())
			return
		}
		w.Header().Set("Content-Type", "application/zip")
		w.Header().Set("Content-Disposition", `attachment; filename="`+id+`.hxp"`)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(data)
	case action == "review" && r.Method == http.MethodPost:
		var req ReviewRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_payload", err.Error())
			return
		}
		entry, err := h.Store.Review(id, req)
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

func (h *Handler) writeCORS(w http.ResponseWriter) {
	origin := "*"
	if len(h.CORSOrigins) > 0 {
		origin = h.CORSOrigins[0]
	}
	w.Header().Set("Access-Control-Allow-Origin", origin)
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
}

func classifyStoreErr(err error) (int, string) {
	switch {
	case errors.Is(err, ErrNotFound):
		return http.StatusNotFound, "experience_not_found"
	case errors.Is(err, ErrInvalidID), errors.Is(err, ErrInvalidStatus),
		errors.Is(err, ErrMissingPackageZip), errors.Is(err, ErrMissingPublisherJSON),
		errors.Is(err, ErrMissingRatingsDat), errors.Is(err, ErrInvalidPackageZip),
		errors.Is(err, ErrInvalidQuery):
		return http.StatusBadRequest, "invalid_payload"
	default:
		return http.StatusInternalServerError, "internal_error"
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
