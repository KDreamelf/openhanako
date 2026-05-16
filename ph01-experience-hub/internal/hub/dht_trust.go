package hub

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"ph01-experience-hub/internal/governance"
)

const DHTPowAlgorithm = "ph01.dht_memory_pow.v1"

var (
	ErrInvalidDHTNodePow = errors.New("invalid dht node pow")
	ErrInvalidDHTFlower  = errors.New("invalid dht service flower")
	ErrInvalidDHTWreath  = errors.New("invalid dht service wreath")
)

func VerifyDHTNodePow(pow *DHTNodePow) error {
	if pow == nil {
		return ErrInvalidDHTNodePow
	}
	if strings.TrimSpace(pow.SchemaVersion) != "" && pow.SchemaVersion != DHTNodePowSchemaVersion {
		return ErrInvalidDHTNodePow
	}
	if !idPattern.MatchString(strings.TrimSpace(pow.NodeID)) {
		return ErrInvalidDHTNodePow
	}
	if strings.TrimSpace(pow.OwnerPubkeyHash) == "" || strings.TrimSpace(pow.Seed) == "" || strings.TrimSpace(pow.SolutionNonce) == "" {
		return ErrInvalidDHTNodePow
	}
	if strings.TrimSpace(pow.OwnerPubkeyHex) != "" {
		hash, err := dhtPubkeyHash(pow.OwnerPubkeyHex)
		if err != nil || !strings.EqualFold(hash, pow.OwnerPubkeyHash) {
			return ErrInvalidDHTNodePow
		}
	}
	if pow.Algorithm != DHTPowAlgorithm {
		return ErrInvalidDHTNodePow
	}
	digest := dhtPowDigest(pow.NodeID, pow.OwnerPubkeyHash, pow.Seed, pow.SolutionNonce, pow.MemoryKiB, pow.RoundCount)
	if !hasLeadingZeroBits(digest[:], normalizeDHTPowDifficultyBits(pow.DifficultyBits)) {
		return ErrInvalidDHTNodePow
	}
	return nil
}

func SolveDHTNodePow(nodeID, ownerPubkeyHex string, difficultyBits, memoryKiB, roundCount int, maxAttempts uint64) (DHTNodePow, bool, error) {
	hash, err := dhtPubkeyHash(ownerPubkeyHex)
	if err != nil {
		return DHTNodePow{}, false, err
	}
	seed, err := randomHex(32)
	if err != nil {
		return DHTNodePow{}, false, err
	}
	if maxAttempts == 0 {
		maxAttempts = 1 << 24
	}
	pow := DHTNodePow{
		SchemaVersion:   DHTNodePowSchemaVersion,
		NodeID:          strings.TrimSpace(nodeID),
		OwnerPubkeyHex:  strings.ToLower(strings.TrimSpace(ownerPubkeyHex)),
		OwnerPubkeyHash: hash,
		Algorithm:       DHTPowAlgorithm,
		DifficultyBits:  normalizeDHTPowDifficultyBits(difficultyBits),
		MemoryKiB:       normalizeDHTPowMemoryKiB(memoryKiB),
		RoundCount:      normalizeDHTPowRoundCount(roundCount),
		Seed:            seed,
		CreatedAt:       nowRFC3339(),
	}
	for i := uint64(0); i < maxAttempts; i++ {
		nonce := fmt.Sprintf("%x", i)
		pow.SolutionNonce = nonce
		if VerifyDHTNodePow(&pow) == nil {
			return pow, true, nil
		}
	}
	return pow, false, nil
}

func ValidateDHTServiceFlower(flower DHTServiceFlower) (DHTServiceFlower, error) {
	flower.SchemaVersion = strings.TrimSpace(flower.SchemaVersion)
	if flower.SchemaVersion == "" {
		flower.SchemaVersion = DHTFlowerSchemaVersion
	}
	if flower.SchemaVersion != DHTFlowerSchemaVersion ||
		!idPattern.MatchString(strings.TrimSpace(flower.FlowerID)) ||
		!idPattern.MatchString(strings.TrimSpace(flower.NodeID)) ||
		strings.TrimSpace(flower.ClientPubkeyHex) == "" ||
		strings.TrimSpace(flower.ResourceHash) == "" ||
		strings.TrimSpace(flower.ServedAt) == "" ||
		strings.TrimSpace(flower.SignatureHex) == "" {
		return DHTServiceFlower{}, ErrInvalidDHTFlower
	}
	flower.FlowerID = strings.TrimSpace(flower.FlowerID)
	flower.NodeID = strings.TrimSpace(flower.NodeID)
	flower.ClientPubkeyHex = strings.ToLower(strings.TrimSpace(flower.ClientPubkeyHex))
	flower.ClientPubkeyHash = strings.ToLower(strings.TrimSpace(flower.ClientPubkeyHash))
	flower.ResourceHash = strings.TrimSpace(flower.ResourceHash)
	flower.WorkKind = strings.TrimSpace(flower.WorkKind)
	if flower.WorkKind == "" {
		flower.WorkKind = "relay"
	}
	hash, err := dhtPubkeyHash(flower.ClientPubkeyHex)
	if err != nil || (flower.ClientPubkeyHash != "" && !strings.EqualFold(hash, flower.ClientPubkeyHash)) {
		return DHTServiceFlower{}, ErrInvalidDHTFlower
	}
	flower.ClientPubkeyHash = hash
	if _, err := time.Parse(time.RFC3339, flower.ServedAt); err != nil {
		return DHTServiceFlower{}, ErrInvalidDHTFlower
	}
	payload := DHTServiceFlowerSigningPayload(flower)
	if err := governance.Verify(flower.ClientPubkeyHex, payload, flower.SignatureHex); err != nil {
		return DHTServiceFlower{}, ErrInvalidDHTFlower
	}
	if strings.TrimSpace(flower.ReceivedAt) == "" {
		flower.ReceivedAt = nowRFC3339()
	}
	return flower, nil
}

