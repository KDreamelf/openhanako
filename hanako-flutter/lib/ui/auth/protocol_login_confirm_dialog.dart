import 'package:flutter/material.dart';

import '../../app/protocol_login_service.dart';
import '../design/design.dart';

class ProtocolLoginConfirmDialog extends StatelessWidget {
  const ProtocolLoginConfirmDialog({
    super.key,
    required this.request,
    required this.trustedCallback,
    required this.accountLabel,
  });

  final ProtocolLoginRequest request;
  final bool trustedCallback;
  final String accountLabel;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final detail = request.detail;
    final serviceLabel = detail.serviceLabel;
    return AlertDialog(
      title: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  palette.accentEmerald.withValues(alpha: 0.28),
                  palette.accentCyan.withValues(alpha: 0.20),
                ],
              ),
              borderRadius: BorderRadius.circular(DS.r8),
              border: Border.all(
                color: palette.accentEmerald.withValues(alpha: 0.40),
              ),
            ),
            child: Icon(
              Icons.shield_outlined,
              size: 16,
              color: palette.accentEmerald,
            ),
          ),
          const SizedBox(width: DS.s10),
          const Text('PH01 授权确认'),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '网页正在请求使用你的 PH01 身份登录$serviceLabel。',
                style: TextStyle(color: palette.textPrimary, height: 1.5),
              ),
              const SizedBox(height: DS.s14),
              if (!trustedCallback) ...[
                HanaBanner(
                  icon: Icons.gpp_bad_outlined,
                  leadingLabel: 'BLOCKED',
                  title: '已阻止不受信任的回调地址',
                  subtitle: '此请求不会被授权。请确认你是从可信页面发起登录。',
                  color: palette.accentCrimson,
                ),
                const SizedBox(height: DS.s14),
              ],
              _InfoRow(label: '本机账号', value: accountLabel),
              _InfoRow(label: '登录目标', value: serviceLabel),
              _InfoRow(label: '请求站点', value: request.callbackOrigin),
              _InfoRow(
                label: '请求 IP',
                value: detail.ip.isEmpty ? '?' : detail.ip,
              ),
              _InfoRow(
                label: 'IP 归属',
                value:
                    detail.ipLocation.isEmpty ? 'unknown' : detail.ipLocation,
              ),
              _InfoRow(
                label: '浏览器',
                value: detail.userAgent.isEmpty ? '?' : detail.userAgent,
              ),
              _InfoRow(label: '过期时间', value: _formatTime(detail.expiresAtTime)),
              _InfoRow(label: '挑战 ID', value: detail.challengeId),
              const SizedBox(height: DS.s10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: DS.s10,
                  vertical: DS.s8,
                ),
                decoration: BoxDecoration(
                  color:
                      palette.bgDeep.withValues(alpha: palette.isDark ? 0.6 : 0.4),
                  borderRadius: BorderRadius.circular(DS.r6),
                  border: Border.all(color: palette.divider),
                ),
                child: SelectableText(
                  request.callbackUrl,
                  style: TextStyle(
                    color: palette.textSecondary,
                    fontFamilyFallback: DS.monoFallback,
                    fontSize: DS.t11,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('拒绝'),
        ),
        FilledButton.icon(
          onPressed:
              trustedCallback ? () => Navigator.of(context).pop(true) : null,
          icon: const Icon(Icons.check_rounded, size: 16),
          label: const Text('授权登录'),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                color: palette.textTertiary,
                fontSize: DS.t12,
                letterSpacing: 0.3,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty ? '-' : value,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: DS.t13,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatTime(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}
