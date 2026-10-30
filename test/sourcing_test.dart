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
import 'package:flutter_app/data/models/sourcing_supplier.dart';
import 'package:flutter_app/data/sourcing_service.dart';
import 'package:flutter_app/data/trend_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('WebSourcingService', () {
    test('reads live IndiaMART and TradeIndia sellers without a key', () async {
      final prefs = await SharedPreferences.getInstance();
      final requests = <http.Request>[];
      final service = WebSourcingService(
        prefs,
        client: MockClient((request) async {
          requests.add(request);
          final url = request.url.toString();
          if (url.contains('dir.indiamart.com')) {
            return http.Response(
              _indiaMartSellerMarkdown,
              200,
              headers: const {'content-type': 'text/plain; charset=utf-8'},
            );
          }
          if (url.contains('tradeindia.com')) {
            return http.Response(
              _tradeIndiaSellerMarkdown,
              200,
              headers: const {'content-type': 'text/plain; charset=utf-8'},
            );
          }
          return http.Response('Not found', 404);
        }),
      );

      expect(service.isConfigured, isFalse);
      final snapshot = await service.searchSellers('cotton kurti');

      expect(requests, hasLength(2));
      expect(
        requests.every((request) => request.url.host == 'r.jina.ai'),
        isTrue,
      );
      expect(
        requests.any(
          (request) => request.url.toString().contains('dir.indiamart.com'),
        ),
        isTrue,
      );
      expect(
        requests.any(
          (request) => request.url.toString().contains('tradeindia.com'),
        ),
        isTrue,
      );

      expect(snapshot.suppliers, hasLength(3));
      expect(
        snapshot.sourceDescription,
        'Live IndiaMART & TradeIndia seller listings',
      );
      expect(
        snapshot.suppliers.map((supplier) => supplier.name),
        containsAll(['Bhadani Export Inc', 'SYASII DESIGNERS LLP']),
      );

      final indiaMart = snapshot.suppliers.firstWhere(
        (supplier) => supplier.platform == SourcingPlatform.indiaMart,
      );
      expect(indiaMart.productTitle, 'cotton kurti');
      expect(indiaMart.verifiedBadge, 'IndiaMART TrustSEAL');
      expect(indiaMart.snippet, contains('Business type: Retailer'));
      expect(indiaMart.url, 'https://dir.indiamart.com/company/10182571/');

      final tradeIndia = snapshot.suppliers.firstWhere(
        (supplier) => supplier.platform == SourcingPlatform.tradeIndia,
      );
      expect(tradeIndia.productTitle, 'Ladies Linen Cotton Kurti');
      expect(tradeIndia.location, 'Surat, Gujarat');
      expect(tradeIndia.priceQuote, '\u20b9175');
      expect(tradeIndia.moq, 'MOQ: 100 Piece/Pieces');
      expect(tradeIndia.verifiedBadge, 'TradeIndia TrustSEAL');
    });

    test('reads only the selected portal', () async {
      final prefs = await SharedPreferences.getInstance();
      final requests = <http.Request>[];
      final service = WebSourcingService(
        prefs,
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            _indiaMartSellerMarkdown,
            200,
            headers: const {'content-type': 'text/plain; charset=utf-8'},
          );
        }),
      );

      final snapshot = await service.searchSellers(
        'cotton kurti',
        platform: SourcingPlatform.indiaMart,
      );

      expect(requests, hasLength(1));
      expect(
        requests.single.url.toString(),
        contains('dir.indiamart.com/search.mp?ss=cotton+kurti'),
      );
      expect(
        snapshot.suppliers.every(
          (supplier) => supplier.platform == SourcingPlatform.indiaMart,
        ),
        isTrue,
      );
    });

    test('requires a product name', () async {
      final prefs = await SharedPreferences.getInstance();
      final service = WebSourcingService(prefs);

      await expectLater(
        service.searchSellers('   '),
        throwsA(
          isA<SourcingException>().having(
            (error) => error.message,
            'message',
            contains('Type a product name'),
          ),
        ),
      );
    });

    test('uses Serper when portal pages return no sellers', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('seller.market.serper.v1', 'serper-test-key');

      final requests = <http.Request>[];
      final service = WebSourcingService(
        prefs,
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.host == 'r.jina.ai') {
            return http.Response(
              'No seller listings',
              200,
              headers: const {'content-type': 'text/plain; charset=utf-8'},
            );
          }
          return http.Response(
            jsonEncode({
              'organic': [
                {
                  'title': 'Ananya Textiles - Cotton Kurti Sets from Jaipur',
                  'link': 'https://www.tradeindia.com/ananya-textiles-12345/',
                  'snippet':
                      'Wholesale supplier in Jaipur, Rajasthan. Rs 220/pc. '
                      'Minimum Order Quantity: 50 pieces.',
                },
              ],
            }),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      final snapshot = await service.searchSellers(
        'cotton kurti',
        platform: SourcingPlatform.tradeIndia,
      );

      expect(requests, hasLength(2));
      expect(requests.last.url.toString(), 'https://google.serper.dev/search');
      expect(requests.last.headers['X-API-KEY'], 'serper-test-key');
      expect(snapshot.sourceDescription, 'Live B2B web search (Serper)');
      expect(snapshot.suppliers.single.name, 'Ananya Textiles');
      expect(snapshot.suppliers.single.location, 'Jaipur, Rajasthan');
    });

    test('throws a clear error when no sellers are found', () async {
      final prefs = await SharedPreferences.getInstance();
      final service = WebSourcingService(
        prefs,
        client: MockClient((_) async => http.Response('No sellers', 200)),
      );

      await expectLater(
        service.searchSellers('cotton kurti'),
        throwsA(
          isA<SourcingException>().having(
            (error) => error.message,
            'message',
            contains('No seller listings were found'),
          ),
        ),
      );
    });

    test('reads IndiaMART contact person and public phone number', () async {
      final prefs = await SharedPreferences.getInstance();
      final requests = <http.Request>[];
      final service = WebSourcingService(
        prefs,
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            _indiaMartContactHtml,
            200,
            headers: const {'content-type': 'text/html; charset=utf-8'},
          );
        }),
      );

      const supplier = SourcingSupplier(
        name: 'Bhadani Export Inc',
        productTitle: 'Cotton Kurti',
        snippet: 'Wholesale supplier',
        url: 'https://dir.indiamart.com/company/10182571/?pos=1',
        platform: SourcingPlatform.indiaMart,
      );

      final enriched = await service.fetchContact(supplier);

      expect(
        requests.single.url.toString(),
        'https://r.jina.ai/https://www.indiamart.com/company/10182571/',
      );
      expect(requests.single.headers['X-Return-Format'], 'html');
      expect(enriched.contactPerson, 'Binay Gupta (Proprietor)');
      expect(enriched.contactPhone, '+91 8047683574');

      await service.fetchContact(supplier);
      expect(requests, hasLength(1));
    });

    test(
      'reads TradeIndia contact person and leaves gated phone empty',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final requests = <http.Request>[];
        final service = WebSourcingService(
          prefs,
          client: MockClient((request) async {
            requests.add(request);
            return http.Response(
              _tradeIndiaContactMarkdown,
              200,
              headers: const {'content-type': 'text/plain; charset=utf-8'},
            );
          }),
        );

        const supplier = SourcingSupplier(
          name: 'SYASII DESIGNERS LLP',
          productTitle: 'Ladies Linen Cotton Kurti',
          snippet: 'Manufacturer',
          url: 'https://www.tradeindia.com/syasii-designers-llp-11577722/',
          platform: SourcingPlatform.tradeIndia,
        );

        final enriched = await service.fetchContact(supplier);

        expect(requests.single.headers['X-Return-Format'], isNull);
        expect(enriched.contactPerson, 'Mr Vishal Ukani');
        expect(enriched.contactPhone, isEmpty);
      },
    );
  });

  group('Product Sourcing Page Widget Tests', () {
    testWidgets(
      'navigates to Sourcing tab in SellerShell and shows search box',
      (tester) async {
        setScreenSize(tester, const Size(1000, 1600));
        final prefs = await SharedPreferences.getInstance();
        final fakeTrend = _FakeTrendSource();
        final fakeGrowth = _FakeGrowthSource();
        final fakeSourcing = _FakeSourcingSource();

        await tester.pumpWidget(
          MyApp(
            themeController: ThemeController(prefs),
            trendSource: fakeTrend,
            growthSource: fakeGrowth,
            sourcingSource: fakeSourcing,
          ),
        );
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();

        // Check bottom navigation has all 3 destinations
        expect(find.text('Top Selling'), findsOneWidget);
        expect(find.text('Sourcing'), findsOneWidget);
        expect(find.text('Growth'), findsOneWidget);

        // Tap on Sourcing tab
        await tester.tap(find.text('Sourcing'));
        await tester.pumpAndSettle();

        // Verify Sourcing screen is displayed
        expect(find.text('Product sourcing (B2B)'), findsOneWidget);
        expect(find.text('B2B Product Sourcing'), findsOneWidget);
        expect(find.text('Search wholesale suppliers'), findsOneWidget);
        expect(find.text('Find sellers for any product'), findsOneWidget);
        expect(find.text('Contact on IndiaMART'), findsNothing);
        expect(find.text('Contact on TradeIndia'), findsNothing);
        expect(fakeSourcing.lastQuery, isEmpty);
      },
    );

    testWidgets('types product name to search suppliers', (tester) async {
      setScreenSize(tester, const Size(1000, 1600));
      final prefs = await SharedPreferences.getInstance();
      final fakeTrend = _FakeTrendSource();
      final fakeGrowth = _FakeGrowthSource();
      final fakeSourcing = _FakeSourcingSource();

      await tester.pumpWidget(
        MyApp(
          themeController: ThemeController(prefs),
          trendSource: fakeTrend,
          growthSource: fakeGrowth,
          sourcingSource: fakeSourcing,
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      // Switch to Sourcing
      await tester.tap(find.text('Sourcing'));
      await tester.pumpAndSettle();

      // Enter search in the sourcing type box
      final textFields = find.byType(TextField);
      expect(textFields, findsWidgets);
      await tester.enterText(textFields.last, 'smart watch');
      await tester.tap(find.byTooltip('Find sellers'));
      await tester.pumpAndSettle();

      expect(fakeSourcing.lastQuery, 'smart watch');
      expect(find.text('Apex Techno Solutions'), findsOneWidget);
      expect(find.text('Binay Gupta (Proprietor)'), findsOneWidget);
      expect(find.text('+91 8047683574'), findsOneWidget);
      expect(find.text('Mr Vishal Ukani (Director)'), findsOneWidget);
      expect(find.text('Phone number not published'), findsOneWidget);
    });
  });
}

const _indiaMartSellerMarkdown = r'''
# Cotton Kurti - IndiaMART

[![Image 1](https://5.imimg.com/data5/SELLER/Default/2024/4/409634810/ladies-cotton-kurti-250x250.png)

[Bhadani Export Inc](https://dir.indiamart.com/company/10182571/?&pos=1&kwd=cotton%20kurti&view=grid)

4.4(262 Reviews)

Verified Exporter

TrustSEAL

GST Verified

IEC Verified

Exporting Since:16+ yrs Est. Year:1982 Business Type:Retailer

Exports To:USA, Australia, Canada, Malaysia, Mauritius

[![Image 2](https://5.imimg.com/data5/SELLER/Default/2020/10/jaipuri-cotton-kurti-250x250.jpg)

[Dot Exports](https://dir.indiamart.com/company/335323/?&pos=2&kwd=cotton%20kurti&view=grid)

3.9(132 Reviews)

Verified Exporter

TrustSEAL

Exporting Since:26+ yrs Est. Year:1954 Business Type:Wholesaler

Exports To:USA, Malaysia, Australia, Canada, UK
''';

const _tradeIndiaSellerMarkdown = r'''
# Search Result - cotton kurti

[![Image 98: Ladies Linen Cotton Kurti](https://cpimg.tistatic.com/04042143/b/4/Ladies-Linen-Cotton-Kurti.jpg) ## Ladies Linen Cotton Kurti](https://www.tradeindia.com/products/ladies-linen-cotton-kurti-c4042143.html)

175.00 INR

MOQ - 100 Piece/Pieces

### [SYASII DESIGNERS LLP](https://www.tradeindia.com/syasii-designers-llp-11577722/)

10 Years

Business Type: Manufacturer | Distributor

 Surat

**Trusted**Seller

Call Now View Number Send Inquiry

Made in India
''';

const _indiaMartContactHtml = r'''
<!doctype html>
<html>
<body>
  <span class="footer__contact-name">Binay Gupta (Proprietor)</span>
  <script>
    var seller = {"pnsNumber":"+91-8047683574","companyName":"Bhadani Export Inc"};
  </script>
</body>
</html>
''';

const _tradeIndiaContactMarkdown = r'''
# SYASII DESIGNERS LLP

GST

24ADIFS2631J1Z2

Rating

4

Director

Mr Vishal Ukani

Address

C-4 To 8, PRAMUKH PARK IND. ESTATE, Surat, Gujarat, 394221, India

Call View Numbers
''';

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
  @override
  bool get isConfigured => false;
  @override
  Future<GrowthStrategySnapshot> loadStrategies(String query) async {
    return GrowthStrategySnapshot(
      strategies: const [],
      query: query,
      sourceDescription: 'Curated',
      fetchedAt: DateTime(2026, 10, 27),
    );
  }
}