func DHTServiceFlowerSigningPayload(flower DHTServiceFlower) []byte {
	lines := []string{
		DHTFlowerSchemaVersion,
		strings.TrimSpace(flower.FlowerID),
		strings.TrimSpace(flower.NodeID),
		strings.ToLower(strings.TrimSpace(flower.ClientPubkeyHash)),
		strings.TrimSpace(flower.ResourceHash),
		strings.TrimSpace(flower.WorkKind),
		strings.TrimSpace(flower.ServedAt),
	}
	return []byte(strings.Join(lines, "\n"))
}

func (s *Store) initDHTTrustIndexes() error {
	if _, err := os.Stat(s.dhtFlowersPath()); os.IsNotExist(err) {
		if err := s.writeDHTFlowers(DHTFlowerIndex{UpdatedAt: nowRFC3339(), Items: []DHTServiceFlower{}}); err != nil {
			return err
		}
	}
	if _, err := os.Stat(s.dhtWreathsPath()); os.IsNotExist(err) {
		if err := s.writeDHTWreaths(DHTWreathIndex{UpdatedAt: nowRFC3339(), Items: []DHTServiceWreath{}}); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) AppendDHTServiceFlower(flower DHTServiceFlower) (DHTServiceFlower, error) {
	validated, err := ValidateDHTServiceFlower(flower)
	if err != nil {
		return DHTServiceFlower{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	idx, err := s.readDHTFlowers()
	if err != nil {
		return DHTServiceFlower{}, err
	}
	for _, item := range idx.Items {
		if item.FlowerID == validated.FlowerID {
			return item, nil
		}
	}
	idx.Items = append(idx.Items, validated)
	idx.UpdatedAt = nowRFC3339()
	if err := s.writeDHTFlowers(idx); err != nil {
		return DHTServiceFlower{}, err
	}
	return validated, nil
}

func (s *Store) ListDHTServiceFlowers(nodeID string, limit int) ([]DHTServiceFlower, error) {
	if !idPattern.MatchString(nodeID) {
		return nil, ErrInvalidDHTNode
	}
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	idx, err := s.readDHTFlowers()
	if err != nil {
		return nil, err
	}
	out := make([]DHTServiceFlower, 0, limit)
	for i := len(idx.Items) - 1; i >= 0 && len(out) < limit; i-- {
		item := idx.Items[i]
		if item.NodeID == nodeID {
			out = append(out, item)
		}
	}
	return out, nil
}

func (s *Store) AggregateDHTServiceFlowers(nodeID string, limit int, gov *governance.Service) (DHTServiceWreath, error) {
	flowers, err := s.ListDHTServiceFlowers(nodeID, limit)
	if err != nil {
		return DHTServiceWreath{}, err
	}
	if len(flowers) == 0 {
		return DHTServiceWreath{}, ErrInvalidDHTWreath
	}
	wreath, err := BuildDHTServiceWreath(nodeID, flowers, gov)
	if err != nil {
		return DHTServiceWreath{}, err
	}
	return s.AppendDHTServiceWreath(wreath)
}

func BuildDHTServiceWreath(nodeID string, flowers []DHTServiceFlower, gov *governance.Service) (DHTServiceWreath, error) {
	if !idPattern.MatchString(strings.TrimSpace(nodeID)) || len(flowers) == 0 {
		return DHTServiceWreath{}, ErrInvalidDHTWreath
	}
	sourceIDs := make([]string, 0, len(flowers))
	clients := map[string]struct{}{}
	lastServedAt := ""
	for _, flower := range flowers {
		sourceIDs = append(sourceIDs, flower.FlowerID)
		clients[flower.ClientPubkeyHash] = struct{}{}
		if flower.ServedAt > lastServedAt {
			lastServedAt = flower.ServedAt
		}
	}
	sort.Strings(sourceIDs)
	wreath := DHTServiceWreath{
		SchemaVersion:     DHTWreathSchemaVersion,
		WreathID:          "wr_" + sha256Hex([]byte(strings.Join(sourceIDs, "\n"))),
		NodeID:            nodeID,
		FlowerCount:       len(flowers),
		UniqueClientCount: len(clients),
		LastServedAt:      lastServedAt,
		CreatedAt:         nowRFC3339(),
		SourceFlowerIDs:   sourceIDs,
	}
	payload, err := json.Marshal(wreathPayload(wreath))
	if err != nil {
		return DHTServiceWreath{}, err
	}
	wreath.SignaturePayloadSHA256 = sha256Hex(payload)
	if gov != nil && gov.Master != nil {
		signature, err := governance.Sign(gov.Master.PrivateKey, payload)
		if err != nil {
			return DHTServiceWreath{}, err
		}
		wreath.SignatureAlgorithm = governance.Algorithm
		wreath.ManagerSignature = signature
		wreath.ManagerCertificate = gov.MasterCertificateRaw
	}
	return wreath, nil
}

func (s *Store) AppendDHTServiceWreath(wreath DHTServiceWreath) (DHTServiceWreath, error) {
	if !idPattern.MatchString(strings.TrimSpace(wreath.NodeID)) || strings.TrimSpace(wreath.WreathID) == "" || wreath.FlowerCount <= 0 {
		return DHTServiceWreath{}, ErrInvalidDHTWreath
	}
	if wreath.SchemaVersion == "" {
		wreath.SchemaVersion = DHTWreathSchemaVersion
	}
	if wreath.SchemaVersion != DHTWreathSchemaVersion {
		return DHTServiceWreath{}, ErrInvalidDHTWreath
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	idx, err := s.readDHTWreaths()
	if err != nil {
		return DHTServiceWreath{}, err
	}
	for _, item := range idx.Items {
		if item.WreathID == wreath.WreathID {
			return item, nil
		}
	}
	idx.Items = append(idx.Items, wreath)
	idx.UpdatedAt = nowRFC3339()
	if err := s.writeDHTWreaths(idx); err != nil {
		return DHTServiceWreath{}, err
	}
	return wreath, nil
}

func (s *Store) ListDHTServiceWreaths(nodeID string, limit int) ([]DHTServiceWreath, error) {
	if !idPattern.MatchString(nodeID) {
		return nil, ErrInvalidDHTNode
	}
	if limit <= 0 || limit > 10 {
		limit = 10
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	idx, err := s.readDHTWreaths()
	if err != nil {
		return nil, err
	}
	out := make([]DHTServiceWreath, 0, limit)
	for i := len(idx.Items) - 1; i >= 0 && len(out) < limit; i-- {
		item := idx.Items[i]
		if item.NodeID == nodeID {
			out = append(out, item)
		}
	}
	return out, nil
}

func (s *Store) DHTTrustBundle(nodeID string) (DHTTrustBundle, error) {
	node, err := s.GetDHTNode(nodeID)
	if err != nil {
		return DHTTrustBundle{}, err
	}
	wreaths, err := s.ListDHTServiceWreaths(nodeID, 10)
	if err != nil {
		return DHTTrustBundle{}, err
	}
	flowers, err := s.ListDHTServiceFlowers(nodeID, 100)
	if err != nil {
		return DHTTrustBundle{}, err
	}
	return DHTTrustBundle{
		SchemaVersion: DHTTrustSchemaVersion,
		NodeID:        nodeID,
		NodePow:       node.NodePow,
		Wreaths:       wreaths,
		Flowers:       flowers,
		UpdatedAt:     nowRFC3339(),
	}, nil
}

func (s *Store) dhtFlowersPath() string {
	return filepath.Join(s.root, "dht_flowers.json")
}

func (s *Store) dhtWreathsPath() string {
	return filepath.Join(s.root, "dht_wreaths.json")
}

func (s *Store) readDHTFlowers() (DHTFlowerIndex, error) {
	data, err := os.ReadFile(s.dhtFlowersPath())
	if err != nil {
		return DHTFlowerIndex{}, err
	}
	var idx DHTFlowerIndex
	if err := json.Unmarshal(data, &idx); err != nil {
		return DHTFlowerIndex{}, err
	}
	if idx.Items == nil {
		idx.Items = []DHTServiceFlower{}
	}
	return idx, nil
}

func (s *Store) writeDHTFlowers(idx DHTFlowerIndex) error {
	if err := os.MkdirAll(s.root, 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(idx, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(s.dhtFlowersPath(), data, 0o644)
}

func (s *Store) readDHTWreaths() (DHTWreathIndex, error) {
	data, err := os.ReadFile(s.dhtWreathsPath())
	if err != nil {
		return DHTWreathIndex{}, err
	}
	var idx DHTWreathIndex
	if err := json.Unmarshal(data, &idx); err != nil {
		return DHTWreathIndex{}, err
	}
	if idx.Items == nil {
		idx.Items = []DHTServiceWreath{}
	}
	return idx, nil
}

func (s *Store) writeDHTWreaths(idx DHTWreathIndex) error {
	if err := os.MkdirAll(s.root, 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(idx, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(s.dhtWreathsPath(), data, 0o644)
}

type dhtWreathPayload struct {
	SchemaVersion     string   `json:"schema_version"`
	WreathID          string   `json:"wreath_id"`
	NodeID            string   `json:"node_id"`
	FlowerCount       int      `json:"flower_count"`
	UniqueClientCount int      `json:"unique_client_count"`
	LastServedAt      string   `json:"last_served_at"`
	CreatedAt         string   `json:"created_at"`
	SourceFlowerIDs   []string `json:"source_flower_ids,omitempty"`
}

func wreathPayload(wreath DHTServiceWreath) dhtWreathPayload {
	return dhtWreathPayload{
		SchemaVersion:     DHTWreathSchemaVersion,
		WreathID:          wreath.WreathID,
		NodeID:            wreath.NodeID,
		FlowerCount:       wreath.FlowerCount,
		UniqueClientCount: wreath.UniqueClientCount,
		LastServedAt:      wreath.LastServedAt,
		CreatedAt:         wreath.CreatedAt,
		SourceFlowerIDs:   append([]string(nil), wreath.SourceFlowerIDs...),
	}
}

func dhtPowDigest(nodeID, ownerPubkeyHash, seed, nonce string, memoryKiB int, roundCount int) [32]byte {
	memoryKiB = normalizeDHTPowMemoryKiB(memoryKiB)
	roundCount = normalizeDHTPowRoundCount(roundCount)
	blockCount := (memoryKiB * 1024) / sha256.Size
	if blockCount < 1 {
		blockCount = 1
	}
	blocks := make([][sha256.Size]byte, blockCount)
	state := sha256.Sum256([]byte(strings.Join([]string{
		DHTPowAlgorithm,
		strings.TrimSpace(nodeID),
		strings.ToLower(strings.TrimSpace(ownerPubkeyHash)),
		strings.TrimSpace(seed),
		strings.TrimSpace(nonce),
	}, "\n")))
	for round := 0; round < roundCount; round++ {
		prev := state[:]
		for i := 0; i < blockCount; i++ {
			h := sha256.New()
			h.Write(prev)
			h.Write([]byte{byte(round), byte(i), byte(i >> 8), byte(i >> 16), byte(i >> 24)})
			sum := h.Sum(nil)
			copy(blocks[i][:], sum)
			prev = blocks[i][:]
		}
		acc := append([]byte(nil), state[:]...)
		for i := blockCount - 1; i >= 0; i-- {
			idx := (int(acc[0]) + int(acc[len(acc)-1]) + i) % blockCount
			h := sha256.New()
			h.Write(acc)
			h.Write(blocks[idx][:])
			acc = h.Sum(acc[:0])
		}
		copy(state[:], acc)
	}
	return state
}

func hasLeadingZeroBits(data []byte, bits int) bool {
	if bits <= 0 {
		return true
	}
	fullBytes := bits / 8
	restBits := bits % 8
	if len(data) < fullBytes {
		return false
	}
	for i := 0; i < fullBytes; i++ {
		if data[i] != 0 {
			return false
		}
	}
	if restBits == 0 {
		return true
	}
	if len(data) <= fullBytes {
		return false
	}
	mask := byte(0xff << (8 - restBits))
	return data[fullBytes]&mask == 0
}

func normalizeDHTPowDifficultyBits(bits int) int {
	if bits < 4 {
		return 4
	}
	if bits > 28 {
		return 28
	}
	return bits
}

func normalizeDHTPowMemoryKiB(memoryKiB int) int {
	if memoryKiB < 16 {
		return 16
	}
	if memoryKiB > 64*1024 {
		return 64 * 1024
	}
	return memoryKiB
}

func normalizeDHTPowRoundCount(roundCount int) int {
	if roundCount < 1 {
		return 1
	}
	if roundCount > 64 {
		return 64
	}
	return roundCount
}

func dhtPubkeyHash(pubkeyHex string) (string, error) {
	raw, err := hex.DecodeString(strings.TrimSpace(pubkeyHex))
	if err != nil {
		return "", err
	}
	if len(raw) != governance.PublicKeyLength {
		return "", fmt.Errorf("invalid pubkey length")
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:]), nil
}

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func randomHex(n int) (string, error) {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}
