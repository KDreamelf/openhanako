import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/desktop_setup.dart';
import 'app/ipc_registry.dart';
import 'app/providers.dart';
import 'core/engine.dart';
import 'ui/browser/browser_window.dart';
import 'ui/chat_page.dart';
import 'ui/editor/editor_window.dart';
import 'ui/settings/settings_window.dart';
import 'ui/themes/themes.dart';

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

  IpcRegistry(engine).install();
  await DesktopSetup.installTray();
  await DesktopSetup.installHotkeys(
    onQuickSwitchModel: () {
      // TODO Phase 3.5: 弹出模型切换 picker
    },
  );

  // 主题模式从 SharedPreferences 读取（设置窗口写入）。
  final sp = await SharedPreferences.getInstance();
  final themeMode = switch (sp.getString('hanako.theme.mode') ?? 'system') {
    'light' => AppThemeMode.light,
    'dark' => AppThemeMode.dark,
    _ => AppThemeMode.system,
  };

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
}

class HanakoApp extends ConsumerWidget {
  const HanakoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'Hanako',
      debugShowCheckedModeBanner: false,
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
        title: 'Hanako Sub Window',
        debugShowCheckedModeBanner: false,
        theme: HanakoThemes.warmPaper(),
        darkTheme: HanakoThemes.dark(),
        themeMode: ThemeMode.system,
        home: switch (route) {
          'settings' => const SettingsWindow(),
          'editor' => EditorWindow(filePath: args['filePath'] as String? ?? ''),
          'browser' => BrowserWindow(url: args['url'] as String? ?? ''),
          _ => Scaffold(body: Center(child: Text('Unknown route: $route'))),
        },
      ),
    );
  }
}

class _FatalErrorApp extends StatelessWidget {
  const _FatalErrorApp({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hanako · Fatal',
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
