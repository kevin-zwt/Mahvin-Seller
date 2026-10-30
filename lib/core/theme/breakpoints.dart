import 'package:flutter/widgets.dart';

enum DeviceType { mobile, tablet, desktop }

/// Screen-width breakpoints. Use these instead of guessing pixel values.
class Breakpoints {
  Breakpoints._();

  static const double tablet = 720;
  static const double desktop = 1080;

  static double widthOf(BuildContext context) =>
      MediaQuery.sizeOf(context).width;

  static DeviceType typeOf(BuildContext context) {
    final width = widthOf(context);
    if (width >= desktop) return DeviceType.desktop;
    if (width >= tablet) return DeviceType.tablet;
    return DeviceType.mobile;
  }

  static bool isWide(BuildContext context) => widthOf(context) >= tablet;

  static bool isDesktop(BuildContext context) => widthOf(context) >= desktop;
}
