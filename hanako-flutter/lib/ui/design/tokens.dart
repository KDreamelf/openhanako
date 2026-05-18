import 'package:flutter/material.dart';

/// PH01 设计 Token 集合。
///
/// 整个 UI 的视觉常量（颜色、间距、字号、圆角、动画、阴影）都从这里取，
/// 保证设计语言全局统一。修改 token 即可全局换肤。
class DS {
  DS._();

  // -------- 间距 --------
  static const double s2 = 2;
  static const double s4 = 4;
  static const double s6 = 6;
  static const double s8 = 8;
  static const double s10 = 10;
  static const double s12 = 12;
  static const double s14 = 14;
  static const double s16 = 16;
  static const double s20 = 20;
  static const double s24 = 24;
  static const double s28 = 28;
  static const double s32 = 32;
  static const double s40 = 40;
  static const double s48 = 48;
  static const double s56 = 56;
  static const double s72 = 72;

  // -------- 圆角 --------
  static const double r4 = 4;
  static const double r6 = 6;
  static const double r8 = 8;
  static const double r10 = 10;
  static const double r12 = 12;
  static const double r14 = 14;
  static const double r16 = 16;
  static const double r20 = 20;
  static const double rPill = 999;

  // -------- 字号 --------
  static const double t10 = 10;
  static const double t11 = 11;
  static const double t12 = 12;
  static const double t13 = 13;
  static const double t14 = 14;
  static const double t15 = 15;
  static const double t16 = 16;
  static const double t18 = 18;
  static const double t20 = 20;
  static const double t22 = 22;
  static const double t26 = 26;
  static const double t32 = 32;

  // -------- 动画时长 --------
  static const Duration dFast = Duration(milliseconds: 120);
  static const Duration dQuick = Duration(milliseconds: 180);
  static const Duration dBase = Duration(milliseconds: 240);
  static const Duration dSlow = Duration(milliseconds: 360);
  static const Duration dPage = Duration(milliseconds: 480);

  // -------- 动画曲线 --------
  static const Curve cEnter = Curves.easeOutCubic;
  static const Curve cExit = Curves.easeInCubic;
  static const Curve cStandard = Curves.easeInOutCubic;
  static const Curve cSpring = Curves.easeOutBack;

  // -------- 描边 / 分隔线宽度 --------
  static const double hairline = 0.6;
  static const double border = 1.0;
  static const double thick = 1.6;

  // -------- 内容最大宽度 --------
  static const double readableWidth = 1080;
  static const double workspaceWidth = 1320;
  static const double sidebarWidth = 280;
  static const double drawerWidth = 320;

  // -------- 字体 fallback 链 --------
  /// 等宽字体 fallback。优先 distinctive 的程序员字体，最后兜底系统 monospace。
  /// 用法：`TextStyle(fontFamily: DS.monoPrimary, fontFamilyFallback: DS.monoFallback)`
  /// 或者直接 `TextStyle(fontFamilyFallback: DS.monoFallback)` 不指定 primary。
  static const String monoPrimary = 'JetBrains Mono';
  static const List<String> monoFallback = <String>[
    'JetBrains Mono',
    'Cascadia Code',
    'Cascadia Mono',
    'Fira Code',
    'Source Code Pro',
    'Consolas',
    'Menlo',
    'monospace',
  ];
}

/// 等宽文本样式 — 整个项目里显示代码 / JSON / 哈希 / 路径用的统一字体。
///
/// 自动从 [DS.monoFallback] 链里挑选系统可用的最先字体。
TextStyle dsMonoStyle({
  double fontSize = DS.t12,
  Color? color,
  FontWeight fontWeight = FontWeight.w500,
  double height = 1.55,
  double letterSpacing = 0.2,
}) {
  return TextStyle(
    fontFamilyFallback: DS.monoFallback,
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    height: height,
    letterSpacing: letterSpacing,
  );
}

/// 在 ThemeData.extensions 里注入语义颜色，全局复用。
@immutable
class HanaPalette extends ThemeExtension<HanaPalette> {
  const HanaPalette({
    required this.brightness,
    required this.bgDeep,
    required this.bgBase,
    required this.bgRaised,
    required this.bgFloating,
    required this.glassFill,
    required this.glassFillStrong,
    required this.glassBorder,
    required this.glassBorderStrong,
    required this.glassGlow,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.textDisabled,
    required this.accentEmerald,
    required this.accentCyan,
    required this.accentLilac,
    required this.accentAmber,
    required this.accentCrimson,
    required this.accentLavender,
    required this.divider,
    required this.scrim,
  });

