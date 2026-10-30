import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// The Mahvin monogram: a gradient tile with a soft glow, used on the splash
/// screen and in the app bar. The launcher icons use the same design
/// (blue → indigo → violet, white "M").
class AppLogo extends StatelessWidget {
  const AppLogo({
    super.key,
    this.size = 44,
    this.letter = 'M',
    this.showShadow = false,
  });

  final double size;
  final String letter;
  final bool showShadow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: AppColors.hero,
        borderRadius: BorderRadius.circular(size * 0.26),
        boxShadow: showShadow ? AppColors.heroShadow : null,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: -size * 0.3,
            right: -size * 0.2,
            child: _Bubble(
              diameter: size * 0.62,
              color: Colors.white.withValues(alpha: 0.16),
            ),
          ),
          Positioned(
            bottom: -size * 0.26,
            left: -size * 0.18,
            child: _Bubble(
              diameter: size * 0.56,
              color: Colors.transparent,
              borderColor: Colors.white.withValues(alpha: 0.3),
            ),
          ),
          Center(
            child: Text(
              letter,
              style: TextStyle(
                height: 1,
                color: Colors.white,
                fontSize: size * 0.52,
                fontWeight: FontWeight.w800,
                letterSpacing: -1,
                shadows: [
                  Shadow(
                    color: const Color(0xFF1E1B4B).withValues(alpha: 0.35),
                    blurRadius: size * 0.12,
                    offset: Offset(0, size * 0.03),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.diameter,
    required this.color,
    this.borderColor,
  });

  final double diameter;
  final Color color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: borderColor == null
            ? null
            : Border.all(color: borderColor!, width: diameter * 0.04),
      ),
    );
  }
}
