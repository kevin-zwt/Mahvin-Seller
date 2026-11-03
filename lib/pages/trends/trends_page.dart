import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../common/widgets/adaptive_grid.dart';
import '../../common/widgets/app_button.dart';
import '../../common/widgets/app_card.dart';
import '../../common/widgets/empty_state.dart';
import '../../common/widgets/section_header.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../data/models/flipkart_category.dart';
import '../../data/models/trend_suggestion.dart';
import '../../data/trend_service.dart';

/// The app's only feature: load top selling products for a Flipkart category
/// or typed product search and show them inside the app.
class TrendsPage extends StatefulWidget {
  const TrendsPage({super.key, required this.source});

  final TrendSource source;

  @override
  State<TrendsPage> createState() => _TrendsPageState();
}

class _TrendsPageState extends State<TrendsPage> {
  bool _loading = false;
  String? _error;
  TrendSnapshot? _snapshot;
  FlipkartQuery _selected = flipkartCategories.first;
  FlipkartCategory _lastCategory = flipkartCategories.first;
  final Map<String, TrendSnapshot> _cache = {};
  final TextEditingController _searchController = TextEditingController();
  int _requestId = 0;

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
    final target = _selected;
    final cached = _cache[target.key];
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
      final snapshot = await widget.source.load(target);
      if (!mounted || requestId != _requestId) return;
      _cache[target.key] = snapshot;
      setState(() {
        if (_selected.key == target.key) _snapshot = snapshot;
        _loading = false;
      });
    } on TrendException catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _error =
            'Could not load Flipkart. Check your connection and try again.';
        _loading = false;
      });
    }
  }

  void _selectTarget(FlipkartQuery target) {
    if (target.key == _selected.key) return;
    _requestId++;
    final cached = _cache[target.key];
    setState(() {
      _selected = target;
      _snapshot = cached;
      _error = null;
      _loading = false;
    });
    if (cached == null) _load();
  }

  void _selectCategory(FlipkartCategory category) {
    _lastCategory = category;
    _searchController.clear();
    _selectTarget(category);
  }

  void _submitSearch(String raw) {
    final query = raw.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    _searchController.text = query;
    _selectTarget(FlipkartQuery.search(query));
  }

  void _clearSearch() {
    _searchController.clear();
    _selectTarget(_lastCategory);
  }

  Future<void> _manageKey() async {
    final changed = await showTrendKeyDialog(context, widget.source);
    if (!mounted || !changed) return;
    setState(() {});
    _cache.clear();
    _load(force: true);
  }

  @override
  Widget build(BuildContext context) {
    final configured = widget.source.isConfigured;
    final snapshot = _snapshot;
    final target = _selected;
    final suggestions = snapshot?.suggestions ?? const <TrendSuggestion>[];
    final updated = snapshot == null
        ? 'Not loaded yet'
        : 'Updated ${TimeOfDay.fromDateTime(snapshot.fetchedAt).format(context)}';

    return ListView(
      padding: AppDimens.pagePadding(
        context,
      ).add(const EdgeInsets.only(top: AppDimens.lg, bottom: AppDimens.xxxl)),
      children: [
        _HeroCard(
          configured: configured,
          loading: _loading,
          productCount: suggestions.length,
          categoryLabel: target.label,
          updated: updated,
          onRefresh: () => _load(force: true),
          onManageKey: _manageKey,
        ),
        const SizedBox(height: AppDimens.lg),
        _ProductSearch(
          controller: _searchController,
          activeQuery: target.isProductSearch ? target.label : null,
          onSubmitted: _submitSearch,
          onClear: _clearSearch,
        ),
        const SizedBox(height: AppDimens.lg),
        _CategoryPicker(
          categories: flipkartCategories,
          selected: target,
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
          _SearchingCard(categoryLabel: target.label),
        ] else if (snapshot != null) ...[
          const SizedBox(height: AppDimens.xl),
          SectionHeader(
            title: target.isProductSearch
                ? 'Top sellers for "${target.label}"'
                : 'Top selling in ${target.label}',
            subtitle: suggestions.isEmpty
                ? 'The Flipkart page loaded, but no product cards were found.'
                : '${suggestions.length} products from Flipkart\'s '
                      '"${target.query}" search, sorted by popularity.',
          ),
          const SizedBox(height: AppDimens.lg),
          if (suggestions.isEmpty)
            const EmptyState(
              icon: Icons.shopping_bag_outlined,
              title: 'No Flipkart products found',
              message:
                  'Flipkart may be temporarily blocking the request. Refresh '
                  'to try again.',
            )
          else
            AdaptiveGrid(
              minItemWidth: 320,
              children: [
                for (var i = 0; i < suggestions.length; i++)
                  _SuggestionCard(
                    rank: i + 1,
                    suggestion: suggestions[i],
                    bestSeller: i == 0,
                  ),
              ],
            ),
          if (snapshot.sources.isNotEmpty) ...[
            const SizedBox(height: AppDimens.xxl),
            SectionHeader(
              title: 'Flipkart page',
              subtitle:
                  'The source Flipkart page used for this list. Click any '
                  'product name or "View on Flipkart" to open the item.',
            ),
            const SizedBox(height: AppDimens.md),
            AppCard(
              padding: const EdgeInsets.symmetric(
                horizontal: AppDimens.lg,
                vertical: AppDimens.sm,
              ),
              shadow: false,
              child: Column(
                children: [
                  for (var i = 0; i < snapshot.sources.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    _SourceRow(source: snapshot.sources[i]),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: AppDimens.lg),
          const _ValidationNote(),
        ],
      ],
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.configured,
    required this.loading,
    required this.productCount,
    required this.categoryLabel,
    required this.updated,
    required this.onRefresh,
    required this.onManageKey,
  });

  final bool configured;
  final bool loading;
  final int productCount;
  final String categoryLabel;
  final String updated;
  final VoidCallback onRefresh;
  final VoidCallback onManageKey;

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
            'Top selling on Flipkart',
            style: theme.textTheme.headlineMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              height: 1.15,
            ),
          ),
          const SizedBox(height: AppDimens.sm),
          Text(
            'Pick a category or type any product to see the products '
            'shoppers are buying most, loaded live from Flipkart and shown '
            'inside the app.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.82),
            ),
          ),
          const SizedBox(height: AppDimens.lg),
          Wrap(
            spacing: AppDimens.sm,
            runSpacing: AppDimens.sm,
            children: [
              _HeroChip(
                icon: Icons.shopping_bag_outlined,
                label: categoryLabel,
              ),
              _HeroChip(
                icon: configured ? Icons.vpn_key_outlined : Icons.public,
                label: configured ? 'Serper' : 'Public reader',
              ),
              _HeroChip(
                icon: Icons.auto_awesome,
                label: productCount == 0
                    ? 'Ready to load'
                    : '$productCount products',
              ),
              _HeroChip(icon: Icons.schedule, label: updated),
            ],
          ),
          const SizedBox(height: AppDimens.xl),
          Wrap(
            spacing: AppDimens.sm,
            runSpacing: AppDimens.sm,
            children: [
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
                        'Loading Flipkart...',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                )
              else
                AppButton(
                  label: 'Refresh products',
                  icon: Icons.refresh,
                  onDark: true,
                  onPressed: onRefresh,
                ),
              AppButton(
                label: configured ? 'API key' : 'Add Serper key',
                icon: Icons.key_outlined,
                variant: AppButtonVariant.outline,
                onDark: true,
                onPressed: onManageKey,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroChip extends StatelessWidget {
  const _HeroChip({required this.icon, required this.label});

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
            constraints: const BoxConstraints(maxWidth: 220),
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

class _ProductSearch extends StatelessWidget {
  const _ProductSearch({
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
          'Search any product',
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
            hintText: 'Try "cotton kurti" or "steel water bottle"',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: IconButton(
              tooltip: 'Find best selling item',
              onPressed: () => onSubmitted(controller.text),
              icon: const Icon(Icons.arrow_forward),
            ),
          ),
        ),
        if (activeQuery != null) ...[
          const SizedBox(height: AppDimens.sm),
          Row(
            children: [
              Icon(
                Icons.local_fire_department_outlined,
                size: 16,
                color: scheme.primary,
              ),
              const SizedBox(width: AppDimens.xs),
              Expanded(
                child: Text(
                  'Showing best selling matches for "$activeQuery"',
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

class _CategoryPicker extends StatelessWidget {
  const _CategoryPicker({
    required this.categories,
    required this.selected,
    required this.onSelected,
  });

  final List<FlipkartCategory> categories;
  final FlipkartQuery selected;
  final ValueChanged<FlipkartCategory> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Shop by category',
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
                label: Text(category.label),
                selected: category.key == selected.key,
                showCheckmark: false,
                onSelected: (_) => onSelected(category),
                selectedColor: scheme.primary,
                labelStyle: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: category.key == selected.key
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

class _SearchingCard extends StatelessWidget {
  const _SearchingCard({required this.categoryLabel});

  final String categoryLabel;

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
            'Loading top selling $categoryLabel products from Flipkart...',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    required this.rank,
    required this.suggestion,
    required this.bestSeller,
  });

  final int rank;
  final TrendSuggestion suggestion;
  final bool bestSeller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return AppCard(
      padding: const EdgeInsets.all(AppDimens.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ProductImage(
                imageUrl: suggestion.imageUrl,
                rank: rank,
                onTap: () => _openProductLink(context, suggestion.url),
              ),
              const SizedBox(width: AppDimens.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (bestSeller || suggestion.mentions > 1) ...[
                      Wrap(
                        spacing: AppDimens.xs,
                        runSpacing: 4,
                        children: [
                          if (bestSeller)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppDimens.sm,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.warning.withValues(
                                  alpha: 0.12,
                                ),
                                borderRadius: BorderRadius.circular(
                                  AppDimens.radiusPill,
                                ),
                              ),
                              child: Text(
                                'Best seller',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: AppColors.warning,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 10.5,
                                ),
                              ),
                            ),
                          if (suggestion.mentions > 1)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppDimens.sm,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.success.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(
                                  AppDimens.radiusPill,
                                ),
                              ),
                              child: Text(
                                '${suggestion.mentions} sources',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: AppColors.success,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 10.5,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: AppDimens.xs),
                    ],
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Tooltip(
                        message: 'Open product on Flipkart',
                        child: InkWell(
                          onTap: () =>
                              _openProductLink(context, suggestion.url),
                          borderRadius: BorderRadius.circular(
                            AppDimens.radiusSm,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    suggestion.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.w700,
                                          height: 1.25,
                                          color: scheme.primary,
                                        ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.open_in_new,
                                  size: 15,
                                  color: scheme.primary,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppDimens.xs),
                    Text(
                      suggestion.reason,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppDimens.md),
          const Divider(height: 1),
          const SizedBox(height: AppDimens.sm),
          Row(
            children: [
              Icon(
                Icons.shopping_bag_outlined,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppDimens.xs),
              Expanded(
                child: Text(
                  suggestion.sourceHost.isNotEmpty
                      ? suggestion.sourceHost
                      : 'flipkart.com',
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
                  onTap: () => _openProductLink(context, suggestion.url),
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
                          'View on Flipkart',
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
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: InkWell(
                  onTap: () => _copyProductLink(context, suggestion.url),
                  borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppDimens.sm,
                      vertical: 4,
                    ),
                    child: Tooltip(
                      message: 'Copy link',
                      child: Icon(Icons.copy, size: 15, color: scheme.primary),
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

Future<void> _copyProductLink(BuildContext context, String url) async {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return;
  await Clipboard.setData(ClipboardData(text: trimmed));
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Product link copied.')));
  }
}

class _ProductImage extends StatelessWidget {
  const _ProductImage({
    required this.imageUrl,
    required this.rank,
    required this.onTap,
  });

  final String? imageUrl;
  final int rank;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final hasImage = imageUrl != null && imageUrl!.trim().isNotEmpty;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF1E293B)
                    : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(AppDimens.radiusSm),
                border: Border.all(color: scheme.outline),
              ),
              clipBehavior: Clip.antiAlias,
              child: hasImage
                  ? Image.network(
                      imageUrl!,
                      fit: BoxFit.contain,
                      width: 84,
                      height: 84,
                      loadingBuilder: (context, child, progress) {
                        if (progress == null) return child;
                        return const Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        );
                      },
                      errorBuilder: (_, _, _) => _fallbackIcon(scheme),
                    )
                  : _fallbackIcon(scheme),
            ),
            Positioned(
              top: -4,
              left: -4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: Text(
                  '#$rank',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 10,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fallbackIcon(ColorScheme scheme) {
    return Center(
      child: Icon(
        Icons.shopping_bag_outlined,
        size: 32,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
      ),
    );
  }
}

Future<void> _openProductLink(BuildContext context, String url) async {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Invalid product link.')));
    }
    return;
  }
  try {
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open Flipkart product page.')),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open Flipkart product page.')),
      );
    }
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.source});

  final TrendSourceLink source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppDimens.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.article_outlined,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppDimens.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  source.title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (source.snippet.isNotEmpty) ...[
                  const SizedBox(height: AppDimens.xs),
                  Text(
                    source.snippet,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: AppDimens.xs),
                Text(
                  source.sourceHost,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
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

class _ValidationNote extends StatelessWidget {
  const _ValidationNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(AppDimens.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(AppDimens.radiusSm),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 17,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppDimens.sm),
          Expanded(
            child: Text(
              'These are live Flipkart category search results sorted by '
              'popularity, not a guarantee of sales. Check demand, '
              'competition, and costs before buying stock.',
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }
}

Future<bool> showTrendKeyDialog(
  BuildContext context,
  TrendSource source,
) async {
  final changed = await showDialog<bool>(
    context: context,
    builder: (_) => _TrendKeyDialog(source: source),
  );
  return changed == true;
}

class _TrendKeyDialog extends StatefulWidget {
  const _TrendKeyDialog({required this.source});

  final TrendSource source;

  @override
  State<_TrendKeyDialog> createState() => _TrendKeyDialogState();
}

class _TrendKeyDialogState extends State<_TrendKeyDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.source.connect(_controller.text);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on TrendException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not save the key. Try again.';
        _busy = false;
      });
    }
  }

  Future<void> _remove() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    await widget.source.disconnect();
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final configured = widget.source.isConfigured;

    return AlertDialog(
      title: Text(
        configured ? 'Serper key connected' : 'Serper API key (optional)',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Products load automatically through a public Flipkart reader. '
              'Add a Serper key only if you want Serper to be tried first.',
              style: theme.textTheme.bodySmall,
            ),
            if (configured) ...[
              const SizedBox(height: AppDimens.md),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppDimens.md),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(AppDimens.radiusSm),
                ),
                child: Text(
                  'Saved key: ${widget.source.maskedKey ?? '••••'}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
            const SizedBox(height: AppDimens.lg),
            TextField(
              controller: _controller,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Serper API key',
                hintText: 'Paste your key',
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show key' : 'Hide key',
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure ? Icons.visibility_outlined : Icons.visibility_off,
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppDimens.sm),
            Text(
              'Create a free key at serper.dev if you want to use Serper. '
              'Reading a Flipkart page uses Serper credits. The key stays on '
              'this device.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppDimens.sm),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.danger,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (configured)
          TextButton(
            onPressed: _busy ? null : _remove,
            child: const Text('Disconnect'),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save key'),
        ),
      ],
    );
  }
}
