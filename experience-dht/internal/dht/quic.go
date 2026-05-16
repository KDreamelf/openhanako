package dht

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"io"
	"log"
	"math/big"
	"strings"
	"time"

	"github.com/quic-go/quic-go"
)

const (
	DefaultQUICListenAddr = ":41002"
	quicALPN              = "ph01-experience-dht"
)

func (h *Handler) RunQUICServer(ctx context.Context, listenAddr string) error {
	listenAddr = strings.TrimSpace(listenAddr)
	if listenAddr == "" {
		listenAddr = DefaultQUICListenAddr
	}
	listener, err := quic.ListenAddr(listenAddr, quicTLSConfig(), &quic.Config{
		MaxIdleTimeout: 15 * time.Second,
	})
	if err != nil {
		return err
	}
	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()
	log.Printf("[info] experience-dht QUIC listening on %s node=%s", listenAddr, h.nodeIDOrConfig())
	for {
		conn, err := listener.Accept(ctx)
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, context.Canceled) {
				return nil
			}
			return err
		}
		go h.handleQUICConnection(ctx, conn)
	}
}

func (h *Handler) handleQUICConnection(ctx context.Context, conn *quic.Conn) {
	defer conn.CloseWithError(0, "")
	stream, err := conn.AcceptStream(ctx)
	if err != nil {
		return
	}
	defer stream.Close()
	_ = stream.SetReadDeadline(time.Now().Add(5 * time.Second))
	line, _ := bufio.NewReader(stream).ReadString('\n')
	if strings.TrimSpace(line) == "" {
		return
	}
	if strings.TrimSpace(line) != "healthz" {
		_, _ = io.WriteString(stream, `{"ok":false,"service":"experience-dht-quic","error":"unknown_command"}`+"\n")
		return
	}
	state, _ := h.Store.Get()
	_, _ = io.WriteString(stream, `{"ok":true,"service":"experience-dht-quic","node_id":"`+h.nodeID(state)+`"}`+"\n")
}

func (h *Handler) nodeIDOrConfig() string {
	state, err := h.Store.Get()
	if err == nil {
		return h.nodeID(state)
	}
	return strings.TrimSpace(h.Config.NodeID)
}

func quicTLSConfig() *tls.Config {
	cert, err := selfSignedQUICCert()
	if err != nil {
		panic(err)
	}
	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		NextProtos:   []string{quicALPN},
	}
}

func selfSignedQUICCert() (tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, err
	}
	template := x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "experience-dht"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return tls.Certificate{}, err
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	return tls.X509KeyPair(certPEM, keyPEM)
}
