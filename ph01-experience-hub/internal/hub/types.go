package hub

import (
	"encoding/json"
	"time"

	"ph01-experience-hub/internal/governance"
)

const (
	StatusInbox    = "inbox"
	StatusNetwork  = "network"
	StatusRejected = "rejected"
	StatusCache    = "cache"

	ExperienceUploadSchemaVersion = "ph01.experience.upload.v1"
	ExperiencePackagePowPurpose   = "ph01.experience.package_submission.v1"

	DHTNodeSchemaVersion           = "ph01.experience.dht_node.v1"
	DHTRegisterSchemaVersion       = "ph01.experience.dht_register.v1"
	DHTNodePowSchemaVersion        = "ph01.experience.dht_node_pow.v1"
	DHTFlowerSchemaVersion         = "ph01.experience.dht_service_flower.v1"
	DHTWreathSchemaVersion         = "ph01.experience.dht_service_wreath.v1"
	DHTTrustSchemaVersion          = "ph01.experience.dht_trust_bundle.v1"
	ReviewChainSchemaVersion       = "ph01.experience.review_chain.v1"
	ReviewChainDemandSchemaVersion = "ph01.experience.review_chain_demand.v1"
	ExperienceDemandSchemaVersion  = "ph01.experience.demand.v1"
	DemandOfferSchemaVersion       = "ph01.experience.demand_offer.v1"

	DHTOwnerKindOfficial = "official"
	DHTOwnerKindUser     = "user"

	DHTRelayPolicyPublic    = "public"
	DHTRelayPolicyOwnerOnly = "owner_only"
	DHTRelayPolicyDisabled  = "disabled"

	DHTHealthHealthy   = "healthy"
	DHTHealthDegraded  = "degraded"
	DHTHealthUnhealthy = "unhealthy"
)

type Config struct {
	Listen         string                     `json:"listen"`
	StorageRoot    string                     `json:"storage_root"`
	AdminToken     string                     `json:"admin_token"`
	CORSOrigins    []string                   `json:"cors_origins"`
	MaxUploadBytes int64                      `json:"max_upload_bytes"`
	Governance     governance.Config          `json:"governance"`
	Review         ReviewConfig               `json:"review"`
	AuthCenter     AuthCenterConfig           `json:"auth_center"`
	ReviewChain    ReviewChainSchedulerConfig `json:"review_chain_scheduler"`
}

type ReviewConfig struct {
	TrustAdminUploads bool `json:"trust_admin_uploads"`
}

type ReviewChainSchedulerConfig struct {
	Enabled          bool `json:"enabled"`
	IntervalSeconds  int  `json:"interval_seconds"`
	PollDelaySeconds int  `json:"poll_delay_seconds"`
	Limit            int  `json:"limit"`
	DHTFanoutLimit   int  `json:"dht_fanout_limit"`
}

type AuthCenterConfig struct {
	BaseURL  string `json:"base_url"`
	Audience string `json:"audience,omitempty"`
}

type SignedRequest struct {
	Payload      string `json:"payload"`
	PubkeyHex    string `json:"pubkey"`
	SignatureHex string `json:"signature"`
	Timestamp    int64  `json:"timestamp"`
	Nonce        string `json:"nonce"`
}

type ExperienceUploadPayload struct {
	SchemaVersion string                `json:"schema_version,omitempty"`
	Filename      string                `json:"filename,omitempty"`
	PackageBase64 string                `json:"package_base64"`
	PackageSHA256 string                `json:"package_sha256,omitempty"`
	PackagePow    *ExperiencePackagePow `json:"package_pow,omitempty"`
}

type ExperiencePackagePow struct {
	ChallengeID   string `json:"challenge_id"`
	PackageSHA256 string `json:"package_sha256,omitempty"`
	PubkeyHash    string `json:"pubkey_hash"`
}

type ExperiencePackagePowChallengeRequest struct {
	PackageSHA256 string `json:"package_sha256"`
	PubkeyHash    string `json:"pubkey_hash"`
}

type ExperiencePackagePowChallengeResponse struct {
	ChallengeID string `json:"challenge_id"`
	ExpiresAt   int64  `json:"expires_at,omitempty"`
}

