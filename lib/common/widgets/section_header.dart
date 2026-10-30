import 'package:flutter/material.dart';

import '../../core/theme/app_dimens.dart';

/// Section title with an optional subtitle and an optional trailing action
/// (usually a `TextButton`).
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
  });

  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: textTheme.titleLarge),
        if (subtitle != null) ...[
          const SizedBox(height: AppDimens.xs),
          Text(subtitle!, style: textTheme.bodyMedium),
        ],
      ],
    );

    if (action == null) return heading;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 480) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading,
              const SizedBox(height: AppDimens.md),
              Align(alignment: Alignment.centerRight, child: action),
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: heading),
            const SizedBox(width: AppDimens.xl),
            action!,
          ],
        );
      },
    );
  }
}
