package dht

import "time"

const (
	StateSchemaVersion     = "ph01.experience.dht_state.v1"
	NodeSchemaVersion      = "ph01.experience.dht_node.v1"
	NodePowSchemaVersion   = "ph01.experience.dht_node_pow.v1"
	FlowerSchemaVersion    = "ph01.experience.dht_service_flower.v1"
	WreathSchemaVersion    = "ph01.experience.dht_service_wreath.v1"
	TrustSchemaVersion     = "ph01.experience.dht_trust_bundle.v1"
	RelayRequestSchema     = "ph01.experience.relay_session_request.v1"
	RelaySessionSchema     = "ph01.experience.relay_session.v1"
	HolePunchRequestSchema = "ph01.experience.hole_punch_request.v1"
	HolePunchSessionSchema = "ph01.experience.hole_punch_session.v1"
	PackageRequestSchema   = "ph01.experience.package_request.v1"
	PackageOfferSchema     = "ph01.experience.package_offer.v1"
	ExperienceDemandSchema = "ph01.experience.demand.v1"
	DemandOfferSchema      = "ph01.experience.demand_offer.v1"

	OwnerKindOfficial = "official"
	OwnerKindUser     = "user"

	RelayPolicyPublic    = "public"
	RelayPolicyOwnerOnly = "owner_only"
	RelayPolicyDisabled  = "disabled"

	HealthHealthy = "healthy"
)

type Config struct {
	Listen                   string          `json:"listen" yaml:"listen"`
	UDPListen                string          `json:"udp_listen" yaml:"udp_listen"`
	QUICListen               string          `json:"quic_listen" yaml:"quic_listen"`
	StatePath                string          `json:"-" yaml:"-"`
	NodeID                   string          `json:"node_id" yaml:"node_id"`
	InitPassword             string          `json:"init_password" yaml:"init_password"`
	AllowReinitialize        bool            `json:"allow_reinitialize" yaml:"allow_reinitialize"`
	ManagerBaseURL           string          `json:"manager_base_url" yaml:"manager_base_url"`
	PublicAPIBaseURL         string          `json:"public_api_base_url" yaml:"public_api_base_url"`
	PublicNetwork            string          `json:"public_network" yaml:"public_network"`
	PublicHost               string          `json:"public_host" yaml:"public_host"`
	PublicPort               int             `json:"public_port" yaml:"public_port"`
	CandidateEndpoints       []Endpoint      `json:"candidate_endpoints" yaml:"candidate_endpoints"`
	OwnerKind                string          `json:"owner_kind" yaml:"owner_kind"`
	Region                   string          `json:"region" yaml:"region"`
	RelayPolicy              string          `json:"relay_policy" yaml:"relay_policy"`
	RelayCapacity            int             `json:"relay_capacity" yaml:"relay_capacity"`
	RelayMaxBytes            int64           `json:"relay_max_bytes" yaml:"relay_max_bytes"`
	HeartbeatIntervalSeconds int             `json:"heartbeat_interval_seconds" yaml:"heartbeat_interval_seconds"`
	PeerTTLSeconds           int             `json:"peer_ttl_seconds" yaml:"peer_ttl_seconds"`
	Capabilities             map[string]bool `json:"capabilities" yaml:"capabilities"`
}

func (c Config) HeartbeatInterval() time.Duration {
	if c.HeartbeatIntervalSeconds <= 0 {
		return time.Minute
	}
	return time.Duration(c.HeartbeatIntervalSeconds) * time.Second
}

func (c Config) PeerTTL() time.Duration {
	if c.PeerTTLSeconds <= 0 {
		return 5 * time.Minute
	}
	return time.Duration(c.PeerTTLSeconds) * time.Second
}

func (c Config) MaxRelayBytes() int64 {
	if c.RelayMaxBytes <= 0 {
		return 64 * 1024 * 1024
	}
	return c.RelayMaxBytes
}

