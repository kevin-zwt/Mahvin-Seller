import 'package:flutter/widgets.dart';

import 'breakpoints.dart';

/// The shared ruler for the UI: spacing, radius and layout constants.
///
/// Never hardcode a 16 or a 18 in a widget — pick a value from here so every
/// page lines up.
class AppDimens {
  AppDimens._();

  // Spacing scale
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;

  // Radius scale
  static const double radiusSm = 12;
  static const double radiusMd = 18;
  static const double radiusLg = 26;
  static const double radiusPill = 999;

  // Layout
  static const double contentMaxWidth = 1100;
  static const double buttonHeight = 48;
  static const double pagePaddingMobile = 20;
  static const double pagePaddingWide = 40;

  /// Horizontal padding used by [AppScaffold]: wider on tablets/desktops.
  static EdgeInsets pagePadding(BuildContext context) => EdgeInsets.symmetric(
    horizontal: Breakpoints.isWide(context)
        ? pagePaddingWide
        : pagePaddingMobile,
  );
}
