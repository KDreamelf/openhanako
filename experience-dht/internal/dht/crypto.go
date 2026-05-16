package dht

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	secp "github.com/decred/dcrd/dcrec/secp256k1/v4"
	ecdsa "github.com/decred/dcrd/dcrec/secp256k1/v4/ecdsa"
)

const (
	publicKeyLength = 65
	signatureLength = 64
)

var ErrInvalidSignature = errors.New("invalid signature")

func VerifySignedRequest(req SignedRequest, now time.Time) error {
	if strings.TrimSpace(req.Payload) == "" || strings.TrimSpace(req.PubkeyHex) == "" ||
		strings.TrimSpace(req.SignatureHex) == "" || strings.TrimSpace(req.Nonce) == "" {
		return ErrInvalidSignature
	}
	signedAt := time.Unix(req.Timestamp, 0).UTC()
	if now.Sub(signedAt) > 5*time.Minute || signedAt.Sub(now) > 5*time.Minute {
		return fmt.Errorf("%w: timestamp expired", ErrInvalidSignature)
	}
	message := req.Payload + "\n" + req.PubkeyHex + "\n" + fmt.Sprint(req.Timestamp) + "\n" + req.Nonce
	return VerifySignature(req.PubkeyHex, []byte(message), req.SignatureHex)
}

func VerifySignature(pubkeyHex string, message []byte, signatureHex string) error {
	pubRaw, err := hex.DecodeString(strings.TrimSpace(pubkeyHex))
	if err != nil {
		return fmt.Errorf("%w: decode pubkey: %v", ErrInvalidSignature, err)
	}
	if len(pubRaw) != publicKeyLength {
		return fmt.Errorf("%w: public key must be %d bytes", ErrInvalidSignature, publicKeyLength)
	}
	pub, err := secp.ParsePubKey(pubRaw)
	if err != nil {
		return fmt.Errorf("%w: parse pubkey: %v", ErrInvalidSignature, err)
	}
	sigRaw, err := hex.DecodeString(strings.TrimSpace(signatureHex))
	if err != nil {
		return fmt.Errorf("%w: decode signature: %v", ErrInvalidSignature, err)
	}
	if len(sigRaw) != signatureLength {
		return fmt.Errorf("%w: signature must be %d bytes", ErrInvalidSignature, signatureLength)
	}
	var r, s secp.ModNScalar
	if r.SetByteSlice(sigRaw[:32]) {
		return fmt.Errorf("%w: r overflows curve order", ErrInvalidSignature)
	}
	if s.SetByteSlice(sigRaw[32:]) {
		return fmt.Errorf("%w: s overflows curve order", ErrInvalidSignature)
	}
	sig := ecdsa.NewSignature(&r, &s)
	digest := sha256.Sum256(message)
	if !sig.Verify(digest[:], pub) {
		return fmt.Errorf("%w: ecdsa verification failed", ErrInvalidSignature)
	}
	return nil
}

func ValidatePubkey(pubkeyHex string) error {
	pubRaw, err := hex.DecodeString(strings.TrimSpace(pubkeyHex))
	if err != nil {
		return err
	}
	if len(pubRaw) != publicKeyLength {
		return fmt.Errorf("public key must be %d bytes", publicKeyLength)
	}
	_, err = secp.ParsePubKey(pubRaw)
	return err
}

func PubkeyHash(pubkeyHex string) (string, error) {
	raw, err := hex.DecodeString(strings.TrimSpace(pubkeyHex))
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:]), nil
}