  final Brightness brightness;

  /// 最深的背景层 — App 最底色，承载所有装饰光晕。
  final Color bgDeep;

  /// 主背景 — Scaffold 默认色（与 bgDeep 略有差异以形成层次）。
  final Color bgBase;

  /// 抬升一层（侧栏、Header、Composer 等）。
  final Color bgRaised;

  /// 再抬升一层（卡片、对话框）。
  final Color bgFloating;

  /// 玻璃材质 — 普通填充。
  final Color glassFill;

  /// 玻璃材质 — 强调填充（对话气泡、关键面板）。
  final Color glassFillStrong;

  /// 玻璃材质 — 描边。
  final Color glassBorder;

  /// 玻璃材质 — 强描边。
  final Color glassBorderStrong;

  /// 顶部环境光辉（左上角光晕等）。
  final Color glassGlow;

  /// 一级文字（主标题、用户消息正文）。
  final Color textPrimary;

  /// 二级文字（说明、subtitle）。
  final Color textSecondary;

  /// 三级文字（时间戳、metadata）。
  final Color textTertiary;

  /// 禁用文字。
  final Color textDisabled;

  /// 翡翠绿 — 主行动 / READY / 成功。
  final Color accentEmerald;

  /// 冷青 — 流式 / 思考 / 工具调用。
  final Color accentCyan;

  /// 淡紫 — Agent 标识。
  final Color accentLilac;

  /// 琥珀 — 警告 / 暂待。
  final Color accentAmber;

  /// 朱红 — 危险 / 错误 / 待授权。
  final Color accentCrimson;

  /// 薰衣草 — 装饰 / hover 高光。
  final Color accentLavender;

  /// 标准分隔线颜色。
  final Color divider;

  /// 遮罩。
  final Color scrim;

  bool get isDark => brightness == Brightness.dark;

  /// 给指定的语义角色取颜色（"emerald" / "cyan" / "amber" / "crimson" / "lavender" / "lilac"）。
  Color accent(String name) => switch (name) {
    'emerald' || 'primary' || 'success' => accentEmerald,
    'cyan' || 'info' || 'streaming' => accentCyan,
    'amber' || 'warning' => accentAmber,
    'crimson' || 'danger' || 'error' => accentCrimson,
    'lavender' => accentLavender,
    'lilac' => accentLilac,
    _ => accentEmerald,
  };

  static HanaPalette dark() => const HanaPalette(
    brightness: Brightness.dark,
    bgDeep: Color(0xFF06080F),
    bgBase: Color(0xFF0A0E1A),
    bgRaised: Color(0xFF0E1424),
    bgFloating: Color(0xFF131B2E),
    glassFill: Color(0x14FFFFFF), // ~8% white
    glassFillStrong: Color(0x1FFFFFFF), // ~12% white
    glassBorder: Color(0x1AFFFFFF), // ~10% white
    glassBorderStrong: Color(0x33FFFFFF), // ~20% white
    glassGlow: Color(0x4D7AE8FF), // soft cyan glow
    textPrimary: Color(0xFFEDF1F7),
    textSecondary: Color(0x8DEDF1F7), // ~55%
    textTertiary: Color(0x52EDF1F7), // ~32%
    textDisabled: Color(0x33EDF1F7),
    accentEmerald: Color(0xFF3DDC97),
    accentCyan: Color(0xFF5CD6C4),
    accentLilac: Color(0xFFA59CFB),
    accentAmber: Color(0xFFF2B85B),
    accentCrimson: Color(0xFFE8654A),
    accentLavender: Color(0xFFC4A0FF),
    divider: Color(0xFF1B2336),
    scrim: Color(0xCC03050B),
  );

  static HanaPalette light() => const HanaPalette(
    brightness: Brightness.light,
    bgDeep: Color(0xFFEFF3F1),
    bgBase: Color(0xFFF7FAF8),
    bgRaised: Color(0xFFFFFFFF),
    bgFloating: Color(0xFFFFFFFF),
    glassFill: Color(0x12000000),
    glassFillStrong: Color(0x1A000000),
    glassBorder: Color(0x1F000000),
    glassBorderStrong: Color(0x33000000),
    glassGlow: Color(0x3D4AC9E0),
    textPrimary: Color(0xFF0E1A1F),
    textSecondary: Color(0x990E1A1F),
    textTertiary: Color(0x5C0E1A1F),
    textDisabled: Color(0x3D0E1A1F),
    accentEmerald: Color(0xFF1F9A6E),
    accentCyan: Color(0xFF1F8FA8),
    accentLilac: Color(0xFF6F62D9),
    accentAmber: Color(0xFFB07A1B),
    accentCrimson: Color(0xFFBB4836),
    accentLavender: Color(0xFF8B6BD9),
    divider: Color(0xFFD5DDE2),
    scrim: Color(0x66000000),
  );

