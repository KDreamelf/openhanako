// Package governance 处理经验网络治理证书和主控签名。
package governance

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"strings"
	"time"

	secp "github.com/decred/dcrd/dcrec/secp256k1/v4"
	ecdsa "github.com/decred/dcrd/dcrec/secp256k1/v4/ecdsa"
)

const (
	Algorithm        = "secp256k1_ecdsa_sha256_rs64"
	PrivateKeyLength = 32
	PublicKeyLength  = 65
	SignatureLength  = 64
)

type Config struct {
	Enabled               bool   `json:"enabled"`
	RootCertificatePath   string `json:"root_certificate_path"`
	MasterCertificatePath string `json:"master_certificate_path"`
	MasterPrivateKeyHex   string `json:"master_private_key_hex"`
}

type Service struct {
	RootCertificateRaw   json.RawMessage
	MasterCertificateRaw json.RawMessage
	Master               *MasterKey
}

type RootCertificate struct {
	SchemaVersion     string `json:"schema_version"`
	KeyID             string `json:"key_id"`
	Algorithm         string `json:"algorithm"`
	PublicKeyHex      string `json:"public_key_hex"`
	CreatedAt         string `json:"created_at,omitempty"`
	FingerprintSHA256 string `json:"fingerprint_sha256,omitempty"`
}

type SignedMasterCertificate struct {
	Certificate            MasterCertificatePayload `json:"certificate"`
	SignatureAlgorithm     string                   `json:"signature_algorithm"`
	SignaturePayloadSHA256 string                   `json:"signature_payload_sha256"`
	RootSignatureHex       string                   `json:"root_signature_hex"`
}

type MasterCertificatePayload struct {
	SchemaVersion   string                     `json:"schema_version"`
	CertificateID   string                     `json:"certificate_id"`
	Role            string                     `json:"role"`
	IssuerRootKeyID string                     `json:"issuer_root_key_id"`
	Algorithm       string                     `json:"algorithm"`
	PublicKeyHex    string                     `json:"public_key_hex"`
	NotBefore       string                     `json:"not_before"`
	NotAfter        string                     `json:"not_after"`
	Extensions      MasterCertificateExtension `json:"extensions"`
}

type MasterCertificateExtension struct {
	RevokedCertificateFingerprints []string `json:"revoked_certificate_fingerprints"`
}

type MasterKey struct {
	Certificate  SignedMasterCertificate
	PrivateKey   *secp.PrivateKey
	PublicKeyHex string
}

type VetoSignRequest struct {
	TargetExperienceID string   `json:"target_experience_id"`
	VetoTarget         string   `json:"veto_target"`
	VetoedPubkeys      []string `json:"vetoed_pubkeys,omitempty"`
	VetoedDAGNodes     []string `json:"vetoed_dag_nodes,omitempty"`
	Reason             string   `json:"reason"`
	PrevHashes         []string `json:"prev_hashes"`
	Timestamp          string   `json:"timestamp,omitempty"`
}

type VetoBlock struct {
	Type               string   `json:"type"`
	TargetExperienceID string   `json:"target_experience_id"`
	VetoTarget         string   `json:"veto_target"`
	VetoedPubkeys      []string `json:"vetoed_pubkeys,omitempty"`
	VetoedDAGNodes     []string `json:"vetoed_dag_nodes,omitempty"`
	Reason             string   `json:"reason"`
	PrevHashes         []string `json:"prev_hashes"`
	Timestamp          string   `json:"timestamp"`
	CertificateID      string   `json:"certificate_id"`
	SignerRole         string   `json:"signer_role"`
	SignatureAlgorithm string   `json:"signature_algorithm"`
	MasterSignature    string   `json:"master_signature"`
}

type vetoPayload struct {
	Type               string   `json:"type"`
	TargetExperienceID string   `json:"target_experience_id"`
	VetoTarget         string   `json:"veto_target"`
	VetoedPubkeys      []string `json:"vetoed_pubkeys,omitempty"`
	VetoedDAGNodes     []string `json:"vetoed_dag_nodes,omitempty"`
	Reason             string   `json:"reason"`
	PrevHashes         []string `json:"prev_hashes"`
	Timestamp          string   `json:"timestamp"`
	CertificateID      string   `json:"certificate_id"`
	SignerRole         string   `json:"signer_role"`
	SignatureAlgorithm string   `json:"signature_algorithm"`
}

type VetoSignResponse struct {
	VetoBlock         VetoBlock       `json:"veto_block"`
	SignaturePayload  json.RawMessage `json:"signature_payload"`
	MasterCertificate json.RawMessage `json:"master_certificate"`
}

func Load(cfg Config) (*Service, error) {
	rootRaw, err := os.ReadFile(cfg.RootCertificatePath)
	if err != nil {
		return nil, fmt.Errorf("read root certificate: %w", err)
	}
	masterRaw, err := os.ReadFile(cfg.MasterCertificatePath)
	if err != nil {
		return nil, fmt.Errorf("read master certificate: %w", err)
	}

	var root RootCertificate
	if err := json.Unmarshal(rootRaw, &root); err != nil {
		return nil, fmt.Errorf("decode root certificate: %w", err)
	}
	var cert SignedMasterCertificate
	if err := json.Unmarshal(masterRaw, &cert); err != nil {
		return nil, fmt.Errorf("decode master certificate: %w", err)
	}
	if err := verifyMasterCertificate(root, cert); err != nil {
		return nil, err
	}
	master, err := LoadMasterKey(cfg.MasterPrivateKeyHex, cert)
	if err != nil {
		return nil, err
	}
	return &Service{
		RootCertificateRaw:   append(json.RawMessage(nil), rootRaw...),
		MasterCertificateRaw: append(json.RawMessage(nil), masterRaw...),
		Master:               master,
	}, nil
}

