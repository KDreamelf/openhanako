package hub

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const reviewChainRefreshPlanSchema = "ph01.experience.review_chain_refresh_plan.v1"

func (s *Store) ReviewChain(id string) (ExperienceReviewChain, error) {
	item, err := s.Get(id)
	if err != nil {
		return ExperienceReviewChain{}, err
	}
	info, err := s.PackageInfo(id)
	if err != nil {
		return ExperienceReviewChain{}, err
	}
	chain := reviewChainFromRatingsData(info.RatingsData)
	if len(chain) == 0 {
		return ExperienceReviewChain{}, ErrMissingRatingsDat
	}
	return ExperienceReviewChain{
		SchemaVersion:     ReviewChainSchemaVersion,
		ExperienceID:      item.ExperienceID,
		PackageHash:       info.Manifest.ContentHash,
		ReviewChain:       chain,
		ReviewChainDigest: reviewChainDigest(chain),
		ReviewChainLength: len(chain),
		UpdatedAt:         item.UpdatedAt,
	}, nil
}

func (s *Store) ReviewChainRefreshPlan(now time.Time, limit int) (ReviewChainRefreshPlan, error) {
	if limit <= 0 {
		limit = 1
	}
	if limit > 20 {
		limit = 20
	}
	items, err := s.List(ListFilter{Status: StatusNetwork})
	if err != nil {
		return ReviewChainRefreshPlan{}, err
	}
	sort.SliceStable(items, func(i, j int) bool {
		return items[i].UpdatedAt < items[j].UpdatedAt
	})
	interval := reviewChainRefreshInterval(len(items))
	plan := ReviewChainRefreshPlan{
		SchemaVersion:          reviewChainRefreshPlanSchema,
		GeneratedAt:            now.UTC().Format(time.RFC3339),
		NetworkPackageCount:    len(items),
		RefreshIntervalSeconds: int(interval.Seconds()),
		LimitPerMinute:         reviewChainLimitPerMinute(len(items)),
		Items:                  []ReviewChainDemand{},
	}
	for _, item := range items {
		if len(plan.Items) >= limit {
			break
		}
		chain, err := s.ReviewChain(item.ExperienceID)
		if err != nil {
			continue
		}
		plan.Items = append(plan.Items, ReviewChainDemand{
			SchemaVersion:       ReviewChainDemandSchemaVersion,
			RequestID:           reviewChainDemandID(chain, now),
			ExperienceID:        chain.ExperienceID,
			PackageHash:         chain.PackageHash,
			ReviewChainDigest:   chain.ReviewChainDigest,
			ReviewChainLength:   chain.ReviewChainLength,
			PreferredTransports: []string{"dht_relay", "manager_seed"},
			TTLSeconds:          3600,
			CreatedAt:           now.UTC().Format(time.RFC3339),
		})
	}
	return plan, nil
}

func (s *Store) ResolveExperienceDemandOffers(requestID, query string, limit int, now time.Time) ([]ExperienceDemandOfferRecord, error) {
	requestID = strings.TrimSpace(requestID)
	query = strings.TrimSpace(query)
	if query == "" {
		return nil, ErrInvalidQuery
	}
	if limit <= 0 {
		limit = 5
	}
	if limit > 20 {
		limit = 20
	}
	items, err := s.List(ListFilter{Status: StatusNetwork, Query: query})
	if err != nil {
		return nil, err
	}
	if len(items) > limit {
		items = items[:limit]
	}
	offeredAt := now.UTC().Format(time.RFC3339)
	out := make([]ExperienceDemandOfferRecord, 0, len(items))
	for _, item := range items {
		chain, err := s.ReviewChain(item.ExperienceID)
		if err != nil || chain.ReviewChainLength == 0 {
			continue
		}
		out = append(out, ExperienceDemandOfferRecord{
			ExperienceDemandOffer: ExperienceDemandOffer{
				SchemaVersion:       DemandOfferSchemaVersion,
				RequestID:           requestID,
				ExperienceID:        item.ExperienceID,
				PackageHash:         chain.PackageHash,
				Title:               item.Title,
				Brief:               item.Brief,
				Keywords:            item.Keywords,
				MatchedReason:       "经验管理端公开索引兜底命中",
				ReviewChain:         chain.ReviewChain,
				ReviewChainDigest:   chain.ReviewChainDigest,
				ReviewChainLength:   chain.ReviewChainLength,
				ProviderPeerID:      "experience-manager",
				AvailableTransports: []string{"manager_seed"},
				Nonce:               reviewChainDemandID(chain, now),
				Timestamp:           offeredAt,
			},
			OfferedAt: offeredAt,
		})
	}
	return out, nil
}

