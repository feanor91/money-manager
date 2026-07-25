import 'package:flutter/material.dart';

/// A clean, minimal "Bento" visual language: soft neutral background,
/// rounded cards, one confident accent color, generous spacing.
class AppTheme {
  static const Color accent = Color(0xFF5B6CFF);
  static const Color positive = Color(0xFF17B26A);
  static const Color negative = Color(0xFFF04438);
  static const Color warning = Color(0xFFF79009);

  static const double cardRadius = 24;
  static const double gridGap = 16;

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.light,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFFF4F5F9),
      fontFamily: 'Roboto',
      textTheme: const TextTheme(
        displaySmall: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5),
        headlineSmall: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.3),
        titleMedium: TextStyle(fontWeight: FontWeight.w600),
        bodyMedium: TextStyle(height: 1.4),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cardRadius)),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.black87,
        centerTitle: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: accent.withValues(alpha: 0.12),
        elevation: 0,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),
    );
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFF0F1115),
      cardTheme: CardThemeData(
        elevation: 0,
        color: const Color(0xFF1A1D24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cardRadius)),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xFF1A1D24),
        indicatorColor: accent.withValues(alpha: 0.2),
        elevation: 0,
      ),
    );
  }
}
