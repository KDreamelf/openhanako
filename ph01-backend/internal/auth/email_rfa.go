package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"mime"
	"net"
	"net/mail"
	"net/smtp"
	"strconv"
	"strings"
	"time"

	"github.com/hanako/ph01-backend/internal/user"
	"github.com/hanako/ph01-backend/pkg/api"
	"github.com/redis/go-redis/v9"
)

var (
	ErrRFANotAvailable      = errors.New(api.ErrRFANotAvailable)
	ErrEmailNotConfigured   = errors.New(api.ErrEmailNotConfigured)
	ErrEmailNotBound        = errors.New(api.ErrEmailNotBound)
	ErrEmailCooldown        = errors.New(api.ErrRateLimitExceeded)
	ErrRFAChallengeNotFound = errors.New(api.ErrRFAChallengeNotFound)
	ErrRFACodeInvalid       = errors.New(api.ErrRFACodeInvalid)
	ErrRFACodeExpired       = errors.New(api.ErrRFACodeExpired)
)

const (
	defaultEmailSendCooldown = 60 * time.Second

	rfaPurposeRegistration   = "registration"
	rfaPurposeRecovery       = "recovery"
	rfaPurposePubkeyRotation = "pubkey_rotation"
)

// EmailSender 发送验证码。生产实现是 SMTP，测试可用内存 fake。
type EmailSender interface {
	Send(ctx context.Context, to, subject, body string) error
}

// EmailMessage 是支持 HTML + 纯文本 fallback 的邮件内容。
type EmailMessage struct {
	Subject  string
	TextBody string
	HTMLBody string
}

type richEmailSender interface {
	SendEmail(ctx context.Context, to string, msg EmailMessage) error
}

// RFAStore 保存邮箱二验挑战和短期恢复授权。
type RFAStore interface {
	SaveChallenge(ctx context.Context, ch *RFAChallenge, ttl time.Duration) error
	GetChallenge(ctx context.Context, id string) (*RFAChallenge, error)
	DeleteChallenge(ctx context.Context, id string) error
	SaveGrant(ctx context.Context, grant *RecoveryGrant, ttl time.Duration) error
	GetGrant(ctx context.Context, token string) (*RecoveryGrant, error)
	ReserveCooldown(ctx context.Context, key string, ttl time.Duration) (time.Duration, bool, error)
	ClearCooldown(ctx context.Context, key string) error
}

// RFAChallenge 是邮箱验证码挑战。CodeHash = SHA256(salt + ":" + code)。
type RFAChallenge struct {
	ID        string    `json:"id"`
	Purpose   string    `json:"purpose,omitempty"`
	UserID    uint64    `json:"user_id"`
	Username  string    `json:"username"`
	Email     string    `json:"email"`
	CodeHash  string    `json:"code_hash"`
	Salt      string    `json:"salt"`
	Attempts  int       `json:"attempts"`
	ExpiresAt time.Time `json:"expires_at"`
}

// RecoveryGrant 只授权深度恢复扩大 K，不是登录态。
type RecoveryGrant struct {
	Token                  string    `json:"token"`
	UserID                 uint64    `json:"user_id"`
	Username               string    `json:"username"`
	MaxCandidatesPerColumn int       `json:"max_candidates_per_column"`
	ExpiresAt              time.Time `json:"expires_at"`
}

// RFAService 管理邮箱二验流程。
type RFAService struct {
	UserStore *user.Store
	Store     RFAStore
	Sender    EmailSender

	ChallengeTTL           time.Duration
	GrantTTL               time.Duration
	SendCooldown           time.Duration
	MaxAttempts            int
	MaxCandidatesPerColumn int
}

func NewRFAService(userStore *user.Store, store RFAStore, sender EmailSender) *RFAService {
	return &RFAService{
		UserStore:              userStore,
		Store:                  store,
		Sender:                 sender,
		ChallengeTTL:           10 * time.Minute,
		GrantTTL:               30 * time.Minute,
		SendCooldown:           defaultEmailSendCooldown,
		MaxAttempts:            5,
		MaxCandidatesPerColumn: 4,
	}
}

