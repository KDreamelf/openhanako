import 'package:flutter/material.dart';

/// 主题集合：子体客户端的白蓝科技主题 + 深蓝星空工作主题。
class HanakoThemes {
  HanakoThemes._();

  static ThemeData warmPaper() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF2F6BFF),
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xFF1D5EFF),
          onPrimary: const Color(0xFFFFFFFF),
          primaryContainer: const Color(0xFFDCE8FF),
          onPrimaryContainer: const Color(0xFF071D4F),
          secondary: const Color(0xFF0D7FA8),
          onSecondary: const Color(0xFFFFFFFF),
          secondaryContainer: const Color(0xFFD2F2FF),
          onSecondaryContainer: const Color(0xFF062B3A),
          tertiary: const Color(0xFF4E63D8),
          onTertiary: const Color(0xFFFFFFFF),
          tertiaryContainer: const Color(0xFFE2E6FF),
          onTertiaryContainer: const Color(0xFF111B5C),
          surface: const Color(0xFFF6FAFF),
          onSurface: const Color(0xFF17243A),
          surfaceContainerLowest: const Color(0xFFFFFFFF),
          surfaceContainerLow: const Color(0xFFEEF6FF),
          surfaceContainer: const Color(0xFFE6F0FB),
          surfaceContainerHigh: const Color(0xFFDCEBFA),
          surfaceContainerHighest: const Color(0xFFCEDFF4),
          outlineVariant: const Color(0xFFC5D4EA),
        );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.primaryContainer,
        labelStyle: TextStyle(color: scheme.onSurface),
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(height: 1.5),
        titleMedium: TextStyle(fontWeight: FontWeight.w600),
      ),
    );
  }

  static ThemeData dark() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF63C8FF),
          brightness: Brightness.dark,
        ).copyWith(
          primary: const Color(0xFF78D7FF),
          onPrimary: const Color(0xFF00243B),
          primaryContainer: const Color(0xFF0B3C66),
          onPrimaryContainer: const Color(0xFFD7F4FF),
          secondary: const Color(0xFF87F1FF),
          onSecondary: const Color(0xFF052C36),
          secondaryContainer: const Color(0xFF0D4050),
          onSecondaryContainer: const Color(0xFFD9F8FF),
          tertiary: const Color(0xFF9EB4FF),
          onTertiary: const Color(0xFF12245E),
          tertiaryContainer: const Color(0xFF233A86),
          onTertiaryContainer: const Color(0xFFE2E8FF),
          surface: const Color(0xFF071426),
          onSurface: const Color(0xFFE9F3FF),
          surfaceContainerLowest: const Color(0xFF050B16),
          surfaceContainerLow: const Color(0xFF0A172A),
          surfaceContainer: const Color(0xFF0E1D34),
          surfaceContainerHigh: const Color(0xFF142846),
          surfaceContainerHighest: const Color(0xFF1A3456),
          outlineVariant: const Color(0xFF2B4668),
        );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.primaryContainer,
        labelStyle: TextStyle(color: scheme.onSurface),
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(height: 1.5),
        titleMedium: TextStyle(fontWeight: FontWeight.w600),
      ),
    );
  }
}
