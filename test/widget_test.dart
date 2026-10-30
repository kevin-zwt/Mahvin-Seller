import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/app.dart';
import 'package:flutter_app/core/theme/theme_controller.dart';
import 'package:flutter_app/data/models/flipkart_category.dart';
import 'package:flutter_app/data/models/trend_suggestion.dart';
import 'package:flutter_app/data/trend_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('loads products without an API key', (tester) async {
    setScreenSize(tester, const Size(900, 1200));
    final source = _FakeTrendSource();

    await pumpApp(tester, source);

    expect(find.text('Top selling on Flipkart'), findsOneWidget);
    expect(find.text('Public reader'), findsOneWidget);
    expect(find.text('Add Serper key'), findsOneWidget);
    expect(find.text('Connect Flipkart data'), findsNothing);
    expect(source.loadCalls, 1);
    expect(find.text('boAt Airdopes 311 Pro'), findsOneWidget);
    expect(find.text('Add product'), findsNothing);
    expect(find.text('Orders'), findsNothing);
  });

  testWidgets('shows Flipkart products returned by the service', (
    tester,
  ) async {
    setScreenSize(tester, const Size(1000, 1400));
    final source = _FakeTrendSource(configured: true, snapshots: [_snapshot()]);

    await pumpApp(tester, source);

    expect(source.loadCalls, 1);
    expect(find.text('Top selling on Flipkart'), findsOneWidget);
    expect(find.text('Top selling in Mobiles'), findsOneWidget);
    expect(find.text('boAt Airdopes 311 Pro'), findsOneWidget);
    expect(find.text('Noise ColorFit Pulse 4'), findsOneWidget);
    expect(
      find.text('₹1,299 \u00b7 MRP ₹2,999 \u00b7 57% off'),
      findsOneWidget,
    );
    expect(find.text('flipkart.com'), findsWidgets);
    expect(find.text('Flipkart page'), findsOneWidget);
    expect(find.text('Flipkart top selling products'), findsOneWidget);
    expect(find.byIcon(Icons.open_in_new), findsWidgets);
    expect(find.text('View on Flipkart'), findsWidgets);
    expect(find.text('Add product'), findsNothing);
    expect(find.text('Sourcing'), findsOneWidget);
  });

  testWidgets('loads a category on selection and reuses its cache', (
    tester,
  ) async {
    setScreenSize(tester, const Size(1000, 1400));
    final source = _FakeTrendSource(
      configured: true,
      snapshots: [
        _snapshot(),
        _snapshot(primaryName: 'Samsung Galaxy M15 5G'),
      ],
    );

    await pumpApp(tester, source);

    expect(source.loadCalls, 1);
    expect(find.text('boAt Airdopes 311 Pro'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Electronics'));
    await tester.pumpAndSettle();

    expect(source.loadCalls, 2);
    expect(source.requestedQueries.map((category) => category.key), [
      'mobiles',
      'electronics',
    ]);
    expect(find.text('Samsung Galaxy M15 5G'), findsOneWidget);
    expect(find.text('Top selling in Electronics'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Mobiles'));
    await tester.pumpAndSettle();

    expect(source.loadCalls, 2);
    expect(find.text('boAt Airdopes 311 Pro'), findsOneWidget);
    expect(find.text('Top selling in Mobiles'), findsOneWidget);
  });

  testWidgets('finds best selling matches for a typed product', (tester) async {
    setScreenSize(tester, const Size(1000, 1400));
    final source = _FakeTrendSource(
      configured: true,
      snapshots: [
        _snapshot(),
        _snapshot(primaryName: 'Cotton Kurti for Women'),
      ],
    );

    await pumpApp(tester, source);
    expect(source.loadCalls, 1);

    await tester.enterText(find.byType(TextField), 'cotton kurti');
    await tester.tap(find.byIcon(Icons.arrow_forward));
    await tester.pumpAndSettle();

    expect(source.loadCalls, 2);
    expect(source.requestedQueries.map((query) => query.key), [
      'mobiles',
      'search:cotton kurti',
    ]);
    expect(find.text('Top sellers for "cotton kurti"'), findsOneWidget);
    expect(find.text('Cotton Kurti for Women'), findsOneWidget);
    expect(find.text('Best seller'), findsOneWidget);

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(source.loadCalls, 2);
    expect(find.text('Top selling in Mobiles'), findsOneWidget);
    expect(find.text('boAt Airdopes 311 Pro'), findsOneWidget);
  });

  testWidgets('refreshes the Flipkart product list', (tester) async {
    setScreenSize(tester, const Size(1000, 1400));
    final source = _FakeTrendSource(
      configured: true,
      snapshots: [
        _snapshot(),
        _snapshot(primaryName: 'boAt Rockerz 450'),
      ],
    );

    await pumpApp(tester, source);
    expect(find.text('boAt Airdopes 311 Pro'), findsOneWidget);

    await tester.tap(find.text('Refresh products'));
    await tester.pumpAndSettle();

    expect(source.loadCalls, 2);
    expect(find.text('boAt Rockerz 450'), findsOneWidget);
    expect(find.text('boAt Airdopes 311 Pro'), findsNothing);
  });

  testWidgets('connects a key and loads products immediately', (tester) async {
    setScreenSize(tester, const Size(900, 1200));
    final source = _FakeTrendSource(snapshots: [_snapshot()]);

    await pumpApp(tester, source);
    expect(find.text('Add Serper key'), findsOneWidget);

    await tester.tap(find.text('Add Serper key'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'serper-test-1234',
    );
    await tester.tap(find.text('Save key'));
    await tester.pumpAndSettle();

    expect(source.isConfigured, isTrue);
    expect(source.loadCalls, 2);
    expect(find.text('boAt Airdopes 311 Pro'), findsOneWidget);
    expect(find.text('API key'), findsOneWidget);
  });

  testWidgets('shows an error with a retry action', (tester) async {
    setScreenSize(tester, const Size(900, 1200));
    final source = _FakeTrendSource(configured: true, throwError: true);

    await pumpApp(tester, source);

    expect(find.text('Flipkart is unavailable.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}

Future<void> pumpApp(WidgetTester tester, TrendSource source) async {
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    MyApp(themeController: ThemeController(prefs), trendSource: source),
  );
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

void setScreenSize(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

TrendSnapshot _snapshot({String primaryName = 'boAt Airdopes 311 Pro'}) {
  return TrendSnapshot(
    suggestions: [
      TrendSuggestion(
        name: primaryName,
        reason: '₹1,299 \u00b7 MRP ₹2,999 \u00b7 57% off',
        sourceTitle: 'Flipkart \u00b7 sorted by popularity',
        url: 'https://www.flipkart.com/boat-airdopes-311-pro/p/itmabc',
      ),
      const TrendSuggestion(
        name: 'Noise ColorFit Pulse 4',
        reason: '₹1,799 \u00b7 MRP ₹4,999 \u00b7 64% off',
        sourceTitle: 'Flipkart \u00b7 sorted by popularity',
        url: 'https://www.flipkart.com/noise-colorfit-pulse-4/p/itmdef',
      ),
    ],
    sources: const [
      TrendSourceLink(
        title: 'Flipkart top selling products',
        url: 'https://www.flipkart.com/search?q=mobile+phones&sort=popularity',
        snippet: '2 products loaded from Flipkart top selling search.',
      ),
    ],
    fetchedAt: DateTime(2026, 10, 27, 10, 30),
  );
}

class _FakeTrendSource implements TrendSource {
  _FakeTrendSource({
    this.configured = false,
    this.snapshots = const [],
    this.throwError = false,
  });

  bool configured;
  final List<TrendSnapshot> snapshots;
  final bool throwError;
  int loadCalls = 0;
  final List<FlipkartQuery> requestedQueries = [];

  @override
  bool get isConfigured => configured;

  @override
  String? get maskedKey => configured ? '\u2022\u2022\u2022\u20221234' : null;

  @override
  Future<void> connect(String apiKey) async {
    configured = true;
  }

  @override
  Future<void> disconnect() async {
    configured = false;
  }

  @override
  Future<TrendSnapshot> load(FlipkartQuery target) async {
    loadCalls++;
    requestedQueries.add(target);
    if (throwError) {
      throw const TrendException('Flipkart is unavailable.');
    }
    if (snapshots.isEmpty) {
      return _snapshot();
    }
    final index = loadCalls - 1;
    return snapshots[index < snapshots.length ? index : snapshots.length - 1];
  }
}
