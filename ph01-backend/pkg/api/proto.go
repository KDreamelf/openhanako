// Package api 定义子体 ↔ 业务后台网关 ↔ AI 网关之间的协议数据结构。
//
// 与 docs/protocol-spec.md 的"协议契约"保持一一对应。
package api

// ========== §3.1 签名包装 ==========

// SignedRequest 是所有需要签名的 API 请求的外层包装。
type SignedRequest struct {
	// Payload 是原始业务请求体的 JSON 字符串（不是嵌套对象）。
	// 待签名内容 = Payload + "\n" + PubkeyHex + "\n" + Timestamp + "\n" + Nonce
	Payload string `json:"payload"`

	// PubkeyHex 是 65 字节非压缩公钥的 hex 形式：04 ‖ X(32) ‖ Y(32)
	PubkeyHex string `json:"pubkey"`

	// SignatureHex 是 64 字节 r‖s 大端的 hex 形式（不用 DER）。
	SignatureHex string `json:"signature"`

	// Timestamp 是 Unix 秒时间戳。服务端拒绝 ±5 分钟之外的请求。
	Timestamp int64 `json:"timestamp"`

	// Nonce 是 8 字节随机 hex。服务端在 5 分钟窗口内拒绝重复值。
	Nonce string `json:"nonce"`
}

// ========== §4 注册 ==========

// RegisterPayload 是注册请求 SignedRequest.Payload 的 JSON 内容。
type RegisterPayload struct {
	Username         string `json:"username"`
	Nickname         string `json:"nickname"`
	Email            string `json:"email"`
	EmailChallengeID string `json:"email_challenge_id"`
	EmailCode        string `json:"email_code"`
	PubkeyHex        string `json:"pubkey_hex"`
}

// IdentityResponse 是注册 / 身份确认成功的返回值。
// 服务端不签发 JWT / access token；长期身份由客户端私钥证明。
type RegisterResponse struct {
	UserID     uint64 `json:"user_id"`
	Username   string `json:"username"`
	Tier       string `json:"tier"`
	PubkeyHash string `json:"pubkey_hash"`
}

// UsernameAvailabilityResponse 是公开用户名预检接口返回值。
type UsernameAvailabilityResponse struct {
	Username  string `json:"username"`
	Available bool   `json:"available"`
}

// RegistrationEmailStartRequest 开始注册邮箱验证。
type RegistrationEmailStartRequest struct {
	Username string `json:"username"`
	Email    string `json:"email"`
}

// RegistrationEmailStartResponse 返回注册邮箱验证码挑战。
type RegistrationEmailStartResponse struct {
	ChallengeID     string `json:"challenge_id"`
	Delivery        string `json:"delivery"`
	ExpiresIn       int    `json:"expires_in"`
	CooldownSeconds int    `json:"cooldown_seconds"`
}

// ========== §5.1 简单登录 ==========

// LoginPayload 是登录请求 SignedRequest.Payload 的 JSON 内容。
type LoginPayload struct {
	Username string `json:"username"`
}

// LoginResponse 是身份确认成功的返回值。结构同 RegisterResponse。
type LoginResponse = RegisterResponse

// RotatePubkeyEmailStartPayload 是密钥轮换邮箱验证发起请求的 SignedRequest.Payload。
//
// 外层 SignedRequest 必须由当前仍有效的旧私钥签名，防止仅凭邮箱验证码发起轮换。
type RotatePubkeyEmailStartPayload struct {
	Username string `json:"username"`
}

// RotatePubkeyEmailStartResponse 返回密钥轮换邮箱验证码挑战。
type RotatePubkeyEmailStartResponse struct {
	ChallengeID     string `json:"challenge_id"`
	Delivery        string `json:"delivery"`
	ExpiresIn       int    `json:"expires_in"`
	CooldownSeconds int    `json:"cooldown_seconds"`
}

// RotatePubkeyPayload 是密钥轮换请求 SignedRequest.Payload 的 JSON 内容。
//
// 外层 SignedRequest 必须由当前仍有效的旧私钥签名；payload 中提交新公钥和邮箱验证码。
type RotatePubkeyPayload struct {
	Username         string `json:"username"`
	EmailChallengeID string `json:"email_challenge_id"`
	EmailCode        string `json:"email_code"`
	NewPubkeyHex     string `json:"new_pubkey_hex"`
}

