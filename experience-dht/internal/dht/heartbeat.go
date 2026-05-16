package dht

import (
	"context"
	"log"
	"strings"
	"time"
)

func (h *Handler) RunHeartbeat(ctx context.Context) {
	ticker := time.NewTicker(h.Config.HeartbeatInterval())
	defer ticker.Stop()
	h.heartbeat(ctx)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			h.heartbeat(ctx)
		}
	}
}

func (h *Handler) heartbeat(ctx context.Context) {
	state, err := h.Store.Get()
	if err != nil {
		log.Printf("[warn] dht heartbeat read state: %v", err)
		return
	}
	if !state.PublicEnabled {
		return
	}
	managerBaseURL, err := h.publicManagerBaseURL("", state)
	if err != nil {
		log.Printf("[warn] dht public registration skipped: invalid manager_base_url: %v", err)
		return
	}
	if strings.TrimSpace(managerBaseURL) == "" {
		log.Printf("[warn] dht public registration skipped: manager_base_url is empty")
		return
	}
	node := h.publicDescriptor(state)
	if err := h.managerForBaseURL(managerBaseURL).Register(ctx, node, state.PublicRegistrationProof); err != nil {
		log.Printf("[warn] dht heartbeat register failed: %v", err)
		return
	}
	if !state.PublicRegistered || !state.PublicEnabled {
		if _, err := h.Store.SetPublic(true, true, managerBaseURL, state.PublicRegistrationProof); err != nil {
			log.Printf("[warn] dht heartbeat update state: %v", err)
		}
	}
}
