package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	secp "github.com/decred/dcrd/dcrec/secp256k1/v4"
	"github.com/hanako/legacy-p2p-authority/internal/rootkey"
)

const (
	rootPrivateSchema   = "legacy.experience.root_private.v1"
	rootPublicSchema    = "legacy.experience.root_certificate.v1"
	masterPrivateSchema = "legacy.experience.master_private.v1"
	masterCertSchema    = "legacy.experience.master_certificate.v1"
)

type privateKeyDocument struct {
	SchemaVersion string `json:"schema_version"`
	KeyID         string `json:"key_id"`
	Algorithm     string `json:"algorithm"`
	PrivateKeyHex string `json:"private_key_hex"`
	PublicKeyHex  string `json:"public_key_hex"`
	CreatedAt     string `json:"created_at"`
}

type rootCertificatePayload struct {
	SchemaVersion string `json:"schema_version"`
	KeyID         string `json:"key_id"`
	Algorithm     string `json:"algorithm"`
	PublicKeyHex  string `json:"public_key_hex"`
	CreatedAt     string `json:"created_at"`
}

type rootCertificateDocument struct {
	rootCertificatePayload
	FingerprintSHA256 string `json:"fingerprint_sha256"`
}

type masterCertificatePayload struct {
	SchemaVersion   string                     `json:"schema_version"`
	CertificateID   string                     `json:"certificate_id"`
	Role            string                     `json:"role"`
	IssuerRootKeyID string                     `json:"issuer_root_key_id"`
	Algorithm       string                     `json:"algorithm"`
	PublicKeyHex    string                     `json:"public_key_hex"`
	NotBefore       string                     `json:"not_before"`
	NotAfter        string                     `json:"not_after"`
	Extensions      masterCertificateExtension `json:"extensions"`
}

type masterCertificateExtension struct {
	RevokedCertificateFingerprints []string `json:"revoked_certificate_fingerprints"`
}

type signedMasterCertificate struct {
	Certificate            masterCertificatePayload `json:"certificate"`
	SignatureAlgorithm     string                   `json:"signature_algorithm"`
	SignaturePayloadSHA256 string                   `json:"signature_payload_sha256"`
	RootSignatureHex       string                   `json:"root_signature_hex"`
}

type manifestDocument struct {
	SchemaVersion              string `json:"schema_version"`
	GeneratedAt                string `json:"generated_at"`
	RootKeyID                  string `json:"root_key_id"`
	RootPublicKeyHex           string `json:"root_public_key_hex"`
	RootFingerprintSHA256      string `json:"root_fingerprint_sha256"`
	MasterCertificateID        string `json:"master_certificate_id"`
	MasterPayloadSHA256        string `json:"master_payload_sha256"`
	PrivateMaterialDirectory   string `json:"private_material_directory"`
	PublicCertificateDirectory string `json:"public_certificate_directory"`
}