// RotatePubkeyResponse 返回轮换后的新公钥信息。
type RotatePubkeyResponse struct {
	UserID               uint64 `json:"user_id"`
	Username             string `json:"username"`
	Tier                 string `json:"tier"`
	OldPubkeyHash        string `json:"old_pubkey_hash"`
	NewPubkeyHash        string `json:"new_pubkey_hash"`
	EffectiveAt          int64  `json:"effective_at"`
	RevokedPreviousCount int64  `json:"revoked_previous_count"`
}

// ========== §5.2 故事恢复登录 ==========

// RecoveryCandidatesRequest 是子体请求恢复期目标公钥哈希集合的请求。
//
// 注意：此请求 **不签名**——子体此时尚未持有私钥。
// 服务端按 IP / username 限频防暴力。
type RecoveryCandidatesRequest struct {
	Username string `json:"username"`
}

// RecoveryCandidatesResponse 返回该用户名下所有未撤销公钥的哈希。
//
// 子体把 PubkeyHashes 注入本地恢复算法的"目标集合"。
type RecoveryCandidatesResponse struct {
	Username        string   `json:"username"`
	PubkeyHashes    []string `json:"pubkey_hashes"`
	ServerSignature string   `json:"server_signature"` // 服务端 root 私钥签名整个响应（防中间人）
}

// RecoveryRFAStartRequest 开始第二阶段恢复邮箱验证。
type RecoveryRFAStartRequest struct {
	Username string `json:"username"`
}

// RecoveryRFAStartResponse 返回挑战 ID 和脱敏投递地址。
type RecoveryRFAStartResponse struct {
	ChallengeID     string `json:"challenge_id"`
	Delivery        string `json:"delivery"`
	ExpiresIn       int    `json:"expires_in"`
	CooldownSeconds int    `json:"cooldown_seconds"`
}

// RecoveryRFAVerifyRequest 校验邮箱验证码。
type RecoveryRFAVerifyRequest struct {
	ChallengeID string `json:"challenge_id"`
	Code        string `json:"code"`
}

// RecoveryRFAVerifyResponse 返回短期恢复授权。
//
// RecoveryGrant 只授权客户端进入更宽矩阵的深度恢复，不是登录态。
type RecoveryRFAVerifyResponse struct {
	RecoveryGrant          string `json:"recovery_grant"`
	ExpiresIn              int    `json:"expires_in"`
	MaxCandidatesPerColumn int    `json:"max_candidates_per_column"`
}

// ========== §6 ECDH 密钥协商 ==========

// HandshakePayload 是 ECDH 协商请求 SignedRequest.Payload 的 JSON 内容。
type HandshakePayload struct {
	// EphemeralPubkey 是子体生成的临时 ECDH 公钥（65 字节非压缩 hex）。
	EphemeralPubkey string `json:"ephemeral_pubkey"`
}

// HandshakeResponse 是协商成功后服务端返回的短期通信通道信息。
type HandshakeResponse struct {
	ChannelID       string   `json:"channel_id"`
	EphemeralPubkey string   `json:"ephemeral_pubkey"` // 服务端的临时公钥
	IdleExpiresIn   int      `json:"idle_expires_in"`  // 通道空闲有效期秒数
	AllowedModels   []string `json:"allowed_models"`
}

// ========== §6.2 加密消息包装 ==========

// EncryptedEnvelope 包装所有协商后的加密消息（请求和响应都用）。
type EncryptedEnvelope struct {
	ChannelID  string `json:"channel_id"`
	Nonce      string `json:"nonce"`      // 12 字节随机 hex
	Ciphertext string `json:"ciphertext"` // AES-256-GCM 密文 hex
	Tag        string `json:"tag"`        // 16 字节认证 tag hex
}

// ========== §6.3 LLM Chat plaintext ==========

// ChatRequest 是解密后的 LLM 调用 plaintext。
type ChatRequest struct {
	Model    string                   `json:"model"`
	Messages []map[string]interface{} `json:"messages"` // 透传上游格式
	Stream   bool                     `json:"stream"`
	Tools    []map[string]interface{} `json:"tools,omitempty"`
	// 其他参数透传
	Extra map[string]interface{} `json:"extra,omitempty"`
}

// ========== §10 错误响应 ==========

// ErrorResponse 是所有非 2xx 响应的统一错误体。
type ErrorResponse struct {
	Error      string `json:"error"`
	Message    string `json:"message,omitempty"`
	RetryAfter int    `json:"retry_after,omitempty"`
}

