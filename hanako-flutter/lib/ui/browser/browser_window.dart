import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design/design.dart';

/// 内嵌浏览器子窗口。
/// Windows / macOS：用 desktop_webview_window 拉起原生 WebView2 / WKWebView。
/// Linux：WebKit GTK 行为差异较大，降级到外部浏览器（用 url_launcher 打开）。
///
/// 注意：webview 需要在 main() 之前调用 [WebviewWindow.isWebviewAvailable] 检测；
/// 这里在构建时检测并自动选择路径。
class BrowserWindow extends StatefulWidget {
  const BrowserWindow({super.key, required this.url});
  final String url;

  @override
  State<BrowserWindow> createState() => _BrowserWindowState();
}

class _BrowserWindowState extends State<BrowserWindow> {
  late final TextEditingController _urlCtrl;
  bool? _available;
  String _currentUrl = '';
  bool _launching = false;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.url;
    _urlCtrl = TextEditingController(text: _currentUrl);
    _detect();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _detect() async {
    try {
      final ok = await WebviewWindow.isWebviewAvailable();
      if (!mounted) return;
      setState(() => _available = ok);
    } catch (_) {
      if (!mounted) return;
      setState(() => _available = false);
    }
  }

  Future<void> _launchInline() async {
    if (_launching) return;
    setState(() => _launching = true);
    try {
      final webview = await WebviewWindow.create(
        configuration: CreateConfiguration(
          windowHeight: 720,
          windowWidth: 1100,
          title: '幻宙01 · 浏览器',
          titleBarHeight: 30,
        ),
      );
      if (!mounted) return;
      webview
        ..setBrightness(Theme.of(context).brightness)
        ..launch(_currentUrl);
    } finally {
      if (mounted) setState(() => _launching = false);
    }
  }

  Future<void> _launchExternal() async {
    final uri = Uri.parse(_currentUrl);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AmbientBackground(
        child: Column(
          children: [
            Container(
              decoration: BoxDecoration(
                color:
                    palette.bgRaised.withValues(alpha: palette.isDark ? 0.70 : 0.86),
                border: Border(
                  bottom: BorderSide(color: palette.divider, width: DS.hairline),
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    DS.s16,
                    DS.s12,
                    DS.s16,
                    DS.s12,
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          GlassIconButton(
                            icon: Icons.arrow_back_rounded,
                            tooltip: '关闭',
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                          const SizedBox(width: DS.s12),
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: palette.accentCyan.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(DS.r8),
                              border: Border.all(
                                color:
                                    palette.accentCyan.withValues(alpha: 0.36),
                              ),
                            ),
                            child: Icon(
                              Icons.public_rounded,
                              size: 18,
                              color: palette.accentCyan,
                            ),
                          ),
                          const SizedBox(width: DS.s10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '浏览器',
                                  style: TextStyle(
                                    color: palette.textPrimary,
                                    fontSize: DS.t18,
                                    fontWeight: FontWeight.w700,
                                    height: 1.15,
                                  ),
                                ),
                                Text(
                                  _available == null
                                      ? '检测 WebView 中…'
                                      : _available!
                                          ? 'WebView 可用 · 内嵌打开'
                                          : '当前平台不支持 WebView · 走外部浏览器',
                                  style: TextStyle(
                                    color: palette.textSecondary,
                                    fontSize: DS.t12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: DS.s10),
                      Row(
                        children: [
                          Expanded(
                            child: _AddressBar(
                              controller: _urlCtrl,
                              onSubmit: (v) =>
                                  setState(() => _currentUrl = v.trim()),
                            ),
                          ),
                          const SizedBox(width: DS.s10),
                          GlassButton(
                            icon: _available == true
                                ? Icons.open_in_browser_rounded
                                : Icons.open_in_new_rounded,
                            label: _available == true ? '内嵌打开' : '外部打开',
                            onPressed: _available == true && !_launching
                                ? _launchInline
                                : _launchExternal,
                            accent: palette.accentEmerald,
                            filled: true,
                            height: 40,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 540),
                  child: Padding(
                    padding: const EdgeInsets.all(DS.s40),
                    child: GlassSurface(
                      padding: const EdgeInsets.all(DS.s24),
                      radius: DS.r14,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  palette.accentCyan.withValues(alpha: 0.36),
                                  palette.accentLavender.withValues(alpha: 0.24),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(DS.r16),
                              border: Border.all(
                                color: palette.accentCyan.withValues(alpha: 0.45),
                              ),
                            ),
                            child: Icon(
                              _available == true
                                  ? Icons.travel_explore_rounded
                                  : Icons.open_in_new_rounded,
                              size: 28,
                              color: palette.accentCyan,
                            ),
                          ),
                          const SizedBox(height: DS.s14),
                          Text(
                            _available == null
                                ? '正在检测…'
                                : _available!
                                    ? '点击右上 · 启动浏览窗'
                                    : '使用系统默认浏览器',
                            style: TextStyle(
                              color: palette.textPrimary,
                              fontSize: DS.t18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _available == null
                                ? '正在询问系统 WebView 能力…'
                                : _available!
                                    ? '内嵌 WebView 已就绪，可以原地打开网页。'
                                    : '当前平台没有内嵌 WebView，会用系统浏览器打开链接。',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: palette.textSecondary,
                              fontSize: DS.t13,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: DS.s16),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: DS.s12,
                              vertical: DS.s10,
                            ),
                            decoration: BoxDecoration(
                              color: palette.bgDeep.withValues(
                                alpha: palette.isDark ? 0.5 : 0.4,
                              ),
                              borderRadius: BorderRadius.circular(DS.r8),
                              border: Border.all(color: palette.divider),
                            ),
                            child: SelectableText(
                              _currentUrl.isEmpty ? '(empty)' : _currentUrl,
                              style: TextStyle(
                                color: palette.textPrimary,
                                fontFamilyFallback: DS.monoFallback,
                                fontSize: DS.t12,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddressBar extends StatefulWidget {
  const _AddressBar({required this.controller, required this.onSubmit});

  final TextEditingController controller;
  final ValueChanged<String> onSubmit;

  @override
  State<_AddressBar> createState() => _AddressBarState();
}

class _AddressBarState extends State<_AddressBar> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Focus(
      onFocusChange: (v) => setState(() => _focused = v),
      child: FocusScope(
        onFocusChange: (v) => setState(() => _focused = v),
        child: AnimatedContainer(
          duration: DS.dQuick,
          decoration: BoxDecoration(
            color: palette.bgDeep.withValues(alpha: palette.isDark ? 0.6 : 0.40),
            borderRadius: BorderRadius.circular(DS.r10),
            border: Border.all(
              color: _focused
                  ? palette.accentCyan.withValues(alpha: 0.55)
                  : palette.divider,
              width: _focused ? 1.4 : DS.hairline,
            ),
          ),
          child: TextField(
            controller: widget.controller,
            decoration: InputDecoration(
              prefixIcon: Icon(
                Icons.public_rounded,
                size: 16,
                color: palette.textTertiary,
              ),
              hintText: 'https://...',
              hintStyle: TextStyle(color: palette.textTertiary),
              isDense: true,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(vertical: DS.s10, horizontal: 0),
            ),
            cursorColor: palette.accentCyan,
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: DS.t13,
              fontFamilyFallback: DS.monoFallback,
            ),
            onSubmitted: widget.onSubmit,
          ),
        ),
      ),
    );
  }
}
