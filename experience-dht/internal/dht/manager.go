package dht

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

type ManagerClient interface {
	ListDHTNodes(ctx context.Context) ([]NodeDescriptor, error)
	Register(ctx context.Context, node NodeDescriptor, proof *SignedRequest) error
	Unregister(ctx context.Context, nodeID string, proof *SignedRequest) error
}

type HTTPManagerClient struct {
	BaseURL string
	Client  *http.Client
}

func (c HTTPManagerClient) ListDHTNodes(ctx context.Context) ([]NodeDescriptor, error) {
	base := strings.TrimRight(strings.TrimSpace(c.BaseURL), "/")
	if base == "" {
		return nil, nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/api/v1/dht/nodes", nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.httpClient().Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("manager dht nodes returned HTTP %d", resp.StatusCode)
	}
	var out struct {
		Items []NodeDescriptor `json:"items"`
		Nodes []NodeDescriptor `json:"nodes"`
		Data  []NodeDescriptor `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	switch {
	case out.Items != nil:
		return out.Items, nil
	case out.Nodes != nil:
		return out.Nodes, nil
	default:
		return out.Data, nil
	}
}

func (c HTTPManagerClient) ResolveExperienceDemandOffers(ctx context.Context, requestID, query string, limit int) ([]ExperienceDemandOfferRecord, error) {
	base := strings.TrimRight(strings.TrimSpace(c.BaseURL), "/")
	if base == "" {
		return nil, nil
	}
	values := url.Values{}
	if strings.TrimSpace(requestID) != "" {
		values.Set("request_id", strings.TrimSpace(requestID))
	}
	if strings.TrimSpace(query) != "" {
		values.Set("q", strings.TrimSpace(query))
	}
	if limit > 0 {
		values.Set("limit", strconv.Itoa(limit))
	}
	endpoint := base + "/api/v1/dht/experience-demands/resolve"
	if encoded := values.Encode(); encoded != "" {
		endpoint += "?" + encoded
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.httpClient().Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("manager demand resolve returned HTTP %d", resp.StatusCode)
	}
	var out struct {
		Items []ExperienceDemandOfferRecord `json:"items"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return out.Items, nil
}

func (c HTTPManagerClient) Register(ctx context.Context, node NodeDescriptor, proof *SignedRequest) error {
	base := strings.TrimRight(strings.TrimSpace(c.BaseURL), "/")
	if base == "" {
		return nil
	}
	data, err := json.Marshal(managerRegisterRequest{
		NodeDescriptor:     node,
		AdminSignedRequest: proof,
	})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/api/v1/dht/nodes/register", bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.httpClient().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("manager register returned HTTP %d", resp.StatusCode)
	}
	return nil
}

func normalizeManagerBaseURL(raw string) (string, error) {
	value := strings.TrimRight(strings.TrimSpace(raw), "/")
	if value == "" {
		return "", nil
	}
	parsed, err := url.Parse(value)
	if err != nil {
		return "", err
	}
	scheme := strings.ToLower(strings.TrimSpace(parsed.Scheme))
	if scheme != "http" && scheme != "https" {
		return "", fmt.Errorf("manager_base_url must use http or https")
	}
	if strings.TrimSpace(parsed.Hostname()) == "" {
		return "", fmt.Errorf("manager_base_url host is required")
	}
	return value, nil
}

func (c HTTPManagerClient) Unregister(ctx context.Context, nodeID string, proof *SignedRequest) error {
	base := strings.TrimRight(strings.TrimSpace(c.BaseURL), "/")
	if base == "" {
		return nil
	}
	var body *bytes.Reader
	if proof != nil {
		data, err := json.Marshal(proof)
		if err != nil {
			return err
		}
		body = bytes.NewReader(data)
	} else {
		body = bytes.NewReader(nil)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, base+"/api/v1/dht/nodes/"+nodeID, body)
	if err != nil {
		return err
	}
	if proof != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.httpClient().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("manager unregister returned HTTP %d", resp.StatusCode)
	}
	return nil
}

type managerRegisterRequest struct {
	NodeDescriptor
	AdminSignedRequest *SignedRequest `json:"admin_signed_request,omitempty"`
}

func (c HTTPManagerClient) httpClient() *http.Client {
	if c.Client != nil {
		return c.Client
	}
	return http.DefaultClient
}

