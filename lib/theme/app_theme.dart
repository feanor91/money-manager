import 'package:flutter/material.dart';

/// Selectable accent-color palettes (see [AppTheme.applyPalette]). Only the
/// accent varies between them - positive/negative/warning stay fixed
/// universal green/red/orange, so a palette change never muddies the
/// profit/loss colour coding the rest of the app relies on.
enum AppPalette { indigo, emerald, slate, amber }

extension AppPaletteX on AppPalette {
  String get label => switch (this) {
        AppPalette.indigo => 'Indigo',
        AppPalette.emerald => 'Emeraude',
        AppPalette.slate => 'Ardoise',
        AppPalette.amber => 'Ambre',
      };

  Color get seed => switch (this) {
        AppPalette.indigo => const Color(0xFF5B6CFF),
        AppPalette.emerald => const Color(0xFF10B981),
        AppPalette.slate => const Color(0xFF64748B),
        AppPalette.amber => const Color(0xFFD97706),
      };
}

/// A clean, minimal "Bento" visual language: soft neutral background,
/// rounded cards, one confident accent color, generous spacing.
class AppTheme {
  /// Mutable on purpose: every screen reads this bare static field at build
  /// time (rather than through Theme.of(context)), so [applyPalette] just
  /// needs to update it before the next rebuild - no need to thread the
  /// palette through every widget that colours itself with the accent.
  static Color accent = AppPalette.indigo.seed;

  static const Color positive = Color(0xFF17B26A);
  static const Color negative = Color(0xFFF04438);
  static const Color warning = Color(0xFFF79009);

  static const double cardRadius = 24;
  static const double gridGap = 16;

  static void applyPalette(AppPalette palette) {
    accent = palette.seed;
  }

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.light,
    );
    // Material 3's tonal surface scale is what actually carries the seed
    // colour's hue into neutral backgrounds - a plain hardcoded grey/white
    // pair looks identical whichever palette is selected. surfaceContainerHighest
    // (more tinted) for the page behind everything, surfaceContainerLowest
    // (closer to white) for cards on top of it, keeps the same "soft
    // background, brighter card" contrast the original design had, just
    // tinted per palette now.
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surfaceContainerHighest,
      fontFamily: 'Roboto',
      textTheme: const TextTheme(
        displaySmall: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5),
        headlineSmall: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.3),
        titleMedium: TextStyle(fontWeight: FontWeight.w600),
        bodyMedium: TextStyle(height: 1.4),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cardRadius)),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: scheme.onSurface,
        centerTitle: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
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
    // In the dark tonal scale the ordering flips: surfaceContainerLowest is
    // the darkest (page background), surfaceContainerHigh a lighter, tinted
    // "elevated" surface for cards - see light() above. Deliberately NOT
    // pure black: a dark, tinted grey reads as a proper dark theme without
    // the harsher, higher-contrast look of true black/AMOLED styling.
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surfaceContainerLowest,
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cardRadius)),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: scheme.onSurface,
        centerTitle: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        indicatorColor: accent.withValues(alpha: 0.2),
        elevation: 0,
      ),
    );
  }
}
