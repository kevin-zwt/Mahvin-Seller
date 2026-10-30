import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../common/widgets/app_logo.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/theme_controller.dart';
import '../../data/growth_strategy_service.dart';
import '../../data/product_link_service.dart';
import '../../data/sourcing_service.dart';
import '../../data/trend_service.dart';
import '../product_data/product_data_page.dart';
import '../sourcing/sourcing_page.dart';
import '../strategies/growth_strategies_page.dart';
import '../trends/trends_page.dart';

/// App shell with navigation between Top Selling, Product Sourcing,
/// Growth Strategies, and Product Link Analyzer.
class SellerShell extends StatefulWidget {
  const SellerShell({
    super.key,
    required this.themeController,
    required this.trendSource,
    this.growthSource,
    this.sourcingSource,
    this.productLinkSource,
  });

  final ThemeController themeController;
  final TrendSource trendSource;
  final GrowthStrategySource? growthSource;
  final SourcingSource? sourcingSource;
  final ProductLinkSource? productLinkSource;

  @override
  State<SellerShell> createState() => _SellerShellState();
}

class _SellerShellState extends State<SellerShell> {
  int _currentIndex = 0;
  GrowthStrategySource? _growthSource;
  SourcingSource? _sourcingSource;
  late ProductLinkSource _productLinkSource;

  @override
  void initState() {
    super.initState();
    _growthSource = widget.growthSource;
    _sourcingSource = widget.sourcingSource;
    _productLinkSource = widget.productLinkSource ?? WebProductLinkService();
    if (_growthSource == null ||
        _sourcingSource == null ||
        widget.productLinkSource == null) {
      SharedPreferences.getInstance().then((prefs) {
        if (mounted) {
          setState(() {
            _growthSource ??= WebGrowthStrategyService(prefs);
            _sourcingSource ??= WebSourcingService(prefs);
            if (widget.productLinkSource == null) {
              _productLinkSource = WebProductLinkService(prefs: prefs);
            }
          });
        }
      });
    }
  }

  @override
  void didUpdateWidget(SellerShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.growthSource != oldWidget.growthSource) {
      _growthSource = widget.growthSource;
    }
    if (widget.sourcingSource != oldWidget.sourcingSource) {
      _sourcingSource = widget.sourcingSource;
    }
    if (widget.productLinkSource != oldWidget.productLinkSource) {
      _productLinkSource = widget.productLinkSource ?? WebProductLinkService();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const AppLogo(size: 30),
            const SizedBox(width: AppDimens.sm),
            Expanded(
              child: Text(
                switch (_currentIndex) {
                  0 => 'Flipkart top selling',
                  1 => 'Product sourcing (B2B)',
                  2 => 'Selling growth strategies',
                  _ => 'Product link analyzer',
                },
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: isDark ? 'Switch to light mode' : 'Switch to dark mode',
            onPressed: () => widget.themeController.toggle(),
            icon: Icon(
              isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            ),
          ),
          const SizedBox(width: AppDimens.sm),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppDimens.contentMaxWidth,
            ),
            child: IndexedStack(
              index: _currentIndex,
              children: [
                TrendsPage(source: widget.trendSource),
                if (_sourcingSource != null)
                  SourcingPage(source: _sourcingSource!)
                else
                  const Center(child: CircularProgressIndicator()),
                if (_growthSource != null)
                  GrowthStrategiesPage(source: _growthSource!)
                else
                  const Center(child: CircularProgressIndicator()),
                ProductDataPage(source: _productLinkSource),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) => setState(() => _currentIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.trending_up_outlined),
            selectedIcon: Icon(Icons.trending_up),
            label: 'Top Selling',
          ),
          NavigationDestination(
            icon: Icon(Icons.inventory_2_outlined),
            selectedIcon: Icon(Icons.inventory_2),
            label: 'Sourcing',
          ),
          NavigationDestination(
            icon: Icon(Icons.lightbulb_outline),
            selectedIcon: Icon(Icons.lightbulb),
            label: 'Growth',
          ),
          NavigationDestination(
            icon: Icon(Icons.manage_search_outlined),
            selectedIcon: Icon(Icons.manage_search),
            label: 'Product Data',
          ),
        ],
      ),
    );
  }
}
