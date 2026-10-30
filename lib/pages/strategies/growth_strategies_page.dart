import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../common/widgets/adaptive_grid.dart';
import '../../common/widgets/app_button.dart';
import '../../common/widgets/app_card.dart';
import '../../common/widgets/empty_state.dart';
import '../../common/widgets/section_header.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../data/growth_strategy_service.dart';
import '../../data/models/growth_strategy.dart';

/// Page showing e-commerce seller growth strategies searched from the web.
class GrowthStrategiesPage extends StatefulWidget {
  const GrowthStrategiesPage({super.key, required this.source});

  final GrowthStrategySource source;

  @override
  State<GrowthStrategiesPage> createState() => _GrowthStrategiesPageState();
}

class _GrowthStrategiesPageState extends State<GrowthStrategiesPage> {
  final TextEditingController _searchController = TextEditingController();
  final Map<String, GrowthStrategySnapshot> _cache = {};

  bool _loading = false;
  String? _error;
  GrowthStrategySnapshot? _snapshot;
  String _selectedCategory = 'All Ideas';
  String _currentQuery = '';
  int _requestId = 0;

  static const _presetCategories = [
    'All Ideas',
    'Advertising',
    'SEO & Listing',
    'Pricing',
    'Returns & RTO',
    'Fulfillment & Stock',
    'Reviews & Trust',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    final cacheKey = _currentQuery.toLowerCase().trim();
    final cached = _cache[cacheKey];
    if (!force && cached != null) {
      setState(() {
        _snapshot = cached;
        _error = null;
        _loading = false;
      });
      return;
    }

    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
      if (cached == null) _snapshot = null;
    });

    try {
      final snapshot = await widget.source.loadStrategies(_currentQuery);
      if (!mounted || requestId != _requestId) return;
      _cache[cacheKey] = snapshot;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _error = 'Could not load growth strategies. Check your connection.';
        _loading = false;
      });
    }
  }

  void _submitSearch(String raw) {
    final query = raw.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    _searchController.text = query;
    setState(() {
      _currentQuery = query;
      _selectedCategory = 'All Ideas';
    });
    _load();
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _currentQuery = '';
      _selectedCategory = 'All Ideas';
    });
    _load();
  }

  void _selectCategory(String category) {
    setState(() {
      _selectedCategory = category;
      _searchController.clear();
      _currentQuery = category == 'All Ideas' ? '' : category;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final allStrategies = snapshot?.strategies ?? const <GrowthStrategy>[];

    // Filter by category if a specific category is selected
    final filteredStrategies = _selectedCategory == 'All Ideas'
        ? allStrategies
        : allStrategies
              .where(
                (s) =>
                    s.category.toLowerCase() == _selectedCategory.toLowerCase(),
              )
              .toList();

    return ListView(
      padding: AppDimens.pagePadding(
        context,
      ).add(const EdgeInsets.only(top: AppDimens.lg, bottom: AppDimens.xxxl)),
      children: [
        _GrowthHeroCard(
          isConfigured: widget.source.isConfigured,
          loading: _loading,
          strategyCount: filteredStrategies.length,
          activeTopic: _currentQuery.isEmpty
              ? _selectedCategory
              : _currentQuery,
          sourceDescription: snapshot?.sourceDescription ?? 'Web search',
          onRefresh: () => _load(force: true),
        ),
        const SizedBox(height: AppDimens.lg),
        _StrategySearch(
          controller: _searchController,
          activeQuery: _currentQuery.isNotEmpty ? _currentQuery : null,
          onSubmitted: _submitSearch,
          onClear: _clearSearch,
        ),
        const SizedBox(height: AppDimens.lg),
        _TopicPicker(
          categories: _presetCategories,
          selected: _selectedCategory,
          onSelected: _selectCategory,
        ),
        if (_loading && snapshot != null) ...[
          const SizedBox(height: AppDimens.md),
          const LinearProgressIndicator(minHeight: 2),
        ],
        if (_error != null) ...[
          const SizedBox(height: AppDimens.lg),
          _ErrorCard(message: _error!, onRetry: () => _load(force: true)),
        ],
        if (_loading && snapshot == null) ...[
          const SizedBox(height: AppDimens.xl),
          const _SearchingCard(),
        ] else if (snapshot != null) ...[
          const SizedBox(height: AppDimens.xl),
          SectionHeader(
            title: _currentQuery.isNotEmpty
                ? 'Growth strategies for "$_currentQuery"'
                : 'Top growth strategies in $_selectedCategory',
            subtitle: filteredStrategies.isEmpty
                ? 'No specific ideas matched your query. Try a different topic.'
                : '${filteredStrategies.length} actionable strategy ideas from web guides and seller playbooks.',
          ),
          const SizedBox(height: AppDimens.lg),
          if (filteredStrategies.isEmpty)
            const EmptyState(
              icon: Icons.lightbulb_outline,
              title: 'No strategies found',
              message: 'Try searching for other growth topics like "PLA ads", "pricing", or "reviews".',
            )
          else
            AdaptiveGrid(
              minItemWidth: 320,
              children: [
                for (final strategy in filteredStrategies)
                  _StrategyCard(strategy: strategy),
              ],
            ),
        ],
      ],
    );
  }
}

class _GrowthHeroCard extends StatelessWidget {
  const _GrowthHeroCard({
    required this.isConfigured,
    required this.loading,
    required this.strategyCount,
    required this.activeTopic,
    required this.sourceDescription,
    required this.onRefresh,
  });

  final bool isConfigured;
  final bool loading;
  final int strategyCount;
  final String activeTopic;
  final String sourceDescription;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(AppDimens.xl),
      decoration: BoxDecoration(
        gradient: AppColors.hero,
        borderRadius: BorderRadius.circular(AppDimens.radiusLg),
        boxShadow: AppColors.heroShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Selling Growth Strategies',
            style: theme.textTheme.headlineMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              height: 1.15,
            ),
          ),
          const SizedBox(height: AppDimens.sm),
          Text(
            'Discover actionable selling tactics, listing optimizations, '
            'advertising playbooks, and pricing strategies searched from across the web.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.85),
            ),
          ),
          const SizedBox(height: AppDimens.lg),
          Wrap(
            spacing: AppDimens.sm,
            runSpacing: AppDimens.sm,
            children: [
              _HeroBadge(icon: Icons.lightbulb_outline, label: activeTopic),
              _HeroBadge(
                icon: isConfigured ? Icons.public : Icons.menu_book_outlined,
                label: sourceDescription,
              ),
              _HeroBadge(
                icon: Icons.auto_graph,
                label: '$strategyCount strategies',
              ),
            ],
          ),
          const SizedBox(height: AppDimens.xl),
          if (loading)
            Container(
              height: AppDimens.buttonHeight,
              padding: const EdgeInsets.symmetric(horizontal: AppDimens.lg),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(AppDimens.radiusPill),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: AppDimens.sm),
                  Text(
                    'Searching growth ideas...',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            )
          else
            AppButton(
              label: 'Refresh strategies',
              icon: Icons.refresh,
              onDark: true,
              onPressed: onRefresh,
            ),
        ],
      ),
    );
  }
}