// 错误码常量（与 protocol-spec.md §10 对齐）
const (
	ErrInvalidSignature          = "invalid_signature"
	ErrTimestampExpired          = "timestamp_expired"
	ErrNonceReplayed             = "nonce_replayed"
	ErrPubkeyNotFound            = "pubkey_not_found"
	ErrUserDisabled              = "user_disabled"
	ErrUserNotFound              = "user_not_found"
	ErrUsernameTaken             = "username_taken"
	ErrModelNotAllowed           = "model_not_allowed"
	ErrRateLimitExceeded         = "rate_limit_exceeded"
	ErrChannelExpired            = "channel_expired"
	ErrInvalidChannel            = "invalid_channel"
	ErrRFANotAvailable           = "rfa_not_available"
	ErrEmailNotConfigured        = "email_not_configured"
	ErrEmailNotBound             = "email_not_bound"
	ErrEmailVerificationRequired = "email_verification_required"
	ErrRFAChallengeNotFound      = "rfa_challenge_not_found"
	ErrRFACodeInvalid            = "rfa_code_invalid"
	ErrRFACodeExpired            = "rfa_code_expired"
	ErrDecryptionFailed          = "decryption_failed"
	ErrInvalidPayload            = "invalid_payload"
	ErrInternalError             = "internal_error"
	ErrGatewaySyncFailed         = "gateway_sync_failed"
	ErrAdminRequired             = "admin_required"
)

// ========== auth-gateway 内部跨服务调用 ==========

// VerifySignatureRequest 是 ai-gateway 调 auth-gateway 的内部请求：
// "帮我验证这个签名是否有效，并告诉我对应的 user_id 和 tier"。
// UserID 可选；传入时表示本次验签期望的认证中心用户 ID，必须与公钥实际归属一致。
type VerifySignatureRequest struct {
	UserID       uint64 `json:"user_id,omitempty"`
	PubkeyHex    string `json:"pubkey_hex"`
	SignatureHex string `json:"signature_hex"`
	Payload      string `json:"payload"`
	Timestamp    int64  `json:"timestamp"`
	Nonce        string `json:"nonce"`
}

// VerifySignatureResponse 返回验签结果。
type VerifySignatureResponse struct {
	Valid      bool   `json:"valid"`
	UserID     uint64 `json:"user_id,omitempty"`
	Username   string `json:"username,omitempty"`
	Tier       string `json:"tier,omitempty"`
	PubkeyHash string `json:"pubkey_hash,omitempty"`
	Error      string `json:"error,omitempty"`
}

// VerifyChallengeSignatureRequest 是 ai-gateway 登录码 / 协议登录专用内部请求：
// 用 user_id 找到该用户未撤销公钥，验证客户端对 challenge 字符串的签名。
type VerifyChallengeSignatureRequest struct {
	UserID       uint64 `json:"user_id"`
	Challenge    string `json:"challenge"`
	SignatureHex string `json:"signature_hex"`
}

// PubkeyBindingCheck 是认证中心对外提供的"用户 ID + 公钥哈希"绑定校验项。
type PubkeyBindingCheck struct {
	UserID     uint64 `json:"user_id"`
	PubkeyHash string `json:"pubkey_hash"`
}

// VerifyPubkeysRequest 支持批量校验公钥哈希是否属于指定用户。
type VerifyPubkeysRequest struct {
	Items []PubkeyBindingCheck `json:"items"`
}

// VerifyPubkeysResponse 在全部命中时只需要 OK=true；未命中项单独返回。
type VerifyPubkeysResponse struct {
	OK      bool                 `json:"ok"`
	Missing []PubkeyBindingCheck `json:"missing,omitempty"`
}

// PubkeyBindingAtCheck 校验某个签名时间点上的 user_id + pubkey_hash 绑定。
//
// SignedAt 是签名发生时的 Unix 秒时间戳。认证中心按公钥 created_at / revoked_at
// 判断该时间点是否处于公钥有效期内。
type PubkeyBindingAtCheck struct {
	UserID     uint64 `json:"user_id"`
	PubkeyHash string `json:"pubkey_hash"`
	SignedAt   int64  `json:"signed_at"`
}

// VerifyPubkeysAtRequest 支持历史公钥有效性批量查询，预留给经验网络。
type VerifyPubkeysAtRequest struct {
	Items []PubkeyBindingAtCheck `json:"items"`
}