func (s *Store) AcceptReviewChainCandidate(candidate ExperienceReviewChain) (ExperienceReviewChain, error) {
	if !idPattern.MatchString(strings.TrimSpace(candidate.ExperienceID)) ||
		strings.TrimSpace(candidate.PackageHash) == "" ||
		len(candidate.ReviewChain) == 0 {
		return ExperienceReviewChain{}, ErrInvalidQuery
	}
	if candidate.SchemaVersion == "" {
		candidate.SchemaVersion = ReviewChainSchemaVersion
	}
	if candidate.SchemaVersion != ReviewChainSchemaVersion {
		return ExperienceReviewChain{}, ErrInvalidQuery
	}
	candidate.ExperienceID = strings.TrimSpace(candidate.ExperienceID)
	candidate.PackageHash = strings.TrimSpace(candidate.PackageHash)
	candidate.ReviewChainDigest = reviewChainDigest(candidate.ReviewChain)
	candidate.ReviewChainLength = len(candidate.ReviewChain)
	candidate.UpdatedAt = nowRFC3339()

	s.mu.Lock()
	defer s.mu.Unlock()
	idx, err := s.readReviewChainCandidates()
	if err != nil {
		return ExperienceReviewChain{}, err
	}
	for i, item := range idx.Items {
		if item.ExperienceID != candidate.ExperienceID {
			continue
		}
		if item.ReviewChainLength >= candidate.ReviewChainLength {
			return item, nil
		}
		idx.Items[i] = candidate
		idx.UpdatedAt = nowRFC3339()
		if err := s.writeReviewChainCandidates(idx); err != nil {
			return ExperienceReviewChain{}, err
		}
		return candidate, nil
	}
	idx.Items = append(idx.Items, candidate)
	idx.UpdatedAt = nowRFC3339()
	if err := s.writeReviewChainCandidates(idx); err != nil {
		return ExperienceReviewChain{}, err
	}
	return candidate, nil
}

func reviewChainRefreshInterval(count int) time.Duration {
	switch {
	case count <= 1000:
		return 72 * time.Hour
	case count <= 10000:
		return 7 * 24 * time.Hour
	default:
		return 30 * 24 * time.Hour
	}
}

func reviewChainLimitPerMinute(count int) int {
	if count > 10000 {
		return 3
	}
	return 1
}

func reviewChainFromRatingsData(data []byte) []map[string]any {
	lines := strings.Split(string(data), "\n")
	out := make([]map[string]any, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var item map[string]any
		if err := json.Unmarshal([]byte(line), &item); err == nil {
			out = append(out, item)
			continue
		}
		out = append(out, map[string]any{
			"schema_version": "ph01.experience.ratings.raw.v1",
			"raw":            line,
		})
	}
	return out
}

func reviewChainDigest(chain []map[string]any) string {
	data, err := json.Marshal(chain)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(data)
	return "sha256:" + hex.EncodeToString(sum[:])
}

func reviewChainDemandID(chain ExperienceReviewChain, now time.Time) string {
	sum := sha256.Sum256([]byte(strings.Join([]string{
		"ph01.experience.review_chain_demand.v1",
		chain.ExperienceID,
		chain.PackageHash,
		now.UTC().Format("2006-01-02T15:04"),
	}, "\n")))
	return "rc_" + hex.EncodeToString(sum[:])[:24]
}

func (s *Store) reviewChainCandidatesPath() string {
	return filepath.Join(s.root, "review_chain_candidates.json")
}

func (s *Store) readReviewChainCandidates() (ReviewChainCandidateIndex, error) {
	data, err := os.ReadFile(s.reviewChainCandidatesPath())
	if errors.Is(err, os.ErrNotExist) {
		return ReviewChainCandidateIndex{UpdatedAt: nowRFC3339(), Items: []ExperienceReviewChain{}}, nil
	}
	if err != nil {
		return ReviewChainCandidateIndex{}, err
	}
	var idx ReviewChainCandidateIndex
	if err := json.Unmarshal(data, &idx); err != nil {
		return ReviewChainCandidateIndex{}, err
	}
	if idx.Items == nil {
		idx.Items = []ExperienceReviewChain{}
	}
	return idx, nil
}

func (s *Store) writeReviewChainCandidates(idx ReviewChainCandidateIndex) error {
	if err := os.MkdirAll(s.root, 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(idx, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(s.reviewChainCandidatesPath(), data, 0o644)
}
