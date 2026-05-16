package hub

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/quic-go/quic-go"

	"ph01-experience-hub/internal/governance"
)

var ErrInvalidDHTNode = errors.New("invalid dht node")
var ErrInvalidDHTOwnershipProof = errors.New("invalid dht ownership proof")

const (
	defaultDHTNodeTTL = 5 * time.Minute
	maxDHTNodeTTL     = 30 * time.Minute
	minDHTNodeTTL     = time.Minute
)

type DHTHealthChecker interface {
	CheckDHTNode(ctx context.Context, node DHTNode) DHTHealthResult
}

type DefaultDHTHealthChecker struct {
	Timeout time.Duration
}

func (c DefaultDHTHealthChecker) CheckDHTNode(ctx context.Context, node DHTNode) DHTHealthResult {
	timeout := c.Timeout
	if timeout <= 0 {
		timeout = time.Second
	}
	dialer := net.Dialer{Timeout: timeout}
	hasAddressOnlyEndpoint := false
	for _, endpoint := range node.Endpoints {
		address := net.JoinHostPort(endpoint.Host, strconv.Itoa(endpoint.Port))
		switch normalizeDHTNetwork(endpoint.Network) {
		case "tcp", "tcp4", "tcp6", "http", "https", "ws", "wss":
			conn, err := dialer.DialContext(ctx, "tcp", address)
			if err == nil {
				_ = conn.Close()
				return DHTHealthResult{Status: DHTHealthHealthy}
			}
		case "quic":
			if err := checkDHTQUIC(ctx, address, timeout); err == nil {
				return DHTHealthResult{Status: DHTHealthHealthy}
			}
			hasAddressOnlyEndpoint = true
		case "udp", "udp4", "udp6":
			if err := checkDHTUDP(ctx, address, timeout); err == nil {
				return DHTHealthResult{Status: DHTHealthHealthy}
			}
			if _, err := net.ResolveUDPAddr("udp", address); err == nil {
				hasAddressOnlyEndpoint = true
			}
		}
	}
	if hasAddressOnlyEndpoint {
		return DHTHealthResult{
			Status:  DHTHealthDegraded,
			Message: "udp/quic endpoint address validated; protocol ping did not confirm reachability",
		}
	}
	return DHTHealthResult{Status: DHTHealthUnhealthy, Message: "no reachable endpoint"}
}

func checkDHTQUIC(ctx context.Context, address string, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	conn, err := quic.DialAddr(ctx, address, &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{"ph01-experience-dht"},
	}, &quic.Config{MaxIdleTimeout: timeout})
	if err != nil {
		return err
	}
	defer conn.CloseWithError(0, "")
	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		return err
	}
	defer stream.Close()
	if _, err := stream.Write([]byte("healthz\n")); err != nil {
		return err
	}
	line, err := bufio.NewReader(stream).ReadString('\n')
	if err != nil {
		return err
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(line), &payload); err != nil {
		return err
	}
	if payload["ok"] != true {
		return errors.New("quic health check returned not ok")
	}
	return nil
}

func checkDHTUDP(ctx context.Context, address string, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	dialer := net.Dialer{Timeout: timeout}
	conn, err := dialer.DialContext(ctx, "udp", address)
	if err != nil {
		return err
	}
	defer conn.Close()
	deadline := time.Now().Add(timeout)
	_ = conn.SetDeadline(deadline)
	if _, err := conn.Write([]byte("healthz\n")); err != nil {
		return err
	}
	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		return err
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(line), &payload); err != nil {
		return err
	}
	if payload["ok"] != true {
		return errors.New("udp health check returned not ok")
	}
	return nil
}

