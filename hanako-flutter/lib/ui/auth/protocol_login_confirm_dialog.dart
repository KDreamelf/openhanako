import 'package:flutter/material.dart';

import '../../app/protocol_login_service.dart';

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
    final theme = Theme.of(context);
    final color = theme.colorScheme;
    final detail = request.detail;
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.security),
          SizedBox(width: 10),
          Text('AI 网关授权确认'),
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
                '网页正在请求使用你的 PH01 身份登录 AI 网关。',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              if (!trustedCallback) ...[
                _WarningBox(
                  icon: Icons.gpp_bad_outlined,
                  color: color.error,
                  title: '已阻止不受信任的回调地址',
                  message: '此请求不会被授权。请确认你是从官方 AI 网关页面发起登录。',
                ),
                const SizedBox(height: 16),
              ],
              _InfoRow(label: '本机账号', value: accountLabel),
              _InfoRow(label: '请求站点', value: request.callbackOrigin),
              _InfoRow(
                label: '请求 IP',
                value: detail.ip.isEmpty ? '?' : detail.ip,
              ),
              _InfoRow(
                label: 'IP 归属',
                value: detail.ipLocation.isEmpty
                    ? 'unknown'
                    : detail.ipLocation,
              ),
              _InfoRow(
                label: '浏览器',
                value: detail.userAgent.isEmpty ? '?' : detail.userAgent,
              ),
              _InfoRow(label: '过期时间', value: _formatTime(detail.expiresAtTime)),
              _InfoRow(label: '挑战 ID', value: detail.challengeId),
              const SizedBox(height: 10),
              SelectableText(
                request.callbackUrl,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: color.onSurfaceVariant,
                  fontFamily: 'monospace',
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
          onPressed: trustedCallback
              ? () => Navigator.of(context).pop(true)
              : null,
          icon: const Icon(Icons.check),
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
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty ? '-' : value,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _WarningBox extends StatelessWidget {
  const _WarningBox({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withAlpha(24),
        border: Border.all(color: color.withAlpha(90)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(color: color, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(message),
              ],
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
