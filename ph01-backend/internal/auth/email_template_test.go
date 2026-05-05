package auth

import (
	"strings"
	"testing"
	"time"
)

func TestBuildVerificationEmailMessageIncludesHTMLFallback(t *testing.T) {
	msg := buildVerificationEmailMessage(verificationEmailRegister, "123456", 10*time.Minute)

	if msg.Subject != "PH01 注册验证码" {
		t.Fatalf("subject = %q", msg.Subject)
	}
	for _, want := range []string{"123456", "phantasm 01", "幻宙01"} {
		if !strings.Contains(msg.TextBody, want) {
			t.Fatalf("text body missing %q", want)
		}
		if !strings.Contains(msg.HTMLBody, want) {
			t.Fatalf("html body missing %q", want)
		}
	}

	raw := string(buildEmailMessage("PH01 <noreply@example.com>", "user@example.com", msg))
	for _, want := range []string{
		"multipart/alternative",
		"text/plain; charset=UTF-8",
		"text/html; charset=UTF-8",
		"Content-Transfer-Encoding: 8bit",
		"PH01 注册验证码",
	} {
		if !strings.Contains(raw, want) {
			t.Fatalf("raw email missing %q\n%s", want, raw)
		}
	}
}

func TestNewSMTPSenderTLSModes(t *testing.T) {
	startTLS, err := NewSMTPSender(SMTPConfig{
		Host:    "smtp.example.com",
		Port:    587,
		From:    "PH01 <noreply@example.com>",
		TLSMode: "require_starttls",
	})
	if err != nil {
		t.Fatalf("require_starttls sender: %v", err)
	}
	if startTLS.Config.Port != 587 || startTLS.Config.TLSMode != "require_starttls" {
		t.Fatalf("unexpected starttls config: %+v", startTLS.Config)
	}

	ssl, err := NewSMTPSender(SMTPConfig{
		Host:    "smtp.example.com",
		Port:    465,
		From:    "PH01 <noreply@example.com>",
		TLSMode: "tls",
	})
	if err != nil {
		t.Fatalf("tls sender: %v", err)
	}
	if ssl.Config.Port != 465 || ssl.Config.TLSMode != "tls" {
		t.Fatalf("unexpected ssl config: %+v", ssl.Config)
	}

	alias, err := NewSMTPSender(SMTPConfig{
		Host:    "smtp.example.com",
		Port:    587,
		From:    "PH01 <noreply@example.com>",
		TLSMode: "starttls",
	})
	if err != nil {
		t.Fatalf("starttls alias sender: %v", err)
	}
	if alias.Config.TLSMode != "require_starttls" {
		t.Fatalf("expected starttls alias to normalize to require_starttls, got %q", alias.Config.TLSMode)
	}

	if _, err := NewSMTPSender(SMTPConfig{
		Host:    "smtp.example.com",
		Port:    25,
		From:    "PH01 <noreply@example.com>",
		TLSMode: "plain",
	}); err == nil {
		t.Fatal("expected plain smtp to be rejected")
	}
	if _, err := NewSMTPSender(SMTPConfig{
		Host:    "smtp.example.com",
		Port:    25,
		From:    "PH01 <noreply@example.com>",
		TLSMode: "require_starttls",
	}); err == nil {
		t.Fatal("expected require_starttls on non-587 port to be rejected")
	}
	if _, err := NewSMTPSender(SMTPConfig{
		Host:    "smtp.example.com",
		Port:    587,
		From:    "PH01 <noreply@example.com>",
		TLSMode: "tls",
	}); err == nil {
		t.Fatal("expected tls on non-465 port to be rejected")
	}
}
