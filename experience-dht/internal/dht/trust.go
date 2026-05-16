package dht

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

const DHTPowAlgorithm = "ph01.dht_memory_pow.v1"

var (
	errInvalidNodePow = errors.New("invalid dht node pow")
	errInvalidFlower  = errors.New("invalid dht service flower")
)

func NewDHTNodePow(nodeID, ownerPubkeyHex string) (*DHTNodePow, error) {
	hash, err := PubkeyHash(ownerPubkeyHex)
	if err != nil {
		return nil, err
	}
	seed, err := randomHex(32)
	if err != nil {
		return nil, err
	}
	pow := DHTNodePow{
		SchemaVersion:   NodePowSchemaVersion,
		NodeID:          strings.TrimSpace(nodeID),
		OwnerPubkeyHex:  strings.ToLower(strings.TrimSpace(ownerPubkeyHex)),
		OwnerPubkeyHash: hash,
		Algorithm:       DHTPowAlgorithm,
		DifficultyBits:  8,
		MemoryKiB:       64,
		RoundCount:      2,
		Seed:            seed,
		CreatedAt:       nowRFC3339(),
	}
	for i := uint64(0); i < 1<<24; i++ {
		pow.SolutionNonce = fmt.Sprintf("%x", i)
		if VerifyDHTNodePow(&pow) == nil {
			return &pow, nil
		}
	}
	return nil, errInvalidNodePow
}

func VerifyDHTNodePow(pow *DHTNodePow) error {
	if pow == nil {
		return errInvalidNodePow
	}
	if strings.TrimSpace(pow.SchemaVersion) != "" && pow.SchemaVersion != NodePowSchemaVersion {
		return errInvalidNodePow
	}
	if strings.TrimSpace(pow.NodeID) == "" || strings.TrimSpace(pow.OwnerPubkeyHash) == "" ||
		pow.Algorithm != DHTPowAlgorithm || strings.TrimSpace(pow.Seed) == "" ||
		strings.TrimSpace(pow.SolutionNonce) == "" {
		return errInvalidNodePow
	}
	if strings.TrimSpace(pow.OwnerPubkeyHex) != "" {
		hash, err := PubkeyHash(pow.OwnerPubkeyHex)
		if err != nil || !strings.EqualFold(hash, pow.OwnerPubkeyHash) {
			return errInvalidNodePow
		}
	}
	digest := dhtPowDigest(pow.NodeID, pow.OwnerPubkeyHash, pow.Seed, pow.SolutionNonce, pow.MemoryKiB, pow.RoundCount)
	if !hasLeadingZeroBits(digest[:], normalizePowDifficultyBits(pow.DifficultyBits)) {
		return errInvalidNodePow
	}
	return nil
}

func ValidateDHTServiceFlower(flower DHTServiceFlower) (DHTServiceFlower, error) {
	if strings.TrimSpace(flower.SchemaVersion) == "" {
		flower.SchemaVersion = FlowerSchemaVersion
	}
	if flower.SchemaVersion != FlowerSchemaVersion ||
		strings.TrimSpace(flower.FlowerID) == "" ||
		strings.TrimSpace(flower.NodeID) == "" ||
		strings.TrimSpace(flower.ClientPubkeyHex) == "" ||
		strings.TrimSpace(flower.ResourceHash) == "" ||
		strings.TrimSpace(flower.ServedAt) == "" ||
		strings.TrimSpace(flower.SignatureHex) == "" {
		return DHTServiceFlower{}, errInvalidFlower
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
	hash, err := PubkeyHash(flower.ClientPubkeyHex)
	if err != nil || (flower.ClientPubkeyHash != "" && !strings.EqualFold(hash, flower.ClientPubkeyHash)) {
		return DHTServiceFlower{}, errInvalidFlower
	}
	flower.ClientPubkeyHash = hash
	if _, err := time.Parse(time.RFC3339, flower.ServedAt); err != nil {
		return DHTServiceFlower{}, errInvalidFlower
	}
	if err := VerifySignature(flower.ClientPubkeyHex, DHTServiceFlowerSigningPayload(flower), flower.SignatureHex); err != nil {
		return DHTServiceFlower{}, errInvalidFlower
	}
	if strings.TrimSpace(flower.ReceivedAt) == "" {
		flower.ReceivedAt = nowRFC3339()
	}
	return flower, nil
}

func DHTServiceFlowerSigningPayload(flower DHTServiceFlower) []byte {
	lines := []string{
		FlowerSchemaVersion,
		strings.TrimSpace(flower.FlowerID),
		strings.TrimSpace(flower.NodeID),
		strings.ToLower(strings.TrimSpace(flower.ClientPubkeyHash)),
		strings.TrimSpace(flower.ResourceHash),
		strings.TrimSpace(flower.WorkKind),
		strings.TrimSpace(flower.ServedAt),
	}
	return []byte(strings.Join(lines, "\n"))
}

func AggregateFlowers(nodeID string, flowers []DHTServiceFlower, limit int) (DHTServiceWreath, bool) {
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	selected := make([]DHTServiceFlower, 0, limit)
	for i := len(flowers) - 1; i >= 0 && len(selected) < limit; i-- {
		if flowers[i].NodeID == nodeID {
			selected = append(selected, flowers[i])
		}
	}
	if len(selected) == 0 {
		return DHTServiceWreath{}, false
	}
	sourceIDs := make([]string, 0, len(selected))
	clients := map[string]struct{}{}
	lastServedAt := ""
	for _, flower := range selected {
		sourceIDs = append(sourceIDs, flower.FlowerID)
		clients[flower.ClientPubkeyHash] = struct{}{}
		if flower.ServedAt > lastServedAt {
			lastServedAt = flower.ServedAt
		}
	}
	sort.Strings(sourceIDs)
	wreath := DHTServiceWreath{
		SchemaVersion:     WreathSchemaVersion,
		WreathID:          "wr_" + sha256Hex([]byte(strings.Join(sourceIDs, "\n"))),
		NodeID:            nodeID,
		FlowerCount:       len(selected),
		UniqueClientCount: len(clients),
		LastServedAt:      lastServedAt,
		CreatedAt:         nowRFC3339(),
		SourceFlowerIDs:   sourceIDs,
	}
	payload, _ := json.Marshal(wreath)
	wreath.SignaturePayloadSHA256 = sha256Hex(payload)
	return wreath, true
}

func dhtPowDigest(nodeID, ownerPubkeyHash, seed, nonce string, memoryKiB int, roundCount int) [32]byte {
	memoryKiB = normalizePowMemoryKiB(memoryKiB)
	roundCount = normalizePowRoundCount(roundCount)
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

func normalizePowDifficultyBits(bits int) int {
	if bits < 4 {
		return 4
	}
	if bits > 28 {
		return 28
	}
	return bits
}

func normalizePowMemoryKiB(memoryKiB int) int {
	if memoryKiB < 16 {
		return 16
	}
	if memoryKiB > 64*1024 {
		return 64 * 1024
	}
	return memoryKiB
}

func normalizePowRoundCount(roundCount int) int {
	if roundCount < 1 {
		return 1
	}
	if roundCount > 64 {
		return 64
	}
	return roundCount
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
