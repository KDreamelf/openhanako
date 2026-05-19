import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/core/browser_manager.dart';
import 'package:hanako/core/preferences_manager.dart';
import 'package:hanako/local_tools/local_tools.dart';
import 'package:hanako/shared/hana_home.dart';

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
    expect(status['url'], url);

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
}
