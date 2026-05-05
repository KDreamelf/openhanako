package hub

import (
	"time"

	"ph01-experience-hub/internal/governance"
)

const (
	StatusInbox    = "inbox"
	StatusNetwork  = "network"
	StatusRejected = "rejected"
	StatusCache    = "cache"
)

type Config struct {
	Listen         string            `json:"listen"`
	StorageRoot    string            `json:"storage_root"`
	AdminToken     string            `json:"admin_token"`
	CORSOrigins    []string          `json:"cors_origins"`
	MaxUploadBytes int64             `json:"max_upload_bytes"`
	Governance     governance.Config `json:"governance"`
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
	Status string `json:"status"`
	Reason string `json:"reason,omitempty"`
}

type ErrorResponse struct {
	Error   string `json:"error"`
	Message string `json:"message,omitempty"`
}

func nowRFC3339() string {
	return time.Now().UTC().Format(time.RFC3339)
}
