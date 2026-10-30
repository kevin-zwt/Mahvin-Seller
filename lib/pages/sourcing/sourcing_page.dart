import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../common/widgets/adaptive_grid.dart';
import '../../common/widgets/app_button.dart';
import '../../common/widgets/app_card.dart';
import '../../common/widgets/empty_state.dart';
import '../../common/widgets/section_header.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../data/models/sourcing_supplier.dart';
import '../../data/sourcing_service.dart';

/// Page for searching wholesale product suppliers from IndiaMART & TradeIndia.
class SourcingPage extends StatefulWidget {
  const SourcingPage({super.key, required this.source});

  final SourcingSource source;

  @override
  State<SourcingPage> createState() => _SourcingPageState();
}

class _SourcingPageState extends State<SourcingPage> {
  final TextEditingController _searchController = TextEditingController();
  final Map<String, SourcingSnapshot> _cache = {};

  bool _loading = false;
  bool _contactsLoading = false;
  String? _error;
  SourcingSnapshot? _snapshot;
  String _currentQuery = '';
  SourcingPlatform _selectedPlatform = SourcingPlatform.all;
  int _requestId = 0;

  static const _quickSuggestions = [
    'Cotton Kurti',
    'Smart Watch',
    'Steel Bottle',
    'Casual Shoes',
    'Bedsheets',
    'TWS Earbuds',
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    if (_currentQuery.isEmpty) {
      setState(() {
        _snapshot = null;
        _error = null;
        _loading = false;
        _contactsLoading = false;
      });
      return;
    }
    final cacheKey =
        '${_currentQuery.toLowerCase().trim()}_${_selectedPlatform.name}';
    final requestId = ++_requestId;
    final cached = _cache[cacheKey];
    if (!force && cached != null) {
      setState(() {
        _snapshot = cached;
        _error = null;
        _loading = false;
        _contactsLoading = false;
      });
      return;
    }

    setState(() {
      _loading = true;
      _contactsLoading = false;
      _error = null;
      if (cached == null) _snapshot = null;
    });

    try {
      final snapshot = await widget.source.searchSellers(
        _currentQuery,
        platform: _selectedPlatform,
      );
      if (!mounted || requestId != _requestId) return;
      _cache[cacheKey] = snapshot;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
        _contactsLoading = snapshot.suppliers.isNotEmpty;
      });
      if (snapshot.suppliers.isNotEmpty) {
        unawaited(_enrichContacts(snapshot, cacheKey, requestId));
      }
    } on SourcingException catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _error = error.message;
        _loading = false;
        _contactsLoading = false;
      });
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _error =
            'Could not load sellers from IndiaMART or TradeIndia. '
            'Check your connection and try again.';
        _loading = false;
        _contactsLoading = false;
      });
    }
  }

  Future<void> _enrichContacts(
    SourcingSnapshot snapshot,
    String cacheKey,
    int requestId,
  ) async {
    final pending = [...snapshot.suppliers];
    final updates = <String, SourcingSupplier>{};

    Future<void> worker() async {
      while (pending.isNotEmpty) {
        if (!mounted || requestId != _requestId) return;
        final supplier = pending.removeAt(0);
        SourcingSupplier enriched;
        try {
          enriched = await widget.source.fetchContact(supplier);
        } catch (_) {
          enriched = supplier;
        }
        if (!mounted || requestId != _requestId) return;
        updates[supplier.url] = enriched;
        setState(() {
          final current = _snapshot;
          if (current == null) return;
          _snapshot = current.copyWith(
            suppliers: [
              for (final item in current.suppliers) updates[item.url] ?? item,
            ],
          );
          _cache[cacheKey] = _snapshot!;
        });
      }
    }

    await Future.wait([for (var i = 0; i < 3; i++) worker()]);
    if (!mounted || requestId != _requestId) return;
    if (_contactsLoading) {
      setState(() => _contactsLoading = false);
    }
  }

  void _submitSearch(String raw) {
    final query = raw.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    _searchController.text = query;
    setState(() {
      _currentQuery = query;
    });
    _load();
  }

  void _clearSearch() {
    _requestId++;
    _searchController.clear();
    setState(() {
      _currentQuery = '';
      _snapshot = null;
      _error = null;
      _loading = false;
      _contactsLoading = false;
    });
  }

  void _selectPlatform(SourcingPlatform platform) {
    if (_selectedPlatform == platform) return;
    setState(() {
      _selectedPlatform = platform;
    });
    if (_currentQuery.isNotEmpty) _load();
  }

  void _openExternalPortalSearch(String platformDomain) {
    final q = _currentQuery.isEmpty ? 'wholesale suppliers' : _currentQuery;
    final encoded = Uri.encodeComponent(q);
    final url = platformDomain.contains('indiamart')
        ? 'https://dir.indiamart.com/search.mp?ss=$encoded'
        : 'https://www.tradeindia.com/search.html?keyword=$encoded';
    _launchSupplierUrl(context, url);
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final suppliers = snapshot?.suppliers ?? const <SourcingSupplier>[];

    return ListView(
      padding: AppDimens.pagePadding(
        context,
      ).add(const EdgeInsets.only(top: AppDimens.lg, bottom: AppDimens.xxxl)),
      children: [
        _SourcingHeroCard(
          isConfigured: widget.source.isConfigured,
          loading: _loading,
          supplierCount: suppliers.length,
          activeQuery: _currentQuery.isEmpty
              ? 'Type a product to search'
              : _currentQuery,
          platformLabel: _selectedPlatform.label,
          sourceDescription:
              snapshot?.sourceDescription ??
              'Live IndiaMART & TradeIndia pages',
          onRefresh: () => _load(force: true),
        ),
        const SizedBox(height: AppDimens.lg),
        _SourcingSearchBox(
          controller: _searchController,
          activeQuery: _currentQuery.isNotEmpty ? _currentQuery : null,
          onSubmitted: _submitSearch,
          onClear: _clearSearch,
        ),
        const SizedBox(height: AppDimens.sm),
        _QuickSuggestionsBar(
          suggestions: _quickSuggestions,
          onSelect: (item) {
            _searchController.text = item;
            _submitSearch(item);
          },
        ),
        const SizedBox(height: AppDimens.lg),
        _PlatformPicker(
          selected: _selectedPlatform,
          onSelected: _selectPlatform,
        ),
        const SizedBox(height: AppDimens.md),
        _ExternalPortalShortcuts(
          query: _currentQuery,
          onOpenIndiaMart: () => _openExternalPortalSearch('indiamart.com'),
          onOpenTradeIndia: () => _openExternalPortalSearch('tradeindia.com'),
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
          _SearchingCard(query: _currentQuery),
        ] else if (snapshot != null) ...[
          const SizedBox(height: AppDimens.xl),
          SectionHeader(
            title: 'Sellers for "$_currentQuery"',
            subtitle: suppliers.isEmpty
                ? 'No direct sellers found for this term. Try the direct portal search buttons above.'
                : '${suppliers.length} sellers from ${_selectedPlatform.label}, '
                      'loaded from IndiaMART and TradeIndia search pages.',
          ),
          if (_contactsLoading) ...[
            const SizedBox(height: AppDimens.sm),
            Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: AppDimens.xs),
                Text(
                  'Loading public contact names and numbers...',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppDimens.lg),
          if (suppliers.isEmpty)
            const EmptyState(
              icon: Icons.inventory_2_outlined,
              title: 'No sellers found',
              message: 'Try searching with a broader product name or click the IndiaMART / TradeIndia direct search buttons above.',
            )
          else
            AdaptiveGrid(
              minItemWidth: 320,
              children: [
                for (final supplier in suppliers)
                  _SupplierCard(supplier: supplier),
              ],
            ),
        ] else if (!_loading && _error == null) ...[
          const SizedBox(height: AppDimens.xl),
          const _SourcingStartCard(),
        ],
      ],
    );
  }
}

