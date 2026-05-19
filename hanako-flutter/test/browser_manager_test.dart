import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/core/browser_manager.dart';
import 'package:hanako/core/preferences_manager.dart';
import 'package:hanako/local_tools/local_tools.dart';
import 'package:hanako/shared/hana_home.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late HanaHome home;
  late BrowserManager browser;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hanako_browser_');
    home = HanaHome.debugFromDirectory(tmp);
    browser = BrowserManager(preferences: PreferencesManager(home));
  });

  tearDown(() async {
    await browser.stop();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('Browser 工具能打开页面、读取标题和关闭状态', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType.html
        ..write(
          '<html><head><title>测试页面</title></head>'
          '<body><h1>Hello Browser</h1><p>正文内容</p></body></html>',
        )
        ..close();
    });

    final url = 'http://${server.address.host}:${server.port}/';
    final raw = await LocalToolRegistry.execute(LocalToolNames.browser, {
      'action': 'navigate',
      'url': url,
    }, browserManager: browser);
    final body = jsonDecode(raw) as Map<String, dynamic>;

    expect(body['ok'], true);
    expect(body['title'], '测试页面');

    final statusRaw = await LocalToolRegistry.execute(LocalToolNames.browser, {
      'action': 'status',
    }, browserManager: browser);
    final status = jsonDecode(statusRaw) as Map<String, dynamic>;
    expect(status['running'], true);
    expect(status['realBrowser'], false);
    expect(status['mode'], 'static');
    expect(status['url'], url);

    final snapshotRaw = await LocalToolRegistry.execute(
      LocalToolNames.browser,
      {'action': 'snapshot'},
      browserManager: browser,
    );
    final snapshot = jsonDecode(snapshotRaw) as Map<String, dynamic>;
    expect(snapshot['ok'], true);
    expect(snapshot['message'], contains('正文内容'));

    final stopRaw = await LocalToolRegistry.execute(LocalToolNames.browser, {
      'action': 'stop',
    }, browserManager: browser);
    final stopped = jsonDecode(stopRaw) as Map<String, dynamic>;
    expect(stopped['ok'], true);
    expect(stopped['running'], false);
  });

  test('Browser 权限关闭后返回中文错误', () async {
    browser.setEnabled(false);

    final raw = await LocalToolRegistry.execute(LocalToolNames.browser, {
      'action': 'navigate',
      'url': 'https://example.com',
    }, browserManager: browser);
    final body = jsonDecode(raw) as Map<String, dynamic>;

    expect(body['ok'], false);
    expect(body['error'], 'browser_disabled');
    expect(body['message'], contains('浏览器工具已在设置中关闭'));
  });

  test('Camoufox 配置文件损坏时不退回静态模式', () async {
    final appDir = Directory(p.join(tmp.path, 'app'))
      ..createSync(recursive: true);
    final browserDir = Directory(p.join(appDir.path, 'browser'))..createSync();
    File(p.join(browserDir.path, 'config.json')).writeAsStringSync('{bad json');
    browser = BrowserManager(
      preferences: PreferencesManager(home),
      appDir: appDir.path,
    );

    final raw = await LocalToolRegistry.execute(LocalToolNames.browser, {
      'action': 'navigate',
      'url': 'https://example.com/page',
    }, browserManager: browser);
    final body = jsonDecode(raw) as Map<String, dynamic>;

    expect(body['ok'], false);
    expect(body['error'], 'browser_failed');
    expect(body['message'], contains('Camoufox 配置文件无效'));
    expect(body['status']['mode'], 'stopped');
  });

  test('web_search 在 Camoufox 启动失败时返回明确不可用错误', () async {
    final appDir = Directory(p.join(tmp.path, 'app'))
      ..createSync(recursive: true);
    final browserDir = Directory(p.join(appDir.path, 'browser'))..createSync();
    final bridge = _writeFakeBridge(browserDir);
    File(p.join(browserDir.path, 'config.json')).writeAsStringSync(
      jsonEncode({
        'venvPython': p.join(browserDir.path, 'missing-python.exe'),
        'bridgeScript': bridge.path,
        'browserExecutable': p.join(browserDir.path, 'camoufox.exe'),
      }),
    );
    File(p.join(browserDir.path, 'camoufox.exe')).writeAsStringSync('fake');
    browser = BrowserManager(
      preferences: PreferencesManager(home),
      appDir: appDir.path,
    );

    final raw = await LocalToolRegistry.execute(LocalToolNames.webSearch, {
      'query': 'openhanako',
    }, browserManager: browser);
    final body = jsonDecode(raw) as Map<String, dynamic>;

    expect(body['ok'], false);
    expect(body['error'], 'camoufox_not_available');
    expect(body['message'], contains('启动错误'));
  });

  test('Camoufox 配置存在时 navigate 会启动本地 bridge 并走真实浏览器路径', () async {
    final python = _findPython();
    if (python == null) {
      markTestSkipped('本机未找到 python，跳过 bridge 子进程测试');
      return;
    }
    final appDir = Directory(p.join(tmp.path, 'app'))
      ..createSync(recursive: true);
    final browserDir = Directory(p.join(appDir.path, 'browser'))..createSync();
    final bridge = _writeFakeBridge(browserDir);
    final record = File(p.join(browserDir.path, 'commands.jsonl'));
    File(p.join(browserDir.path, 'config.json')).writeAsStringSync(
      jsonEncode({
        'venvPython': python,
        'bridgeScript': bridge.path,
        'recordPath': record.path,
        'browserExecutable': p.join(browserDir.path, 'camoufox.exe'),
      }),
    );
    File(p.join(browserDir.path, 'camoufox.exe')).writeAsStringSync('fake');
    browser = BrowserManager(
      preferences: PreferencesManager(home),
      appDir: appDir.path,
    );

    final raw = await LocalToolRegistry.execute(LocalToolNames.browser, {
      'action': 'navigate',
      'url': 'https://example.com/page',
    }, browserManager: browser);
    final body = jsonDecode(raw) as Map<String, dynamic>;
    expect(body['ok'], true);
    expect(body['title'], 'Fake Camoufox');
    expect(body['status']['realBrowser'], true);
    expect(body['status']['mode'], 'camoufox');
    expect(browser.isRunning, true);

    final snapshotRaw = await LocalToolRegistry.execute(
      LocalToolNames.browser,
      {'action': 'snapshot'},
      browserManager: browser,
    );
    final snapshot = jsonDecode(snapshotRaw) as Map<String, dynamic>;
    expect(snapshot['message'], contains('Fake page text'));

    final actions = record
        .readAsLinesSync()
        .map((line) => (jsonDecode(line) as Map<String, dynamic>)['action'])
        .toList();
    expect(actions, containsAllInOrder(['start', 'navigate', 'snapshot']));
  });

  test('web_search 使用 Camoufox bridge 返回结构化搜索结果', () async {
    final python = _findPython();
    if (python == null) {
      markTestSkipped('本机未找到 python，跳过 bridge 子进程测试');
      return;
    }
    final appDir = Directory(p.join(tmp.path, 'app'))
      ..createSync(recursive: true);
    final browserDir = Directory(p.join(appDir.path, 'browser'))..createSync();
    final bridge = _writeFakeBridge(browserDir);
    File(p.join(browserDir.path, 'config.json')).writeAsStringSync(
      jsonEncode({
        'venvPython': python,
        'bridgeScript': bridge.path,
        'browserExecutable': p.join(browserDir.path, 'camoufox.exe'),
      }),
    );
    File(p.join(browserDir.path, 'camoufox.exe')).writeAsStringSync('fake');
    browser = BrowserManager(
      preferences: PreferencesManager(home),
      appDir: appDir.path,
    );

    final raw = await LocalToolRegistry.execute(LocalToolNames.webSearch, {
      'query': 'openhanako',
      'maxResults': 1,
    }, browserManager: browser);
    final body = jsonDecode(raw) as Map<String, dynamic>;
    expect(body['ok'], true);
    expect(body['source'], 'bing');
    expect(body['results'], isA<List>());
    expect((body['results'] as List).single['title'], 'OpenHanako');
  });

  test('交互类 action 在 bridge 模式下有真实执行入口', () async {
    final python = _findPython();
    if (python == null) {
      markTestSkipped('本机未找到 python，跳过 bridge 子进程测试');
      return;
    }
    final appDir = Directory(p.join(tmp.path, 'app'))
      ..createSync(recursive: true);
    final browserDir = Directory(p.join(appDir.path, 'browser'))..createSync();
    final bridge = _writeFakeBridge(browserDir);
    File(p.join(browserDir.path, 'config.json')).writeAsStringSync(
      jsonEncode({
        'venvPython': python,
        'bridgeScript': bridge.path,
        'browserExecutable': p.join(browserDir.path, 'camoufox.exe'),
      }),
    );
    File(p.join(browserDir.path, 'camoufox.exe')).writeAsStringSync('fake');
    browser = BrowserManager(
      preferences: PreferencesManager(home),
      appDir: appDir.path,
    );

    for (final args in [
      {'action': 'scroll', 'direction': 'down', 'amount': 120},
      {'action': 'key', 'key': 'Enter'},
      {'action': 'select', 'selector': '#choice', 'value': 'a'},
      {'action': 'click', 'selector': '#submit'},
      {'action': 'type', 'selector': '#name', 'text': 'Hanako'},
      {'action': 'screenshot'},
    ]) {
      final raw = await LocalToolRegistry.execute(
        LocalToolNames.browser,
        args,
        browserManager: browser,
      );
      final body = jsonDecode(raw) as Map<String, dynamic>;
      expect(body['ok'], true, reason: args.toString());
    }
  });

  test('安装脚本使用 Hanako browser bridge 而不是 camoufox-connector RPC', () {
    final iss = File('installers/windows.iss').readAsStringSync();
    expect(iss, contains('hanako_browser_bridge.py'));
    expect(iss, contains('"bridgeScript"'));
    expect(iss, contains('"browserExecutable"'));
    expect(iss, contains('"excludeDefaultAddons"'));
    expect(iss, contains('FindBrowserExecutable'));
    expect(iss, contains('hanako_browser_bridge.py*'));
    expect(iss, isNot(contains('MODULES eq camoufox')));
    expect(iss, isNot(contains('camoufox-connector')));
    expect(iss, isNot(contains('camoufox_connector')));
  });

  test('bridge 默认排除全部 Camoufox 默认插件且失败闭环', () {
    final bridge = File('installers/hanako_browser_bridge.py').readAsStringSync();
    expect(bridge, contains('def _default_addons_to_exclude'));
    expect(bridge, contains('from camoufox import DefaultAddons'));
    expect(bridge, contains('from camoufox.addons import DefaultAddons'));
    expect(bridge, contains('list(DefaultAddons)'));
    expect(bridge, contains('default_addon_exclusion_unavailable'));
  });
}

