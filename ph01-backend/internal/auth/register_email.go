package auth

import (
	"context"
	"crypto/subtle"
	"errors"
	"strings"
	"time"

	"github.com/hanako/ph01-backend/internal/user"
	"github.com/hanako/ph01-backend/pkg/api"
	"gorm.io/gorm"
)

// RegistrationEmailService 管理新账号注册前的邮箱验证码。
type RegistrationEmailService struct {
	UserStore *user.Store
	Store     RFAStore
	Sender    EmailSender

	ChallengeTTL time.Duration
	MaxAttempts  int
}

func NewRegistrationEmailService(userStore *user.Store, store RFAStore, sender EmailSender) *RegistrationEmailService {
	return &RegistrationEmailService{
		UserStore:    userStore,
		Store:        store,
		Sender:       sender,
		ChallengeTTL: 10 * time.Minute,
		MaxAttempts:  5,
	}
}

func (s *RegistrationEmailService) available() bool {
	return s != nil && s.UserStore != nil && s.Store != nil && s.Sender != nil
}

func (s *RegistrationEmailService) Start(ctx context.Context, username, email string) (*api.RegistrationEmailStartResponse, error) {
	if !s.available() {
		return nil, ErrEmailNotConfigured
	}
	username = strings.TrimSpace(username)
	if username == "" || len(username) > 32 {
		return nil, errors.New(api.ErrInvalidPayload)
	}
	email, err := normalizeEmailRequired(email)
	if err != nil {
		return nil, err
	}
	if existing, err := s.UserStore.GetByUsername(username); err == nil && existing != nil {
		return nil, errors.New(api.ErrUsernameTaken)
	} else if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, err
	}

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
		Username:  username,
		Email:     email,
		CodeHash:  hashRFACode(salt, code),
		Salt:      salt,
		ExpiresAt: now.Add(s.ChallengeTTL),
	}
	if err := s.Store.SaveChallenge(ctx, ch, s.ChallengeTTL); err != nil {
		return nil, err
	}

	msg := buildVerificationEmailMessage(verificationEmailRegister, code, s.ChallengeTTL)
	if err := sendEmailMessage(ctx, s.Sender, email, msg); err != nil {
		_ = s.Store.DeleteChallenge(ctx, challengeID)
		return nil, err
	}
	return &api.RegistrationEmailStartResponse{
		ChallengeID: challengeID,
		Delivery:    maskEmail(email),
		ExpiresIn:   int(s.ChallengeTTL.Seconds()),
	}, nil
}

func (s *RegistrationEmailService) Verify(ctx context.Context, challengeID, username, email, code string) error {
	if !s.available() {
		return ErrEmailNotConfigured
	}
	challengeID = strings.TrimSpace(challengeID)
	username = strings.TrimSpace(username)
	code = strings.TrimSpace(code)
	email, err := normalizeEmailRequired(email)
	if err != nil {
		return err
	}
	if challengeID == "" || username == "" || code == "" {
		return errors.New(api.ErrEmailVerificationRequired)
	}

	ch, err := s.Store.GetChallenge(ctx, challengeID)
	if err != nil {
		return err
	}
	now := time.Now().UTC()
	if now.After(ch.ExpiresAt) {
		_ = s.Store.DeleteChallenge(ctx, challengeID)
		return ErrRFACodeExpired
	}
	if ch.Attempts >= s.MaxAttempts {
		_ = s.Store.DeleteChallenge(ctx, challengeID)
		return ErrRFAChallengeNotFound
	}
	if !strings.EqualFold(ch.Username, username) || !strings.EqualFold(ch.Email, email) {
		return errors.New(api.ErrEmailVerificationRequired)
	}

	gotHash := hashRFACode(ch.Salt, code)
	if subtle.ConstantTimeCompare([]byte(gotHash), []byte(ch.CodeHash)) != 1 {
		ch.Attempts++
		if ch.Attempts >= s.MaxAttempts {
			_ = s.Store.DeleteChallenge(ctx, challengeID)
		} else {
			_ = s.Store.SaveChallenge(ctx, ch, time.Until(ch.ExpiresAt))
		}
		return ErrRFACodeInvalid
	}
	return s.Store.DeleteChallenge(ctx, challengeID)
}
