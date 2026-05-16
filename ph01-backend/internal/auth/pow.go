package auth

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/hanako/ph01-backend/pkg/api"
)

const (
	UserPowAlgorithm             = "ph01.memory_pow.v1"
	DefaultUserPowDifficultyBits = 4
	DefaultUserPowMemoryKiB      = 1024 * 1024
	DefaultUserPowRoundCount     = 2
	DefaultUserPowTTL            = 10 * time.Minute

	userPowWordBytes    = 8
	userPowMinMemoryKiB = 16
	userPowMaxMemoryKiB = 1024 * 1024
	userPowMaxRounds    = 64
)

var (
	ErrPowChallengeNotFound = errors.New("pow challenge not found")
	ErrPowChallengeExpired  = errors.New("pow challenge expired")
	ErrPowInvalidSolution   = errors.New("pow solution invalid")
	ErrPowSubjectMismatch   = errors.New("pow subject mismatch")
)

type UserPowService struct {
	mu             sync.Mutex
	challenges     map[string]api.UserPowChallengeResponse
	DifficultyBits int
	MemoryKiB      int
	RoundCount     int
	TTL            time.Duration
}

type DelegatedPowService struct {
	mu             sync.Mutex
	challenges     map[string]api.DelegatedPowChallengeResponse
	proofs         map[string]api.DelegatedPowStatusResponse
	DifficultyBits int
	MemoryKiB      int
	RoundCount     int
	TTL            time.Duration
}

func NewUserPowService() *UserPowService {
	return &UserPowService{
		challenges:     map[string]api.UserPowChallengeResponse{},
		DifficultyBits: DefaultUserPowDifficultyBits,
		MemoryKiB:      DefaultUserPowMemoryKiB,
		RoundCount:     DefaultUserPowRoundCount,
		TTL:            DefaultUserPowTTL,
	}
}

func NewDelegatedPowService() *DelegatedPowService {
	return &DelegatedPowService{
		challenges:     map[string]api.DelegatedPowChallengeResponse{},
		proofs:         map[string]api.DelegatedPowStatusResponse{},
		DifficultyBits: DefaultUserPowDifficultyBits,
		MemoryKiB:      DefaultUserPowMemoryKiB,
		RoundCount:     DefaultUserPowRoundCount,
		TTL:            DefaultUserPowTTL,
	}
}

