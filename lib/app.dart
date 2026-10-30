import 'package:flutter/material.dart';

import 'core/app_info.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'data/growth_strategy_service.dart';
import 'data/product_link_service.dart';
import 'data/sourcing_service.dart';
import 'data/trend_service.dart';
import 'pages/shell/seller_shell.dart';
import 'pages/splash/splash_page.dart';

class MyApp extends StatelessWidget {
  const MyApp({
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
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeController.mode,
      builder: (context, mode, _) {
        return MaterialApp(
          title: AppInfo.name,
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: mode,
          home: SplashPage(
            next: SellerShell(
              themeController: themeController,
              trendSource: trendSource,
              growthSource: growthSource,
              sourcingSource: sourcingSource,
              productLinkSource: productLinkSource,
            ),
          ),
        );
      },
    );
  }
}