class _HeroBadge extends StatelessWidget {
  const _HeroBadge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.sm,
        vertical: 5,
      ),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppDimens.radiusPill),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white.withValues(alpha: 0.9)),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _StrategySearch extends StatelessWidget {
  const _StrategySearch({
    required this.controller,
    required this.activeQuery,
    required this.onSubmitted,
    required this.onClear,
  });

  final TextEditingController controller;
  final String? activeQuery;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Search growth ideas',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppDimens.sm),
        TextField(
          controller: controller,
          textInputAction: TextInputAction.search,
          onSubmitted: onSubmitted,
          decoration: InputDecoration(
            hintText:
                'Try "reduce returns", "ad campaigns", or "festival sale"',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: IconButton(
              tooltip: 'Find strategies',
              onPressed: () => onSubmitted(controller.text),
              icon: const Icon(Icons.arrow_forward),
            ),
          ),
        ),
        if (activeQuery != null) ...[
          const SizedBox(height: AppDimens.sm),
          Row(
            children: [
              Icon(Icons.search, size: 16, color: scheme.primary),
              const SizedBox(width: AppDimens.xs),
              Expanded(
                child: Text(
                  'Showing results for "$activeQuery"',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton(onPressed: onClear, child: const Text('Clear')),
            ],
          ),
        ],
      ],
    );
  }
}

