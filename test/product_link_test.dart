import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/app.dart';
import 'package:flutter_app/core/theme/theme_controller.dart';
import 'package:flutter_app/data/models/flipkart_category.dart';
import 'package:flutter_app/data/models/product_link_data.dart';
import 'package:flutter_app/data/models/trend_suggestion.dart';
import 'package:flutter_app/data/product_link_service.dart';
import 'package:flutter_app/data/trend_service.dart';
import 'package:flutter_app/pages/product_data/product_data_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Product link service', () {
    test(
      'uses the og:image from Serper metadata when markdown has no images',
      () {
        final data = parseProductMarkdown(
          '# VeBNoR Solid Men Polo Neck Light Green T-Shirt\n\nSolid polo.',
          'https://www.flipkart.com/x/p/itm1',
          metadata: {
            'title': 'VeBNoR Solid Men Polo Neck Light Green T-Shirt',
            'og:image': 'https://rukminim2.flixcart.com/image/300/300/xif0q/t-shirt/m/v/a/s-ts125-vebnor-original-imahmc2zskmncqxp.jpeg',
          },
          fetchedAt: DateTime(2026),
        );
        expect(data.photos, hasLength(1));
        expect(
          data.photos.first.url,
          'https://rukminim2.flixcart.com/image/832/832/xif0q/t-shirt/m/v/a/s-ts125-vebnor-original-imahmc2zskmncqxp.jpeg',
        );
      },
    );

    test('normalizes share text and bare host links', () {
      expect(
        normalizeProductLink(
          'Look at this: https://www.flipkart.com/item/p/123?pid=ABC. ',
        ),
        'https://www.flipkart.com/item/p/123?pid=ABC',
      );
      expect(
        normalizeProductLink('www.amazon.in/dp/B0ABC123'),
        'https://www.amazon.in/dp/B0ABC123',
      );
    });

    test('rejects links that are not product URLs', () {
      expect(
        () => normalizeProductLink('not a link'),
        throwsA(
          isA<ProductLinkException>().having(
            (error) => error.message,
            'message',
            contains('does not look like a product link'),
          ),
        ),
      );
    });

    test('parses JSON-LD, OpenGraph, photos, features and specs', () {
      final data = parseProductHtml(
        _productHtml,
        'https://www.demo-store.com/products/noise-buds-x',
        fetchedAt: DateTime(2026, 10, 29),
      );

      expect(data.title, 'Noise Buds X');
      expect(data.siteName, 'Demo Store');
      expect(data.sourceHost, 'demo-store.com');
      expect(data.brand, 'Noise');
      expect(data.category, 'Audio');
      expect(data.price, '\u20b91,299');
      expect(data.mrp, '\u20b91,999');
      expect(data.discount, '35% off');
      expect(data.rating, '4.3');
      expect(data.reviewCount, '1,200');
      expect(data.availability, 'In stock');
      expect(data.seller, 'Demo Seller');
      expect(data.sku, 'SKU123');
      expect(data.description, contains('wireless earbuds'));
      expect(data.keyFeatures, hasLength(3));
      expect(data.keyFeatures.first, contains('40 hours'));
      expect(data.keywords, contains('wireless earbuds'));
      expect(data.keywords, contains('noise'));
      expect(data.photos, hasLength(3));
      expect(data.photos.every((photo) => !photo.url.contains('logo')), isTrue);
      expect(
        data.specs.map((spec) => spec.label),
        containsAll(['Battery', 'Colour', 'Warranty']),
      );
      expect(data.fetchedAt, DateTime(2026, 10, 29));
    });

    test('deduplicates resized photos and keeps the largest version', () {
      final data = parseProductHtml('''
        <html>
        <head><meta property="og:title" content="Demo Product"></head>
        <body>
          <img src="https://rukminim2.flixcart.com/image/40/40/abc/product.jpeg">
          <img src="https://rukminim2.flixcart.com/image/1600/2140/abc/product.jpeg">
          <img src="https://m.media-amazon.com/images/I/61L1ItFgFHL._SL500_.jpg">
          <img src="https://m.media-amazon.com/images/I/61L1ItFgFHL._SL1200_.jpg">
        </body>
        </html>
        ''', 'https://www.flipkart.com/item/p/1');

      expect(data.photos, hasLength(2));
      expect(
        data.photos.map((photo) => photo.url),
        contains(contains('/1600/2140/')),
      );
      expect(
        data.photos.map((photo) => photo.url),
        contains(contains('_SL1200_')),
      );
    });

    test('finds gallery images embedded in page JSON', () {
      final data = parseProductHtml(r'''
        <html>
        <head><title>Demo Product</title></head>
        <body>
          <script>
            window.__STATE__ = {
              "images": [
                "https:\/\/rukminim2.flixcart.com\/image\/480\/640\/abc\/product.jpeg",
                "https:\/\/rukminim2.flixcart.com\/image\/960\/1280\/abc\/product.jpeg",
                "https:\/\/m.media-amazon.com\/images\/I\/61L1ItFgFHL._SL1200_.jpg"
              ]
            };
          </script>
        </body>
        </html>
        ''', 'https://www.demo-store.com/products/demo');

      expect(data.photos, hasLength(2));
      expect(
        data.photos.map((photo) => photo.url),
        contains(contains('/960/1280/')),
      );
      expect(
        data.photos.map((photo) => photo.url),
        contains(contains('61L1ItFgFHL')),
      );
    });

    test('loads through the public reader and sends HTML format', () async {
      final requests = <http.Request>[];
      final service = WebProductLinkService(
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            _productHtml,
            200,
            headers: const {'content-type': 'text/html; charset=utf-8'},
          );
        }),
        clock: () => DateTime(2026, 10, 29),
      );

      final data = await service.load(
        'https://www.demo-store.com/products/noise-buds-x',
      );

      expect(
        requests.single.url.toString(),
        'https://r.jina.ai/https://www.demo-store.com/products/noise-buds-x',
      );
      expect(requests.single.headers['X-Return-Format'], 'html');
      expect(data.title, 'Noise Buds X');
    });

    test('shows a clear error when the reader is rate limited', () async {
      final service = WebProductLinkService(
        client: MockClient(
          (_) async => http.Response('Too many requests', 429),
        ),
      );

      await expectLater(
        service.load('https://www.demo-store.com/products/noise-buds-x'),
        throwsA(
          isA<ProductLinkException>().having(
            (error) => error.message,
            'message',
            contains('rate limited'),
          ),
        ),
      );
    });

    test('detects a store denial page returned with HTTP 200', () async {
      final service = WebProductLinkService(
        client: MockClient(
          (_) async => http.Response(_blockedFlipkartHtml, 200),
        ),
      );

      await expectLater(
        service.load('https://www.flipkart.com/item/p/123'),
        throwsA(
          isA<ProductLinkException>().having(
            (error) => error.message,
            'message',
            contains('blocked the free reader'),
          ),
        ),
      );
    });

    test('falls back to Serper when the reader is blocked', () async {
      SharedPreferences.setMockInitialValues({
        'seller.market.serper.v1': 'serper-test-key',
      });
      final prefs = await SharedPreferences.getInstance();
      final requests = <http.Request>[];
      final service = WebProductLinkService(
        prefs: prefs,
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.host == 'r.jina.ai') {
            return http.Response(_blockedAmazonHtml, 200);
          }
          return http.Response(
            jsonEncode({
              'markdown': _productMarkdown,
              'metadata': {
                'title': 'Noise Buds X - Amazon.in',
                'description':
                    'Wireless earbuds with active noise cancellation.',
                'publisher': 'Amazon',
              },
              'images': [
                'https://cdn.example.com/earbuds-1.jpg',
                'https://cdn.example.com/earbuds-2.jpg',
                'https://cdn.example.com/earbuds-3.jpg',
              ],
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
        clock: () => DateTime(2026, 10, 29),
      );

      final data = await service.load('https://www.amazon.in/dp/B0ABC12345');

      expect(requests, hasLength(2));
      expect(requests.last.url.host, 'scrape.serper.dev');
      expect(requests.last.headers['X-API-KEY'], 'serper-test-key');
      expect(
        jsonDecode(requests.last.body)['url'],
        'https://www.amazon.in/dp/B0ABC12345',
      );
      expect(data.title, 'Noise Buds X');
      expect(data.siteName, 'Amazon');
      expect(data.sourceHost, 'amazon.in');
      expect(data.price, '\u20b91,299');
      expect(data.mrp, '\u20b91,999');
      expect(data.discount, '35% off');
      expect(data.rating, '4.3');
      expect(data.reviewCount, '1,200');
      expect(data.brand, 'Noise');
      expect(data.sku, 'SKU123');
      expect(data.description, contains('wireless earbuds'));
      expect(data.keyFeatures, hasLength(3));
      expect(data.photos, hasLength(3));
      expect(data.keywords, contains('earbuds'));
      expect(
        data.specs.map((spec) => spec.label),
        containsAll(['Battery', 'Colour', 'SKU']),
      );
    });
  });

  group('Product Data page', () {
    testWidgets('opens the tab, reads a link, and shows product data', (
      tester,
    ) async {
      setScreenSize(tester, const Size(1200, 1700));
      final prefs = await SharedPreferences.getInstance();
      final fake = _FakeProductLinkSource();

      await tester.pumpWidget(
        MyApp(
          themeController: ThemeController(prefs),
          trendSource: _FakeTrendSource(),
          productLinkSource: fake,
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(find.text('Product Data'), findsOneWidget);
      await tester.tap(find.text('Product Data'));
      await tester.pumpAndSettle();

      expect(find.text('Product link analyzer'), findsOneWidget);
      expect(find.text('Product Link Analyzer'), findsOneWidget);
      expect(find.text('Paste a product link'), findsWidgets);

      final input = find.descendant(
        of: find.byType(ProductDataPage),
        matching: find.byType(TextField),
      );
      await tester.enterText(
        input,
        'https://www.demo-store.com/products/noise-buds-x',
      );
      await tester.tap(find.text('Fetch product data'));
      await tester.pumpAndSettle();

      expect(fake.lastLink, contains('demo-store.com'));
      expect(find.text('Wireless Earbuds Pro'), findsWidgets);
      expect(find.text('\u20b91,299'), findsWidgets);
      expect(find.text('Product photos'), findsOneWidget);
      expect(find.byTooltip('Download photo 1'), findsOneWidget);
      expect(find.byTooltip('Copy photo 1 link'), findsOneWidget);
      expect(find.text('Copy all'), findsWidgets);

      final scrollable = find
          .descendant(
            of: find.byType(ProductDataPage),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('40 hours playback'),
        500,
        scrollable: scrollable,
      );
      expect(find.text('Key features'), findsWidgets);
      expect(find.text('40 hours playback'), findsOneWidget);
      expect(find.byTooltip('Copy feature 1'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('bluetooth'),
        500,
        scrollable: scrollable,
      );
      expect(find.text('Keywords'), findsWidgets);
      expect(find.text('bluetooth'), findsOneWidget);
    });

    testWidgets('long keywords do not overflow on a mobile screen', (
      tester,
    ) async {
      setScreenSize(tester, const Size(360, 800));
      final prefs = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        MyApp(
          themeController: ThemeController(prefs),
          trendSource: _FakeTrendSource(),
          productLinkSource: _LongKeywordProductLinkSource(),
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Product Data'));
      await tester.pumpAndSettle();

      final input = find.descendant(
        of: find.byType(ProductDataPage),
        matching: find.byType(TextField),
      );
      await tester.enterText(
        input,
        'https://www.demo-store.com/products/noise-buds-x',
      );

      final scrollable = find
          .descendant(
            of: find.byType(ProductDataPage),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Fetch product data'),
        300,
        scrollable: scrollable,
      );
      await tester.tap(find.text('Fetch product data'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text(_longKeyword),
        500,
        scrollable: scrollable,
      );

      expect(tester.takeException(), isNull);
    });
  });
}

const _longKeyword =
    'wireless bluetooth earbuds with active noise cancellation';

class _LongKeywordProductLinkSource implements ProductLinkSource {
  @override
  Future<ProductLinkData> load(String link) async {
    return ProductLinkData(
      sourceUrl: 'https://www.demo-store.com/products/noise-buds-x',
      sourceHost: 'demo-store.com',
      siteName: 'Demo Store',
      title: 'Wireless Earbuds Pro',
      keywords: const [_longKeyword, 'bluetooth'],
      fetchedAt: DateTime(2026, 10, 29),
    );
  }
}

void setScreenSize(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _FakeProductLinkSource implements ProductLinkSource {
  String lastLink = '';

  @override
  Future<ProductLinkData> load(String link) async {
    lastLink = link;
    return ProductLinkData(
      sourceUrl: 'https://www.demo-store.com/products/noise-buds-x',
      sourceHost: 'demo-store.com',
      siteName: 'Demo Store',
      title: 'Wireless Earbuds Pro',
      description:
          'Wireless earbuds with active noise cancellation and a long battery.',
      brand: 'Demo Audio',
      price: '\u20b91,299',
      mrp: '\u20b91,999',
      discount: '35% off',
      rating: '4.3',
      reviewCount: '1,200',
      availability: 'In stock',
      seller: 'Demo Seller',
      keywords: const ['bluetooth', 'earbuds', 'noise cancellation'],
      keyFeatures: const [
        '40 hours playback',
        'Active noise cancellation',
        'Fast USB-C charging',
      ],
      photos: const [
        ProductPhoto(url: 'https://cdn.example.com/earbuds-1.jpg'),
        ProductPhoto(url: 'https://cdn.example.com/earbuds-2.jpg'),
      ],
      specs: const [
        ProductSpec(label: 'Battery', value: '40 hours'),
        ProductSpec(label: 'Colour', value: 'Black'),
      ],
      fetchedAt: DateTime(2026, 10, 29),
    );
  }
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
  Future<TrendSnapshot> load(FlipkartQuery target) async {
    return TrendSnapshot(
      suggestions: const <TrendSuggestion>[],
      sources: const [],
      fetchedAt: DateTime(2026, 10, 29),
    );
  }
}

const _blockedFlipkartHtml = r'''
<!doctype html>
<html>
<head><title>Online Shopping India | Flipkart.com</title></head>
<body>
  <h1>Wow, looks like all of India is here!</h1>
  <p>Hang in there, the offers are worth the wait.</p>
  <p>GRN: 0.9dc82c17.1793256562.1789004 ClientIP: 167.71.90.33</p>
</body>
</html>
''';

const _blockedAmazonHtml = r'''
<!doctype html>
<html>
<head><title>503 - Service Unavailable Error</title></head>
<body><h1>503 - Service Unavailable Error</h1></body>
</html>
''';

const _productMarkdown = r'''
# Noise Buds X

₹1,299 ₹1,999 35% off

4.3 ★
1,200 Ratings

![Noise Buds X](https://cdn.example.com/earbuds-1.jpg)
![Noise Buds X](https://cdn.example.com/earbuds-2.jpg)

## Highlights
- 40 hours playback with the charging case
- Active noise cancellation for calls and music
- Fast USB-C charging in a compact design

## Product description
Noise Buds X are wireless earbuds with active noise cancellation, a pocketable case, and all-day comfort.

## Specifications
| Brand | Noise |
| Battery | 40 hours |
| Colour | Black |
| SKU | SKU123 |
''';

const _productHtml = r'''
<!doctype html>
<html>
<head>
  <title>Noise Buds X | Demo Store</title>
  <meta property="og:site_name" content="Demo Store">
  <meta property="og:title" content="Noise Buds X | Demo Store">
  <meta name="description" content="Short store description.">
  <meta name="keywords" content="wireless earbuds, tws, bluetooth">
  <meta property="og:image" content="https://cdn.example.com/earbuds-1.jpg">
  <meta property="og:image" content="https://cdn.example.com/earbuds-2.jpg">
  <script type="application/ld+json">
  {
    "@context": "https://schema.org",
    "@type": "Product",
    "name": "Noise Buds X",
    "description": "Noise Buds X are wireless earbuds with active noise cancellation, a pocketable case, and all-day comfort.",
    "image": [
      "https://cdn.example.com/earbuds-1.jpg",
      "https://cdn.example.com/earbuds-2.jpg",
      "https://cdn.example.com/earbuds-3.jpg"
    ],
    "brand": {"@type": "Brand", "name": "Noise"},
    "category": "Audio",
    "sku": "SKU123",
    "keywords": "earbuds, tws, bluetooth",
    "aggregateRating": {
      "@type": "AggregateRating",
      "ratingValue": "4.3",
      "reviewCount": "1200"
    },
    "offers": {
      "@type": "Offer",
      "price": "1299.00",
      "priceCurrency": "INR",
      "availability": "https://schema.org/InStock",
      "seller": {"@type": "Organization", "name": "Demo Seller"}
    },
    "additionalProperty": [
      {"@type": "PropertyValue", "name": "Battery", "value": "40 hours"}
    ]
  }
  </script>
</head>
<body>
  <h1>Noise Buds X</h1>
  <div class="mrp">MRP &#8377;1,999</div>
  <div class="discount">35% off</div>
  <div id="feature-bullets">
    <ul>
      <li>40 hours playback with the charging case</li>
      <li>Active noise cancellation for calls and music</li>
      <li>Fast USB-C charging in a compact design</li>
    </ul>
  </div>
  <table>
    <tr><th>Colour</th><td>Black</td></tr>
    <tr><th>Warranty</th><td>1 year</td></tr>
  </table>
  <img src="https://cdn.example.com/logo.png" alt="Store logo">
  <img src="https://cdn.example.com/earbuds-3.jpg" alt="Noise Buds X">
</body>
</html>
''';
