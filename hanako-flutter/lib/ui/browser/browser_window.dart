import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

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
  bool? _available;
  String _currentUrl = '';
  bool _launching = false;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.url;
    _detect();
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
          title: 'Hanako · Browser',
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
    final urlCtrl = TextEditingController(text: _currentUrl);

    return Scaffold(
      appBar: AppBar(
        title: const Text('浏览器'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: urlCtrl,
                    decoration: InputDecoration(
                      hintText: 'https://...',
                      isDense: true,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6)),
                      prefixIcon: const Icon(Icons.public, size: 18),
                    ),
                    onSubmitted: (v) {
                      setState(() => _currentUrl = v.trim());
                    },
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _available == true && !_launching
                      ? _launchInline
                      : _launchExternal,
                  icon: Icon(_available == true
                      ? Icons.open_in_browser
                      : Icons.open_in_new),
                  label: Text(_available == true ? '内嵌打开' : '外部打开'),
                ),
              ],
            ),
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _available == true ? Icons.public : Icons.open_in_new,
                  size: 56,
                ),
                const SizedBox(height: 12),
                Text(
                  _available == null
                      ? '检测中…'
                      : _available!
                          ? '内嵌 WebView 可用，点击右上"内嵌打开"启动浏览窗。'
                          : '当前平台 WebView 不可用，将用系统默认浏览器打开。',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                SelectableText(
                  _currentUrl,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
