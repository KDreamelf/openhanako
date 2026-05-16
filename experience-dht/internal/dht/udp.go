package dht

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net"
	"strings"
)

const DefaultUDPListenAddr = ":41001"

func (h *Handler) RunUDPServer(ctx context.Context, listenAddr string) error {
	listenAddr = strings.TrimSpace(listenAddr)
	if listenAddr == "" {
		listenAddr = DefaultUDPListenAddr
	}
	addr, err := net.ResolveUDPAddr("udp", listenAddr)
	if err != nil {
		return err
	}
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		return err
	}
	defer conn.Close()
	go func() {
		<-ctx.Done()
		_ = conn.Close()
	}()
	log.Printf("[info] experience-dht UDP listening on %s node=%s", listenAddr, h.nodeIDOrConfig())
	buf := make([]byte, 2048)
	for {
		n, remote, err := conn.ReadFromUDP(buf)
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		payload := h.udpHealthPayload(strings.TrimSpace(string(buf[:n])))
		_, _ = conn.WriteToUDP(payload, remote)
	}
}

func (h *Handler) udpHealthPayload(command string) []byte {
	ok := command == "healthz"
	payload := map[string]any{
		"ok":      ok,
		"service": "experience-dht-udp",
	}
	if !ok {
		payload["error"] = "unknown_command"
	} else {
		state, _ := h.Store.Get()
		payload["node_id"] = h.nodeID(state)
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return []byte(`{"ok":false,"service":"experience-dht-udp","error":"encode_failed"}` + "\n")
	}
	return append(data, '\n')
}