func (s *RFAService) available() bool {
	return s != nil && s.UserStore != nil && s.Store != nil && s.Sender != nil
}

func (s *RFAService) Start(ctx context.Context, username string) (*api.RecoveryRFAStartResponse, error) {
	if !s.available() {
		return nil, ErrRFANotAvailable
	}
	username = strings.TrimSpace(username)
	if username == "" {
		return nil, errors.New(api.ErrInvalidPayload)
	}
	u, err := s.UserStore.GetByUsername(username)
	if err != nil {
		return nil, err
	}

	return s.startEmailChallenge(ctx, u, rfaPurposeRecovery, verificationEmailRecovery)
}

func (s *RFAService) StartPubkeyRotation(ctx context.Context, u *user.User) (*api.RotatePubkeyEmailStartResponse, error) {
	resp, err := s.startEmailChallenge(ctx, u, rfaPurposePubkeyRotation, verificationEmailRotation)
	if err != nil {
		return nil, err
	}
	return &api.RotatePubkeyEmailStartResponse{
		ChallengeID:     resp.ChallengeID,
		Delivery:        resp.Delivery,
		ExpiresIn:       resp.ExpiresIn,
		CooldownSeconds: resp.CooldownSeconds,
	}, nil
}

func (s *RFAService) Verify(ctx context.Context, challengeID, code string) (*api.RecoveryRFAVerifyResponse, error) {
	if !s.available() {
		return nil, ErrRFANotAvailable
	}
	now := time.Now().UTC()
	ch, err := s.verifyEmailChallenge(ctx, challengeID, code, rfaPurposeRecovery, 0, "")
	if err != nil {
		return nil, err
	}
	token, err := randomToken(32)
	if err != nil {
		return nil, err
	}
	grant := &RecoveryGrant{
		Token:                  token,
		UserID:                 ch.UserID,
		Username:               ch.Username,
		MaxCandidatesPerColumn: s.MaxCandidatesPerColumn,
		ExpiresAt:              now.Add(s.GrantTTL),
	}
	if err := s.Store.SaveGrant(ctx, grant, s.GrantTTL); err != nil {
		return nil, err
	}
	return &api.RecoveryRFAVerifyResponse{
		RecoveryGrant:          token,
		ExpiresIn:              int(s.GrantTTL.Seconds()),
		MaxCandidatesPerColumn: s.MaxCandidatesPerColumn,
	}, nil
}

func (s *RFAService) VerifyPubkeyRotation(ctx context.Context, challengeID, code string, userID uint64, username string) error {
	if !s.available() {
		return ErrRFANotAvailable
	}
	_, err := s.verifyEmailChallenge(ctx, challengeID, code, rfaPurposePubkeyRotation, userID, username)
	return err
}

func (s *RFAService) startEmailChallenge(ctx context.Context, u *user.User, purpose string, kind verificationEmailKind) (*api.RecoveryRFAStartResponse, error) {
	if !s.available() {
		return nil, ErrRFANotAvailable
	}
	if u == nil || strings.TrimSpace(u.Username) == "" {
		return nil, errors.New(api.ErrInvalidPayload)
	}
	if u.Disabled {
		return nil, errors.New(api.ErrUserDisabled)
	}
	email := strings.TrimSpace(u.Email)
	if email == "" {
		return nil, ErrEmailNotBound
	}
	if _, err := mail.ParseAddress(email); err != nil {
		return nil, ErrEmailNotBound
	}
	cooldownSeconds := durationSeconds(s.SendCooldown)
	releaseCooldown, err := reserveEmailSendCooldown(ctx, s.Store, purpose, email, s.SendCooldown)
	if err != nil {
		return nil, err
	}
	releaseCooldownOnFailure := releaseCooldown != nil
	defer func() {
		if releaseCooldownOnFailure {
			_ = releaseCooldown(ctx)
		}
	}()

	code, err := randomNumericCode(6)
	if err != nil {
		return nil, err
	}
	salt, err := randomToken(16)
	if err != nil {
		return nil, err
	}
	challengeID, err := randomToken(18)
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	ch := &RFAChallenge{
		ID:        challengeID,
		Purpose:   purpose,
		UserID:    u.ID,
		Username:  u.Username,
		Email:     email,
		CodeHash:  hashRFACode(salt, code),
		Salt:      salt,
		ExpiresAt: now.Add(s.ChallengeTTL),
	}
	if err := s.Store.SaveChallenge(ctx, ch, s.ChallengeTTL); err != nil {
		return nil, err
	}

	msg := buildVerificationEmailMessage(kind, code, s.ChallengeTTL)
	if err := sendEmailMessage(ctx, s.Sender, email, msg); err != nil {
		_ = s.Store.DeleteChallenge(ctx, challengeID)
		return nil, err
	}
	releaseCooldownOnFailure = false

	return &api.RecoveryRFAStartResponse{
		ChallengeID:     challengeID,
		Delivery:        maskEmail(email),
		ExpiresIn:       int(s.ChallengeTTL.Seconds()),
		CooldownSeconds: cooldownSeconds,
	}, nil
}

