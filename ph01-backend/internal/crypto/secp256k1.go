// Package crypto 提供 secp256k1 ECDSA 验签 + ECDH 协商 + AES-256-GCM。
//
// 与子体侧 hanako-flutter/lib/identity/keypair.dart 保持完全一致：
//   - 65 字节非压缩公钥：0x04 ‖ X(32) ‖ Y(32)
//   - 64 字节签名：r ‖ s 大端，**不**用 DER
//   - SHA-256 摘要
package crypto

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"

	secp "github.com/decred/dcrd/dcrec/secp256k1/v4"
	ecdsa "github.com/decred/dcrd/dcrec/secp256k1/v4/ecdsa"
)

// PubkeyLength 是非压缩 secp256k1 公钥的固定长度（含 0x04 前缀）。
const PubkeyLength = 65

// SignatureLength 是 r‖s 固定长度签名的字节数。
const SignatureLength = 64

// ErrInvalidPubkey 表示公钥格式或曲线点不合法。
var ErrInvalidPubkey = errors.New("invalid public key")

// ErrInvalidSignature 表示签名解析失败或验证未通过。
var ErrInvalidSignature = errors.New("invalid signature")

// ParsePubkey 把 65 字节的非压缩公钥 hex 解析为 secp256k1 公钥。
func ParsePubkey(pubkeyHex string) (*secp.PublicKey, error) {
	raw, err := hex.DecodeString(pubkeyHex)
	if err != nil {
		return nil, fmt.Errorf("%w: hex decode: %v", ErrInvalidPubkey, err)
	}
	if len(raw) != PubkeyLength {
		return nil, fmt.Errorf("%w: expected %d bytes, got %d",
			ErrInvalidPubkey, PubkeyLength, len(raw))
	}
	if raw[0] != 0x04 {
		return nil, fmt.Errorf("%w: not uncompressed format (prefix=0x%02x)",
			ErrInvalidPubkey, raw[0])
	}
	pub, err := secp.ParsePubKey(raw)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidPubkey, err)
	}
	return pub, nil
}

// SerializePubkey 反向：把公钥序列化为 65 字节非压缩 hex。
func SerializePubkey(pub *secp.PublicKey) string {
	return hex.EncodeToString(pub.SerializeUncompressed())
}

// PubkeyHash 计算公钥的 SHA-256 哈希（hex 形式，64 字符）。
// 与 hanako-flutter 的 HanakoKeyPair.publicKeyHash 算法一致。
func PubkeyHash(pubkeyHex string) (string, error) {
	raw, err := hex.DecodeString(pubkeyHex)
	if err != nil {
		return "", err
	}
	if len(raw) != PubkeyLength {
		return "", fmt.Errorf("invalid pubkey length: %d", len(raw))
	}
	h := sha256.Sum256(raw)
	return hex.EncodeToString(h[:]), nil
}

// VerifySignature 验证 64 字节 r‖s 大端格式签名。
//
// 参数：
//   pubkeyHex   - 65 字节非压缩公钥 hex
//   message     - 待签名的原始字节（内部做 SHA-256）
//   signatureHex - 64 字节 r‖s hex
//
// 返回 nil 表示验证通过；其他 error 表示失败原因。
func VerifySignature(pubkeyHex string, message []byte, signatureHex string) error {
	pub, err := ParsePubkey(pubkeyHex)
	if err != nil {
		return err
	}
	sigRaw, err := hex.DecodeString(signatureHex)
	if err != nil {
		return fmt.Errorf("%w: signature hex decode: %v", ErrInvalidSignature, err)
	}
	if len(sigRaw) != SignatureLength {
		return fmt.Errorf("%w: expected %d bytes, got %d",
			ErrInvalidSignature, SignatureLength, len(sigRaw))
	}
	r := new(big.Int).SetBytes(sigRaw[:32])
	s := new(big.Int).SetBytes(sigRaw[32:])

	// dcrd 的 ECDSA 用 ModNScalar 表达 r/s
	var rScalar, sScalar secp.ModNScalar
	if rScalar.SetByteSlice(r.Bytes()) {
		return fmt.Errorf("%w: r overflows curve order", ErrInvalidSignature)
	}
	if sScalar.SetByteSlice(s.Bytes()) {
		return fmt.Errorf("%w: s overflows curve order", ErrInvalidSignature)
	}
	sig := ecdsa.NewSignature(&rScalar, &sScalar)

	digest := sha256.Sum256(message)
	if !sig.Verify(digest[:], pub) {
		return fmt.Errorf("%w: ecdsa verification failed", ErrInvalidSignature)
	}
	return nil
}

// SignMessage 用私钥（32 字节）对 message 做 SHA-256 后签名，返回 64 字节 r‖s hex。
// 服务端正常工作不需要签名（除非有 root 私钥签发响应），此函数主要供测试和服务端 root 签名使用。
func SignMessage(privKeyBytes []byte, message []byte) (string, error) {
	if len(privKeyBytes) != 32 {
		return "", fmt.Errorf("private key must be 32 bytes, got %d", len(privKeyBytes))
	}
	priv := secp.PrivKeyFromBytes(privKeyBytes)
	digest := sha256.Sum256(message)
	sig := ecdsa.Sign(priv, digest[:])

	r := sig.R()
	s := sig.S()
	rBytes := r.Bytes()
	sBytes := s.Bytes()

	out := make([]byte, 64)
	copy(out[:32], rBytes[:])
	copy(out[32:], sBytes[:])
	return hex.EncodeToString(out), nil
}
