import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/theme/theme_controller.dart';
import 'data/growth_strategy_service.dart';
import 'data/product_link_service.dart';
import 'data/sourcing_service.dart';
import 'data/trend_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();

  runApp(
    MyApp(
      themeController: ThemeController(prefs),
      trendSource: WebTrendService(prefs),
      growthSource: WebGrowthStrategyService(prefs),
      sourcingSource: WebSourcingService(prefs),
      productLinkSource: WebProductLinkService(prefs: prefs),
    ),
  );
}
