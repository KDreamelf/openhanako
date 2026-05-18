import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:windows_single_instance/windows_single_instance.dart';

import 'app/desktop_setup.dart';
import 'app/ipc_registry.dart';
import 'app/protocol_login_service.dart';
import 'app/providers.dart';
import 'app/window_factory.dart';
import 'app/windows_title_bar.dart';
import 'core/engine.dart';
import 'ui/auth/protocol_login_confirm_dialog.dart';
import 'ui/browser/browser_window.dart';
import 'ui/chat_page.dart';
import 'ui/editor/editor_window.dart';
import 'ui/themes/themes.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
ProtocolLoginService? _protocolLoginService;
final List<String> _pendingProtocolUrls = [];

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 子窗口入口（desktop_multi_window 派生进程）
  if (args.firstOrNull == 'multi_window') {
    DartPluginRegistrant.ensureInitialized();
    final raw = args.length >= 3 ? args[2] : '{}';
    final wargs = raw.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
    runApp(_SubWindowApp(args: wargs));
    return;
  }

  final initialProtocolUrls = ProtocolLoginService.urlsFromArgs(args);
  if (Platform.isWindows) {
    await WindowsSingleInstance.ensureSingleInstance(
      args,
      'phantasm_01',
      onSecondWindow: _handleSecondInstanceArgs,
    );
  }

  // 主窗口
  await DesktopSetup.initWindow();

  HanaEngine engine;
  try {
    engine = await HanaEngine.initialize();
  } catch (e, st) {
    // ignore: avoid_print
    print('[engine init failed] $e\n$st');
    runApp(_FatalErrorApp(message: '$e'));
    return;
  }

  _protocolLoginService = ProtocolLoginService(
    engine,
    messengerKey: rootScaffoldMessengerKey,
    onIdentityChanged: _notifyIdentityChanged,
    authorizationConfirmer: _confirmProtocolLoginAuthorization,
  );
  IpcRegistry(engine).install();
  await DesktopSetup.installTray(
    onOpenSettings: () async {
      final context = rootNavigatorKey.currentContext;
      if (context == null) return;
      await WindowFactory.openSettings(context);
    },
  );
  await DesktopSetup.installHotkeys(
    onQuickSwitchModel: () {
      // TODO Phase 3.5: 弹出模型切换 picker
    },
  );
  if (args.contains('--ph01-smoke-quit')) {
    await DesktopSetup.quitApp();
    return;
  }
  engine.startAutomation();

  // 主题模式从 SharedPreferences 读取（设置窗口写入）。
  final sp = await SharedPreferences.getInstance();
  final themeMode = switch (sp.getString('hanako.theme.mode') ?? 'system') {
    'light' => AppThemeMode.light,
    'dark' => AppThemeMode.dark,
    _ => AppThemeMode.system,
  };

  // 在 Flutter build 之前先同步 Windows 标题栏的明暗，
  // 这样启动时不会出现"短暂浅色按钮在浅色背景看不清"的闪烁。
  final initialBrightnessDark = switch (themeMode) {
    AppThemeMode.dark => true,
    AppThemeMode.light => false,
    AppThemeMode.system =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness ==
          Brightness.dark,
  };
  applyWindowsTitleBarBrightness(initialBrightnessDark);

  runApp(
    ProviderScope(
      overrides: [
        engineProvider.overrideWithValue(engine),
        identityRepositoryProvider.overrideWithValue(engine.identityRepository),
        themeModeProvider.overrideWith((_) => themeMode),
      ],
      child: const HanakoApp(),
    ),
  );

  WidgetsBinding.instance.addPostFrameCallback((_) {
    final urls = <String>[...initialProtocolUrls, ..._pendingProtocolUrls];
    _pendingProtocolUrls.clear();
    if (urls.isNotEmpty) {
      unawaited(_protocolLoginService?.handleUrls(urls));
    }
  });
}