func NewDHTNodeFromRegister(req DHTRegisterRequest, now time.Time, authorizedAdmin bool) (DHTNode, error) {
	schema := strings.TrimSpace(req.SchemaVersion)
	if schema == "" {
		schema = DHTNodeSchemaVersion
	}
	if schema != DHTNodeSchemaVersion && schema != DHTRegisterSchemaVersion {
		return DHTNode{}, ErrInvalidDHTNode
	}
	nodeID := strings.TrimSpace(req.NodeID)
	if !idPattern.MatchString(nodeID) {
		return DHTNode{}, ErrInvalidDHTNode
	}
	ownerKind := normalizeDHTOwnerKind(req.OwnerKind)
	if ownerKind == DHTOwnerKindOfficial && !authorizedAdmin {
		ownerKind = DHTOwnerKindUser
	}
	relayPolicy := normalizeDHTRelayPolicy(req.RelayPolicy)
	var nodePow *DHTNodePow
	if req.NodePow != nil {
		pow := *req.NodePow
		pow.SchemaVersion = strings.TrimSpace(pow.SchemaVersion)
		if pow.SchemaVersion == "" {
			pow.SchemaVersion = DHTNodePowSchemaVersion
		}
		if pow.NodeID == "" {
			pow.NodeID = nodeID
		}
		if pow.OwnerPubkeyHex == "" {
			pow.OwnerPubkeyHex = strings.TrimSpace(req.OwnerPeerID)
		}
		if err := VerifyDHTNodePow(&pow); err != nil {
			return DHTNode{}, err
		}
		if pow.NodeID != nodeID {
			return DHTNode{}, ErrInvalidDHTNodePow
		}
		nodePow = &pow
	}
	endpoints, err := normalizeDHTEndpoints(req.Endpoints)
	if err != nil {
		return DHTNode{}, err
	}
	load := DHTLoad{
		RelayActiveSessions: nonNegative(req.Load.RelayActiveSessions),
		RelayCapacity:       nonNegative(req.Load.RelayCapacity),
	}
	ttl := normalizeDHTTTL(req.TTLSeconds)
	expiresAt := now.UTC().Add(ttl).Format(time.RFC3339)
	return DHTNode{
		SchemaVersion:     DHTNodeSchemaVersion,
		NodeID:            nodeID,
		OwnerKind:         ownerKind,
		OwnerPeerID:       strings.TrimSpace(req.OwnerPeerID),
		DHTPeerID:         strings.TrimSpace(req.DHTPeerID),
		NodePow:           nodePow,
		Endpoints:         endpoints,
		Capabilities:      normalizeDHTCapabilities(req.Capabilities),
		RelayPolicy:       relayPolicy,
		Region:            strings.TrimSpace(req.Region),
		Load:              load,
		HealthStatus:      DHTHealthUnhealthy,
		LastHealthCheckAt: now.UTC().Format(time.RFC3339),
		ExpiresAt:         expiresAt,
	}, nil
}

func validateDHTOwnershipProof(node DHTNode, proof *SignedRequest) error {
	owner := strings.TrimSpace(node.OwnerPeerID)
	if owner == "" {
		return ErrInvalidDHTOwnershipProof
	}
	if proof == nil {
		return ErrInvalidDHTOwnershipProof
	}
	if !strings.EqualFold(strings.TrimSpace(proof.PubkeyHex), owner) {
		return ErrInvalidDHTOwnershipProof
	}
	if strings.TrimSpace(proof.Payload) == "" ||
		strings.TrimSpace(proof.SignatureHex) == "" ||
		strings.TrimSpace(proof.Nonce) == "" ||
		proof.Timestamp == 0 {
		return ErrInvalidDHTOwnershipProof
	}
	signed := proof.Payload + "\n" + proof.PubkeyHex + "\n" + fmt.Sprintf("%d", proof.Timestamp) + "\n" + proof.Nonce
	if err := governance.Verify(proof.PubkeyHex, []byte(signed), proof.SignatureHex); err != nil {
		return ErrInvalidDHTOwnershipProof
	}
	return nil
}

