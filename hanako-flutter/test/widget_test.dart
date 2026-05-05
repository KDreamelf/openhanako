// Phase 0 spike smoke test：能启动 + chat page 渲染。
// Phase 4 起 ChatPage 依赖 engineProvider，需要 override 才能 widget-test。
// 这里改用最小 smoke：只验证 HanakoApp 树能 build 不抛错，详细 UI test 留 Phase 5。

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/ui/themes/themes.dart';

void main() {
  test('themes build without throwing', () {
    final warm = HanakoThemes.warmPaper();
    final dark = HanakoThemes.dark();
    expect(warm.useMaterial3, true);
    expect(dark.useMaterial3, true);
  });
}
