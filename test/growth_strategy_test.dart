import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/app.dart';
import 'package:flutter_app/core/theme/theme_controller.dart';
import 'package:flutter_app/data/growth_strategy_service.dart';
import 'package:flutter_app/data/models/growth_strategy.dart';
import 'package:flutter_app/data/trend_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('WebGrowthStrategyService', () {
    test(
      'returns curated strategies when no Serper key is configured',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final service = WebGrowthStrategyService(prefs);

        expect(service.isConfigured, isFalse);

        final snapshot = await service.loadStrategies('');
        expect(snapshot.strategies, isNotEmpty);
        expect(snapshot.strategies.length, greaterThanOrEqualTo(5));
        expect(
          snapshot.sourceDescription,
          contains('Curated E-Commerce Playbook'),
        );

        final titles = snapshot.strategies.map((s) => s.title).toList();
        expect(titles.any((t) => t.contains('Flipkart Assured')), isTrue);
        expect(titles.any((t) => t.contains('Product Listing Ads')), isTrue);
      },
    );

    test('filters curated strategies by topic query', () async {
      final prefs = await SharedPreferences.getInstance();
      final service = WebGrowthStrategyService(prefs);

      final returnStrategies = await service.loadStrategies('return');
      expect(returnStrategies.strategies, isNotEmpty);
      expect(
        returnStrategies.strategies.every(
          (s) =>
              s.title.toLowerCase().contains('return') ||
              s.description.toLowerCase().contains('return') ||
              s.category.toLowerCase().contains('return') ||
              s.actionPoints.any((ap) => ap.toLowerCase().contains('return')),
        ),
        isTrue,
      );
    });

    test('searches web through Serper when key is configured', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('seller.market.serper.v1', 'serper-test-key');

      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'organic': [
              {
                'title': '10 Proven Tactics to Boost Flipkart Seller Sales',
                'link': 'https://sellerguide.in/flipkart-sales-growth',
                'snippet': 'Learn how top sellers optimize Product Listing Ads, manage inventory, and maintain a 4+ star rating.',
                'sitelinks': [
                  {'title': 'Run Smart PLA Ads'},
                  {'title': 'Optimize Keyword Titles'},
                ],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final service = WebGrowthStrategyService(prefs, client: client);
      expect(service.isConfigured, isTrue);

      final snapshot = await service.loadStrategies('advertising');
      expect(requests, hasLength(1));
      expect(requests.first.url.toString(), 'https://google.serper.dev/search');
      expect(requests.first.headers['X-API-KEY'], 'serper-test-key');

      expect(snapshot.strategies, hasLength(1));
      final first = snapshot.strategies.first;
      expect(first.title, '10 Proven Tactics to Boost Flipkart Seller Sales');
      expect(first.sourceUrl, 'https://sellerguide.in/flipkart-sales-growth');
      expect(first.sourceHost, 'sellerguide.in');
      expect(first.actionPoints, contains('Run Smart PLA Ads'));
      expect(first.actionPoints, contains('Optimize Keyword Titles'));
    });
  });

  group('Growth Strategies Page Widget Tests', () {
    testWidgets('navigates to Growth Strategies tab in SellerShell', (
      tester,
    ) async {
      setScreenSize(tester, const Size(1000, 1600));
      final prefs = await SharedPreferences.getInstance();
      final fakeTrend = _FakeTrendSource();
      final fakeGrowth = _FakeGrowthSource();

      await tester.pumpWidget(
        MyApp(
          themeController: ThemeController(prefs),
          trendSource: fakeTrend,
          growthSource: fakeGrowth,
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      // Starts on Top Selling tab
      expect(find.text('Flipkart top selling'), findsOneWidget);
      expect(find.text('Top Selling'), findsOneWidget);
      expect(find.text('Growth'), findsOneWidget);

      // Tap on Growth Strategies tab in NavigationBar
      await tester.tap(find.text('Growth'));
      await tester.pumpAndSettle();

      // Now on Selling growth strategies page
      expect(find.text('Selling growth strategies'), findsOneWidget);
      expect(find.text('Search growth ideas'), findsOneWidget);
      expect(
        find.text('Qualify for Flipkart Assured Badge to Gain 3x Visibility'),
        findsOneWidget,
      );
      expect(find.text('Read web guide'), findsWidgets);
    });

    testWidgets('searches and filters growth strategy ideas', (tester) async {
      setScreenSize(tester, const Size(1000, 1600));
      final prefs = await SharedPreferences.getInstance();
      final fakeTrend = _FakeTrendSource();
      final fakeGrowth = _FakeGrowthSource();

      await tester.pumpWidget(
        MyApp(
          themeController: ThemeController(prefs),
          trendSource: fakeTrend,
          growthSource: fakeGrowth,
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      // Switch to Growth Strategies
      await tester.tap(find.text('Growth'));
      await tester.pumpAndSettle();

      // Enter search query in strategy search field
      await tester.enterText(find.byType(TextField).last, 'advertising');
      await tester.tap(find.byTooltip('Find strategies'));
      await tester.pumpAndSettle();

      expect(fakeGrowth.lastQuery, 'advertising');
      expect(
        find.text(
          'Run Product Listing Ads (PLA) on High-Search Intent Keywords',
        ),
        findsOneWidget,
      );
    });
  });
}

void setScreenSize(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _FakeTrendSource implements TrendSource {
  @override
  bool get isConfigured => false;
  @override
  String? get maskedKey => null;
  @override
  Future<void> connect(String apiKey) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<TrendSnapshot> load(dynamic target) async {
    return TrendSnapshot(
      suggestions: const [],
      sources: const [],
      fetchedAt: DateTime(2026, 10, 27),
    );
  }
}

class _FakeGrowthSource implements GrowthStrategySource {
  String lastQuery = '';

  @override
  bool get isConfigured => false;

  @override
  Future<GrowthStrategySnapshot> loadStrategies(String query) async {
    lastQuery = query;
    return GrowthStrategySnapshot(
      strategies: const [
        GrowthStrategy(
          title: 'Qualify for Flipkart Assured Badge to Gain 3x Visibility',
          description: 'Flipkart Assured products receive a prominent trust badge and higher search ranking.',
          category: 'Fulfillment & Stock',
          sourceUrl: 'https://seller.flipkart.com/grow',
          sourceTitle: 'seller.flipkart.com',
          impactLevel: 'High Impact',
          actionPoints: ['Maintain cancellation rate under 0.5%'],
        ),
        GrowthStrategy(
          title: 'Run Product Listing Ads (PLA) on High-Search Intent Keywords',
          description: 'Product Listing Ads put your products right at top search slots.',
          category: 'Advertising',
          sourceUrl: 'https://seller.flipkart.com/advertise',
          sourceTitle: 'seller.flipkart.com',
          impactLevel: 'Conversion Booster',
          actionPoints: ['Set competitive CPC bids on keywords'],
        ),
      ],
      query: query,
      sourceDescription: 'Curated E-Commerce Playbook',
      fetchedAt: DateTime(2026, 10, 27),
    );
  }
}