type State struct {
	SchemaVersion           string         `json:"schema_version"`
	NodeID                  string         `json:"node_id"`
	BoundPubkeyHex          string         `json:"bound_pubkey_hex,omitempty"`
	BoundAt                 string         `json:"bound_at,omitempty"`
	RuntimeConfig           RuntimeConfig  `json:"runtime_config,omitempty"`
	BootstrapManagerURL     string         `json:"bootstrap_manager_base_url,omitempty"`
	PublicEnabled           bool           `json:"public_enabled"`
	PublicRegistered        bool           `json:"public_registered"`
	PublicManagerURL        string         `json:"public_manager_base_url,omitempty"`
	PublicRegistrationProof *SignedRequest `json:"public_registration_proof,omitempty"`
	NodePow                 *DHTNodePow    `json:"node_pow,omitempty"`
	UpdatedAt               string         `json:"updated_at"`
}

type RuntimeConfig struct {
	PublicAPIBaseURL   string          `json:"public_api_base_url,omitempty"`
	PublicNetwork      string          `json:"public_network,omitempty"`
	PublicHost         string          `json:"public_host,omitempty"`
	PublicPort         int             `json:"public_port,omitempty"`
	CandidateEndpoints []Endpoint      `json:"candidate_endpoints,omitempty"`
	OwnerKind          string          `json:"owner_kind,omitempty"`
	Region             string          `json:"region,omitempty"`
	RelayPolicy        string          `json:"relay_policy,omitempty"`
	RelayCapacity      int             `json:"relay_capacity,omitempty"`
	Capabilities       map[string]bool `json:"capabilities,omitempty"`
}

type Endpoint struct {
	Network           string `json:"network"`
	Host              string `json:"host"`
	Port              int    `json:"port"`
	RequiresHolePunch bool   `json:"requires_hole_punch,omitempty"`
}

type Load struct {
	RelayActiveSessions int `json:"relay_active_sessions"`
	RelayCapacity       int `json:"relay_capacity"`
}

type NodeDescriptor struct {
	SchemaVersion     string          `json:"schema_version,omitempty"`
	NodeID            string          `json:"node_id"`
	OwnerKind         string          `json:"owner_kind,omitempty"`
	OwnerPeerID       string          `json:"owner_peer_id,omitempty"`
	DHTPeerID         string          `json:"dht_peer_id,omitempty"`
	NodePow           *DHTNodePow     `json:"node_pow,omitempty"`
	Endpoints         []Endpoint      `json:"endpoints"`
	Capabilities      map[string]bool `json:"capabilities,omitempty"`
	RelayPolicy       string          `json:"relay_policy,omitempty"`
	Region            string          `json:"region,omitempty"`
	Load              Load            `json:"load,omitempty"`
	TTLSeconds        int             `json:"ttl_seconds,omitempty"`
	HealthStatus      string          `json:"health_status,omitempty"`
	LastHealthCheckAt string          `json:"last_health_check_at,omitempty"`
	ExpiresAt         string          `json:"expires_at,omitempty"`
}

type DHTNodePow struct {
	SchemaVersion   string `json:"schema_version,omitempty"`
	NodeID          string `json:"node_id"`
	OwnerPubkeyHex  string `json:"owner_pubkey_hex,omitempty"`
	OwnerPubkeyHash string `json:"owner_pubkey_hash"`
	Algorithm       string `json:"algorithm"`
	DifficultyBits  int    `json:"difficulty_bits"`
	MemoryKiB       int    `json:"memory_kib"`
	RoundCount      int    `json:"round_count"`
	Seed            string `json:"seed"`
	SolutionNonce   string `json:"solution_nonce"`
	CreatedAt       string `json:"created_at,omitempty"`
}

type DHTServiceFlower struct {
	SchemaVersion    string `json:"schema_version,omitempty"`
	FlowerID         string `json:"flower_id"`
	NodeID           string `json:"node_id"`
	ClientPubkeyHex  string `json:"client_pubkey_hex"`
	ClientPubkeyHash string `json:"client_pubkey_hash"`
	ResourceHash     string `json:"resource_hash"`
	WorkKind         string `json:"work_kind,omitempty"`
	ServedAt         string `json:"served_at"`
	SignatureHex     string `json:"signature"`
	ReceivedAt       string `json:"received_at,omitempty"`
}

