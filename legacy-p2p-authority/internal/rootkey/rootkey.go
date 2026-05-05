// Package rootkey 封装 P2P 网络治理 Root 私钥的加载和签名。
package rootkey

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"

	secp "github.com/decred/dcrd/dcrec/secp256k1/v4"
	ecdsa "github.com/decred/dcrd/dcrec/secp256k1/v4/ecdsa"
)

const (
	PrivateKeyLength = 32
	PublicKeyLength  = 65
	SignatureLength  = 64
	Algorithm        = "secp256k1_ecdsa_sha256_rs64"
)

type RootKey struct {
	KeyID        string
	PrivateKey   *secp.PrivateKey
	PublicKeyHex string
}

type Certificate struct {
	KeyID        string `json:"key_id"`
	Algorithm    string `json:"algorithm"`
	PublicKeyHex string `json:"public_key_hex"`
}

func Load(keyID, privateKeyHex string) (*RootKey, error) {
	raw, err := hex.DecodeString(privateKeyHex)
	if err != nil {
		return nil, fmt.Errorf("decode private key: %w", err)
	}
	if len(raw) != PrivateKeyLength {
		return nil, fmt.Errorf("private key must be %d bytes, got %d", PrivateKeyLength, len(raw))
	}
	priv := secp.PrivKeyFromBytes(raw)
	return &RootKey{
		KeyID:        keyID,
		PrivateKey:   priv,
		PublicKeyHex: hex.EncodeToString(priv.PubKey().SerializeUncompressed()),
	}, nil
}

func (k *RootKey) Certificate() Certificate {
	return Certificate{
		KeyID:        k.KeyID,
		Algorithm:    Algorithm,
		PublicKeyHex: k.PublicKeyHex,
	}
}

func (k *RootKey) Sign(message []byte) (string, error) {
	if k == nil || k.PrivateKey == nil {
		return "", fmt.Errorf("root key is not loaded")
	}
	digest := sha256.Sum256(message)
	sig := ecdsa.Sign(k.PrivateKey, digest[:])

	r := sig.R()
	s := sig.S()
	rBytes := r.Bytes()
	sBytes := s.Bytes()
	out := make([]byte, SignatureLength)
	copy(out[:32], rBytes[:])
	copy(out[32:], sBytes[:])
	return hex.EncodeToString(out), nil
}

func Verify(publicKeyHex string, message []byte, signatureHex string) error {
	pubRaw, err := hex.DecodeString(publicKeyHex)
	if err != nil {
		return fmt.Errorf("decode public key: %w", err)
	}
	if len(pubRaw) != PublicKeyLength {
		return fmt.Errorf("public key must be %d bytes, got %d", PublicKeyLength, len(pubRaw))
	}
	pub, err := secp.ParsePubKey(pubRaw)
	if err != nil {
		return fmt.Errorf("parse public key: %w", err)
	}

	sigRaw, err := hex.DecodeString(signatureHex)
	if err != nil {
		return fmt.Errorf("decode signature: %w", err)
	}
	if len(sigRaw) != SignatureLength {
		return fmt.Errorf("signature must be %d bytes, got %d", SignatureLength, len(sigRaw))
	}

	var r, s secp.ModNScalar
	if r.SetByteSlice(sigRaw[:32]) {
		return fmt.Errorf("signature r overflows curve order")
	}
	if s.SetByteSlice(sigRaw[32:]) {
		return fmt.Errorf("signature s overflows curve order")
	}
	sig := ecdsa.NewSignature(&r, &s)
	digest := sha256.Sum256(message)
	if !sig.Verify(digest[:], pub) {
		return fmt.Errorf("signature verification failed")
	}
	return nil
}
