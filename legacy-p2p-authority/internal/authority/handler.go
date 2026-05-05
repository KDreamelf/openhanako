// Package authority 提供 P2P 网络治理接口。
package authority

import (
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"slices"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/hanako/legacy-p2p-authority/internal/rootkey"
)

type Handler struct {
	Root       *rootkey.RootKey
	AdminToken string
}

type VetoSignRequest struct {
	TargetExperienceID string   `json:"target_experience_id"`
	VetoTarget         string   `json:"veto_target"`
	VetoedPubkeys      []string `json:"vetoed_pubkeys,omitempty"`
	VetoedDAGNodes     []string `json:"vetoed_dag_nodes,omitempty"`
	Reason             string   `json:"reason"`
	PrevHashes         []string `json:"prev_hashes"`
	Timestamp          string   `json:"timestamp,omitempty"`
}

type VetoBlock struct {
	Type                string   `json:"type"`
	TargetExperienceID  string   `json:"target_experience_id"`
	VetoTarget          string   `json:"veto_target"`
	VetoedPubkeys       []string `json:"vetoed_pubkeys,omitempty"`
	VetoedDAGNodes      []string `json:"vetoed_dag_nodes,omitempty"`
	Reason              string   `json:"reason"`
	PrevHashes          []string `json:"prev_hashes"`
	Timestamp           string   `json:"timestamp"`
	RootKeyID           string   `json:"root_key_id"`
	RootAlgorithm       string   `json:"root_algorithm"`
	MasterRootSignature string   `json:"master_root_signature"`
}

type vetoPayload struct {
	Type               string   `json:"type"`
	TargetExperienceID string   `json:"target_experience_id"`
	VetoTarget         string   `json:"veto_target"`
	VetoedPubkeys      []string `json:"vetoed_pubkeys,omitempty"`
	VetoedDAGNodes     []string `json:"vetoed_dag_nodes,omitempty"`
	Reason             string   `json:"reason"`
	PrevHashes         []string `json:"prev_hashes"`
	Timestamp          string   `json:"timestamp"`
	RootKeyID          string   `json:"root_key_id"`
	RootAlgorithm      string   `json:"root_algorithm"`
}

func (h *Handler) Register(r *gin.Engine) {
	r.GET("/healthz", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"ok": true, "service": "p2p-authority"})
	})
	api := r.Group("/api/v1")
	api.GET("/root/certificate", h.HandleRootCertificate)
	admin := api.Group("")
	admin.Use(h.authMiddleware)
	admin.POST("/veto_blocks/sign", h.HandleSignVetoBlock)
}

func (h *Handler) HandleRootCertificate(c *gin.Context) {
	c.JSON(http.StatusOK, h.Root.Certificate())
}

func (h *Handler) HandleSignVetoBlock(c *gin.Context) {
	var req VetoSignRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		errorJSON(c, http.StatusBadRequest, "invalid_payload", err.Error())
		return
	}
	if req.TargetExperienceID == "" {
		errorJSON(c, http.StatusBadRequest, "invalid_payload", "target_experience_id is required")
		return
	}
	if !slices.Contains([]string{"ratings", "experience", "veto"}, req.VetoTarget) {
		errorJSON(c, http.StatusBadRequest, "invalid_payload", "veto_target must be ratings, experience, or veto")
		return
	}
	if req.Reason == "" {
		errorJSON(c, http.StatusBadRequest, "invalid_payload", "reason is required")
		return
	}
	if len(req.PrevHashes) == 0 {
		errorJSON(c, http.StatusBadRequest, "invalid_payload", "prev_hashes is required")
		return
	}
	timestamp := req.Timestamp
	if timestamp == "" {
		timestamp = time.Now().UTC().Format(time.RFC3339)
	}

	payload := vetoPayload{
		Type:               "veto_block",
		TargetExperienceID: req.TargetExperienceID,
		VetoTarget:         req.VetoTarget,
		VetoedPubkeys:      req.VetoedPubkeys,
		VetoedDAGNodes:     req.VetoedDAGNodes,
		Reason:             req.Reason,
		PrevHashes:         req.PrevHashes,
		Timestamp:          timestamp,
		RootKeyID:          h.Root.KeyID,
		RootAlgorithm:      rootkey.Algorithm,
	}
	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	signature, err := h.Root.Sign(payloadBytes)
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"veto_block": VetoBlock{
			Type:                payload.Type,
			TargetExperienceID:  payload.TargetExperienceID,
			VetoTarget:          payload.VetoTarget,
			VetoedPubkeys:       payload.VetoedPubkeys,
			VetoedDAGNodes:      payload.VetoedDAGNodes,
			Reason:              payload.Reason,
			PrevHashes:          payload.PrevHashes,
			Timestamp:           payload.Timestamp,
			RootKeyID:           payload.RootKeyID,
			RootAlgorithm:       payload.RootAlgorithm,
			MasterRootSignature: signature,
		},
		"signature_payload": json.RawMessage(payloadBytes),
	})
}

func (h *Handler) authMiddleware(c *gin.Context) {
	header := c.GetHeader("Authorization")
	const prefix = "Bearer "
	if len(header) <= len(prefix) || header[:len(prefix)] != prefix {
		errorJSON(c, http.StatusUnauthorized, "missing_bearer", "")
		c.Abort()
		return
	}
	token := header[len(prefix):]
	if subtle.ConstantTimeCompare([]byte(token), []byte(h.AdminToken)) != 1 {
		errorJSON(c, http.StatusUnauthorized, "invalid_admin_token", "")
		c.Abort()
		return
	}
	c.Next()
}

func errorJSON(c *gin.Context, status int, code, msg string) {
	c.JSON(status, gin.H{"error": code, "message": msg})
}
