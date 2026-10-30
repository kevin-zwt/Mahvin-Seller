import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

enum AppButtonVariant { filled, tonal, outline }

/// The shared button used on every page.
///
/// [onDark] flips the colors so it stays readable on the gradient hero panel.
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.variant = AppButtonVariant.filled,
    this.onDark = false,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final AppButtonVariant variant;
  final bool onDark;

  /// Stretches the button to the full available width.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final button = _buildButton(context);

    if (!expand) return button;
    return SizedBox(width: double.infinity, child: button);
  }

  Widget _buildButton(BuildContext context) {
    final text = Text(label);
    final scheme = Theme.of(context).colorScheme;

    switch (variant) {
      case AppButtonVariant.filled:
        final style = onDark
            ? FilledButton.styleFrom(
                backgroundColor: AppColors.surface,
                foregroundColor: AppColors.accent,
              )
            : null;
        return icon == null
            ? FilledButton(onPressed: onPressed, style: style, child: text)
            : FilledButton.icon(
                onPressed: onPressed,
                style: style,
                icon: Icon(icon, size: 19),
                label: text,
              );

      case AppButtonVariant.tonal:
        final style = onDark
            ? FilledButton.styleFrom(
                backgroundColor: Colors.white.withValues(alpha: 0.16),
                foregroundColor: Colors.white,
              )
            : FilledButton.styleFrom(
                backgroundColor: scheme.secondaryContainer,
                foregroundColor: scheme.onSecondaryContainer,
              );
        return icon == null
            ? FilledButton(onPressed: onPressed, style: style, child: text)
            : FilledButton.icon(
                onPressed: onPressed,
                style: style,
                icon: Icon(icon, size: 19),
                label: text,
              );

      case AppButtonVariant.outline:
        final style = onDark
            ? OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.55)),
              )
            : null;
        return icon == null
            ? OutlinedButton(onPressed: onPressed, style: style, child: text)
            : OutlinedButton.icon(
                onPressed: onPressed,
                style: style,
                icon: Icon(icon, size: 19),
                label: text,
              );
    }
  }
}