void _handleSecondInstanceArgs(List<String> args) {
  unawaited(DesktopSetup.showMainWindow());
  final urls = ProtocolLoginService.urlsFromArgs(args);
  if (urls.isEmpty) return;
  final service = _protocolLoginService;
  if (service == null) {
    _pendingProtocolUrls.addAll(urls);
    return;
  }
  unawaited(service.handleUrls(urls));
}

void _notifyIdentityChanged() {
  final context = rootNavigatorKey.currentContext;
  if (context == null) return;
  final container = ProviderScope.containerOf(context, listen: false);
  final notifier = container.read(identityRevisionProvider.notifier);
  notifier.state++;
}

Future<bool> _confirmProtocolLoginAuthorization(
  ProtocolLoginRequest request,
) async {
  await DesktopSetup.showMainWindow();
  final context = rootNavigatorKey.currentContext;
  if (context == null || !context.mounted) return false;
  final container = ProviderScope.containerOf(context, listen: false);
  final eng = container.read(engineProvider);
  final cfg = eng.config.read();
  final auth = cfg['auth'] is Map ? cfg['auth'] as Map : const {};
  final user = cfg['user'] is Map ? cfg['user'] as Map : const {};
  final username = _stringValue(auth['username']) ?? _stringValue(user['name']);
  final userId = _stringValue(auth['user_id']);
  final accountParts = <String>[];
  if (username != null) accountParts.add(username);
  if (userId != null) accountParts.add('ID $userId');
  final accountLabel = accountParts.join(' · ');
  final approved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ProtocolLoginConfirmDialog(
      request: request,
      trustedCallback: request.isTrustedCallback(
        aiBaseUrl: eng.backendClient.aiBaseUrl,
        authBaseUrl: eng.backendClient.authBaseUrl,
      ),
      accountLabel: accountLabel.isEmpty ? '本机 PH01 身份' : accountLabel,
    ),
  );
  return approved ?? false;
}

String? _stringValue(Object? value) {
  if (value is! String && value is! num) return null;
  final text = '$value'.trim();
  return text.isEmpty ? null : text;
}

class HanakoApp extends ConsumerWidget {
  const HanakoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final systemDark =
        MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final effectiveDark = switch (mode) {
      AppThemeMode.dark => true,
      AppThemeMode.light => false,
      AppThemeMode.system => systemDark,
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      applyWindowsTitleBarBrightness(effectiveDark);
    });
    return MaterialApp(
      title: '幻宙01',
      debugShowCheckedModeBanner: false,
      navigatorKey: rootNavigatorKey,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      theme: HanakoThemes.warmPaper(),
      darkTheme: HanakoThemes.dark(),
      themeMode: switch (mode) {
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
        AppThemeMode.system => ThemeMode.system,
      },
      home: const ChatPage(),
    );
  }
}

class _SubWindowApp extends StatelessWidget {
  const _SubWindowApp({required this.args});
  final Map<String, dynamic> args;

  @override
  Widget build(BuildContext context) {
    final route = args['route'] as String? ?? 'main';
    return ProviderScope(
      child: MaterialApp(
        title: '幻宙01 子窗口',
        debugShowCheckedModeBanner: false,
        theme: HanakoThemes.warmPaper(),
        darkTheme: HanakoThemes.dark(),
        themeMode: ThemeMode.system,
        home: switch (route) {
          'settings' => _UnsupportedSubWindow(route: route),
          'editor' => EditorWindow(filePath: args['filePath'] as String? ?? ''),
          'browser' => BrowserWindow(url: args['url'] as String? ?? ''),
          _ => Scaffold(body: Center(child: Text('Unknown route: $route'))),
        },
      ),
    );
  }
}

class _UnsupportedSubWindow extends StatelessWidget {
  const _UnsupportedSubWindow({required this.route});

  final String route;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(child: Text('Unsupported sub window route: $route')),
    );
  }
}

class _FatalErrorApp extends StatelessWidget {
  const _FatalErrorApp({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '幻宙01 · Fatal',
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(40),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 56, color: Colors.red),
                const SizedBox(height: 16),
                const Text(
                  'Engine 初始化失败',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
