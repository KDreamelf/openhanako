package dht

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

var (
	ErrAlreadyBound    = errors.New("dht is already bound")
	ErrInvalidPassword = errors.New("invalid init password")
	ErrNotBound        = errors.New("dht is not bound")
)

type StateStore struct {
	path string
	mu   sync.Mutex
}

func NewStateStore(path string) *StateStore {
	return &StateStore{path: path}
}

func (s *StateStore) CacheDir() string {
	return filepath.Join(filepath.Dir(s.path), "cache")
}

func (s *StateStore) Init(nodeID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, err := os.Stat(s.path); err == nil {
		state, err := s.readLocked()
		if err != nil {
			return err
		}
		if strings.TrimSpace(state.NodeID) == "" {
			generated, err := nodeIDOrGenerated(nodeID)
			if err != nil {
				return err
			}
			state.NodeID = generated
			state.UpdatedAt = nowRFC3339()
			return s.writeLocked(state)
		}
		if strings.TrimSpace(state.BoundPubkeyHex) != "" && state.NodePow == nil {
			pow, err := NewDHTNodePow(state.NodeID, state.BoundPubkeyHex)
			if err != nil {
				return err
			}
			state.NodePow = pow
			state.UpdatedAt = nowRFC3339()
			return s.writeLocked(state)
		}
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	resolvedNodeID, err := nodeIDOrGenerated(nodeID)
	if err != nil {
		return err
	}
	state := State{
		SchemaVersion: StateSchemaVersion,
		NodeID:        resolvedNodeID,
		UpdatedAt:     nowRFC3339(),
	}
	return s.writeLocked(state)
}

func (s *StateStore) Get() (State, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.readLocked()
}

func (s *StateStore) Bind(cfg Config, pubkeyHex, initPassword string) (State, error) {
	if strings.TrimSpace(cfg.InitPassword) == "" || initPassword != cfg.InitPassword {
		return State{}, ErrInvalidPassword
	}
	if err := ValidatePubkey(pubkeyHex); err != nil {
		return State{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	state, err := s.readLocked()
	if err != nil {
		return State{}, err
	}
	if strings.TrimSpace(state.BoundPubkeyHex) != "" && !cfg.AllowReinitialize {
		return State{}, ErrAlreadyBound
	}
	now := nowRFC3339()
	state.SchemaVersion = StateSchemaVersion
	if strings.TrimSpace(state.NodeID) == "" {
		nodeID, err := nodeIDOrGenerated(cfg.NodeID)
		if err != nil {
			return State{}, err
		}
		state.NodeID = nodeID
	}
	state.BoundPubkeyHex = strings.ToLower(strings.TrimSpace(pubkeyHex))
	pow, err := NewDHTNodePow(state.NodeID, state.BoundPubkeyHex)
	if err != nil {
		return State{}, err
	}
	state.NodePow = pow
	state.BoundAt = now
	state.UpdatedAt = now
	if err := s.writeLocked(state); err != nil {
		return State{}, err
	}
	return state, nil
}

func (s *StateStore) SetPublic(enabled, registered bool, managerBaseURL string, proof *SignedRequest) (State, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, err := s.readLocked()
	if err != nil {
		return State{}, err
	}
	state.PublicEnabled = enabled
	state.PublicRegistered = registered
	if enabled {
		state.PublicManagerURL = strings.TrimSpace(managerBaseURL)
		if proof != nil {
			copied := *proof
			state.PublicRegistrationProof = &copied
		}
	} else {
		state.PublicManagerURL = ""
		state.PublicRegistrationProof = nil
	}
	state.UpdatedAt = nowRFC3339()
	if err := s.writeLocked(state); err != nil {
		return State{}, err
	}
	return state, nil
}

func (s *StateStore) SetRuntimeConfig(runtime RuntimeConfig) (State, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, err := s.readLocked()
	if err != nil {
		return State{}, err
	}
	state.RuntimeConfig = runtime
	state.UpdatedAt = nowRFC3339()
	if err := s.writeLocked(state); err != nil {
		return State{}, err
	}
	return state, nil
}

func (s *StateStore) SetBootstrapManager(managerBaseURL string) (State, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, err := s.readLocked()
	if err != nil {
		return State{}, err
	}
	state.BootstrapManagerURL = strings.TrimSpace(managerBaseURL)
	state.UpdatedAt = nowRFC3339()
	if err := s.writeLocked(state); err != nil {
		return State{}, err
	}
	return state, nil
}

func (s *StateStore) readLocked() (State, error) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		return State{}, err
	}
	var state State
	if err := json.Unmarshal(data, &state); err != nil {
		return State{}, err
	}
	if state.SchemaVersion == "" {
		state.SchemaVersion = StateSchemaVersion
	}
	return state, nil
}

func (s *StateStore) writeLocked(state State) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(s.path, data, 0o600)
}

func nowRFC3339() string {
	return time.Now().UTC().Format(time.RFC3339)
}

func nodeIDOrGenerated(nodeID string) (string, error) {
	trimmed := strings.TrimSpace(nodeID)
	if trimmed != "" {
		return trimmed, nil
	}
	return generateUUID()
}

func generateUUID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return strings.Join([]string{
		hex.EncodeToString(b[0:4]),
		hex.EncodeToString(b[4:6]),
		hex.EncodeToString(b[6:8]),
		hex.EncodeToString(b[8:10]),
		hex.EncodeToString(b[10:16]),
	}, "-"), nil
}