func main() {
	privateOut := flag.String("private-out", filepath.Join("..", "secrets", "generated", "experience-network"), "private material output directory")
	publicOut := flag.String("public-out", filepath.Join("..", "certs", "public", "experience-network"), "public certificate output directory")
	keyID := flag.String("root-key-id", "", "root key id")
	masterID := flag.String("master-certificate-id", "", "master certificate id")
	force := flag.Bool("force", false, "overwrite existing files")
	flag.Parse()

	now := time.Now().UTC()
	if *keyID == "" {
		*keyID = "legacy-exp-root-" + now.Format("20060102")
	}
	if *masterID == "" {
		*masterID = "legacy-exp-master-" + now.Format("20060102")
	}

	if err := os.MkdirAll(*privateOut, 0o700); err != nil {
		panic(err)
	}
	if err := os.MkdirAll(*publicOut, 0o755); err != nil {
		panic(err)
	}

	rootPriv, err := generatePrivateKey()
	if err != nil {
		panic(err)
	}
	masterPriv, err := generatePrivateKey()
	if err != nil {
		panic(err)
	}

	rootDoc := privateKeyDocument{
		SchemaVersion: rootPrivateSchema,
		KeyID:         *keyID,
		Algorithm:     rootkey.Algorithm,
		PrivateKeyHex: rootPriv.privateHex,
		PublicKeyHex:  rootPriv.publicHex,
		CreatedAt:     now.Format(time.RFC3339),
	}
	masterPrivateDoc := privateKeyDocument{
		SchemaVersion: masterPrivateSchema,
		KeyID:         *masterID,
		Algorithm:     rootkey.Algorithm,
		PrivateKeyHex: masterPriv.privateHex,
		PublicKeyHex:  masterPriv.publicHex,
		CreatedAt:     now.Format(time.RFC3339),
	}

	rootPayload := rootCertificatePayload{
		SchemaVersion: rootPublicSchema,
		KeyID:         *keyID,
		Algorithm:     rootkey.Algorithm,
		PublicKeyHex:  rootPriv.publicHex,
		CreatedAt:     now.Format(time.RFC3339),
	}
	rootFingerprint := sha256Hex(mustHexBytes(rootPriv.publicHex))
	rootCertificate := rootCertificateDocument{
		rootCertificatePayload: rootPayload,
		FingerprintSHA256:      rootFingerprint,
	}

	notBefore := now.Add(-1 * time.Hour)
	notAfter := now.AddDate(3, 0, 0)
	masterPayload := masterCertificatePayload{
		SchemaVersion:   masterCertSchema,
		CertificateID:   *masterID,
		Role:            "experience_review_master",
		IssuerRootKeyID: *keyID,
		Algorithm:       rootkey.Algorithm,
		PublicKeyHex:    masterPriv.publicHex,
		NotBefore:       notBefore.Format(time.RFC3339),
		NotAfter:        notAfter.Format(time.RFC3339),
		Extensions: masterCertificateExtension{
			RevokedCertificateFingerprints: []string{},
		},
	}
	payloadBytes := mustJSON(masterPayload)
	root, err := rootkey.Load(*keyID, rootPriv.privateHex)
	if err != nil {
		panic(err)
	}
	sig, err := root.Sign(payloadBytes)
	if err != nil {
		panic(err)
	}
	masterCertificate := signedMasterCertificate{
		Certificate:            masterPayload,
		SignatureAlgorithm:     rootkey.Algorithm,
		SignaturePayloadSHA256: sha256Hex(payloadBytes),
		RootSignatureHex:       sig,
	}

	manifest := manifestDocument{
		SchemaVersion:              "legacy.experience.key_material_manifest.v1",
		GeneratedAt:                now.Format(time.RFC3339),
		RootKeyID:                  *keyID,
		RootPublicKeyHex:           rootPriv.publicHex,
		RootFingerprintSHA256:      rootFingerprint,
		MasterCertificateID:        *masterID,
		MasterPayloadSHA256:        masterCertificate.SignaturePayloadSHA256,
		PrivateMaterialDirectory:   filepath.Clean(*privateOut),
		PublicCertificateDirectory: filepath.Clean(*publicOut),
	}

	mustWriteJSON(filepath.Join(*privateOut, "root-private.json"), rootDoc, 0o600, *force)
	mustWriteJSON(filepath.Join(*privateOut, "master-private.json"), masterPrivateDoc, 0o600, *force)
	mustWriteJSON(filepath.Join(*privateOut, "legacy-p2p-authority-root-private.env"), map[string]string{
		"P2P_AUTHORITY_ROOT_PRIVATE_KEY_HEX":       rootPriv.privateHex,
		"LEGACY_EXPERIENCE_MASTER_PRIVATE_KEY_HEX": masterPriv.privateHex,
	}, 0o600, *force)
	mustWriteJSON(filepath.Join(*publicOut, "root-certificate.json"), rootCertificate, 0o644, *force)
	mustWriteJSON(filepath.Join(*publicOut, "master-certificate.json"), masterCertificate, 0o644, *force)
	mustWriteJSON(filepath.Join(*publicOut, "manifest.json"), manifest, 0o644, *force)

	fmt.Println("generated private material:", filepath.Clean(*privateOut))
	fmt.Println("generated public certificates:", filepath.Clean(*publicOut))
	fmt.Println("root key id:", *keyID)
	fmt.Println("root public key:", rootPriv.publicHex)
}

type generatedKey struct {
	privateHex string
	publicHex  string
}

func generatePrivateKey() (generatedKey, error) {
	priv, err := secp.GeneratePrivateKeyFromRand(rand.Reader)
	if err != nil {
		return generatedKey{}, err
	}
	return generatedKey{
		privateHex: hex.EncodeToString(priv.Serialize()),
		publicHex:  hex.EncodeToString(priv.PubKey().SerializeUncompressed()),
	}, nil
}

func mustJSON(v any) []byte {
	out, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return out
}

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func mustHexBytes(value string) []byte {
	out, err := hex.DecodeString(value)
	if err != nil {
		panic(err)
	}
	return out
}

func mustWriteJSON(path string, v any, perm os.FileMode, force bool) {
	if _, err := os.Stat(path); err == nil && !force {
		panic(fmt.Sprintf("%s already exists; pass -force to overwrite", path))
	}
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		panic(err)
	}
	data = append(data, '\n')
	if err := os.WriteFile(path, data, perm); err != nil {
		panic(err)
	}
}
