package governance

import (
	"encoding/json"
	"testing"
)

const privateKeyOne = "0000000000000000000000000000000000000000000000000000000000000001"
const publicKeyOne = "0479be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8"

func TestSignVetoBlockWithMasterCertificate(t *testing.T) {
	cert := SignedMasterCertificate{
		Certificate: MasterCertificatePayload{
			CertificateID: "test-master",
			Role:          "experience_review_master",
			Algorithm:     Algorithm,
			PublicKeyHex:  publicKeyOne,
		},
		SignatureAlgorithm: Algorithm,
	}
	master, err := LoadMasterKey(privateKeyOne, cert)
	if err != nil {
		t.Fatalf("load master key: %v", err)
	}
	svc := &Service{
		Master:               master,
		MasterCertificateRaw: json.RawMessage(`{"certificate":{"certificate_id":"test-master"}}`),
	}
	resp, err := svc.SignVetoBlock(VetoSignRequest{
		TargetExperienceID: "exp_1",
		VetoTarget:         "ratings",
		VetoedPubkeys:      []string{"pk_a"},
		Reason:             "bot_attack_detected",
		PrevHashes:         []string{"sha256_prev"},
		Timestamp:          "2026-05-04T00:00:00Z",
	})
	if err != nil {
		t.Fatalf("sign veto block: %v", err)
	}
	if resp.VetoBlock.CertificateID != "test-master" {
		t.Fatalf("certificate id = %q", resp.VetoBlock.CertificateID)
	}
	if resp.VetoBlock.MasterSignature == "" {
		t.Fatal("missing master signature")
	}
	if err := Verify(publicKeyOne, resp.SignaturePayload, resp.VetoBlock.MasterSignature); err != nil {
		t.Fatalf("verify master signature: %v", err)
	}
}

func TestSignReviewMaterials(t *testing.T) {
	cert := SignedMasterCertificate{
		Certificate: MasterCertificatePayload{
			CertificateID:   "test-master",
			Role:            "experience_review_master",
			IssuerRootKeyID: "test-root",
			Algorithm:       Algorithm,
			PublicKeyHex:    publicKeyOne,
		},
		SignatureAlgorithm: Algorithm,
	}
	master, err := LoadMasterKey(privateKeyOne, cert)
	if err != nil {
		t.Fatalf("load master key: %v", err)
	}
	svc := &Service{
		Master:               master,
		MasterCertificateRaw: json.RawMessage(`{"certificate":{"certificate_id":"test-master"}}`),
	}
	materials, err := svc.SignReview(ReviewSignRequest{
		ExperienceID:    "exp_1",
		PackageHash:     "abc123",
		PublisherPubkey: publicKeyOne,
		ReviewMode:      "manual_review",
		ReviewedAt:      "2026-05-09T00:00:00Z",
	})
	if err != nil {
		t.Fatalf("sign review: %v", err)
	}
	if materials.SchemaVersion != "ph01.experience.review_materials.v1" {
		t.Fatalf("unexpected schema: %s", materials.SchemaVersion)
	}
	if materials.ManagerReviewSignature == "" || materials.SignaturePayloadSHA256 == "" {
		t.Fatalf("review signature materials incomplete: %+v", materials)
	}
	if err := Verify(publicKeyOne, materials.SignaturePayload, materials.ManagerReviewSignature); err != nil {
		t.Fatalf("verify review signature: %v", err)
	}
}

func TestLoadMasterKeyRejectsMismatchedCertificate(t *testing.T) {
	cert := SignedMasterCertificate{
		Certificate: MasterCertificatePayload{
			PublicKeyHex: "04aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		},
	}
	if _, err := LoadMasterKey(privateKeyOne, cert); err == nil {
		t.Fatal("expected mismatched certificate to fail")
	}
}
