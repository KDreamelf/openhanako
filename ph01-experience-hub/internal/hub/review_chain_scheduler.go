package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"ph01-experience-hub/internal/governance"
)

const managerDemandPeerID = "experience-manager"

var errReviewChainSchedulerNotConfigured = errors.New("review chain scheduler is not configured")

type ReviewChainScheduler struct {
	Store      *Store
	Governance *governance.Service
	Config     ReviewChainSchedulerConfig
	Client     *http.Client
}

func (s *ReviewChainScheduler) Run(ctx context.Context) {
	interval := s.interval()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		if err := s.RunOnce(ctx, time.Now().UTC()); err != nil && !errors.Is(err, context.Canceled) {
			log.Printf("[warn] review-chain scheduler: %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (s *ReviewChainScheduler) RunOnce(ctx context.Context, now time.Time) error {
	if s == nil || s.Store == nil || s.Governance == nil || s.Governance.Master == nil {
		return errReviewChainSchedulerNotConfigured
	}
	plan, err := s.Store.ReviewChainRefreshPlan(now, s.limit())
	if err != nil {
		return err
	}
	if len(plan.Items) == 0 {
		return nil
	}
	nodes, err := s.Store.ListDHTNodes(now)
	if err != nil {
		return err
	}
	bases := dhtAPIBaseURLs(nodes, s.dhtFanoutLimit())
	if len(bases) == 0 {
		return nil
	}
	for _, demand := range plan.Items {
		signed, err := s.signDemand(demand, now)
		if err != nil {
			return err
		}
		for _, baseURL := range bases {
			if err := s.postDemand(ctx, baseURL, signed); err != nil {
				log.Printf("[warn] review-chain demand post failed dht=%s request=%s err=%v", baseURL, demand.RequestID, err)
			}
		}
	}
	if delay := s.pollDelay(); delay > 0 {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
	}
	for _, demand := range plan.Items {
		for _, baseURL := range bases {
			offers, err := s.fetchDemandOffers(ctx, baseURL, demand.RequestID)
			if err != nil {
				log.Printf("[warn] review-chain offer poll failed dht=%s request=%s err=%v", baseURL, demand.RequestID, err)
				continue
			}
			for _, offer := range offers {
				chain := offer.ReviewChain
				if len(chain) == 0 {
					chain, err = s.fetchOfferReviewChain(ctx, baseURL, offer)
					if err != nil {
						log.Printf("[warn] review-chain fetch failed dht=%s request=%s err=%v", baseURL, demand.RequestID, err)
						continue
					}
				}
				if len(chain) == 0 {
					continue
				}
				_, err = s.Store.AcceptReviewChainCandidate(ExperienceReviewChain{
					SchemaVersion: ReviewChainSchemaVersion,
					ExperienceID:  nonEmptyString(offer.ExperienceID, demand.ExperienceID),
					PackageHash:   nonEmptyString(offer.PackageHash, demand.PackageHash),
					ReviewChain:   chain,
				})
				if err != nil {
					log.Printf("[warn] review-chain candidate rejected request=%s experience=%s err=%v", demand.RequestID, offer.ExperienceID, err)
				}
			}
		}
	}
	return nil
}

func (s *ReviewChainScheduler) signDemand(demand ReviewChainDemand, now time.Time) (SignedRequest, error) {
	payload := ExperienceDemand{
		SchemaVersion:        ExperienceDemandSchemaVersion,
		RequestID:            demand.RequestID,
		NaturalLanguageQuery: reviewChainDemandQuery(demand),
		QueryLanguage:        "zh-CN",
		QueryKeywords: []string{
			demand.ExperienceID,
			demand.PackageHash,
			demand.ReviewChainDigest,
			"评价链",
		},
		RequesterPeerID:     managerDemandPeerID,
		PreferredTransports: demand.PreferredTransports,
		TTLSeconds:          demand.TTLSeconds,
		HopLimit:            8,
		CreatedAt:           demand.CreatedAt,
		Nonce:               demand.RequestID,
	}
	if payload.CreatedAt == "" {
		payload.CreatedAt = now.UTC().Format(time.RFC3339)
	}
	if payload.TTLSeconds <= 0 {
		payload.TTLSeconds = 3600
	}
	if len(payload.PreferredTransports) == 0 {
		payload.PreferredTransports = []string{"dht_relay", "manager_seed"}
	}
	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		return SignedRequest{}, err
	}
	pubkey := s.Governance.Master.PublicKeyHex
	timestamp := now.UTC().Unix()
	nonce := demand.RequestID + "-" + strconv.FormatInt(timestamp, 10)
	signed := fmt.Sprintf("%s\n%s\n%d\n%s", string(payloadBytes), pubkey, timestamp, nonce)
	signature, err := governance.Sign(s.Governance.Master.PrivateKey, []byte(signed))
	if err != nil {
		return SignedRequest{}, err
	}
	return SignedRequest{
		Payload:      string(payloadBytes),
		PubkeyHex:    pubkey,
		SignatureHex: signature,
		Timestamp:    timestamp,
		Nonce:        nonce,
	}, nil
}

func (s *ReviewChainScheduler) postDemand(ctx context.Context, baseURL string, signed SignedRequest) error {
	body, err := json.Marshal(signed)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/api/v1/experience-demands", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := s.httpClient().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return fmt.Errorf("dht demand status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(data)))
	}
	return nil
}