func (s *UserPowService) Create(pubkeyHash string, now time.Time) (api.UserPowChallengeResponse, error) {
	if s == nil {
		s = NewUserPowService()
	}
	pubkeyHash = strings.ToLower(strings.TrimSpace(pubkeyHash))
	challengeID, err := randomHex(16)
	if err != nil {
		return api.UserPowChallengeResponse{}, err
	}
	seed, err := randomHex(32)
	if err != nil {
		return api.UserPowChallengeResponse{}, err
	}
	ttl := s.TTL
	if ttl <= 0 {
		ttl = DefaultUserPowTTL
	}
	resp := api.UserPowChallengeResponse{
		ChallengeID:    challengeID,
		PubkeyHash:     pubkeyHash,
		Algorithm:      UserPowAlgorithm,
		DifficultyBits: normalizePowDifficultyBits(s.DifficultyBits),
		MemoryKiB:      normalizePowMemoryKiB(s.MemoryKiB),
		RoundCount:     normalizePowRoundCount(s.RoundCount),
		Seed:           seed,
		ExpiresAt:      now.UTC().Add(ttl).Unix(),
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.challenges == nil {
		s.challenges = map[string]api.UserPowChallengeResponse{}
	}
	s.cleanupLocked(now)
	s.challenges[challengeID] = resp
	return resp, nil
}

func (s *DelegatedPowService) Create(purpose, subjectHash, pubkeyHash string, now time.Time) (api.DelegatedPowChallengeResponse, error) {
	if s == nil {
		s = NewDelegatedPowService()
	}
	purpose = strings.TrimSpace(purpose)
	subjectHash = strings.ToLower(strings.TrimSpace(subjectHash))
	pubkeyHash = strings.ToLower(strings.TrimSpace(pubkeyHash))
	challengeID, err := randomHex(16)
	if err != nil {
		return api.DelegatedPowChallengeResponse{}, err
	}
	seed, err := randomHex(32)
	if err != nil {
		return api.DelegatedPowChallengeResponse{}, err
	}
	ttl := s.TTL
	if ttl <= 0 {
		ttl = DefaultUserPowTTL
	}
	resp := api.DelegatedPowChallengeResponse{
		ChallengeID:    challengeID,
		Purpose:        purpose,
		SubjectHash:    subjectHash,
		PubkeyHash:     pubkeyHash,
		Algorithm:      UserPowAlgorithm,
		DifficultyBits: normalizePowDifficultyBits(s.DifficultyBits),
		MemoryKiB:      normalizePowMemoryKiB(s.MemoryKiB),
		RoundCount:     normalizePowRoundCount(s.RoundCount),
		Seed:           seed,
		ExpiresAt:      now.UTC().Add(ttl).Unix(),
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.challenges == nil {
		s.challenges = map[string]api.DelegatedPowChallengeResponse{}
	}
	if s.proofs == nil {
		s.proofs = map[string]api.DelegatedPowStatusResponse{}
	}
	s.cleanupLocked(now)
	s.challenges[resp.ChallengeID] = resp
	return resp, nil
}

func (s *UserPowService) Verify(payload api.UserPowVerifyPayload, now time.Time) (api.UserPowChallengeResponse, error) {
	if s == nil {
		return api.UserPowChallengeResponse{}, ErrPowChallengeNotFound
	}
	challengeID := strings.TrimSpace(payload.ChallengeID)
	pubkeyHash := strings.ToLower(strings.TrimSpace(payload.PubkeyHash))
	s.mu.Lock()
	challenge, ok := s.challenges[challengeID]
	if ok {
		delete(s.challenges, challengeID)
	}
	s.cleanupLocked(now)
	s.mu.Unlock()
	if !ok {
		return api.UserPowChallengeResponse{}, ErrPowChallengeNotFound
	}
	if challenge.ExpiresAt <= now.UTC().Unix() {
		return api.UserPowChallengeResponse{}, ErrPowChallengeExpired
	}
	if challenge.PubkeyHash != pubkeyHash {
		return api.UserPowChallengeResponse{}, ErrPowInvalidSolution
	}
	if !VerifyUserPoWSolution(challenge, payload.SolutionNonce) {
		return api.UserPowChallengeResponse{}, ErrPowInvalidSolution
	}
	return challenge, nil
}

func (s *DelegatedPowService) Challenge(challengeID string, now time.Time) (api.DelegatedPowChallengeResponse, bool) {
	if s == nil {
		return api.DelegatedPowChallengeResponse{}, false
	}
	challengeID = strings.TrimSpace(challengeID)
	if challengeID == "" {
		return api.DelegatedPowChallengeResponse{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cleanupLocked(now)
	challenge, ok := s.challenges[challengeID]
	return challenge, ok
}

func (s *DelegatedPowService) Verify(payload api.DelegatedPowVerifyPayload, now time.Time) (api.DelegatedPowStatusResponse, error) {
	if s == nil {
		return api.DelegatedPowStatusResponse{}, ErrPowChallengeNotFound
	}
	challengeID := strings.TrimSpace(payload.ChallengeID)
	purpose := strings.TrimSpace(payload.Purpose)
	subjectHash := strings.ToLower(strings.TrimSpace(payload.SubjectHash))
	pubkeyHash := strings.ToLower(strings.TrimSpace(payload.PubkeyHash))
	s.mu.Lock()
	challenge, ok := s.challenges[challengeID]
	if ok {
		delete(s.challenges, challengeID)
	}
	s.cleanupLocked(now)
	s.mu.Unlock()
	if !ok {
		return api.DelegatedPowStatusResponse{}, ErrPowChallengeNotFound
	}
	if challenge.ExpiresAt <= now.UTC().Unix() {
		return api.DelegatedPowStatusResponse{}, ErrPowChallengeExpired
	}
	if challenge.Purpose != purpose || challenge.SubjectHash != subjectHash {
		return api.DelegatedPowStatusResponse{}, ErrPowSubjectMismatch
	}
	if challenge.PubkeyHash != "" && challenge.PubkeyHash != pubkeyHash {
		return api.DelegatedPowStatusResponse{}, ErrPowSubjectMismatch
	}
	if !VerifyDelegatedPoWSolution(challenge, payload.SolutionNonce) {
		return api.DelegatedPowStatusResponse{}, ErrPowInvalidSolution
	}
	if pubkeyHash == "" {
		pubkeyHash = challenge.PubkeyHash
	}
	status := api.DelegatedPowStatusResponse{
		ChallengeID: challenge.ChallengeID,
		Purpose:     challenge.Purpose,
		SubjectHash: challenge.SubjectHash,
		PubkeyHash:  pubkeyHash,
		Verified:    true,
		Algorithm:   challenge.Algorithm,
		Score: UserPowScore(api.UserPowChallengeResponse{
			DifficultyBits: challenge.DifficultyBits,
			MemoryKiB:      challenge.MemoryKiB,
			RoundCount:     challenge.RoundCount,
		}),
		VerifiedAt: now.UTC().Unix(),
		ExpiresAt:  challenge.ExpiresAt,
	}
	s.mu.Lock()
	if s.proofs == nil {
		s.proofs = map[string]api.DelegatedPowStatusResponse{}
	}
	s.cleanupLocked(now)
	s.proofs[status.ChallengeID] = status
	s.mu.Unlock()
	return status, nil
}

func (s *DelegatedPowService) Status(req api.DelegatedPowStatusRequest, now time.Time) api.DelegatedPowStatusResponse {
	challengeID := strings.TrimSpace(req.ChallengeID)
	purpose := strings.TrimSpace(req.Purpose)
	subjectHash := strings.ToLower(strings.TrimSpace(req.SubjectHash))
	pubkeyHash := strings.ToLower(strings.TrimSpace(req.PubkeyHash))
	out := api.DelegatedPowStatusResponse{
		ChallengeID: challengeID,
		Purpose:     purpose,
		SubjectHash: subjectHash,
		PubkeyHash:  pubkeyHash,
	}
	if s == nil || challengeID == "" {
		return out
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cleanupLocked(now)
	status, ok := s.proofs[challengeID]
	if !ok {
		return out
	}
	if purpose != "" && status.Purpose != purpose {
		return out
	}
	if subjectHash != "" && status.SubjectHash != subjectHash {
		return out
	}
	if pubkeyHash != "" && status.PubkeyHash != pubkeyHash {
		return out
	}
	return status
}

func (s *UserPowService) cleanupLocked(now time.Time) {
	nowUnix := now.UTC().Unix()
	for id, challenge := range s.challenges {
		if challenge.ExpiresAt <= nowUnix {
			delete(s.challenges, id)
		}
	}
}

func (s *DelegatedPowService) cleanupLocked(now time.Time) {
	nowUnix := now.UTC().Unix()
	for id, challenge := range s.challenges {
		if challenge.ExpiresAt <= nowUnix {
			delete(s.challenges, id)
		}
	}
	for id, proof := range s.proofs {
		if proof.ExpiresAt <= nowUnix {
			delete(s.proofs, id)
		}
	}
}

func VerifyUserPoWSolution(challenge api.UserPowChallengeResponse, nonce string) bool {
	nonce = strings.TrimSpace(nonce)
	if nonce == "" {
		return false
	}
	digest := UserPowDigest(
		challenge.Seed,
		challenge.PubkeyHash,
		nonce,
		challenge.MemoryKiB,
		challenge.RoundCount,
	)
	return hasLeadingZeroBits(digest[:], normalizePowDifficultyBits(challenge.DifficultyBits))
}

func VerifyDelegatedPoWSolution(challenge api.DelegatedPowChallengeResponse, nonce string) bool {
	nonce = strings.TrimSpace(nonce)
	if nonce == "" {
		return false
	}
	digest := UserPowDigest(
		challenge.Seed,
		challenge.SubjectHash,
		nonce,
		challenge.MemoryKiB,
		challenge.RoundCount,
	)
	return hasLeadingZeroBits(digest[:], normalizePowDifficultyBits(challenge.DifficultyBits))
}

func UserPowScore(challenge api.UserPowChallengeResponse) int {
	score := normalizePowDifficultyBits(challenge.DifficultyBits)
	score += floorLog2(normalizePowMemoryKiB(challenge.MemoryKiB) / userPowMinMemoryKiB)
	score += floorLog2(normalizePowRoundCount(challenge.RoundCount))
	return score
}

func SolveUserPoW(challenge api.UserPowChallengeResponse, maxAttempts uint64) (string, bool) {
	if maxAttempts == 0 {
		maxAttempts = 1 << 24
	}
	for i := uint64(0); i < maxAttempts; i++ {
		nonce := strconv.FormatUint(i, 16)
		if VerifyUserPoWSolution(challenge, nonce) {
			return nonce, true
		}
	}
	return "", false
}

func UserPowDigest(seed, pubkeyHash, nonce string, memoryKiB int, roundCount int) [32]byte {
	memoryKiB = normalizePowMemoryKiB(memoryKiB)
	roundCount = normalizePowRoundCount(roundCount)
	wordCount := (memoryKiB * 1024) / userPowWordBytes
	if wordCount < 1 {
		wordCount = 1
	}
	workspace := make([]uint64, wordCount)
	base := sha256.Sum256([]byte(strings.Join([]string{
		UserPowAlgorithm,
		strings.TrimSpace(seed),
		strings.ToLower(strings.TrimSpace(pubkeyHash)),
		strings.TrimSpace(nonce),
	}, "\n")))
	acc := [4]uint64{
		binary.LittleEndian.Uint64(base[0:8]),
		binary.LittleEndian.Uint64(base[8:16]),
		binary.LittleEndian.Uint64(base[16:24]),
		binary.LittleEndian.Uint64(base[24:32]),
	}
	for stage := 0; stage < roundCount; stage++ {
		stageSeed := userPowStageSeed(base, acc, stage)
		state := binary.LittleEndian.Uint64(stageSeed[0:8]) ^ uint64(stage+1)
		if state == 0 {
			state = 0x9e3779b97f4a7c15
		}
		step := binary.LittleEndian.Uint64(stageSeed[8:16]) | 1
		for i := range workspace {
			state = userPowNextState(state + step)
			word := userPowSplitMix64(state ^ uint64(i) ^ acc[i&3])
			workspace[i] = word
			acc[i&3] = userPowSplitMix64(acc[i&3] + word + uint64(i) + uint64(stage))
		}
		probeCount := userPowProbeCount(len(workspace))
		for i := 0; i < probeCount; i++ {
			lane := i & 3
			idx := userPowSplitMix64(acc[lane]+uint64(i)*0x9e3779b97f4a7c15+uint64(stage)) % uint64(len(workspace))
			word := workspace[idx]
			acc[lane] = userPowSplitMix64(acc[(lane+1)&3] ^ word ^ uint64(idx) ^ uint64(i))
		}
		edge := workspace[(stage*0x9e3779b9)%len(workspace)]
		acc[stage&3] = userPowSplitMix64(acc[stage&3] ^ edge ^ uint64(probeCount) ^ uint64(stage))
	}
	return userPowDigestAccumulators(acc)
}

func userPowProbeCount(wordCount int) int {
	probes := wordCount / 16
	if probes < 1024 {
		return 1024
	}
	return probes
}

func userPowStageSeed(base [32]byte, acc [4]uint64, stage int) [32]byte {
	var buf [72]byte
	copy(buf[:32], base[:])
	for i, value := range acc {
		binary.LittleEndian.PutUint64(buf[32+i*8:40+i*8], value)
	}
	binary.LittleEndian.PutUint64(buf[64:72], uint64(stage))
	return sha256.Sum256(buf[:])
}

func userPowDigestAccumulators(acc [4]uint64) [32]byte {
	var buf [32]byte
	for i, value := range acc {
		binary.LittleEndian.PutUint64(buf[i*8:8+i*8], value)
	}
	return sha256.Sum256(buf[:])
}

func userPowNextState(value uint64) uint64 {
	value ^= value >> 12
	value ^= value << 25
	value ^= value >> 27
	return value * 2685821657736338717
}

func userPowSplitMix64(value uint64) uint64 {
	value += 0x9e3779b97f4a7c15
	value = (value ^ (value >> 30)) * 0xbf58476d1ce4e5b9
	value = (value ^ (value >> 27)) * 0x94d049bb133111eb
	return value ^ (value >> 31)
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
	if !bytes.Equal(data[:fullBytes], make([]byte, fullBytes)) {
		return false
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
	if memoryKiB < userPowMinMemoryKiB {
		return userPowMinMemoryKiB
	}
	if memoryKiB > userPowMaxMemoryKiB {
		return userPowMaxMemoryKiB
	}
	return memoryKiB
}

func normalizePowRoundCount(roundCount int) int {
	if roundCount < 1 {
		return 1
	}
	if roundCount > userPowMaxRounds {
		return userPowMaxRounds
	}
	return roundCount
}

func floorLog2(value int) int {
	if value <= 1 {
		return 0
	}
	score := 0
	for value > 1 {
		value >>= 1
		score++
	}
	return score
}

func randomHex(n int) (string, error) {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}
