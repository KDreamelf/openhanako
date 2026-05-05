package ph01auth

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"
)

func TestClientVerifySignatureAndPubkeys(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/auth/verify_signature":
			var req VerifySignatureRequest
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				t.Fatalf("decode verify_signature: %v", err)
			}
			if req.PubkeyHex != "04abcd" {
				t.Fatalf("unexpected pubkey: %s", req.PubkeyHex)
			}
			if req.UserID != 42 {
				t.Fatalf("unexpected user_id: %d", req.UserID)
			}
			_ = json.NewEncoder(w).Encode(VerifySignatureResponse{
				Valid:      true,
				UserID:     42,
				Username:   "alice",
				Tier:       "free",
				PubkeyHash: "hash",
			})
		case "/api/v1/auth/verify_challenge_signature":
			var req VerifyChallengeSignatureRequest
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				t.Fatalf("decode verify_challenge_signature: %v", err)
			}
			if req.UserID != 42 || req.Challenge != "challenge" || req.SignatureHex != "sig" {
				t.Fatalf("unexpected challenge signature request: %+v", req)
			}
			_ = json.NewEncoder(w).Encode(VerifySignatureResponse{
				Valid:      true,
				UserID:     42,
				Username:   "alice",
				Tier:       "free",
				PubkeyHash: "hash",
			})
		case "/api/v1/auth/verify_pubkeys":
			var req VerifyPubkeysRequest
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				t.Fatalf("decode verify_pubkeys: %v", err)
			}
			if len(req.Items) != 1 {
				t.Fatalf("expected one item, got %d", len(req.Items))
			}
			_ = json.NewEncoder(w).Encode(VerifyPubkeysResponse{OK: true})
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	client := NewClient(srv.URL)
	sigResp, err := client.VerifySignature(context.Background(), VerifySignatureRequest{
		UserID:       42,
		PubkeyHex:    "04abcd",
		SignatureHex: "sig",
		Payload:      "{}",
		Timestamp:    1,
		Nonce:        "nonce",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !sigResp.Valid || sigResp.UserID != 42 {
		t.Fatalf("unexpected verify_signature response: %+v", sigResp)
	}
	challengeResp, err := client.VerifyChallengeSignature(context.Background(), VerifyChallengeSignatureRequest{
		UserID:       42,
		Challenge:    "challenge",
		SignatureHex: "sig",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !challengeResp.Valid || challengeResp.PubkeyHash != "hash" {
		t.Fatalf("unexpected verify_challenge_signature response: %+v", challengeResp)
	}

	pubResp, err := client.VerifyPubkeys(context.Background(), VerifyPubkeysRequest{
		Items: []PubkeyBindingCheck{{UserID: 42, PubkeyHash: "hash"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !pubResp.OK {
		t.Fatalf("unexpected verify_pubkeys response: %+v", pubResp)
	}
}

func TestClientWithTLS(t *testing.T) {
	caCertPEM, caKeyPEM := mustGenerateCA(t)
	serverCertPEM, serverKeyPEM := mustGenerateLeafCert(t, caCertPEM, caKeyPEM, true)
	clientCertPEM, clientKeyPEM := mustGenerateLeafCert(t, caCertPEM, caKeyPEM, false)

	dir := t.TempDir()
	caPath := writeTempFile(t, dir, "ca.pem", caCertPEM)
	serverCertPath := writeTempFile(t, dir, "server-cert.pem", serverCertPEM)
	serverKeyPath := writeTempFile(t, dir, "server-key.pem", serverKeyPEM)
	clientCertPath := writeTempFile(t, dir, "client-cert.pem", clientCertPEM)
	clientKeyPath := writeTempFile(t, dir, "client-key.pem", clientKeyPEM)

	caPool := x509.NewCertPool()
	if !caPool.AppendCertsFromPEM(caCertPEM) {
		t.Fatal("failed to append CA cert")
	}
	serverCert, err := tls.LoadX509KeyPair(serverCertPath, serverKeyPath)
	if err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.TLS == nil || len(r.TLS.VerifiedChains) == 0 {
			http.Error(w, "missing client cert", http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(VerifySignatureResponse{
			Valid:    true,
			UserID:   7,
			Username: "mtls",
		})
	}))
	srv.TLS = &tls.Config{
		Certificates: []tls.Certificate{serverCert},
		ClientAuth:   tls.RequireAndVerifyClientCert,
		ClientCAs:    caPool,
		MinVersion:   tls.VersionTLS12,
	}
	srv.StartTLS()
	defer srv.Close()

	plainClient := NewClient(srv.URL)
	if _, err := plainClient.VerifySignature(context.Background(), VerifySignatureRequest{
		PubkeyHex:    "04abcd",
		SignatureHex: "sig",
		Payload:      "{}",
		Timestamp:    1,
		Nonce:        "nonce",
	}); err == nil {
		t.Fatal("expected request without client cert to fail")
	}

	client, err := NewClientWithTLS(srv.URL, TLSFiles{
		CACertPath:     caPath,
		ClientCertPath: clientCertPath,
		ClientKeyPath:  clientKeyPath,
	})
	if err != nil {
		t.Fatal(err)
	}
	resp, err := client.VerifySignature(context.Background(), VerifySignatureRequest{
		PubkeyHex:    "04abcd",
		SignatureHex: "sig",
		Payload:      "{}",
		Timestamp:    1,
		Nonce:        "nonce",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !resp.Valid || resp.UserID != 7 {
		t.Fatalf("unexpected mTLS response: %+v", resp)
	}
}

func mustGenerateCA(t *testing.T) ([]byte, []byte) {
	t.Helper()
	cert, key := mustGenerateCert(t, nil, nil, true, false)
	return cert, key
}

func mustGenerateLeafCert(t *testing.T, caCertPEM, caKeyPEM []byte, server bool) ([]byte, []byte) {
	t.Helper()
	return mustGenerateCert(t, caCertPEM, caKeyPEM, false, server)
}

func mustGenerateCert(t *testing.T, caCertPEM, caKeyPEM []byte, isCA bool, server bool) ([]byte, []byte) {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}

	serial, err := rand.Int(rand.Reader, big.NewInt(1<<62))
	if err != nil {
		t.Fatal(err)
	}

	template := &x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:   "ph01-auth-test",
			Organization: []string{"PH01"},
		},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment | x509.KeyUsageCertSign,
		BasicConstraintsValid: true,
		IsCA:                  isCA,
	}
	if server {
		template.DNSNames = []string{"localhost"}
		template.IPAddresses = []net.IP{net.ParseIP("127.0.0.1")}
	}
	if !isCA {
		template.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth}
	}

	parent := template
	signer := priv
	if caCertPEM != nil && caKeyPEM != nil {
		caCert, err := parseCert(caCertPEM)
		if err != nil {
			t.Fatal(err)
		}
		caKey, err := parseKey(caKeyPEM)
		if err != nil {
			t.Fatal(err)
		}
		parent = caCert
		signer = caKey
		template.IsCA = false
		template.KeyUsage = x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment
	}

	derBytes, err := x509.CreateCertificate(rand.Reader, template, parent, &priv.PublicKey, signer)
	if err != nil {
		t.Fatal(err)
	}

	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: derBytes})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(priv)})
	return certPEM, keyPEM
}

func parseCert(pemBytes []byte) (*x509.Certificate, error) {
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errors.New("invalid certificate pem")
	}
	return x509.ParseCertificate(block.Bytes)
}

func parseKey(pemBytes []byte) (*rsa.PrivateKey, error) {
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errors.New("invalid private key pem")
	}
	return x509.ParsePKCS1PrivateKey(block.Bytes)
}

func writeTempFile(t *testing.T, dir, name string, data []byte) string {
	t.Helper()
	path := dir + string(os.PathSeparator) + name
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}
