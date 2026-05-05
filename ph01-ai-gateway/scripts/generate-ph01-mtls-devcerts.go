package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"flag"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

func main() {
	outDir := flag.String("out", filepath.Join("dev-certs", "ph01-mtls"), "output directory")
	flag.Parse()

	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		panic(err)
	}

	caCert, caKey, err := generateCA()
	if err != nil {
		panic(err)
	}
	if err := writePEM(filepath.Join(*outDir, "root-ca.pem"), "CERTIFICATE", caCert); err != nil {
		panic(err)
	}
	if err := writePEM(filepath.Join(*outDir, "root-ca-key.pem"), "RSA PRIVATE KEY", x509.MarshalPKCS1PrivateKey(caKey)); err != nil {
		panic(err)
	}

	authCert, authKey, err := generateLeaf(caCert, caKey, "ph01-auth-center", []string{"ph01-auth-center", "auth-center", "ph01-auth-center.local", "localhost"}, []net.IP{net.ParseIP("127.0.0.1")})
	if err != nil {
		panic(err)
	}
	if err := writePEM(filepath.Join(*outDir, "auth-center.pem"), "CERTIFICATE", authCert); err != nil {
		panic(err)
	}
	if err := writePEM(filepath.Join(*outDir, "auth-center-key.pem"), "RSA PRIVATE KEY", x509.MarshalPKCS1PrivateKey(authKey)); err != nil {
		panic(err)
	}

	gatewayCert, gatewayKey, err := generateLeaf(caCert, caKey, "ph01-ai-gateway", []string{"ph01-ai-gateway", "ai-gateway", "ph01-ai-gateway.local", "localhost"}, []net.IP{net.ParseIP("127.0.0.1")})
	if err != nil {
		panic(err)
	}
	if err := writePEM(filepath.Join(*outDir, "ai-gateway.pem"), "CERTIFICATE", gatewayCert); err != nil {
		panic(err)
	}
	if err := writePEM(filepath.Join(*outDir, "ai-gateway-key.pem"), "RSA PRIVATE KEY", x509.MarshalPKCS1PrivateKey(gatewayKey)); err != nil {
		panic(err)
	}

	fmt.Println("generated:", *outDir)
}

func generateCA() ([]byte, *rsa.PrivateKey, error) {
	key, err := rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		return nil, nil, err
	}
	tpl := &x509.Certificate{
		SerialNumber:          mustSerial(),
		Subject:               pkix.Name{CommonName: "PH01 Root CA", Organization: []string{"PH01"}},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().AddDate(10, 0, 0),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            2,
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		return nil, nil, err
	}
	return der, key, nil
}

func generateLeaf(caCertDER []byte, caKey *rsa.PrivateKey, commonName string, dnsNames []string, ips []net.IP) ([]byte, *rsa.PrivateKey, error) {
	caCert, err := x509.ParseCertificate(caCertDER)
	if err != nil {
		return nil, nil, err
	}
	key, err := rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		return nil, nil, err
	}
	tpl := &x509.Certificate{
		SerialNumber:          mustSerial(),
		Subject:               pkix.Name{CommonName: commonName, Organization: []string{"PH01"}},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().AddDate(3, 0, 0),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		BasicConstraintsValid: true,
		ExtKeyUsage: []x509.ExtKeyUsage{
			x509.ExtKeyUsageClientAuth,
			x509.ExtKeyUsageServerAuth,
		},
		DNSNames:    dnsNames,
		IPAddresses: ips,
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, caCert, &key.PublicKey, caKey)
	if err != nil {
		return nil, nil, err
	}
	return der, key, nil
}

func mustSerial() *big.Int {
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		panic(err)
	}
	return serial
}

func writePEM(path, typ string, der []byte) error {
	return os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: typ, Bytes: der}), 0o600)
}