type DHTServiceWreath struct {
	SchemaVersion          string   `json:"schema_version,omitempty"`
	WreathID               string   `json:"wreath_id"`
	NodeID                 string   `json:"node_id"`
	FlowerCount            int      `json:"flower_count"`
	UniqueClientCount      int      `json:"unique_client_count"`
	LastServedAt           string   `json:"last_served_at"`
	CreatedAt              string   `json:"created_at"`
	SourceFlowerIDs        []string `json:"source_flower_ids,omitempty"`
	SignaturePayloadSHA256 string   `json:"signature_payload_sha256,omitempty"`
	SignatureAlgorithm     string   `json:"signature_algorithm,omitempty"`
	ManagerSignature       string   `json:"manager_signature,omitempty"`
}

type DHTTrustBundle struct {
	SchemaVersion string             `json:"schema_version"`
	NodeID        string             `json:"node_id"`
	NodePow       *DHTNodePow        `json:"node_pow,omitempty"`
	Wreaths       []DHTServiceWreath `json:"wreaths"`
	Flowers       []DHTServiceFlower `json:"flowers"`
	UpdatedAt     string             `json:"updated_at"`
}

type SignedRequest struct {
	Payload      string `json:"payload"`
	PubkeyHex    string `json:"pubkey"`
	SignatureHex string `json:"signature"`
	Timestamp    int64  `json:"timestamp"`
	Nonce        string `json:"nonce"`
}

type BindRequest struct {
	InitPassword   string        `json:"init_password"`
	PubkeyHex      string        `json:"pubkey_hex"`
	ManagerBaseURL string        `json:"manager_base_url,omitempty"`
	RuntimeConfig  RuntimeConfig `json:"runtime_config,omitempty"`
}

type PublicModeRequest struct {
	Enabled        bool   `json:"enabled"`
	ManagerBaseURL string `json:"manager_base_url,omitempty"`
}

type BootstrapManagerRequest struct {
	ManagerBaseURL string `json:"manager_base_url,omitempty"`
}

type RuntimeConfigRequest struct {
	RuntimeConfig RuntimeConfig `json:"runtime_config"`
}

type PresenceRequest struct {
	PeerID        string     `json:"peer_id"`
	OwnerPeerID   string     `json:"owner_peer_id,omitempty"`
	Endpoints     []Endpoint `json:"endpoints"`
	PackageHashes []string   `json:"package_hashes,omitempty"`
	TTLSeconds    int        `json:"ttl_seconds,omitempty"`
}

type ProviderRecord struct {
	PeerID        string     `json:"peer_id"`
	OwnerPeerID   string     `json:"owner_peer_id,omitempty"`
	Endpoints     []Endpoint `json:"endpoints"`
	PackageHashes []string   `json:"package_hashes,omitempty"`
	ExpiresAt     string     `json:"expires_at"`
	UpdatedAt     string     `json:"updated_at"`
}

type RelaySessionRequest struct {
	SchemaVersion        string `json:"schema_version,omitempty"`
	RequestID            string `json:"request_id"`
	ExperienceID         string `json:"experience_id"`
	PackageHash          string `json:"package_hash"`
	RequesterPeerID      string `json:"requester_peer_id"`
	RequesterOwnerPeerID string `json:"requester_owner_peer_id,omitempty"`
	ProviderPeerID       string `json:"provider_peer_id"`
	ProviderOwnerPeerID  string `json:"provider_owner_peer_id,omitempty"`
	TTLSeconds           int    `json:"ttl_seconds,omitempty"`
	MaxBytes             int64  `json:"max_bytes,omitempty"`
}

type RelaySession struct {
	SchemaVersion   string `json:"schema_version"`
	SessionID       string `json:"session_id"`
	RequestID       string `json:"request_id"`
	ExperienceID    string `json:"experience_id"`
	PackageHash     string `json:"package_hash"`
	RequesterPeerID string `json:"requester_peer_id"`
	ProviderPeerID  string `json:"provider_peer_id"`
	ExpiresAt       string `json:"expires_at"`
	MaxBytes        int64  `json:"max_bytes"`
	Status          string `json:"status"`
	Bytes           int64  `json:"bytes,omitempty"`
	PayloadSHA256   string `json:"payload_sha256,omitempty"`
}