type Manifest struct {
	SchemaVersion string   `json:"schema_version,omitempty"`
	ExperienceID  string   `json:"experience_id"`
	Title         string   `json:"title"`
	Brief         string   `json:"brief,omitempty"`
	Keywords      []string `json:"keywords,omitempty"`
	CreatedAt     string   `json:"created_at,omitempty"`

	PublisherPubkey string `json:"publisher_pubkey,omitempty"`
	ContentHash     string `json:"content_hash,omitempty"`
}

type Index struct {
	UpdatedAt string       `json:"updated_at"`
	Items     []IndexEntry `json:"items"`
}

type IndexEntry struct {
	ExperienceID string   `json:"experience_id"`
	Title        string   `json:"title"`
	Brief        string   `json:"brief,omitempty"`
	Keywords     []string `json:"keywords,omitempty"`
	Status       string   `json:"status"`
	Path         string   `json:"path"`
	PackagePath  string   `json:"package_path"`
	RawPath      string   `json:"raw_path,omitempty"`
	ContentHash  string   `json:"content_hash,omitempty"`
	CreatedAt    string   `json:"created_at,omitempty"`
	UpdatedAt    string   `json:"updated_at"`
	ReviewReason string   `json:"review_reason,omitempty"`
}

type ListFilter struct {
	Status  string
	Keyword string
	Query   string
}

type SearchFilter struct {
	Status string
	Query  string
	Limit  int
}

type SearchResult struct {
	ExperienceID string `json:"experience_id"`
	Title        string `json:"title"`
	Status       string `json:"status"`
	Path         string `json:"path"`
	Line         int    `json:"line"`
	Column       int    `json:"column"`
	Snippet      string `json:"snippet"`
}

type ReviewRequest struct {
	Status       string `json:"status"`
	Reason       string `json:"reason,omitempty"`
	ReviewMode   string `json:"review_mode,omitempty"`
	ReviewedBy   string `json:"reviewed_by,omitempty"`
	ReviewedRole string `json:"reviewed_role,omitempty"`
}

type DHTIndex struct {
	UpdatedAt string    `json:"updated_at"`
	Items     []DHTNode `json:"items"`
}

type DHTEndpoint struct {
	Network           string `json:"network"`
	Host              string `json:"host"`
	Port              int    `json:"port"`
	RequiresHolePunch bool   `json:"requires_hole_punch,omitempty"`
}

type DHTLoad struct {
	RelayActiveSessions int `json:"relay_active_sessions"`
	RelayCapacity       int `json:"relay_capacity"`
}

type DHTNode struct {
	SchemaVersion     string          `json:"schema_version"`
	NodeID            string          `json:"node_id"`
	OwnerKind         string          `json:"owner_kind"`
	OwnerPeerID       string          `json:"owner_peer_id,omitempty"`
	DHTPeerID         string          `json:"dht_peer_id,omitempty"`
	NodePow           *DHTNodePow     `json:"node_pow,omitempty"`
	Endpoints         []DHTEndpoint   `json:"endpoints"`
	Capabilities      map[string]bool `json:"capabilities"`
	RelayPolicy       string          `json:"relay_policy"`
	Region            string          `json:"region,omitempty"`
	Load              DHTLoad         `json:"load"`
	HealthStatus      string          `json:"health_status"`
	LastHealthCheckAt string          `json:"last_health_check_at"`
	ExpiresAt         string          `json:"expires_at"`
}

type DHTRegisterRequest struct {
	SchemaVersion      string          `json:"schema_version,omitempty"`
	NodeID             string          `json:"node_id"`
	OwnerKind          string          `json:"owner_kind,omitempty"`
	OwnerPeerID        string          `json:"owner_peer_id,omitempty"`
	DHTPeerID          string          `json:"dht_peer_id,omitempty"`
	NodePow            *DHTNodePow     `json:"node_pow,omitempty"`
	Endpoints          []DHTEndpoint   `json:"endpoints"`
	Capabilities       map[string]bool `json:"capabilities,omitempty"`
	RelayPolicy        string          `json:"relay_policy,omitempty"`
	Region             string          `json:"region,omitempty"`
	Load               DHTLoad         `json:"load,omitempty"`
	TTLSeconds         int             `json:"ttl_seconds,omitempty"`
	AdminSignedRequest *SignedRequest  `json:"admin_signed_request,omitempty"`
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
	SchemaVersion          string          `json:"schema_version,omitempty"`
	WreathID               string          `json:"wreath_id"`
	NodeID                 string          `json:"node_id"`
	FlowerCount            int             `json:"flower_count"`
	UniqueClientCount      int             `json:"unique_client_count"`
	LastServedAt           string          `json:"last_served_at"`
	CreatedAt              string          `json:"created_at"`
	SourceFlowerIDs        []string        `json:"source_flower_ids,omitempty"`
	SignaturePayloadSHA256 string          `json:"signature_payload_sha256,omitempty"`
	SignatureAlgorithm     string          `json:"signature_algorithm,omitempty"`
	ManagerSignature       string          `json:"manager_signature,omitempty"`
	ManagerCertificate     json.RawMessage `json:"manager_certificate,omitempty"`
}