func (s *RFAService) verifyEmailChallenge(ctx context.Context, challengeID, code, purpose string, userID uint64, username string) (*RFAChallenge, error) {
	challengeID = strings.TrimSpace(challengeID)
	code = strings.TrimSpace(code)
	username = strings.TrimSpace(username)
	if challengeID == "" || code == "" {
		return nil, errors.New(api.ErrInvalidPayload)
	}

	ch, err := s.Store.GetChallenge(ctx, challengeID)
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	if now.After(ch.ExpiresAt) {
		_ = s.Store.DeleteChallenge(ctx, challengeID)
		return nil, ErrRFACodeExpired
	}
	if ch.Attempts >= s.MaxAttempts {
		_ = s.Store.DeleteChallenge(ctx, challengeID)
		return nil, ErrRFAChallengeNotFound
	}
	if !challengePurposeMatches(ch.Purpose, purpose) {
		return nil, ErrRFAChallengeNotFound
	}
	if userID != 0 && ch.UserID != userID {
		return nil, errors.New(api.ErrEmailVerificationRequired)
	}
	if username != "" && !strings.EqualFold(ch.Username, username) {
		return nil, errors.New(api.ErrEmailVerificationRequired)
	}

	gotHash := hashRFACode(ch.Salt, code)
	if subtle.ConstantTimeCompare([]byte(gotHash), []byte(ch.CodeHash)) != 1 {
		ch.Attempts++
		if ch.Attempts >= s.MaxAttempts {
			_ = s.Store.DeleteChallenge(ctx, challengeID)
		} else {
			_ = s.Store.SaveChallenge(ctx, ch, time.Until(ch.ExpiresAt))
		}
		return nil, ErrRFACodeInvalid
	}

	_ = s.Store.DeleteChallenge(ctx, challengeID)
	return ch, nil
}

func challengePurposeMatches(actual, want string) bool {
	actual = strings.TrimSpace(actual)
	want = strings.TrimSpace(want)
	if actual == want {
		return true
	}
	// 老版本挑战没有 purpose 字段。只兼容注册/恢复，轮换必须显式带 purpose。
	return actual == "" && (want == rfaPurposeRegistration || want == rfaPurposeRecovery)
}

func hashRFACode(salt, code string) string {
	sum := sha256.Sum256([]byte(salt + ":" + code))
	return hex.EncodeToString(sum[:])
}

func randomNumericCode(digits int) (string, error) {
	if digits <= 0 {
		digits = 6
	}
	max := big.NewInt(1)
	for i := 0; i < digits; i++ {
		max.Mul(max, big.NewInt(10))
	}
	n, err := rand.Int(rand.Reader, max)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%0"+strconv.Itoa(digits)+"d", n.Int64()), nil
}

