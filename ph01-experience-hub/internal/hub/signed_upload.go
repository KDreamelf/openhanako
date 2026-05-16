package hub

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"ph01-experience-hub/internal/governance"
)

var (
	errSignedUploadInvalidPayload    = errors.New("invalid signed upload payload")
	errSignedUploadTimestampExpired  = errors.New("timestamp expired")
	errSignedUploadInvalidSignature  = errors.New("invalid signature")
	errSignedUploadPackageHashFailed = errors.New("package sha256 mismatch")
)

const signedUploadMaxSkew = 5 * time.Minute

type decodedExperienceUpload struct {
	PackageBytes []byte
	Payload      ExperienceUploadPayload
	Signed       SignedRequest
	PubkeyHash   string
}

func decodeSignedExperienceUpload(body []byte, now time.Time) (decodedExperienceUpload, error) {
	var req SignedRequest
	if err := json.Unmarshal(body, &req); err != nil {
		return decodedExperienceUpload{}, fmt.Errorf("%w: %v", errSignedUploadInvalidPayload, err)
	}
	if err := verifySignedRequest(req, now); err != nil {
		return decodedExperienceUpload{}, err
	}

	var payload ExperienceUploadPayload
	if err := json.Unmarshal([]byte(req.Payload), &payload); err != nil {
		return decodedExperienceUpload{}, fmt.Errorf("%w: %v", errSignedUploadInvalidPayload, err)
	}
	if schema := strings.TrimSpace(payload.SchemaVersion); schema != "" && schema != ExperienceUploadSchemaVersion {
		return decodedExperienceUpload{}, fmt.Errorf("%w: unsupported schema_version %q", errSignedUploadInvalidPayload, schema)
	}
	encoded := strings.TrimSpace(payload.PackageBase64)
	if encoded == "" {
		return decodedExperienceUpload{}, fmt.Errorf("%w: package_base64 required", errSignedUploadInvalidPayload)
	}
	packageBytes, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return decodedExperienceUpload{}, fmt.Errorf("%w: package_base64 decode: %v", errSignedUploadInvalidPayload, err)
	}
	if len(packageBytes) == 0 {
		return decodedExperienceUpload{}, fmt.Errorf("%w: package is empty", errSignedUploadInvalidPayload)
	}
	sum := sha256.Sum256(packageBytes)
	packageHash := hex.EncodeToString(sum[:])
	if declared := strings.TrimSpace(payload.PackageSHA256); declared != "" {
		if !strings.EqualFold(declared, packageHash) {
			return decodedExperienceUpload{}, errSignedUploadPackageHashFailed
		}
	}
	payload.PackageSHA256 = packageHash
	pubkeyHash, err := dhtPubkeyHash(req.PubkeyHex)
	if err != nil {
		return decodedExperienceUpload{}, fmt.Errorf("%w: pubkey hash: %v", errSignedUploadInvalidPayload, err)
	}
	return decodedExperienceUpload{
		PackageBytes: packageBytes,
		Payload:      payload,
		Signed:       req,
		PubkeyHash:   pubkeyHash,
	}, nil
}

func verifySignedRequest(req SignedRequest, now time.Time) error {
	if strings.TrimSpace(req.Payload) == "" ||
		strings.TrimSpace(req.PubkeyHex) == "" ||
		strings.TrimSpace(req.SignatureHex) == "" ||
		strings.TrimSpace(req.Nonce) == "" ||
		req.Timestamp == 0 {
		return fmt.Errorf("%w: signed request fields required", errSignedUploadInvalidPayload)
	}
	delta := now.Unix() - req.Timestamp
	if delta > int64(signedUploadMaxSkew.Seconds()) || delta < -int64(signedUploadMaxSkew.Seconds()) {
		return fmt.Errorf("%w: skew=%ds", errSignedUploadTimestampExpired, delta)
	}
	signed := req.Payload + "\n" + req.PubkeyHex + "\n" + fmt.Sprintf("%d", req.Timestamp) + "\n" + req.Nonce
	if err := governance.Verify(req.PubkeyHex, []byte(signed), req.SignatureHex); err != nil {
		return fmt.Errorf("%w: %v", errSignedUploadInvalidSignature, err)
	}
	return nil
}