class _FakeSourcingSource implements SourcingSource {
  String lastQuery = '';

  @override
  bool get isConfigured => false;

  @override
  Future<SourcingSupplier> fetchContact(SourcingSupplier supplier) async {
    if (supplier.platform == SourcingPlatform.indiaMart) {
      if (supplier.name.contains('Apex')) {
        return supplier.copyWith(
          contactPerson: 'Binay Gupta (Proprietor)',
          contactPhone: '+91 8047683574',
        );
      }
      return supplier.copyWith(
        contactPerson: 'Ramesh Shah (Owner)',
        contactPhone: '+91 98765 43210',
      );
    }
    return supplier.copyWith(contactPerson: 'Mr Vishal Ukani (Director)');
  }

  @override
  Future<SourcingSnapshot> searchSellers(
    String query, {
    SourcingPlatform platform = SourcingPlatform.all,
  }) async {
    lastQuery = query;
    return SourcingSnapshot(
      suppliers: const [
        SourcingSupplier(
          name: 'Vardhman Textile Mills',
          productTitle: 'Pure Cotton Printed Kurtis',
          snippet: 'Wholesale manufacturer in Surat.',
          url: 'https://www.indiamart.com/vardhman',
          platform: SourcingPlatform.indiaMart,
          location: 'Surat, Gujarat',
          priceQuote: '₹140 - ₹280 / piece',
          moq: 'MOQ: 25 pieces',
        ),
        SourcingSupplier(
          name: 'Royal Rajasthan Handlooms',
          productTitle: 'Cotton Anarkali Kurti Sets',
          snippet: 'Direct manufacturer in Jaipur.',
          url: 'https://www.tradeindia.com/royal-rajasthan',
          platform: SourcingPlatform.tradeIndia,
          location: 'Jaipur, Rajasthan',
          priceQuote: '₹220 - ₹450 / piece',
          moq: 'MOQ: 20 pieces',
        ),
        SourcingSupplier(
          name: 'Apex Techno Solutions',
          productTitle: 'Bluetooth Calling Smart Watch',
          snippet: 'OEM supplier of smart watches in Delhi.',
          url: 'https://www.indiamart.com/apex-techno',
          platform: SourcingPlatform.indiaMart,
          location: 'Delhi NCR',
          priceQuote: '₹550 - ₹1,100 / piece',
        ),
      ],
      query: query,
      platform: platform,
      sourceDescription: 'Verified Hubs',
      fetchedAt: DateTime(2026, 10, 28),
    );
  }
}