func randomToken(n int) (string, error) {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

func maskEmail(email string) string {
	parts := strings.Split(email, "@")
	if len(parts) != 2 {
		return "***"
	}
	local := []rune(parts[0])
	domain := parts[1]
	switch len(local) {
	case 0:
		return "***@" + domain
	case 1:
		return string(local[0]) + "***@" + domain
	case 2:
		return string(local[0]) + "***" + string(local[1]) + "@" + domain
	default:
		return string(local[0]) + "***" + string(local[len(local)-1]) + "@" + domain
	}
}

func sendEmailMessage(ctx context.Context, sender EmailSender, to string, msg EmailMessage) error {
	if rich, ok := sender.(richEmailSender); ok {
		return rich.SendEmail(ctx, to, msg)
	}
	return sender.Send(ctx, to, msg.Subject, msg.TextBody)
}

type EmailCooldownError struct {
	RetryAfter time.Duration
}

func (e *EmailCooldownError) Error() string {
	return api.ErrRateLimitExceeded
}

func (e *EmailCooldownError) Is(target error) bool {
	return target == ErrEmailCooldown
}

func emailCooldownRetryAfterSeconds(err error) int {
	var cooldownErr *EmailCooldownError
	if !errors.As(err, &cooldownErr) {
		return 0
	}
	return durationSeconds(cooldownErr.RetryAfter)
}

func reserveEmailSendCooldown(ctx context.Context, store RFAStore, purpose, email string, cooldown time.Duration) (func(context.Context) error, error) {
	if cooldown <= 0 {
		return nil, nil
	}
	key := emailCooldownKey(purpose, email)
	retryAfter, reserved, err := store.ReserveCooldown(ctx, key, cooldown)
	if err != nil {
		return nil, err
	}
	if !reserved {
		if retryAfter <= 0 {
			retryAfter = cooldown
		}
		return nil, &EmailCooldownError{RetryAfter: retryAfter}
	}
	return func(ctx context.Context) error {
		return store.ClearCooldown(ctx, key)
	}, nil
}

func emailCooldownKey(purpose, email string) string {
	purpose = strings.ToLower(strings.TrimSpace(purpose))
	email = strings.ToLower(strings.TrimSpace(email))
	sum := sha256.Sum256([]byte(purpose + "\n" + email))
	return purpose + ":" + hex.EncodeToString(sum[:])
}

func durationSeconds(d time.Duration) int {
	if d <= 0 {
		return 0
	}
	return int((d + time.Second - 1) / time.Second)
}

// RedisRFAStore 用 Redis 保存短期挑战和恢复授权。
type RedisRFAStore struct {
	Client *redis.Client
	Prefix string
}

func NewRedisRFAStore(c *redis.Client) *RedisRFAStore {
	return &RedisRFAStore{Client: c, Prefix: "rfa"}
}

func NewRedisRFAStoreWithPrefix(c *redis.Client, prefix string) *RedisRFAStore {
	prefix = strings.TrimSpace(prefix)
	if prefix == "" {
		prefix = "rfa"
	}
	return &RedisRFAStore{Client: c, Prefix: prefix}
}

func (s *RedisRFAStore) SaveChallenge(ctx context.Context, ch *RFAChallenge, ttl time.Duration) error {
	b, err := json.Marshal(ch)
	if err != nil {
		return err
	}
	return s.Client.Set(ctx, s.challengeKey(ch.ID), b, ttl).Err()
}

func (s *RedisRFAStore) GetChallenge(ctx context.Context, id string) (*RFAChallenge, error) {
	raw, err := s.Client.Get(ctx, s.challengeKey(id)).Bytes()
	if err != nil {
		if errors.Is(err, redis.Nil) {
			return nil, ErrRFAChallengeNotFound
		}
		return nil, err
	}
	var ch RFAChallenge
	if err := json.Unmarshal(raw, &ch); err != nil {
		return nil, err
	}
	return &ch, nil
}

func (s *RedisRFAStore) DeleteChallenge(ctx context.Context, id string) error {
	return s.Client.Del(ctx, s.challengeKey(id)).Err()
}

func (s *RedisRFAStore) SaveGrant(ctx context.Context, grant *RecoveryGrant, ttl time.Duration) error {
	b, err := json.Marshal(grant)
	if err != nil {
		return err
	}
	return s.Client.Set(ctx, s.grantKey(grant.Token), b, ttl).Err()
}

func (s *RedisRFAStore) GetGrant(ctx context.Context, token string) (*RecoveryGrant, error) {
	raw, err := s.Client.Get(ctx, s.grantKey(token)).Bytes()
	if err != nil {
		if errors.Is(err, redis.Nil) {
			return nil, ErrRFAChallengeNotFound
		}
		return nil, err
	}
	var grant RecoveryGrant
	if err := json.Unmarshal(raw, &grant); err != nil {
		return nil, err
	}
	if time.Now().UTC().After(grant.ExpiresAt) {
		return nil, ErrRFAChallengeNotFound
	}
	return &grant, nil
}

func (s *RedisRFAStore) ReserveCooldown(ctx context.Context, key string, ttl time.Duration) (time.Duration, bool, error) {
	cooldownKey := s.cooldownKey(key)
	ok, err := s.Client.SetNX(ctx, cooldownKey, "1", ttl).Result()
	if err != nil {
		return 0, false, err
	}
	if ok {
		return 0, true, nil
	}
	retryAfter, err := s.Client.TTL(ctx, cooldownKey).Result()
	if err != nil {
		return 0, false, err
	}
	if retryAfter <= 0 {
		retryAfter = ttl
	}
	return retryAfter, false, nil
}

func (s *RedisRFAStore) ClearCooldown(ctx context.Context, key string) error {
	return s.Client.Del(ctx, s.cooldownKey(key)).Err()
}

func (s *RedisRFAStore) challengeKey(id string) string {
	return s.Prefix + ":challenge:" + id
}

func (s *RedisRFAStore) grantKey(token string) string {
	return s.Prefix + ":grant:" + token
}

func (s *RedisRFAStore) cooldownKey(key string) string {
	return s.Prefix + ":cooldown:" + key
}

// SMTPConfig 是注册与恢复验证码邮件发送配置。
type SMTPConfig struct {
	Host     string
	Port     int
	Username string
	Password string
	From     string
	TLSMode  string
}

type SMTPSender struct {
	Config SMTPConfig
}

func NewSMTPSender(cfg SMTPConfig) (*SMTPSender, error) {
	cfg.Host = strings.TrimSpace(cfg.Host)
	cfg.From = strings.TrimSpace(cfg.From)
	cfg.TLSMode = strings.ToLower(strings.TrimSpace(cfg.TLSMode))
	if cfg.Host == "" || cfg.From == "" {
		return nil, ErrEmailNotConfigured
	}
	if cfg.TLSMode == "" || cfg.TLSMode == "starttls" {
		cfg.TLSMode = "require_starttls"
	}
	if cfg.Port == 0 {
		if cfg.TLSMode == "tls" {
			cfg.Port = 465
		} else {
			cfg.Port = 587
		}
	}
	switch cfg.TLSMode {
	case "tls":
		if cfg.Port != 465 {
			return nil, errors.New("smtp tls mode must use port 465")
		}
	case "require_starttls":
		if cfg.Port != 587 {
			return nil, errors.New("smtp require_starttls mode must use port 587")
		}
	default:
		return nil, fmt.Errorf("unsupported smtp tls_mode: %s", cfg.TLSMode)
	}
	return &SMTPSender{Config: cfg}, nil
}

func (s *SMTPSender) Send(ctx context.Context, to, subject, body string) error {
	return s.SendEmail(ctx, to, EmailMessage{
		Subject:  subject,
		TextBody: body,
	})
}

func (s *SMTPSender) SendEmail(ctx context.Context, to string, msg EmailMessage) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
	}
	cfg := s.Config
	toAddr, err := mail.ParseAddress(to)
	if err != nil {
		return err
	}
	fromAddr, err := mail.ParseAddress(cfg.From)
	if err != nil {
		return err
	}
	addr := net.JoinHostPort(cfg.Host, strconv.Itoa(cfg.Port))
	client, err := s.smtpClient(addr)
	if err != nil {
		return err
	}
	defer client.Close()

	if err := s.upgradeTLS(client); err != nil {
		return err
	}
	if cfg.Username != "" || cfg.Password != "" {
		auth := smtp.PlainAuth("", cfg.Username, cfg.Password, cfg.Host)
		if err := client.Auth(auth); err != nil {
			return err
		}
	}
	if err := client.Mail(fromAddr.Address); err != nil {
		return err
	}
	if err := client.Rcpt(toAddr.Address); err != nil {
		return err
	}
	w, err := client.Data()
	if err != nil {
		return err
	}
	if _, err := w.Write(buildEmailMessage(fromAddr.String(), toAddr.String(), msg)); err != nil {
		_ = w.Close()
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	return client.Quit()
}

