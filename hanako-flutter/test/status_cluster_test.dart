import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/ui/widgets/status_cluster.dart';

void main() {
  testWidgets('状态条默认只显示独立图标，点击单项只展开该项', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: StatusCluster(
              items: [
                StatusClusterItem(
                  icon: Icons.lan_outlined,
                  label: 'DHT 2/3',
                  color: Colors.blue,
                ),
                StatusClusterItem(
                  icon: Icons.ads_click_outlined,
                  label: '界面模型',
                  color: Colors.green,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('DHT 2/3'), findsNothing);
    expect(find.text('界面模型'), findsNothing);

    await tester.tap(find.byTooltip('DHT 2/3'));
    await tester.pumpAndSettle();

    expect(find.text('DHT 2/3'), findsOneWidget);
    expect(find.text('界面模型'), findsNothing);
  });

  testWidgets('带动作的状态项点击仍执行动作', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StatusCluster(
              items: [
                StatusClusterItem(
                  icon: Icons.key_outlined,
                  label: '身份未解锁',
                  color: Colors.red,
                  onPressed: () => taps++,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('身份未解锁'));
    await tester.pumpAndSettle();

    expect(taps, 1);
    expect(find.text('身份未解锁'), findsOneWidget);
  });
}