func (s *ReviewChainScheduler) fetchDemandOffers(ctx context.Context, baseURL, requestID string) ([]ExperienceDemandOfferRecord, error) {
	endpoint, err := url.Parse(baseURL + "/api/v1/experience-demands/" + url.PathEscape(requestID) + "/offers")
	if err != nil {
		return nil, err
	}
	query := endpoint.Query()
	query.Set("include_review_chain", "false")
	endpoint.RawQuery = query.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return nil, err
	}
	resp, err := s.httpClient().Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return nil, fmt.Errorf("dht offers status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(data)))
	}
	var out struct {
		Items []ExperienceDemandOfferRecord `json:"items"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return out.Items, nil
}

func (s *ReviewChainScheduler) fetchOfferReviewChain(ctx context.Context, baseURL string, offer ExperienceDemandOfferRecord) ([]map[string]any, error) {
	ref := offer.ReviewChainRef
	if ref == nil || strings.TrimSpace(ref.URL) == "" {
		return nil, nil
	}
	endpoint, err := url.Parse(strings.TrimSpace(ref.URL))
	if err != nil {
		return nil, err
	}
	if !endpoint.IsAbs() {
		root, err := url.Parse(baseURL)
		if err != nil {
			return nil, err
		}
		endpoint = root.ResolveReference(endpoint)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return nil, err
	}
	resp, err := s.httpClient().Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return nil, fmt.Errorf("review chain status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(data)))
	}
	var payload struct {
		ReviewChain []map[string]any `json:"review_chain"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, err
	}
	return payload.ReviewChain, nil
}

func (s *ReviewChainScheduler) httpClient() *http.Client {
	if s.Client != nil {
		return s.Client
	}
	return &http.Client{Timeout: 10 * time.Second}
}

func (s *ReviewChainScheduler) interval() time.Duration {
	if s.Config.IntervalSeconds > 0 {
		return time.Duration(s.Config.IntervalSeconds) * time.Second
	}
	return time.Minute
}

func (s *ReviewChainScheduler) pollDelay() time.Duration {
	if s.Config.PollDelaySeconds <= 0 {
		return 0
	}
	return time.Duration(s.Config.PollDelaySeconds) * time.Second
}

func (s *ReviewChainScheduler) limit() int {
	if s.Config.Limit <= 0 {
		return 1
	}
	if s.Config.Limit > 20 {
		return 20
	}
	return s.Config.Limit
}

func (s *ReviewChainScheduler) dhtFanoutLimit() int {
	if s.Config.DHTFanoutLimit <= 0 {
		return 3
	}
	if s.Config.DHTFanoutLimit > 20 {
		return 20
	}
	return s.Config.DHTFanoutLimit
}

func dhtAPIBaseURLs(nodes []DHTNode, limit int) []string {
	out := make([]string, 0, len(nodes))
	seen := map[string]struct{}{}
	for _, node := range nodes {
		baseURL := dhtAPIBaseURL(node)
		if baseURL == "" {
			continue
		}
		if _, exists := seen[baseURL]; exists {
			continue
		}
		seen[baseURL] = struct{}{}
		out = append(out, baseURL)
		if limit > 0 && len(out) >= limit {
			break
		}
	}
	return out
}

func dhtAPIBaseURL(node DHTNode) string {
	var fallback string
	for _, endpoint := range node.Endpoints {
		network := normalizeDHTNetwork(endpoint.Network)
		if network != "https" && network != "http" {
			continue
		}
		baseURL := network + "://" + endpoint.Host
		if endpoint.Port > 0 && !((network == "https" && endpoint.Port == 443) || (network == "http" && endpoint.Port == 80)) {
			baseURL += ":" + strconv.Itoa(endpoint.Port)
		}
		if network == "https" {
			return baseURL
		}
		if fallback == "" {
			fallback = baseURL
		}
	}
	return fallback
}

func reviewChainDemandQuery(demand ReviewChainDemand) string {
	parts := []string{"拉取经验包评价链"}
	if strings.TrimSpace(demand.ExperienceID) != "" {
		parts = append(parts, "experience_id="+strings.TrimSpace(demand.ExperienceID))
	}
	if strings.TrimSpace(demand.PackageHash) != "" {
		parts = append(parts, "package_hash="+strings.TrimSpace(demand.PackageHash))
	}
	if strings.TrimSpace(demand.ReviewChainDigest) != "" {
		parts = append(parts, "known_review_chain="+strings.TrimSpace(demand.ReviewChainDigest))
	}
	if demand.ReviewChainLength > 0 {
		parts = append(parts, "known_length="+strconv.Itoa(demand.ReviewChainLength))
	}
	return strings.Join(parts, " ")
}

func nonEmptyString(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}