func (s *SMTPSender) smtpClient(addr string) (*smtp.Client, error) {
	cfg := s.Config
	if strings.EqualFold(cfg.TLSMode, "tls") {
		conn, err := tls.DialWithDialer(&net.Dialer{Timeout: 10 * time.Second}, "tcp", addr, &tls.Config{
			ServerName: cfg.Host,
			MinVersion: tls.VersionTLS12,
		})
		if err != nil {
			return nil, err
		}
		return smtp.NewClient(conn, cfg.Host)
	}
	conn, err := net.DialTimeout("tcp", addr, 10*time.Second)
	if err != nil {
		return nil, err
	}
	return smtp.NewClient(conn, cfg.Host)
}

func (s *SMTPSender) upgradeTLS(client *smtp.Client) error {
	mode := strings.ToLower(strings.TrimSpace(s.Config.TLSMode))
	switch mode {
	case "", "require_starttls":
		ok, _ := client.Extension("STARTTLS")
		if ok {
			return client.StartTLS(&tls.Config{
				ServerName: s.Config.Host,
				MinVersion: tls.VersionTLS12,
			})
		}
		return errors.New("smtp server does not support STARTTLS")
	case "tls":
		return nil
	default:
		return fmt.Errorf("unsupported smtp tls_mode: %s", s.Config.TLSMode)
	}
}