// VerifyPubkeysAtResponse 在全部命中时只需要 OK=true；未命中项单独返回。
type VerifyPubkeysAtResponse struct {
	OK      bool                   `json:"ok"`
	Missing []PubkeyBindingAtCheck `json:"missing,omitempty"`
}

// ========== 管理后台 API ==========

// AdminUserListResponse 列出系统所有用户（分页）。
type AdminUserListResponse struct {
	Total int         `json:"total"`
	Page  int         `json:"page"`
	Items []AdminUser `json:"items"`
}

type AdminUser struct {
	ID        uint64        `json:"id"`
	Username  string        `json:"username"`
	Nickname  string        `json:"nickname"`
	Email     string        `json:"email,omitempty"`
	Tier      string        `json:"tier"`
	Role      string        `json:"role"`
	Disabled  bool          `json:"disabled"`
	CreatedAt string        `json:"created_at"`
	Pubkeys   []AdminPubkey `json:"pubkeys"`
}

type AdminPubkey struct {
	ID         uint64  `json:"id"`
	PubkeyHash string  `json:"pubkey_hash"`
	PubkeyHex  string  `json:"pubkey_hex,omitempty"`
	CreatedAt  string  `json:"created_at"`
	RevokedAt  *string `json:"revoked_at,omitempty"`
}

// AdminUpdateUserRequest 管理员修改用户 tier / disable。
type AdminUpdateUserRequest struct {
	Tier     *string `json:"tier,omitempty"`
	Disabled *bool   `json:"disabled,omitempty"`
	Email    *string `json:"email,omitempty"`
	Role     *string `json:"role,omitempty"`
}

type AdminSessionUser struct {
	ID       uint64 `json:"id"`
	Username string `json:"username"`
	Nickname string `json:"nickname"`
	Role     string `json:"role"`
}

type AdminLoginResponse struct {
	Token     string           `json:"token"`
	ExpiresAt int64            `json:"expires_at"`
	User      AdminSessionUser `json:"user"`
}

type AdminSMTPConfig struct {
	Enabled     bool   `json:"enabled"`
	Host        string `json:"host"`
	Port        int    `json:"port"`
	Username    string `json:"username"`
	From        string `json:"from"`
	TLSMode     string `json:"tls_mode"`
	PasswordSet bool   `json:"password_set"`
}

type AdminUpdateSMTPConfigRequest struct {
	Enabled  *bool   `json:"enabled,omitempty"`
	Host     *string `json:"host,omitempty"`
	Port     *int    `json:"port,omitempty"`
	Username *string `json:"username,omitempty"`
	Password *string `json:"password,omitempty"`
	From     *string `json:"from,omitempty"`
	TLSMode  *string `json:"tls_mode,omitempty"`
}

type AdminTestSMTPRequest struct {
	To string `json:"to"`
}

type AdminLogListResponse struct {
	Total int        `json:"total"`
	Page  int        `json:"page"`
	Items []AdminLog `json:"items"`
}

type AdminLog struct {
	ID            uint64 `json:"id"`
	ActorID       uint64 `json:"actor_id"`
	ActorUsername string `json:"actor_username"`
	ActorRole     string `json:"actor_role"`
	Action        string `json:"action"`
	Target        string `json:"target"`
	Detail        string `json:"detail,omitempty"`
	CreatedAt     string `json:"created_at"`
}

// LLM 上游配置（旧 Go 版 ai-gateway 原型管理后台用）
type LLMUpstream struct {
	ID        uint64 `json:"id"`
	Name      string `json:"name"` // openai / anthropic / dashscope ...
	BaseURL   string `json:"base_url"`
	APIKey    string `json:"api_key,omitempty"` // 列表展示时不返回
	Format    string `json:"format"`            // openai / anthropic
	Enabled   bool   `json:"enabled"`
	CreatedAt string `json:"created_at"`
}

// ModelMapping 把 "对外 model 名" 映射到 "上游 ID + 上游 model 名"
type ModelMapping struct {
	ID           uint64 `json:"id"`
	PublicName   string `json:"public_name"` // 对子体暴露的名字
	UpstreamID   uint64 `json:"upstream_id"`
	UpstreamName string `json:"upstream_name"`
	MinTier      string `json:"min_tier"` // 最低 tier 才能用，free/pro/enterprise
	Enabled      bool   `json:"enabled"`
}
