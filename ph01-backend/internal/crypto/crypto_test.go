package crypto

import (
	"crypto/rand"
	"encoding/hex"
	"testing"

	secp "github.com/decred/dcrd/dcrec/secp256k1/v4"
)

// TestSignatureRoundtrip：用一对随机密钥签名 + 验签自洽。
func TestSignatureRoundtrip(t *testing.T) {
	priv, err := secp.GeneratePrivateKey()
	if err != nil {
		t.Fatal(err)
	}
	privBytes := priv.Serialize()
	pubHex := hex.EncodeToString(priv.PubKey().SerializeUncompressed())
	msg := []byte("hello hanako")
	sig, err := SignMessage(privBytes, msg)
	if err != nil {
		t.Fatal(err)
	}
	if err := VerifySignature(pubHex, msg, sig); err != nil {
		t.Fatalf("verify: %v", err)
	}
	// 篡改消息应失败
	if err := VerifySignature(pubHex, []byte("hello hanak0"), sig); err == nil {
		t.Fatal("verify should have failed on tampered message")
	}
}

// TestECDHRoundtrip：双方各自派生应得到同一对称密钥。
func TestECDHRoundtrip(t *testing.T) {
	a, err := NewEphemeralKey()
	if err != nil {
		t.Fatal(err)
	}
	b, err := NewEphemeralKey()
	if err != nil {
		t.Fatal(err)
	}
	keyA, err := DeriveSharedKey(a.PrivateKey, b.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	keyB, err := DeriveSharedKey(b.PrivateKey, a.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(keyA) != hex.EncodeToString(keyB) {
		t.Fatalf("ECDH mismatch: a=%x b=%x", keyA, keyB)
	}
	if len(keyA) != 32 {
		t.Fatalf("expected 32 byte key, got %d", len(keyA))
	}
}

// TestAESGCMRoundtrip：加密 + 解密自洽。
func TestAESGCMRoundtrip(t *testing.T) {
	key := make([]byte, 32)
	rand.Read(key)
	plaintext := []byte("hanako encrypted message round trip OK")
	nonceHex, ctHex, tagHex, err := EncryptGCM(key, plaintext)
	if err != nil {
		t.Fatal(err)
	}
	dec, err := DecryptGCM(key, nonceHex, ctHex, tagHex)
	if err != nil {
		t.Fatal(err)
	}
	if string(dec) != string(plaintext) {
		t.Fatalf("decrypted mismatch: got %s", dec)
	}
	// 错误 key 应失败
	wrongKey := make([]byte, 32)
	if _, err := DecryptGCM(wrongKey, nonceHex, ctHex, tagHex); err == nil {
		t.Fatal("decrypt with wrong key should fail")
	}
}

// TestPubkeyHashStable：同一公钥的 hash 必须稳定。
func TestPubkeyHashStable(t *testing.T) {
	priv, _ := secp.GeneratePrivateKey()
	pubHex := hex.EncodeToString(priv.PubKey().SerializeUncompressed())
	h1, err := PubkeyHash(pubHex)
	if err != nil {
		t.Fatal(err)
	}
	h2, err := PubkeyHash(pubHex)
	if err != nil {
		t.Fatal(err)
	}
	if h1 != h2 {
		t.Fatalf("not stable: %s vs %s", h1, h2)
	}
	if len(h1) != 64 {
		t.Fatalf("expected 64 hex chars, got %d", len(h1))
	}
}