func LoadMasterKey(privateKeyHex string, cert SignedMasterCertificate) (*MasterKey, error) {
	raw, err := hex.DecodeString(strings.TrimSpace(privateKeyHex))
	if err != nil {
		return nil, fmt.Errorf("decode master private key: %w", err)
	}
	if len(raw) != PrivateKeyLength {
		return nil, fmt.Errorf("master private key must be %d bytes, got %d", PrivateKeyLength, len(raw))
	}
	priv := secp.PrivKeyFromBytes(raw)
	publicHex := hex.EncodeToString(priv.PubKey().SerializeUncompressed())
	if !strings.EqualFold(publicHex, cert.Certificate.PublicKeyHex) {
		return nil, fmt.Errorf("master private key does not match master certificate public key")
	}
	return &MasterKey{
		Certificate:  cert,
		PrivateKey:   priv,
		PublicKeyHex: publicHex,
	}, nil
}

func (s *Service) SignVetoBlock(req VetoSignRequest) (VetoSignResponse, error) {
	if s == nil || s.Master == nil {
		return VetoSignResponse{}, fmt.Errorf("governance service is not configured")
	}
	if strings.TrimSpace(req.TargetExperienceID) == "" {
		return VetoSignResponse{}, fmt.Errorf("target_experience_id is required")
	}
	if !slices.Contains([]string{"ratings", "experience", "veto"}, req.VetoTarget) {
		return VetoSignResponse{}, fmt.Errorf("veto_target must be ratings, experience, or veto")
	}
	if strings.TrimSpace(req.Reason) == "" {
		return VetoSignResponse{}, fmt.Errorf("reason is required")
	}
	if len(req.PrevHashes) == 0 {
		return VetoSignResponse{}, fmt.Errorf("prev_hashes is required")
	}
	timestamp := strings.TrimSpace(req.Timestamp)
	if timestamp == "" {
		timestamp = time.Now().UTC().Format(time.RFC3339)
	}

	cert := s.Master.Certificate.Certificate
	payload := vetoPayload{
		Type:               "veto_block",
		TargetExperienceID: req.TargetExperienceID,
		VetoTarget:         req.VetoTarget,
		VetoedPubkeys:      req.VetoedPubkeys,
		VetoedDAGNodes:     req.VetoedDAGNodes,
		Reason:             req.Reason,
		PrevHashes:         req.PrevHashes,
		Timestamp:          timestamp,
		CertificateID:      cert.CertificateID,
		SignerRole:         cert.Role,
		SignatureAlgorithm: Algorithm,
	}
	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		return VetoSignResponse{}, err
	}
	signature, err := Sign(s.Master.PrivateKey, payloadBytes)
	if err != nil {
		return VetoSignResponse{}, err
	}
	return VetoSignResponse{
		VetoBlock: VetoBlock{
			Type:               payload.Type,
			TargetExperienceID: payload.TargetExperienceID,
			VetoTarget:         payload.VetoTarget,
			VetoedPubkeys:      payload.VetoedPubkeys,
			VetoedDAGNodes:     payload.VetoedDAGNodes,
			Reason:             payload.Reason,
			PrevHashes:         payload.PrevHashes,
			Timestamp:          payload.Timestamp,
			CertificateID:      payload.CertificateID,
			SignerRole:         payload.SignerRole,
			SignatureAlgorithm: payload.SignatureAlgorithm,
			MasterSignature:    signature,
		},
		SignaturePayload:  json.RawMessage(payloadBytes),
		MasterCertificate: s.MasterCertificateRaw,
	}, nil
}

func verifyMasterCertificate(root RootCertificate, cert SignedMasterCertificate) error {
	if root.Algorithm != Algorithm || cert.SignatureAlgorithm != Algorithm || cert.Certificate.Algorithm != Algorithm {
		return fmt.Errorf("unsupported governance certificate algorithm")
	}
	if root.KeyID == "" || cert.Certificate.IssuerRootKeyID != root.KeyID {
		return fmt.Errorf("master certificate issuer does not match root key id")
	}
	notBefore, err := time.Parse(time.RFC3339, cert.Certificate.NotBefore)
	if err != nil {
		return fmt.Errorf("parse master certificate not_before: %w", err)
	}
	notAfter, err := time.Parse(time.RFC3339, cert.Certificate.NotAfter)
	if err != nil {
		return fmt.Errorf("parse master certificate not_after: %w", err)
	}
	now := time.Now().UTC()
	if now.Before(notBefore) || now.After(notAfter) {
		return fmt.Errorf("master certificate is not valid at current time")
	}
	payloadBytes, err := json.Marshal(cert.Certificate)
	if err != nil {
		return err
	}
	if got := sha256Hex(payloadBytes); cert.SignaturePayloadSHA256 != "" && !strings.EqualFold(got, cert.SignaturePayloadSHA256) {
		return fmt.Errorf("master certificate payload sha256 mismatch")
	}
	if err := Verify(root.PublicKeyHex, payloadBytes, cert.RootSignatureHex); err != nil {
		return fmt.Errorf("verify master certificate root signature: %w", err)
	}
	return nil
}

func Sign(privateKey *secp.PrivateKey, message []byte) (string, error) {
	if privateKey == nil {
		return "", fmt.Errorf("private key is not loaded")
	}
	digest := sha256.Sum256(message)
	sig := ecdsa.Sign(privateKey, digest[:])

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

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
