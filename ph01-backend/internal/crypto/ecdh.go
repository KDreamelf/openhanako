// Package crypto 的 ECDH 部分。
//
// 子体 ↔ AI 网关密钥协商：
//   1. 双方各自生成临时 secp256k1 密钥对
//   2. 服务端 ECDH(s_priv, e_pub) = 子体 ECDH(e_priv, s_pub) = 共享 X 坐标
//   3. HKDF-SHA256(共享, salt="hanako-aes-v1", info="") → 32 字节 AES key
//
// 所有派生密钥仅用于 AES-256-GCM 会话加密，不直接落盘。
package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"

	secp "github.com/decred/dcrd/dcrec/secp256k1/v4"
	"golang.org/x/crypto/hkdf"
)

// HKDFSalt 是约定的 HKDF salt（与子体侧对齐）。
const HKDFSalt = "hanako-aes-v1"

// AESKeyLength = 32 (AES-256)
const AESKeyLength = 32

// AESNonceLength = 12 (GCM 标准)
const AESNonceLength = 12

// AESTagLength = 16 (GCM 认证 tag)
const AESTagLength = 16

// EphemeralKey 是一对临时 secp256k1 密钥（用于一次握手）。
type EphemeralKey struct {
	PrivateKey *secp.PrivateKey
	PublicKey  *secp.PublicKey
}

// NewEphemeralKey 生成一对新的临时密钥。
func NewEphemeralKey() (*EphemeralKey, error) {
	priv, err := secp.GeneratePrivateKey()
	if err != nil {
		return nil, fmt.Errorf("generate ephemeral key: %w", err)
	}
	return &EphemeralKey{
		PrivateKey: priv,
		PublicKey:  priv.PubKey(),
	}, nil
}

// PublicKeyHex 返回 65 字节非压缩公钥 hex。
func (e *EphemeralKey) PublicKeyHex() string {
	return hex.EncodeToString(e.PublicKey.SerializeUncompressed())
}

// DeriveSharedKey 用本地 [私钥] 与远端 [公钥] 做 ECDH，再 HKDF 派生 AES-256 key。
//
// 返回 32 字节 AES key。
func DeriveSharedKey(localPriv *secp.PrivateKey, remotePub *secp.PublicKey) ([]byte, error) {
	// dcrd v4 ECDH = scalar multiply 后取 X 坐标。
	shared := secpGenerateSharedSecret(localPriv, remotePub)
	hkdfReader := hkdf.New(sha256.New, shared, []byte(HKDFSalt), nil)
	aesKey := make([]byte, AESKeyLength)
	if _, err := io.ReadFull(hkdfReader, aesKey); err != nil {
		return nil, fmt.Errorf("hkdf: %w", err)
	}
	return aesKey, nil
}

// secpGenerateSharedSecret 计算 ECDH 共享秘密（X 坐标的 32 字节）。
func secpGenerateSharedSecret(priv *secp.PrivateKey, pub *secp.PublicKey) []byte {
	var pubJ secp.JacobianPoint
	pub.AsJacobian(&pubJ)
	var resJ secp.JacobianPoint
	secp.ScalarMultNonConst(&priv.Key, &pubJ, &resJ)
	resJ.ToAffine()
	xBytes := resJ.X.Bytes()
	return xBytes[:]
}

// EncryptGCM 用 [aesKey] (32 字节) 对 plaintext 做 AES-256-GCM 加密。
//
// 返回：
//   nonceHex (12 字节随机)
//   ciphertextHex (含末尾 tag 的密文 - GCM 模式 Seal 输出 = ct ‖ tag)
//   tagHex (16 字节 tag)
//
// 注意：Go 的 cipher.AEAD.Seal 把 tag 拼在密文末尾。我们拆出来便于跨语言对齐
// （子体侧 pointycastle GCMBlockCipher.process 也是把 tag 附在密文末尾，
// 所以传输格式上 ciphertext 和 tag 可以分开发，也可合并发——这里合并，子体
// 端也合并 process 即可）。
func EncryptGCM(aesKey, plaintext []byte) (nonceHex, ciphertextHex, tagHex string, err error) {
	block, err := aes.NewCipher(aesKey)
	if err != nil {
		return "", "", "", fmt.Errorf("aes new cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", "", "", fmt.Errorf("gcm new: %w", err)
	}
	nonce := make([]byte, AESNonceLength)
	if _, err := rand.Read(nonce); err != nil {
		return "", "", "", fmt.Errorf("nonce rand: %w", err)
	}
	combined := gcm.Seal(nil, nonce, plaintext, nil)
	if len(combined) < AESTagLength {
		return "", "", "", errors.New("gcm seal output too short")
	}
	ct := combined[:len(combined)-AESTagLength]
	tag := combined[len(combined)-AESTagLength:]
	return hex.EncodeToString(nonce),
		hex.EncodeToString(ct),
		hex.EncodeToString(tag), nil
}

// DecryptGCM 反向：用 [aesKey] 对 (nonce, ciphertext, tag) 做 AES-256-GCM 解密。
func DecryptGCM(aesKey []byte, nonceHex, ciphertextHex, tagHex string) ([]byte, error) {
	block, err := aes.NewCipher(aesKey)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	nonce, err := hex.DecodeString(nonceHex)
	if err != nil {
		return nil, fmt.Errorf("nonce hex: %w", err)
	}
	ct, err := hex.DecodeString(ciphertextHex)
	if err != nil {
		return nil, fmt.Errorf("ciphertext hex: %w", err)
	}
	tag, err := hex.DecodeString(tagHex)
	if err != nil {
		return nil, fmt.Errorf("tag hex: %w", err)
	}
	if len(nonce) != AESNonceLength {
		return nil, fmt.Errorf("nonce length: %d", len(nonce))
	}
	if len(tag) != AESTagLength {
		return nil, fmt.Errorf("tag length: %d", len(tag))
	}
	combined := append(ct, tag...)
	pt, err := gcm.Open(nil, nonce, combined, nil)
	if err != nil {
		return nil, fmt.Errorf("gcm open (auth failed?): %w", err)
	}
	return pt, nil
}