type HolePunchSessionRequest struct {
	SchemaVersion        string     `json:"schema_version,omitempty"`
	RequestID            string     `json:"request_id"`
	ExperienceID         string     `json:"experience_id,omitempty"`
	PackageHash          string     `json:"package_hash"`
	RequesterPeerID      string     `json:"requester_peer_id"`
	RequesterOwnerPeerID string     `json:"requester_owner_peer_id,omitempty"`
	RequesterAddrs       []Endpoint `json:"requester_addrs,omitempty"`
	ProviderPeerID       string     `json:"provider_peer_id"`
	ProviderOwnerPeerID  string     `json:"provider_owner_peer_id,omitempty"`
	ProviderAddrs        []Endpoint `json:"provider_addrs,omitempty"`
	TTLSeconds           int        `json:"ttl_seconds,omitempty"`
}

type HolePunchReport struct {
	PeerID           string     `json:"peer_id"`
	Role             string     `json:"role"`
	Result           string     `json:"result"`
	ObservedEndpoint *Endpoint  `json:"observed_endpoint,omitempty"`
	LocalEndpoints   []Endpoint `json:"local_endpoints,omitempty"`
	Message          string     `json:"message,omitempty"`
	UpdatedAt        string     `json:"updated_at,omitempty"`
}

type HolePunchSession struct {
	SchemaVersion   string           `json:"schema_version"`
	SessionID       string           `json:"session_id"`
	RequestID       string           `json:"request_id"`
	ExperienceID    string           `json:"experience_id,omitempty"`
	PackageHash     string           `json:"package_hash"`
	RequesterPeerID string           `json:"requester_peer_id"`
	RequesterAddrs  []Endpoint       `json:"requester_addrs,omitempty"`
	ProviderPeerID  string           `json:"provider_peer_id"`
	ProviderAddrs   []Endpoint       `json:"provider_addrs,omitempty"`
	PunchToken      string           `json:"punch_token"`
	ExpiresAt       string           `json:"expires_at"`
	Status          string           `json:"status"`
	RequesterReport *HolePunchReport `json:"requester_report,omitempty"`
	ProviderReport  *HolePunchReport `json:"provider_report,omitempty"`
}

type PackageRequest struct {
	SchemaVersion        string     `json:"schema_version,omitempty"`
	RequestID            string     `json:"request_id"`
	ExperienceID         string     `json:"experience_id"`
	PackageHash          string     `json:"package_hash"`
	RequesterPeerID      string     `json:"requester_peer_id"`
	RequesterOwnerPeerID string     `json:"requester_owner_peer_id,omitempty"`
	RequesterPublicKey   string     `json:"requester_public_key,omitempty"`
	RequesterAddrs       []Endpoint `json:"requester_addrs,omitempty"`
	PreferredTransports  []string   `json:"preferred_transports,omitempty"`
	DHTNodeID            string     `json:"dht_node_id,omitempty"`
	Nonce                string     `json:"nonce,omitempty"`
	Timestamp            string     `json:"timestamp,omitempty"`
	RequesterSignature   string     `json:"requester_signature,omitempty"`
	TTLSeconds           int        `json:"ttl_seconds,omitempty"`
}

type PackageRequestRecord struct {
	PackageRequest
	ExpiresAt string `json:"expires_at"`
	UpdatedAt string `json:"updated_at"`
}

type PackageOffer struct {
	SchemaVersion       string         `json:"schema_version,omitempty"`
	RequestID           string         `json:"request_id"`
	ExperienceID        string         `json:"experience_id"`
	PackageHash         string         `json:"package_hash"`
	ProviderPeerID      string         `json:"provider_peer_id"`
	ProviderOwnerPeerID string         `json:"provider_owner_peer_id,omitempty"`
	ProviderAddrs       []Endpoint     `json:"provider_addrs,omitempty"`
	AvailableTransports []string       `json:"available_transports,omitempty"`
	ReviewMaterials     map[string]any `json:"review_materials,omitempty"`
	Publisher           map[string]any `json:"publisher,omitempty"`
	Nonce               string         `json:"nonce,omitempty"`
	Timestamp           string         `json:"timestamp,omitempty"`
	ProviderSignature   string         `json:"provider_signature,omitempty"`
}