class _TopicPicker extends StatelessWidget {
  const _TopicPicker({
    required this.categories,
    required this.selected,
    required this.onSelected,
  });

  final List<String> categories;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Browse by growth pillar',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppDimens.sm),
        Wrap(
          spacing: AppDimens.sm,
          runSpacing: AppDimens.sm,
          children: [
            for (final category in categories)
              ChoiceChip(
                label: Text(category),
                selected: category.toLowerCase() == selected.toLowerCase(),
                showCheckmark: false,
                onSelected: (_) => onSelected(category),
                selectedColor: scheme.primary,
                labelStyle: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: category.toLowerCase() == selected.toLowerCase()
                      ? scheme.onPrimary
                      : scheme.onSurface,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _StrategyCard extends StatelessWidget {
  const _StrategyCard({required this.strategy});

  final GrowthStrategy strategy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Color categoryColor;
    switch (strategy.category) {
      case 'Advertising':
        categoryColor = AppColors.accent;
        break;
      case 'Pricing':
        categoryColor = AppColors.warning;
        break;
      case 'Returns & RTO':
        categoryColor = AppColors.danger;
        break;
      case 'Reviews & Trust':
        categoryColor = AppColors.success;
        break;
      default:
        categoryColor = scheme.primary;
    }

    return AppCard(
      padding: const EdgeInsets.all(AppDimens.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: categoryColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                ),
                child: Text(
                  strategy.category,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: categoryColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                  border: Border.all(
                    color: scheme.outline.withValues(alpha: 0.3),
                  ),
                ),
                child: Text(
                  strategy.impactLevel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 10.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppDimens.md),
          // Strategy Title (Clickable!)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Tooltip(
              message: 'Open web article',
              child: InkWell(
                onTap: () => _launchStrategyUrl(context, strategy.sourceUrl),
                borderRadius: BorderRadius.circular(AppDimens.radiusSm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        strategy.title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.open_in_new, size: 15, color: scheme.primary),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: AppDimens.sm),
          Text(
            strategy.description,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.9),
              height: 1.4,
            ),
          ),
          if (strategy.actionPoints.isNotEmpty) ...[
            const SizedBox(height: AppDimens.md),
            Container(
              padding: const EdgeInsets.all(AppDimens.sm),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(AppDimens.radiusSm),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final point in strategy.actionPoints) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2.5),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.check_circle_outline,
                            size: 14,
                            color: scheme.primary,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              point,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: AppDimens.md),
          const Divider(height: 1),
          const SizedBox(height: AppDimens.sm),
          Row(
            children: [
              Icon(Icons.language, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: AppDimens.xs),
              Expanded(
                child: Text(
                  strategy.sourceHost,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: InkWell(
                  onTap: () => _launchStrategyUrl(context, strategy.sourceUrl),
                  borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppDimens.sm,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Read web guide',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.primary,
                            fontWeight: FontWeight.w700,
                            fontSize: 11.5,
                          ),
                        ),
                        const SizedBox(width: 3),
                        Icon(
                          Icons.open_in_new,
                          size: 13,
                          color: scheme.primary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SearchingCard extends StatelessWidget {
  const _SearchingCard();

  @override
  Widget build(BuildContext context) {
    return AppCard(
      shadow: false,
      child: Column(
        children: [
          const SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
          const SizedBox(height: AppDimens.md),
          Text(
            'Searching top selling growth strategies from the web...',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppDimens.md),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(AppDimens.radiusSm),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 18, color: AppColors.danger),
          const SizedBox(width: AppDimens.sm),
          Expanded(child: Text(message, style: theme.textTheme.bodySmall)),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

Future<void> _launchStrategyUrl(BuildContext context, String url) async {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Invalid guide link.')));
    }
    return;
  }
  try {
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open web guide.')),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open web guide.')),
      );
    }
  }
}