  @override
  HanaPalette copyWith({
    Brightness? brightness,
    Color? bgDeep,
    Color? bgBase,
    Color? bgRaised,
    Color? bgFloating,
    Color? glassFill,
    Color? glassFillStrong,
    Color? glassBorder,
    Color? glassBorderStrong,
    Color? glassGlow,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? textDisabled,
    Color? accentEmerald,
    Color? accentCyan,
    Color? accentLilac,
    Color? accentAmber,
    Color? accentCrimson,
    Color? accentLavender,
    Color? divider,
    Color? scrim,
  }) => HanaPalette(
    brightness: brightness ?? this.brightness,
    bgDeep: bgDeep ?? this.bgDeep,
    bgBase: bgBase ?? this.bgBase,
    bgRaised: bgRaised ?? this.bgRaised,
    bgFloating: bgFloating ?? this.bgFloating,
    glassFill: glassFill ?? this.glassFill,
    glassFillStrong: glassFillStrong ?? this.glassFillStrong,
    glassBorder: glassBorder ?? this.glassBorder,
    glassBorderStrong: glassBorderStrong ?? this.glassBorderStrong,
    glassGlow: glassGlow ?? this.glassGlow,
    textPrimary: textPrimary ?? this.textPrimary,
    textSecondary: textSecondary ?? this.textSecondary,
    textTertiary: textTertiary ?? this.textTertiary,
    textDisabled: textDisabled ?? this.textDisabled,
    accentEmerald: accentEmerald ?? this.accentEmerald,
    accentCyan: accentCyan ?? this.accentCyan,
    accentLilac: accentLilac ?? this.accentLilac,
    accentAmber: accentAmber ?? this.accentAmber,
    accentCrimson: accentCrimson ?? this.accentCrimson,
    accentLavender: accentLavender ?? this.accentLavender,
    divider: divider ?? this.divider,
    scrim: scrim ?? this.scrim,
  );

  @override
  HanaPalette lerp(ThemeExtension<HanaPalette>? other, double t) {
    if (other is! HanaPalette) return this;
    return HanaPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      bgDeep: Color.lerp(bgDeep, other.bgDeep, t)!,
      bgBase: Color.lerp(bgBase, other.bgBase, t)!,
      bgRaised: Color.lerp(bgRaised, other.bgRaised, t)!,
      bgFloating: Color.lerp(bgFloating, other.bgFloating, t)!,
      glassFill: Color.lerp(glassFill, other.glassFill, t)!,
      glassFillStrong: Color.lerp(glassFillStrong, other.glassFillStrong, t)!,
      glassBorder: Color.lerp(glassBorder, other.glassBorder, t)!,
      glassBorderStrong: Color.lerp(
        glassBorderStrong,
        other.glassBorderStrong,
        t,
      )!,
      glassGlow: Color.lerp(glassGlow, other.glassGlow, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      textDisabled: Color.lerp(textDisabled, other.textDisabled, t)!,
      accentEmerald: Color.lerp(accentEmerald, other.accentEmerald, t)!,
      accentCyan: Color.lerp(accentCyan, other.accentCyan, t)!,
      accentLilac: Color.lerp(accentLilac, other.accentLilac, t)!,
      accentAmber: Color.lerp(accentAmber, other.accentAmber, t)!,
      accentCrimson: Color.lerp(accentCrimson, other.accentCrimson, t)!,
      accentLavender: Color.lerp(accentLavender, other.accentLavender, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
    );
  }
}

/// 在 widget 中获取 [HanaPalette] 的便捷扩展。
extension HanaPaletteResolver on BuildContext {
  /// `context.palette` — 推荐写法，比 `Theme.of(context).extension<HanaPalette>()` 简洁。
  HanaPalette get palette =>
      Theme.of(this).extension<HanaPalette>() ??
      (Theme.of(this).brightness == Brightness.dark
          ? HanaPalette.dark()
          : HanaPalette.light());
}