class _SourcingHeroCard extends StatelessWidget {
  const _SourcingHeroCard({
    required this.isConfigured,
    required this.loading,
    required this.supplierCount,
    required this.activeQuery,
    required this.platformLabel,
    required this.sourceDescription,
    required this.onRefresh,
  });

  final bool isConfigured;
  final bool loading;
  final int supplierCount;
  final String activeQuery;
  final String platformLabel;
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
            'B2B Product Sourcing',
            style: theme.textTheme.headlineMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              height: 1.15,
            ),
          ),
          const SizedBox(height: AppDimens.sm),
          Text(
            'Type any product name to find live wholesale manufacturers, '
            'suppliers, and bulk price quotes from IndiaMART & TradeIndia.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.85),
            ),
          ),
          const SizedBox(height: AppDimens.lg),
          Wrap(
            spacing: AppDimens.sm,
            runSpacing: AppDimens.sm,
            children: [
              _HeroBadge(icon: Icons.inventory_2_outlined, label: activeQuery),
              _HeroBadge(icon: Icons.storefront_outlined, label: platformLabel),
              _HeroBadge(
                icon: isConfigured ? Icons.public : Icons.verified_outlined,
                label: sourceDescription,
              ),
              _HeroBadge(
                icon: Icons.people_outline,
                label: '$supplierCount suppliers',
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
                    'Searching suppliers...',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            )
          else
            AppButton(
              label: 'Refresh suppliers',
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

class _SourcingSearchBox extends StatelessWidget {
  const _SourcingSearchBox({
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
          'Search wholesale suppliers',
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
            hintText: 'Type any product (e.g. "cotton kurti", "steel bottle")',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: IconButton(
              tooltip: 'Find sellers',
              onPressed: () => onSubmitted(controller.text),
              icon: const Icon(Icons.arrow_forward),
            ),
          ),
        ),
        if (activeQuery != null) ...[
          const SizedBox(height: AppDimens.sm),
          Row(
            children: [
              Icon(Icons.inventory_2_outlined, size: 16, color: scheme.primary),
              const SizedBox(width: AppDimens.xs),
              Expanded(
                child: Text(
                  'Showing sellers for "$activeQuery"',
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

class _QuickSuggestionsBar extends StatelessWidget {
  const _QuickSuggestionsBar({
    required this.suggestions,
    required this.onSelect,
  });

  final List<String> suggestions;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Wrap(
      spacing: AppDimens.xs,
      runSpacing: 4,
      children: [
        Text(
          'Popular:',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
            fontSize: 11,
          ),
        ),
        const SizedBox(width: 2),
        for (final item in suggestions)
          InkWell(
            onTap: () => onSelect(item),
            borderRadius: BorderRadius.circular(AppDimens.radiusPill),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                border: Border.all(
                  color: scheme.outline.withValues(alpha: 0.3),
                ),
              ),
              child: Text(
                item,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _PlatformPicker extends StatelessWidget {
  const _PlatformPicker({required this.selected, required this.onSelected});

  final SourcingPlatform selected;
  final ValueChanged<SourcingPlatform> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      children: [
        for (final platform in SourcingPlatform.values) ...[
          Padding(
            padding: const EdgeInsets.only(right: AppDimens.sm),
            child: ChoiceChip(
              label: Text(platform.label),
              selected: selected == platform,
              showCheckmark: false,
              onSelected: (_) => onSelected(platform),
              selectedColor: scheme.primary,
              labelStyle: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: selected == platform
                    ? scheme.onPrimary
                    : scheme.onSurface,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ExternalPortalShortcuts extends StatelessWidget {
  const _ExternalPortalShortcuts({
    required this.query,
    required this.onOpenIndiaMart,
    required this.onOpenTradeIndia,
  });

  final String query;
  final VoidCallback onOpenIndiaMart;
  final VoidCallback onOpenTradeIndia;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(AppDimens.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(AppDimens.radiusSm),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.open_in_browser, size: 18, color: scheme.primary),
          const SizedBox(width: AppDimens.sm),
          Expanded(
            child: Text(
              'Direct search on B2B portals:',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
          OutlinedButton.icon(
            onPressed: onOpenIndiaMart,
            icon: const Icon(Icons.open_in_new, size: 12),
            label: const Text('IndiaMART', style: TextStyle(fontSize: 11)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
            ),
          ),
          const SizedBox(width: AppDimens.sm),
          OutlinedButton.icon(
            onPressed: onOpenTradeIndia,
            icon: const Icon(Icons.open_in_new, size: 12),
            label: const Text('TradeIndia', style: TextStyle(fontSize: 11)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
            ),
          ),
        ],
      ),
    );
  }
}

class _SupplierCard extends StatelessWidget {
  const _SupplierCard({required this.supplier});

  final SourcingSupplier supplier;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final isIndiaMart = supplier.platform == SourcingPlatform.indiaMart;
    final platformColor = isIndiaMart
        ? const Color(0xFF0F766E)
        : const Color(0xFFC2410C);

    return AppCard(
      padding: const EdgeInsets.all(AppDimens.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppDimens.xs,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: platformColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.storefront, size: 12, color: platformColor),
                    const SizedBox(width: 4),
                    Text(
                      supplier.platform.label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: platformColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.success.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                ),
                child: Text(
                  supplier.verifiedBadge,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.success,
                    fontWeight: FontWeight.w700,
                    fontSize: 10,
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.location_on_outlined,
                    size: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    supplier.location,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AppDimens.md),
          // Supplier / Company Name (Clickable)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Tooltip(
              message: 'View supplier on ${supplier.platform.label}',
              child: InkWell(
                onTap: () => _launchSupplierUrl(context, supplier.url),
                borderRadius: BorderRadius.circular(AppDimens.radiusSm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        supplier.name,
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
          const SizedBox(height: 4),
          Text(
            supplier.productTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          if (supplier.hasContact) ...[
            const SizedBox(height: AppDimens.sm),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: AppDimens.sm,
                vertical: AppDimens.xs,
              ),
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(AppDimens.radiusSm),
                border: Border.all(
                  color: AppColors.success.withValues(alpha: 0.2),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (supplier.contactPerson.isNotEmpty)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.person_outline,
                          size: 15,
                          color: AppColors.success,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            supplier.contactPerson,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  if (supplier.contactPhone.isNotEmpty)
                    Row(
                      children: [
                        const Icon(
                          Icons.call_outlined,
                          size: 14,
                          color: AppColors.success,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            supplier.contactPhone,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                      ],
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(top: 2, left: 20),
                      child: Text(
                        'Phone number not published',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontSize: 10.5,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (supplier.priceQuote.isNotEmpty || supplier.moq.isNotEmpty) ...[
            const SizedBox(height: AppDimens.sm),
            Wrap(
              spacing: AppDimens.sm,
              runSpacing: 4,
              children: [
                if (supplier.priceQuote.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppDimens.radiusSm),
                    ),
                    child: Text(
                      supplier.priceQuote,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.warning,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                  ),
                if (supplier.moq.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withValues(
                        alpha: 0.4,
                      ),
                      borderRadius: BorderRadius.circular(AppDimens.radiusSm),
                      border: Border.all(
                        color: scheme.outline.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Text(
                      supplier.moq,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: AppDimens.sm),
          Text(
            supplier.snippet,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.88),
              height: 1.35,
            ),
          ),
          const SizedBox(height: AppDimens.md),
          const Divider(height: 1),
          const SizedBox(height: AppDimens.sm),
          Row(
            children: [
              Icon(Icons.language, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: AppDimens.xs),
              Expanded(
                child: Text(
                  supplier.sourceHost,
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
                  onTap: () => _launchSupplierUrl(context, supplier.url),
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
                          'Contact on ${supplier.platform.label}',
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

class _SourcingStartCard extends StatelessWidget {
  const _SourcingStartCard();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.storefront_outlined,
      title: 'Find sellers for any product',
      message:
          'Type a product above to search live IndiaMART and TradeIndia '
          'seller listings, including company name, city, price, and MOQ.',
    );
  }
}

class _SearchingCard extends StatelessWidget {
  const _SearchingCard({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final title = query.isEmpty ? 'wholesale suppliers' : query;
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
            'Searching $title suppliers from IndiaMART & TradeIndia...',
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

Future<void> _launchSupplierUrl(BuildContext context, String url) async {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Invalid supplier link.')));
    }
    return;
  }
  try {
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open supplier page.')),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open supplier page.')),
      );
    }
  }
}
