import 'package:flutter/material.dart';

import '../design/design.dart';

/// 桌面页面转场 — fade + 微缩放（0.985 → 1.0），避免 Material 默认 SlideUp
/// 在桌面端显得"移动化"。
class _DesktopPageTransitionsBuilder extends PageTransitionsBuilder {
  const _DesktopPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final fade = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final scale = Tween<double>(begin: 0.985, end: 1.0).animate(fade);
    return FadeTransition(
      opacity: fade,
      child: ScaleTransition(scale: scale, child: child),
    );
  }
}

const _kDesktopPageTransitions = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.windows: _DesktopPageTransitionsBuilder(),
    TargetPlatform.macOS: _DesktopPageTransitionsBuilder(),
    TargetPlatform.linux: _DesktopPageTransitionsBuilder(),
    TargetPlatform.android: ZoomPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
  },
);

class HanakoThemes {
  HanakoThemes._();

  static const _fontFamily = 'Microsoft YaHei UI';
  static const _fontFallback = <String>[
    'Microsoft YaHei',
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'PingFang SC',
    'Source Han Sans SC',
    'SimHei',
    'Arial Unicode MS',
  ];

  static TextTheme _buildTextTheme(Color primary, Color secondary) =>
      TextTheme(
        displayLarge: TextStyle(
          color: primary,
          fontSize: DS.t32,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
          height: 1.1,
        ),
        displayMedium: TextStyle(
          color: primary,
          fontSize: DS.t26,
          fontWeight: FontWeight.w700,
          height: 1.15,
        ),
        headlineMedium: TextStyle(
          color: primary,
          fontSize: DS.t22,
          fontWeight: FontWeight.w700,
          height: 1.2,
        ),
        titleLarge: TextStyle(
          color: primary,
          fontSize: DS.t18,
          fontWeight: FontWeight.w700,
          height: 1.25,
        ),
        titleMedium: TextStyle(
          color: primary,
          fontSize: DS.t16,
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
        titleSmall: TextStyle(
          color: primary,
          fontSize: DS.t14,
          fontWeight: FontWeight.w600,
          height: 1.35,
        ),
        bodyLarge: TextStyle(
          color: primary,
          fontSize: DS.t16,
          height: 1.55,
        ),
        bodyMedium: TextStyle(
          color: primary,
          fontSize: DS.t14,
          height: 1.55,
        ),
        bodySmall: TextStyle(
          color: secondary,
          fontSize: DS.t12,
          height: 1.5,
        ),
        labelLarge: TextStyle(
          color: primary,
          fontSize: DS.t13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
        labelMedium: TextStyle(
          color: secondary,
          fontSize: DS.t12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
        labelSmall: TextStyle(
          color: secondary,
          fontSize: DS.t11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      );

  static ThemeData warmPaper() {
    final palette = HanaPalette.light();
    final scheme = ColorScheme(
      brightness: Brightness.light,
      primary: palette.accentEmerald,
      onPrimary: Colors.white,
      primaryContainer: palette.accentEmerald.withValues(alpha: 0.14),
      onPrimaryContainer: const Color(0xFF0A3024),
      secondary: palette.accentCyan,
      onSecondary: Colors.white,
      secondaryContainer: palette.accentCyan.withValues(alpha: 0.12),
      onSecondaryContainer: const Color(0xFF123227),
      tertiary: palette.accentAmber,
      onTertiary: Colors.white,
      tertiaryContainer: palette.accentAmber.withValues(alpha: 0.16),
      onTertiaryContainer: const Color(0xFF3B2708),
      error: palette.accentCrimson,
      onError: Colors.white,
      errorContainer: palette.accentCrimson.withValues(alpha: 0.16),
      onErrorContainer: const Color(0xFF3B1510),
      surface: palette.bgBase,
      onSurface: palette.textPrimary,
      onSurfaceVariant: palette.textSecondary,
      surfaceContainerLowest: palette.bgRaised,
      surfaceContainerLow: palette.bgBase,
      surfaceContainer: palette.bgBase,
      surfaceContainerHigh: palette.bgRaised,
      surfaceContainerHighest: palette.bgFloating,
      outline: palette.divider,
      outlineVariant: palette.divider,
      shadow: Colors.black,
      scrim: palette.scrim,
      inverseSurface: palette.bgFloating,
      onInverseSurface: palette.textPrimary,
      inversePrimary: palette.accentEmerald,
      surfaceTint: Colors.transparent,
    );

    return ThemeData(
      colorScheme: scheme,
      brightness: Brightness.light,
      useMaterial3: true,
      fontFamily: _fontFamily,
      fontFamilyFallback: _fontFallback,
      scaffoldBackgroundColor: palette.bgBase,
      canvasColor: palette.bgBase,
      visualDensity: VisualDensity.standard,
      extensions: [palette],
      pageTransitionsTheme: _kDesktopPageTransitions,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: palette.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: 56,
      ),
      dividerTheme: DividerThemeData(color: palette.divider, space: 1),
      iconTheme: IconThemeData(color: palette.textPrimary, size: 18),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: palette.textPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DS.r8),
          ),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: palette.bgRaised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DS.r10),
          side: BorderSide(color: palette.divider),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.bgRaised,
        hintStyle: TextStyle(color: palette.textTertiary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DS.r10),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DS.r10),
          borderSide: BorderSide(color: palette.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DS.r10),
          borderSide: BorderSide(color: palette.accentEmerald, width: 1.4),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: palette.glassFill,
        selectedColor: palette.accentEmerald.withValues(alpha: 0.16),
        labelStyle: TextStyle(color: palette.textPrimary, fontSize: DS.t12),
        side: BorderSide(color: palette.glassBorder),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DS.rPill),
        ),
        padding: const EdgeInsets.symmetric(horizontal: DS.s10, vertical: 4),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: palette.accentEmerald,
          foregroundColor: Colors.white,
          padding:
              const EdgeInsets.symmetric(horizontal: DS.s16, vertical: DS.s10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DS.r8),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: palette.accentEmerald,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DS.r8),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: palette.divider),
          foregroundColor: palette.textPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DS.r8),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: palette.bgFloating,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DS.r14),
          side: BorderSide(color: palette.divider),
        ),
        titleTextStyle: TextStyle(
          color: palette.textPrimary,
          fontSize: DS.t18,
          fontWeight: FontWeight.w700,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: palette.bgFloating,
        contentTextStyle: TextStyle(color: palette.textPrimary),
        behavior: SnackBarBehavior.floating,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DS.r10),
          side: BorderSide(color: palette.divider),
        ),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: palette.bgRaised,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.only(
            topRight: Radius.circular(DS.r16),
            bottomRight: Radius.circular(DS.r16),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: palette.textSecondary,
        textColor: palette.textPrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DS.r8),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: palette.bgFloating,
          borderRadius: BorderRadius.circular(DS.r8),
          border: Border.all(color: palette.divider),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        textStyle: TextStyle(color: palette.textPrimary, fontSize: DS.t12),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: palette.accentEmerald,
        unselectedLabelColor: palette.textSecondary,
        indicatorColor: palette.accentEmerald,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        overlayColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.hovered)
              ? palette.accentEmerald.withValues(alpha: 0.06)
              : null,
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(
          palette.textSecondary.withValues(alpha: 0.32),
        ),
        radius: const Radius.circular(DS.r8),
        thickness: WidgetStateProperty.all(6),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: palette.accentEmerald,
        linearTrackColor: palette.glassFill,
      ),
      textTheme: _buildTextTheme(palette.textPrimary, palette.textSecondary),
    );
  }

  static ThemeData dark() {
    final palette = HanaPalette.dark();
    final scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: palette.accentEmerald,
      onPrimary: const Color(0xFF06120A),
      primaryContainer: palette.accentEmerald.withValues(alpha: 0.16),
      onPrimaryContainer: const Color(0xFFD2F5E6),
      secondary: palette.accentCyan,
      onSecondary: const Color(0xFF061410),
      secondaryContainer: palette.accentCyan.withValues(alpha: 0.14),
      onSecondaryContainer: const Color(0xFFD6F7F0),
      tertiary: palette.accentAmber,
      onTertiary: const Color(0xFF1D1606),
      tertiaryContainer: palette.accentAmber.withValues(alpha: 0.16),
      onTertiaryContainer: const Color(0xFFFFF1C6),
      error: palette.accentCrimson,
      onError: const Color(0xFF1A0C08),
      errorContainer: palette.accentCrimson.withValues(alpha: 0.16),
      onErrorContainer: const Color(0xFFFBD5CA),
      surface: palette.bgBase,
      onSurface: palette.textPrimary,
      onSurfaceVariant: palette.textSecondary,
      surfaceContainerLowest: palette.bgDeep,
      surfaceContainerLow: palette.bgBase,
      surfaceContainer: palette.bgRaised,
      surfaceContainerHigh: palette.bgFloating,
      surfaceContainerHighest: palette.bgFloating,
      outline: palette.divider,
      outlineVariant: palette.divider,
      shadow: Colors.black,
      scrim: palette.scrim,
      inverseSurface: palette.bgFloating,
      onInverseSurface: palette.textPrimary,
      inversePrimary: palette.accentEmerald,
      surfaceTint: Colors.transparent,
    );

    return ThemeData(
      colorScheme: scheme,
      brightness: Brightness.dark,
      useMaterial3: true,
      fontFamily: _fontFamily,
      fontFamilyFallback: _fontFallback,
      scaffoldBackgroundColor: palette.bgBase,
      canvasColor: palette.bgBase,
      visualDensity: VisualDensity.standard,
      extensions: [palette],
      pageTransitionsTheme: _kDesktopPageTransitions,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: palette.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: 56,
      ),
      dividerTheme: DividerThemeData(color: palette.divider, space: 1),
      iconTheme: IconThemeData(color: palette.textPrimary, size: 18),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: palette.textPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DS.r8),
          ),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: palette.bgRaised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DS.r10),
          side: BorderSide(color: palette.divider),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.bgRaised,
        hintStyle: TextStyle(color: palette.textTertiary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DS.r10),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DS.r10),
          borderSide: BorderSide(color: palette.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DS.r10),
          borderSide: BorderSide(color: palette.accentEmerald, width: 1.4),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: palette.glassFill,
        selectedColor: palette.accentEmerald.withValues(alpha: 0.16),
        labelStyle: TextStyle(color: palette.textPrimary, fontSize: DS.t12),
        side: BorderSide(color: palette.glassBorder),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DS.rPill),
        ),
        padding: const EdgeInsets.symmetric(horizontal: DS.s10, vertical: 4),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: palette.accentEmerald,
          foregroundColor: const Color(0xFF06120A),
          padding:
              const EdgeInsets.symmetric(horizontal: DS.s16, vertical: DS.s10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DS.r8),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: palette.accentEmerald,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DS.r8),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: palette.divider),
          foregroundColor: palette.textPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DS.r8),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: palette.bgFloating,
        surfaceTintColor: Colors.transparent,
        elevation: 24,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DS.r14),
          side: BorderSide(color: palette.divider),
        ),
        titleTextStyle: TextStyle(
          color: palette.textPrimary,
          fontSize: DS.t18,
          fontWeight: FontWeight.w700,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: palette.bgFloating,
        contentTextStyle: TextStyle(color: palette.textPrimary),
        behavior: SnackBarBehavior.floating,
        elevation: 12,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DS.r10),
          side: BorderSide(color: palette.divider),
        ),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: palette.bgRaised,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.only(
            topRight: Radius.circular(DS.r16),
            bottomRight: Radius.circular(DS.r16),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: palette.textSecondary,
        textColor: palette.textPrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DS.r8),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: palette.bgFloating,
          borderRadius: BorderRadius.circular(DS.r8),
          border: Border.all(color: palette.divider),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.50),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        textStyle: TextStyle(color: palette.textPrimary, fontSize: DS.t12),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: palette.accentEmerald,
        unselectedLabelColor: palette.textSecondary,
        indicatorColor: palette.accentEmerald,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        overlayColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.hovered)
              ? palette.accentEmerald.withValues(alpha: 0.06)
              : null,
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(
          palette.textSecondary.withValues(alpha: 0.36),
        ),
        radius: const Radius.circular(DS.r8),
        thickness: WidgetStateProperty.all(6),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: palette.accentEmerald,
        linearTrackColor: palette.glassFill,
      ),
      textTheme: _buildTextTheme(palette.textPrimary, palette.textSecondary),
    );
  }
}