type DHTTrustBundle struct {
	SchemaVersion string             `json:"schema_version"`
	NodeID        string             `json:"node_id"`
	NodePow       *DHTNodePow        `json:"node_pow,omitempty"`
	Wreaths       []DHTServiceWreath `json:"wreaths"`
	Flowers       []DHTServiceFlower `json:"flowers"`
	UpdatedAt     string             `json:"updated_at"`
}

type DHTFlowerIndex struct {
	UpdatedAt string             `json:"updated_at"`
	Items     []DHTServiceFlower `json:"items"`
}

type DHTWreathIndex struct {
	UpdatedAt string             `json:"updated_at"`
	Items     []DHTServiceWreath `json:"items"`
}

type DHTHealthResult struct {
	Status  string `json:"status"`
	Message string `json:"message,omitempty"`
}

type ExperienceReviewChain struct {
	SchemaVersion     string           `json:"schema_version"`
	ExperienceID      string           `json:"experience_id"`
	PackageHash       string           `json:"package_hash"`
	ReviewChain       []map[string]any `json:"review_chain"`
	ReviewChainDigest string           `json:"review_chain_digest"`
	ReviewChainLength int              `json:"review_chain_length"`
	UpdatedAt         string           `json:"updated_at"`
}

type ReviewChainDemand struct {
	SchemaVersion       string   `json:"schema_version"`
	RequestID           string   `json:"request_id"`
	ExperienceID        string   `json:"experience_id"`
	PackageHash         string   `json:"package_hash"`
	ReviewChainDigest   string   `json:"review_chain_digest,omitempty"`
	ReviewChainLength   int      `json:"review_chain_length,omitempty"`
	PreferredTransports []string `json:"preferred_transports,omitempty"`
	TTLSeconds          int      `json:"ttl_seconds,omitempty"`
	CreatedAt           string   `json:"created_at"`
}

type ReviewChainRefreshPlan struct {
	SchemaVersion          string              `json:"schema_version"`
	GeneratedAt            string              `json:"generated_at"`
	NetworkPackageCount    int                 `json:"network_package_count"`
	RefreshIntervalSeconds int                 `json:"refresh_interval_seconds"`
	LimitPerMinute         int                 `json:"limit_per_minute"`
	Items                  []ReviewChainDemand `json:"items"`
}

type ReviewChainCandidateIndex struct {
	UpdatedAt string                  `json:"updated_at"`
	Items     []ExperienceReviewChain `json:"items"`
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
	RequesterPubkeyHash  string            `json:"requester_pubkey_hash,omitempty"`
	PreferredTransports  []string          `json:"preferred_transports,omitempty"`
	TTLSeconds           int               `json:"ttl_seconds,omitempty"`
	HopLimit             int               `json:"hop_limit,omitempty"`
	ReturnPath           []DemandReturnHop `json:"return_path,omitempty"`
	CreatedAt            string            `json:"created_at,omitempty"`
	Nonce                string            `json:"nonce,omitempty"`
}

type ReviewChainRef struct {
	Digest string `json:"digest"`
	Length int    `json:"length"`
	URL    string `json:"url,omitempty"`
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
	ProviderAddrs       []DHTEndpoint     `json:"provider_addrs,omitempty"`
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

type ErrorResponse struct {
	Error   string `json:"error"`
	Message string `json:"message,omitempty"`
}

func nowRFC3339() string {
	return time.Now().UTC().Format(time.RFC3339)
}
