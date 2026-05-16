package auth

import (
	"testing"
	"time"
)

func TestNewUserPowServiceUsesTargetDefaults(t *testing.T) {
	service := NewUserPowService()
	if service.DifficultyBits != DefaultUserPowDifficultyBits {
		t.Fatalf("difficulty bits = %d", service.DifficultyBits)
	}
	if service.MemoryKiB != DefaultUserPowMemoryKiB {
		t.Fatalf("memory kib = %d", service.MemoryKiB)
	}
	if service.RoundCount != DefaultUserPowRoundCount {
		t.Fatalf("round count = %d", service.RoundCount)
	}
	if service.TTL != DefaultUserPowTTL {
		t.Fatalf("ttl = %s", service.TTL)
	}

	challenge, err := service.Create("abcdef", time.Unix(1778323200, 0))
	if err != nil {
		t.Fatalf("create challenge: %v", err)
	}
	if challenge.DifficultyBits != DefaultUserPowDifficultyBits ||
		challenge.MemoryKiB != DefaultUserPowMemoryKiB ||
		challenge.RoundCount != DefaultUserPowRoundCount {
		t.Fatalf("unexpected challenge defaults: %+v", challenge)
	}
	if score := UserPowScore(challenge); score != 21 {
		t.Fatalf("default pow score = %d", score)
	}
}
