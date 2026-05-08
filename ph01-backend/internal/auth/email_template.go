package auth

import (
	"fmt"
	"strings"
	"time"
)

type verificationEmailKind string

const (
	verificationEmailRegister verificationEmailKind = "register"
	verificationEmailRecovery verificationEmailKind = "recovery"
	verificationEmailRotation verificationEmailKind = "rotation"
)

func buildVerificationEmailMessage(kind verificationEmailKind, code string, ttl time.Duration) EmailMessage {
	minutes := int(ttl.Minutes())
	if minutes <= 0 {
		minutes = 10
	}
	title := "PH01 身份验证码"
	action := "完成身份验证"
	switch kind {
	case verificationEmailRegister:
		title = "PH01 注册验证码"
		action = "完成新账号注册"
	case verificationEmailRecovery:
		title = "PH01 恢复验证码"
		action = "继续账号恢复"
	case verificationEmailRotation:
		title = "PH01 密钥轮换验证码"
		action = "确认密钥轮换"
	}

	text := fmt.Sprintf(`%s

验证码：%s

该验证码 %d 分钟内有效，用于%s。若不是你本人操作，请忽略这封邮件，不要转发验证码。

phantasm 01 / 幻宙01`, title, code, minutes, action)

	html := verificationEmailHTML(title, action, code, minutes)
	return EmailMessage{
		Subject:  title,
		TextBody: text,
		HTMLBody: html,
	}
}

func verificationEmailHTML(title, action, code string, minutes int) string {
	codeCells := strings.Builder{}
	for _, r := range code {
		codeCells.WriteString(`<span style="display:inline-block;min-width:34px;margin:0 3px;padding:10px 0;border-radius:8px;background:#ffffff;border:1px solid #b8d8ff;color:#0b63ce;font-family:'SFMono-Regular','Consolas','Liberation Mono',monospace;font-size:25px;font-weight:700;line-height:1;text-align:center;">`)
		codeCells.WriteRune(r)
		codeCells.WriteString(`</span>`)
	}

	return fmt.Sprintf(`<!doctype html>
<html lang="zh-CN">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>%s</title>
  </head>
  <body style="margin:0;padding:0;background:#eef6ff;color:#102033;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI','Microsoft YaHei',sans-serif;">
    <table role="presentation" width="100%%" cellspacing="0" cellpadding="0" style="width:100%%;background:#eef6ff;padding:28px 12px;">
      <tr>
        <td align="center">
          <table role="presentation" width="100%%" cellspacing="0" cellpadding="0" style="width:100%%;max-width:560px;background:#ffffff;border:1px solid #d6e8ff;border-radius:12px;overflow:hidden;box-shadow:0 18px 42px rgba(19,82,160,0.13);">
            <tr>
              <td style="padding:0;background:#061936;">
                <table role="presentation" width="100%%" cellspacing="0" cellpadding="0">
                  <tr>
                    <td style="padding:26px 30px 22px;">
                      <div style="font-size:13px;line-height:1.4;color:#89c7ff;font-weight:600;">phantasm 01 · 幻宙01</div>
                      <h1 style="margin:8px 0 0;color:#f6fbff;font-size:25px;line-height:1.25;font-weight:700;">%s</h1>
                    </td>
                    <td width="112" align="right" style="padding:18px 22px 18px 0;">
                      <div style="width:76px;height:76px;border-radius:50%%;border:1px solid rgba(130,202,255,0.55);background:#0d2f63;">
                        <div style="width:42px;height:42px;margin:16px auto 0;border-radius:50%%;border:1px solid #68bfff;"></div>
                        <div style="width:54px;height:1px;margin:-22px auto 0;background:#68bfff;"></div>
                        <div style="width:1px;height:54px;margin:-27px auto 0;background:#68bfff;"></div>
                      </div>
                    </td>
                  </tr>
                </table>
              </td>
            </tr>
            <tr>
              <td style="padding:30px;">
                <p style="margin:0;color:#35506f;font-size:15px;line-height:1.7;">你正在%s。请在子体客户端中输入下面的验证码。</p>
                <div style="margin:24px 0 20px;padding:20px;border-radius:12px;background:#edf6ff;border:1px solid #cfe5ff;text-align:center;">
                  <div style="margin-bottom:12px;color:#426180;font-size:13px;line-height:1.4;">验证码</div>
                  <div aria-label="%s" style="white-space:nowrap;">%s</div>
                </div>
                <table role="presentation" width="100%%" cellspacing="0" cellpadding="0" style="margin:0 0 22px;">
                  <tr>
                    <td style="padding:13px 14px;border-radius:9px;background:#f7fbff;border:1px solid #e0efff;color:#426180;font-size:13px;line-height:1.6;">
                      该验证码 %d 分钟内有效。认证中心不会向你索要验证码、助记词或私钥。
                    </td>
                  </tr>
                </table>
                <p style="margin:0;color:#6a7d94;font-size:13px;line-height:1.7;">若不是你本人操作，可以直接忽略这封邮件。</p>
              </td>
            </tr>
            <tr>
              <td style="padding:16px 30px 22px;background:#f8fbff;border-top:1px solid #e2efff;color:#7890aa;font-size:12px;line-height:1.6;">
                PH01 身份系统只使用公钥确认账号，私钥始终保留在你的设备中。
              </td>
            </tr>
          </table>
        </td>
      </tr>
    </table>
  </body>
</html>`, title, title, action, code, codeCells.String(), minutes)
}