func buildEmailMessage(from, to string, msg EmailMessage) []byte {
	var b strings.Builder
	headers := map[string]string{
		"From":         from,
		"To":           to,
		"Subject":      mime.QEncoding.Encode("utf-8", msg.Subject),
		"Date":         time.Now().UTC().Format(time.RFC1123Z),
		"MIME-Version": "1.0",
	}
	if strings.TrimSpace(msg.HTMLBody) == "" {
		headers["Content-Type"] = "text/plain; charset=UTF-8"
		order := []string{"From", "To", "Subject", "Date", "MIME-Version", "Content-Type"}
		for _, k := range order {
			b.WriteString(k)
			b.WriteString(": ")
			b.WriteString(headers[k])
			b.WriteString("\r\n")
		}
		b.WriteString("\r\n")
		b.WriteString(msg.TextBody)
		if !strings.HasSuffix(msg.TextBody, "\n") {
			b.WriteString("\r\n")
		}
		return []byte(b.String())
	}

	boundary := "ph01-" + strconv.FormatInt(time.Now().UnixNano(), 36)
	headers["Content-Type"] = `multipart/alternative; boundary="` + boundary + `"`
	order := []string{"From", "To", "Subject", "Date", "MIME-Version", "Content-Type"}
	for _, k := range order {
		b.WriteString(k)
		b.WriteString(": ")
		b.WriteString(headers[k])
		b.WriteString("\r\n")
	}
	b.WriteString("\r\n")
	writeEmailPart(&b, boundary, "text/plain; charset=UTF-8", msg.TextBody)
	writeEmailPart(&b, boundary, "text/html; charset=UTF-8", msg.HTMLBody)
	b.WriteString("--")
	b.WriteString(boundary)
	b.WriteString("--\r\n")
	return []byte(b.String())
}

func writeEmailPart(b *strings.Builder, boundary, contentType, body string) {
	b.WriteString("--")
	b.WriteString(boundary)
	b.WriteString("\r\n")
	b.WriteString("Content-Type: ")
	b.WriteString(contentType)
	b.WriteString("\r\n")
	b.WriteString("Content-Transfer-Encoding: 8bit\r\n\r\n")
	b.WriteString(body)
	if !strings.HasSuffix(body, "\n") {
		b.WriteString("\r\n")
	}
}