func NodeDescriptorFromConfig(cfg Config, state State) NodeDescriptor {
	nodeID := strings.TrimSpace(state.NodeID)
	if nodeID == "" {
		nodeID = strings.TrimSpace(cfg.NodeID)
	}
	ownerKind := strings.TrimSpace(cfg.OwnerKind)
	if ownerKind == "" {
		ownerKind = OwnerKindUser
	}
	relayPolicy := strings.TrimSpace(cfg.RelayPolicy)
	if relayPolicy == "" {
		relayPolicy = RelayPolicyOwnerOnly
	}
	capabilities := cfg.Capabilities
	if capabilities == nil {
		capabilities = map[string]bool{}
	}
	endpoints := make([]Endpoint, 0, 2)
	if endpoint, ok := publicAPIEndpointFromConfig(cfg); ok {
		endpoints = append(endpoints, endpoint)
	}
	endpoints = append(endpoints, candidateEndpointsFromConfig(cfg)...)
	return NodeDescriptor{
		SchemaVersion: NodeSchemaVersion,
		NodeID:        nodeID,
		OwnerKind:     ownerKind,
		OwnerPeerID:   state.BoundPubkeyHex,
		DHTPeerID:     nodeID,
		NodePow:       state.NodePow,
		Endpoints:     endpoints,
		Capabilities:  capabilities,
		RelayPolicy:   relayPolicy,
		Region:        strings.TrimSpace(cfg.Region),
		Load: Load{
			RelayCapacity: cfg.RelayCapacity,
		},
		TTLSeconds: int(cfg.HeartbeatInterval().Seconds()) * 3,
	}
}

func candidateEndpointsFromConfig(cfg Config) []Endpoint {
	if len(cfg.CandidateEndpoints) > 0 {
		out := make([]Endpoint, 0, len(cfg.CandidateEndpoints))
		seen := map[string]bool{}
		for _, endpoint := range cfg.CandidateEndpoints {
			normalized := normalizeEndpoint(endpoint)
			if !validEndpoint(normalized) {
				continue
			}
			key := strings.ToLower(normalized.Network) + "|" + strings.ToLower(normalized.Host) + "|" + strconv.Itoa(normalized.Port)
			if seen[key] {
				continue
			}
			seen[key] = true
			out = append(out, normalized)
		}
		return out
	}
	network := strings.TrimSpace(cfg.PublicNetwork)
	if network == "" {
		network = "udp"
	}
	if strings.TrimSpace(cfg.PublicHost) == "" || cfg.PublicPort <= 0 {
		return nil
	}
	endpoint := normalizeEndpoint(Endpoint{
		Network: network,
		Host:    strings.TrimSpace(cfg.PublicHost),
		Port:    cfg.PublicPort,
	})
	if !validEndpoint(endpoint) {
		return nil
	}
	return []Endpoint{endpoint}
}

func publicAPIEndpointFromConfig(cfg Config) (Endpoint, bool) {
	raw := strings.TrimSpace(cfg.PublicAPIBaseURL)
	if raw == "" {
		raw = inferredPublicAPIBaseURL(cfg)
	}
	if raw == "" {
		return Endpoint{}, false
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return Endpoint{}, false
	}
	scheme := strings.ToLower(strings.TrimSpace(parsed.Scheme))
	if scheme != "http" && scheme != "https" {
		return Endpoint{}, false
	}
	host := strings.TrimSpace(parsed.Hostname())
	if host == "" {
		return Endpoint{}, false
	}
	port := parsed.Port()
	if port == "" {
		if scheme == "https" {
			port = "443"
		} else {
			port = "80"
		}
	}
	parsedPort, err := strconv.Atoi(port)
	if err != nil {
		return Endpoint{}, false
	}
	return Endpoint{
		Network: scheme,
		Host:    host,
		Port:    parsedPort,
	}, true
}

func inferredPublicAPIBaseURL(cfg Config) string {
	host := strings.TrimSpace(cfg.PublicHost)
	if host == "" {
		return ""
	}
	port := listenPort(cfg.Listen)
	if port <= 0 {
		port = 8091
	}
	if strings.Contains(host, ":") && !strings.HasPrefix(host, "[") {
		host = "[" + host + "]"
	}
	return "http://" + host + ":" + strconv.Itoa(port)
}

func listenPort(listen string) int {
	listen = strings.TrimSpace(listen)
	if listen == "" {
		return 8091
	}
	_, port, err := net.SplitHostPort(listen)
	if err == nil {
		if parsed, parseErr := strconv.Atoi(port); parseErr == nil {
			return parsed
		}
		return 0
	}
	if strings.HasPrefix(listen, ":") {
		parsed, parseErr := strconv.Atoi(strings.TrimPrefix(listen, ":"))
		if parseErr == nil {
			return parsed
		}
	}
	return 0
}

func validEndpoint(endpoint Endpoint) bool {
	if strings.TrimSpace(endpoint.Network) == "" || strings.TrimSpace(endpoint.Host) == "" {
		return false
	}
	return endpoint.Port > 0 && endpoint.Port <= 65535 && !strings.ContainsAny(endpoint.Host, " \t\r\n/")
}

func normalizeEndpoint(endpoint Endpoint) Endpoint {
	network := strings.ToLower(strings.TrimSpace(endpoint.Network))
	if network == "" {
		network = "udp"
	}
	return Endpoint{
		Network:           network,
		Host:              strings.TrimSpace(endpoint.Host),
		Port:              endpoint.Port,
		RequiresHolePunch: endpoint.RequiresHolePunch,
	}
}

func endpointAddr(endpoint Endpoint) string {
	return endpoint.Host + ":" + strconv.Itoa(endpoint.Port)
}