String? _findPython() {
  for (final exe in ['python', 'python3']) {
    try {
      final result = Process.runSync(exe, ['--version']);
      if (result.exitCode == 0) return exe;
    } catch (_) {}
  }
  return null;
}

File _writeFakeBridge(Directory browserDir) {
  final file = File(p.join(browserDir.path, 'fake_bridge.py'));
  file.writeAsStringSync(r'''
import json
import sys

config = json.loads(open(sys.argv[1], encoding="utf-8").read())
record_path = config.get("recordPath")

def reply(command_id, **payload):
    print(json.dumps({"id": command_id, **payload}, ensure_ascii=False), flush=True)

for line in sys.stdin:
    if not line.strip():
        continue
    command = json.loads(line)
    if record_path:
        with open(record_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(command, ensure_ascii=False) + "\n")
    command_id = command.get("id")
    action = command.get("action")
    if action == "start":
        reply(command_id, ok=True, message="started", running=True)
    elif action == "navigate":
        reply(command_id, ok=True, message="opened", url=command.get("url"), title="Fake Camoufox")
    elif action == "snapshot":
        reply(command_id, ok=True, message="Fake page text", text="Fake page text", url="https://example.com/page", title="Fake Camoufox")
    elif action == "evaluate":
        reply(command_id, ok=True, message='[{"title":"OpenHanako","url":"https://example.com","snippet":"Result"}]', result='[{"title":"OpenHanako","url":"https://example.com","snippet":"Result"}]')
    elif action == "screenshot":
        reply(command_id, ok=True, message="shot", screenshot="ZmFrZQ==")
    elif action == "stop":
        reply(command_id, ok=True, message="stopped", running=False)
    else:
        reply(command_id, ok=True, message=f"{action} ok", running=True)
''');
  return file;
}
