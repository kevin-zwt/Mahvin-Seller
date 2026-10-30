import 'package:flutter/material.dart';

/// Colors and gradients used across the app, for both theme modes.
class AppColors {
  AppColors._();

  // Light mode
  static const Color accent = Color(0xFF4F46E5);
  static const Color background = Color(0xFFF7F9FC);
  static const Color surface = Colors.white;
  static const Color border = Color(0xFFE6EBF2);

  static const Color ink = Color(0xFF0F172A);
  static const Color inkSoft = Color(0xFF475569);
  static const Color inkMuted = Color(0xFF94A3B8);

  // Status colors
  static const Color success = Color(0xFF16A34A);
  static const Color warning = Color(0xFFD97706);
  static const Color danger = Color(0xFFDC2626);

  // Dark mode
  static const Color darkBackground = Color(0xFF0A1020);
  static const Color darkSurface = Color(0xFF131B2E);
  static const Color darkBorder = Color(0xFF26314A);

  static const Color darkInk = Color(0xFFF1F5F9);
  static const Color darkInkSoft = Color(0xFFB6C2D6);
  static const Color darkInkMuted = Color(0xFF8494AD);

  /// Hero panel background: blue → indigo → violet.
  static const Gradient hero = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF2563EB), Color(0xFF4F46E5), Color(0xFF7C3AED)],
  );

  /// Soft card shadow — modern "floating" look without heaviness.
  static List<BoxShadow> softShadow(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    return [
      BoxShadow(
        color: (isDark ? Colors.black : ink).withValues(
          alpha: isDark ? 0.45 : 0.06,
        ),
        blurRadius: 28,
        offset: const Offset(0, 12),
      ),
    ];
  }

  static List<BoxShadow> get heroShadow => [
    BoxShadow(
      color: const Color(0xFF4F46E5).withValues(alpha: 0.32),
      blurRadius: 44,
      offset: const Offset(0, 18),
    ),
  ];
}
