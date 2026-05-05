package system

import (
	"context"

	"github.com/hanako/ph01-backend/internal/auth"
)

type DynamicSMTPSender struct {
	Store *Store
}

func NewDynamicSMTPSender(store *Store) *DynamicSMTPSender {
	return &DynamicSMTPSender{Store: store}
}

func (s *DynamicSMTPSender) Send(ctx context.Context, to, subject, body string) error {
	return s.SendEmail(ctx, to, auth.EmailMessage{
		Subject:  subject,
		TextBody: body,
	})
}

func (s *DynamicSMTPSender) SendEmail(ctx context.Context, to string, msg auth.EmailMessage) error {
	if s == nil || s.Store == nil {
		return auth.ErrEmailNotConfigured
	}
	settings, err := s.Store.GetSMTPSettings()
	if err != nil {
		return err
	}
	if !settings.Enabled {
		return auth.ErrEmailNotConfigured
	}
	sender, err := auth.NewSMTPSender(auth.SMTPConfig{
		Host:     settings.Host,
		Port:     settings.Port,
		Username: settings.Username,
		Password: settings.Password,
		From:     settings.From,
		TLSMode:  settings.TLSMode,
	})
	if err != nil {
		return err
	}
	return sender.SendEmail(ctx, to, msg)
}