type PackageOfferRecord struct {
	PackageOffer
	OfferedAt string `json:"offered_at"`
}

type DemandReturnHop struct {
	NodeID     string `json:"node_id"`
	APIBaseURL string `json:"api_base_url,omitempty"`
	SeenAt     string `json:"seen_at,omitempty"`
}

type ExperienceDemand struct {
	SchemaVersion        string            `json:"schema_version,omitempty"`
	RequestID            string            `json:"request_id"`
	NaturalLanguageQuery string            `json:"natural_language_query"`
	QueryLanguage        string            `json:"query_language,omitempty"`
	QueryKeywords        []string          `json:"query_keywords,omitempty"`
	RequesterPeerID      string            `json:"requester_peer_id"`
	RequesterOwnerPeerID string            `json:"requester_owner_peer_id,omitempty"`
	RequesterPubkeyHash  string            `json:"requester_pubkey_hash,omitempty"`
	PreferredTransports  []string          `json:"preferred_transports,omitempty"`
	TTLSeconds           int               `json:"ttl_seconds,omitempty"`
	HopLimit             int               `json:"hop_limit,omitempty"`
	ReturnPath           []DemandReturnHop `json:"return_path,omitempty"`
	CreatedAt            string            `json:"created_at,omitempty"`
	Nonce                string            `json:"nonce,omitempty"`
	RequesterSignature   string            `json:"requester_signature,omitempty"`
}

type ExperienceDemandRecord struct {
	ExperienceDemand
	ExpiresAt string `json:"expires_at"`
	UpdatedAt string `json:"updated_at"`
}

type ExperienceDemandOffer struct {
	SchemaVersion       string            `json:"schema_version,omitempty"`
	RequestID           string            `json:"request_id"`
	ExperienceID        string            `json:"experience_id"`
	PackageHash         string            `json:"package_hash"`
	Title               string            `json:"title,omitempty"`
	Brief               string            `json:"brief,omitempty"`
	Keywords            []string          `json:"keywords,omitempty"`
	MatchedReason       string            `json:"matched_reason,omitempty"`
	ReviewChain         []map[string]any  `json:"review_chain,omitempty"`
	ReviewChainDigest   string            `json:"review_chain_digest,omitempty"`
	ReviewChainLength   int               `json:"review_chain_length,omitempty"`
	ReviewChainRef      *ReviewChainRef   `json:"review_chain_ref,omitempty"`
	ProviderPeerID      string            `json:"provider_peer_id"`
	ProviderOwnerPeerID string            `json:"provider_owner_peer_id,omitempty"`
	ProviderAddrs       []Endpoint        `json:"provider_addrs,omitempty"`
	AvailableTransports []string          `json:"available_transports,omitempty"`
	ReturnPath          []DemandReturnHop `json:"return_path,omitempty"`
	RelaySessionID      string            `json:"relay_session_id,omitempty"`
	Nonce               string            `json:"nonce,omitempty"`
	Timestamp           string            `json:"timestamp,omitempty"`
	ProviderSignature   string            `json:"provider_signature,omitempty"`
}

type ExperienceDemandOfferRecord struct {
	ExperienceDemandOffer
	OfferedAt string `json:"offered_at"`
}

type ReviewChainRef struct {
	Digest string `json:"digest"`
	Length int    `json:"length"`
	URL    string `json:"url,omitempty"`
}

type ReviewChainPayload struct {
	SchemaVersion string           `json:"schema_version"`
	Digest        string           `json:"digest"`
	Length        int              `json:"length"`
	ReviewChain   []map[string]any `json:"review_chain"`
	UpdatedAt     string           `json:"updated_at"`
}

type PackageCacheRecord struct {
	PackageHash   string `json:"package_hash"`
	ExperienceID  string `json:"experience_id,omitempty"`
	Bytes         int64  `json:"bytes"`
	PayloadSHA256 string `json:"payload_sha256"`
	StoredAt      string `json:"stored_at"`
	ExpiresAt     string `json:"expires_at"`
}

type ErrorResponse struct {
	Error   string `json:"error"`
	Message string `json:"message,omitempty"`
}