func (s *Store) initDHTIndex() error {
	if _, err := os.Stat(s.dhtIndexPath()); os.IsNotExist(err) {
		return s.writeDHTIndex(DHTIndex{UpdatedAt: nowRFC3339(), Items: []DHTNode{}})
	}
	return nil
}

func (s *Store) UpsertDHTNode(node DHTNode) (DHTNode, error) {
	if err := validateDHTNode(node); err != nil {
		return DHTNode{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	idx, err := s.readDHTIndex()
	if err != nil {
		return DHTNode{}, err
	}
	pos := -1
	for i, item := range idx.Items {
		if item.NodeID == node.NodeID {
			pos = i
			break
		}
	}
	if pos >= 0 {
		idx.Items[pos] = node
	} else {
		idx.Items = append(idx.Items, node)
	}
	idx.UpdatedAt = nowRFC3339()
	if err := s.writeDHTIndex(idx); err != nil {
		return DHTNode{}, err
	}
	return node, nil
}

func (s *Store) ListDHTNodes(now time.Time) ([]DHTNode, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	idx, err := s.readDHTIndex()
	if err != nil {
		return nil, err
	}
	out := make([]DHTNode, 0, len(idx.Items))
	for _, item := range idx.Items {
		if isPublicDHTNodeVisible(item, now) {
			out = append(out, item)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Region != out[j].Region {
			return out[i].Region < out[j].Region
		}
		return out[i].Load.RelayActiveSessions < out[j].Load.RelayActiveSessions
	})
	return out, nil
}

func (s *Store) DeleteDHTNode(nodeID string) error {
	if !idPattern.MatchString(nodeID) {
		return ErrInvalidDHTNode
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	idx, err := s.readDHTIndex()
	if err != nil {
		return err
	}
	out := idx.Items[:0]
	found := false
	for _, item := range idx.Items {
		if item.NodeID == nodeID {
			found = true
			continue
		}
		out = append(out, item)
	}
	if !found {
		return ErrNotFound
	}
	idx.Items = out
	idx.UpdatedAt = nowRFC3339()
	return s.writeDHTIndex(idx)
}

func (s *Store) GetDHTNode(nodeID string) (DHTNode, error) {
	if !idPattern.MatchString(nodeID) {
		return DHTNode{}, ErrInvalidDHTNode
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	idx, err := s.readDHTIndex()
	if err != nil {
		return DHTNode{}, err
	}
	for _, item := range idx.Items {
		if item.NodeID == nodeID {
			return item, nil
		}
	}
	return DHTNode{}, ErrNotFound
}

func (s *Store) dhtIndexPath() string {
	return filepath.Join(s.root, "dht_nodes.json")
}

func (s *Store) readDHTIndex() (DHTIndex, error) {
	data, err := os.ReadFile(s.dhtIndexPath())
	if err != nil {
		return DHTIndex{}, err
	}
	var idx DHTIndex
	if err := json.Unmarshal(data, &idx); err != nil {
		return DHTIndex{}, err
	}
	if idx.Items == nil {
		idx.Items = []DHTNode{}
	}
	return idx, nil
}

func (s *Store) writeDHTIndex(idx DHTIndex) error {
	if err := os.MkdirAll(s.root, 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(idx, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(s.dhtIndexPath(), data, 0o644)
}

func validateDHTNode(node DHTNode) error {
	if node.SchemaVersion != DHTNodeSchemaVersion {
		return ErrInvalidDHTNode
	}
	if !idPattern.MatchString(node.NodeID) {
		return ErrInvalidDHTNode
	}
	if node.OwnerKind != DHTOwnerKindOfficial && node.OwnerKind != DHTOwnerKindUser {
		return ErrInvalidDHTNode
	}
	if node.RelayPolicy != DHTRelayPolicyPublic && node.RelayPolicy != DHTRelayPolicyOwnerOnly && node.RelayPolicy != DHTRelayPolicyDisabled {
		return ErrInvalidDHTNode
	}
	if node.NodePow != nil {
		if err := VerifyDHTNodePow(node.NodePow); err != nil {
			return err
		}
		if node.NodePow.NodeID != node.NodeID {
			return ErrInvalidDHTNodePow
		}
	}
	if normalizeDHTHealthStatus(node.HealthStatus) != node.HealthStatus {
		return ErrInvalidDHTNode
	}
	if _, err := normalizeDHTEndpoints(node.Endpoints); err != nil {
		return err
	}
	if strings.TrimSpace(node.ExpiresAt) == "" {
		return ErrInvalidDHTNode
	}
	return nil
}

func isPublicDHTNodeVisible(node DHTNode, now time.Time) bool {
	if node.HealthStatus == DHTHealthUnhealthy {
		return false
	}
	if len(node.Endpoints) == 0 {
		return false
	}
	expiresAt, err := time.Parse(time.RFC3339, node.ExpiresAt)
	if err != nil || !expiresAt.After(now.UTC()) {
		return false
	}
	for _, endpoint := range node.Endpoints {
		if validDHTEndpoint(endpoint) {
			return true
		}
	}
	return false
}

func normalizeDHTEndpoints(in []DHTEndpoint) ([]DHTEndpoint, error) {
	if len(in) == 0 {
		return nil, ErrInvalidDHTNode
	}
	out := make([]DHTEndpoint, 0, len(in))
	for _, endpoint := range in {
		endpoint.Network = normalizeDHTNetwork(endpoint.Network)
		endpoint.Host = strings.TrimSpace(endpoint.Host)
		if !validDHTEndpoint(endpoint) {
			return nil, ErrInvalidDHTNode
		}
		out = append(out, endpoint)
	}
	return out, nil
}

func validDHTEndpoint(endpoint DHTEndpoint) bool {
	if endpoint.Network == "" || endpoint.Host == "" || endpoint.Port <= 0 || endpoint.Port > 65535 {
		return false
	}
	return !strings.ContainsAny(endpoint.Host, " \t\r\n/")
}

func normalizeDHTNetwork(network string) string {
	network = strings.ToLower(strings.TrimSpace(network))
	if network == "" {
		return "udp"
	}
	return network
}

func normalizeDHTOwnerKind(ownerKind string) string {
	switch strings.TrimSpace(ownerKind) {
	case DHTOwnerKindOfficial:
		return DHTOwnerKindOfficial
	default:
		return DHTOwnerKindUser
	}
}

func normalizeDHTRelayPolicy(policy string) string {
	switch strings.TrimSpace(policy) {
	case DHTRelayPolicyOwnerOnly:
		return DHTRelayPolicyOwnerOnly
	case DHTRelayPolicyDisabled:
		return DHTRelayPolicyDisabled
	default:
		return DHTRelayPolicyPublic
	}
}

func normalizeDHTHealthStatus(status string) string {
	switch strings.TrimSpace(status) {
	case DHTHealthHealthy:
		return DHTHealthHealthy
	case DHTHealthDegraded:
		return DHTHealthDegraded
	default:
		return DHTHealthUnhealthy
	}
}

func normalizeDHTCapabilities(in map[string]bool) map[string]bool {
	if len(in) == 0 {
		return map[string]bool{}
	}
	out := make(map[string]bool, len(in))
	for key, value := range in {
		key = strings.TrimSpace(key)
		if key == "" {
			continue
		}
		out[key] = value
	}
	return out
}

func normalizeDHTTTL(ttlSeconds int) time.Duration {
	if ttlSeconds <= 0 {
		return defaultDHTNodeTTL
	}
	ttl := time.Duration(ttlSeconds) * time.Second
	if ttl < minDHTNodeTTL {
		return minDHTNodeTTL
	}
	if ttl > maxDHTNodeTTL {
		return maxDHTNodeTTL
	}
	return ttl
}

func nonNegative(value int) int {
	if value < 0 {
		return 0
	}
	return value
}
