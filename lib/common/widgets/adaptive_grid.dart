import 'package:flutter/material.dart';

import '../../core/theme/app_dimens.dart';

/// A responsive grid: stacks into 1, 2 or 3+ columns depending on available
/// width, without any per-page breakpoint math.
class AdaptiveGrid extends StatelessWidget {
  const AdaptiveGrid({
    super.key,
    required this.children,
    this.minItemWidth = 300,
    this.spacing = AppDimens.lg,
    this.runSpacing = AppDimens.lg,
  });

  final List<Widget> children;
  final double minItemWidth;
  final double spacing;
  final double runSpacing;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        var columns =
            ((constraints.maxWidth + spacing) / (minItemWidth + spacing))
                .floor();
        if (columns < 1) columns = 1;
        if (columns > children.length) columns = children.length;

        final itemWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: runSpacing,
          children: [
            for (final child in children)
              SizedBox(width: itemWidth, child: child),
          ],
        );
      },
    );
  }
}
