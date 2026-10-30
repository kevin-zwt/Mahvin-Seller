import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/data/models/flipkart_category.dart';
import 'package:flutter_app/data/trend_service.dart';

const mobileCategory = FlipkartCategory(
  key: 'mobiles',
  label: 'Mobiles',
  query: 'mobile phones',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('loads from the public reader without an API key', () async {
    final prefs = await SharedPreferences.getInstance();
    final requests = <http.Request>[];
    final service = WebTrendService(
      prefs,
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          _flipkartCategoryMarkdown,
          200,
          headers: const {'content-type': 'text/plain; charset=utf-8'},
        );
      }),
    );

    expect(service.isConfigured, isFalse);
    final snapshot = await service.load(mobileCategory);

    expect(requests, hasLength(1));
    expect(requests.first.method, 'GET');
    expect(
      requests.first.url.toString(),
      'https://r.jina.ai/'
      'https://www.flipkart.com/search?q=mobile+phones&sort=popularity',
    );
    expect(snapshot.suggestions, isNotEmpty);
    expect(snapshot.suggestions.first.name, 'BOLTT EVO (Sky Blue, 64 GB)');
  });

  test('uses a typed product query in the reader URL', () async {
    final prefs = await SharedPreferences.getInstance();
    final requests = <http.Request>[];
    final service = WebTrendService(
      prefs,
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          _flipkartCategoryMarkdown,
          200,
          headers: const {'content-type': 'text/plain; charset=utf-8'},
        );
      }),
    );
    final query = FlipkartQuery.search('  Cotton Kurti  ');

    expect(query.key, 'search:cotton kurti');
    expect(query.label, 'Cotton Kurti');
    expect(query.query, 'Cotton Kurti');

    final snapshot = await service.load(query);

    expect(requests, hasLength(1));
    expect(
      requests.first.url.toString(),
      'https://r.jina.ai/'
      'https://www.flipkart.com/search?q=Cotton+Kurti&sort=popularity',
    );
    expect(snapshot.suggestions, isNotEmpty);
  });

  test('connects and masks a key', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = WebTrendService(prefs);

    await service.connect('serper-test-1234');

    expect(service.isConfigured, isTrue);
    expect(service.maskedKey, '\u2022\u2022\u2022\u20221234');

    await service.disconnect();
    expect(service.isConfigured, isFalse);
    expect(service.maskedKey, isNull);
  });

  test('scrapes and parses top selling products for a category', () async {
    final prefs = await SharedPreferences.getInstance();
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response(
        jsonEncode({
          'markdown': _flipkartMarkdown,
          'metadata': {
            'title':
                'Trending- Buy Products Online at Best Price in India | '
                'Flipkart.com',
          },
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    });

    final service = WebTrendService(
      prefs,
      client: client,
      clock: () => DateTime(2026, 10, 27),
    );
    await service.connect('serper-test-1234');

    final snapshot = await service.load(mobileCategory);

    expect(requests, hasLength(1));
    expect(requests.first.url.toString(), 'https://scrape.serper.dev');
    expect(requests.first.headers['X-API-KEY'], 'serper-test-1234');
    final body = jsonDecode(requests.first.body) as Map<String, dynamic>;
    expect(
      body['url'],
      'https://www.flipkart.com/search?q=mobile+phones&sort=popularity',
    );
    expect(body['includeMarkdown'], isTrue);

    expect(snapshot.suggestions.map((item) => item.name), [
      'BLACK SHOES PREMIUM QUALITY SNEAKERS Sneakers For Men',
      'Men Full Sleeve Printed Sweatshirt',
      'Smart Watch with AMOLED Display',
    ]);
    expect(
      snapshot.suggestions.first.reason,
      '₹457 \u00b7 MRP ₹2,999 \u00b7 84% off',
    );
    expect(
      snapshot.suggestions.first.imageUrl,
      'https://rukminim2.flixcart.com/image/612/612/shoe.jpeg?q=70',
    );
    expect(
      snapshot.suggestions[1].reason,
      '₹438 \u00b7 MRP ₹1,999 \u00b7 78% off',
    );
    expect(
      snapshot.suggestions[2].reason,
      '₹1,299 \u00b7 MRP ₹4,999 \u00b7 74% off',
    );
    expect(snapshot.suggestions, hasLength(3));
    expect(snapshot.sources, hasLength(1));
    expect(
      snapshot.sources.single.title,
      'Trending- Buy Products Online at Best Price in India | Flipkart.com',
    );
    expect(snapshot.sources.single.snippet, contains('3 products'));
    expect(
      snapshot.sources.single.url,
      'https://www.flipkart.com/search?q=mobile+phones&sort=popularity',
    );
    expect(snapshot.sources.single.snippet, contains('mobile phones'));
    expect(snapshot.fetchedAt, DateTime(2026, 10, 27));
  });

  test('parses category cards that combine image, title, and price', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = WebTrendService(
      prefs,
      client: MockClient((_) async {
        return http.Response(
          jsonEncode({'markdown': _flipkartCategoryMarkdown}),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    await service.connect('serper-test-1234');

    final snapshot = await service.load(mobileCategory);

    expect(snapshot.suggestions.map((item) => item.name), [
      'BOLTT EVO (Sky Blue, 64 GB)',
      'Vivo T4 Lite 5G (Prism Blue 2026) ( 4GB 64GB)',
    ]);
    expect(
      snapshot.suggestions.first.reason,
      '\u20B99,999 \u00b7 MRP \u20B917,999 \u00b7 44% off',
    );
    expect(
      snapshot.suggestions.first.imageUrl,
      'https://rukminim2.flixcart.com/image/312/312/xif0q/mobile/p/t/y/-original-imahs3pdarcqgyzf.jpeg?q=70',
    );
    expect(
      snapshot.suggestions.last.reason,
      '\u20B915,999 \u00b7 MRP \u20B927,999 \u00b7 42% off',
    );
  });

  test(
    'falls back to Flipkart product pages when the page is unreadable',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.host == 'scrape.serper.dev') {
          return http.Response(
            jsonEncode({'markdown': 'No product cards'}),
            200,
          );
        }
        if (request.url.host == 'r.jina.ai') {
          return http.Response('No product cards', 200);
        }
        return http.Response(
          jsonEncode({
            'organic': [
              {
                'title':
                    'boAt Airdopes 311 Pro - Buy boAt Airdopes 311 Pro Online '
                    'at Best Price | Flipkart.com',
                'link': 'https://www.flipkart.com/boat-airdopes-311-pro/p/itmabc?pid=ABC',
                'snippet': 'TWS earbuds with 50 hours playback.',
              },
              {
                'title': 'Unrelated result',
                'link': 'https://example.com/boat',
                'snippet': 'Should be ignored.',
              },
            ],
          }),
          200,
        );
      });

      final service = WebTrendService(prefs, client: client);
      await service.connect('serper-test-1234');

      final snapshot = await service.load(mobileCategory);

      expect(requests, hasLength(3));
      expect(requests[1].url.host, 'r.jina.ai');
      expect(requests.last.url.toString(), 'https://google.serper.dev/search');
      expect(
        jsonDecode(requests.last.body)['q'],
        'site:flipkart.com/p/ mobile phones top selling',
      );
      expect(snapshot.suggestions, hasLength(1));
      expect(snapshot.suggestions.single.name, 'boAt Airdopes 311 Pro');
      expect(
        snapshot.suggestions.single.reason,
        'TWS earbuds with 50 hours playback.',
      );
      expect(snapshot.suggestions.single.sourceHost, 'flipkart.com');
      expect(snapshot.sources.single.title, 'Flipkart product pages');
    },
  );

  test('falls back to the public reader when Serper fails', () async {
    final prefs = await SharedPreferences.getInstance();
    final requests = <http.Request>[];
    final service = WebTrendService(
      prefs,
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.host == 'scrape.serper.dev') {
          return http.Response('unavailable', 500);
        }
        return http.Response(
          _flipkartCategoryMarkdown,
          200,
          headers: const {'content-type': 'text/plain; charset=utf-8'},
        );
      }),
    );
    await service.connect('serper-test-1234');

    final snapshot = await service.load(mobileCategory);

    expect(requests, hasLength(2));
    expect(requests.last.url.host, 'r.jina.ai');
    expect(snapshot.suggestions, isNotEmpty);
    expect(snapshot.suggestions.first.name, 'BOLTT EVO (Sky Blue, 64 GB)');
  });

  test('surfaces an invalid API key when every source is blocked', () async {
    final prefs = await SharedPreferences.getInstance();
    var calls = 0;
    final service = WebTrendService(
      prefs,
      client: MockClient((_) async {
        calls++;
        return http.Response('unauthorized', 401);
      }),
    );
    await service.connect('serper-test-1234');

    await expectLater(
      service.load(mobileCategory),
      throwsA(
        isA<TrendException>().having(
          (error) => error.message,
          'message',
          contains('rejected'),
        ),
      ),
    );
    expect(calls, 3);
  });

  test('surfaces a rate limit when every source is limited', () async {
    final prefs = await SharedPreferences.getInstance();
    var calls = 0;
    final service = WebTrendService(
      prefs,
      client: MockClient((_) async {
        calls++;
        return http.Response('too many requests', 429);
      }),
    );
    await service.connect('serper-test-1234');

    await expectLater(
      service.load(mobileCategory),
      throwsA(
        isA<TrendException>().having(
          (error) => error.message,
          'message',
          contains('limit'),
        ),
      ),
    );
    expect(calls, 3);
  });

  test('throws a clear error when both the page and fallback fail', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = WebTrendService(
      prefs,
      client: MockClient((_) async => http.Response('unavailable', 500)),
    );
    await service.connect('serper-test-1234');

    await expectLater(
      service.load(mobileCategory),
      throwsA(
        isA<TrendException>().having(
          (error) => error.message,
          'message',
          contains('Could not load Flipkart'),
        ),
      ),
    );
  });

  test('throws when both sources return no products', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = WebTrendService(
      prefs,
      client: MockClient((request) async {
        if (request.url.host == 'scrape.serper.dev') {
          return http.Response(jsonEncode({'markdown': 'Nothing here'}), 200);
        }
        return http.Response(jsonEncode({'organic': []}), 200);
      }),
    );
    await service.connect('serper-test-1234');

    await expectLater(
      service.load(mobileCategory),
      throwsA(
        isA<TrendException>().having(
          (error) => error.message,
          'message',
          contains('no product cards'),
        ),
      ),
    );
  });
}

const _flipkartMarkdown = r'''
# Trending products

[![Image 3](https://rukminim2.flixcart.com/image/612/612/shoe.jpeg?q=70)](https://www.flipkart.com/tigonis-black-shoes/p/itm742b48108b5ef?pid=SHO123)

tigonis

[BLACK SHOES PREMIUM QUALITY SNEAKERS Sneakers For Men](https://www.flipkart.com/tigonis-black-shoes/p/itm742b48108b5ef?pid=SHO123)

Black , 9

[₹457 ₹2,999 84% off](https://www.flipkart.com/tigonis-black-shoes/p/itm742b48108b5ef?pid=SHO123)

[![Image 4](https://rukminim2.flixcart.com/image/612/612/sweatshirt.jpeg?q=70)](https://www.flipkart.com/tripr-sweatshirt/p/itm0c0b3cfb1b0b7?pid=SWSH123)

TRIPR

[Men Full Sleeve Printed Sweatshirt](https://www.flipkart.com/tripr-sweatshirt/p/itm0c0b3cfb1b0b7?pid=SWSH123)

[₹438 ₹1,999 78% off](https://www.flipkart.com/tripr-sweatshirt/p/itm0c0b3cfb1b0b7?pid=SWSH123)

[![Image 5](https://rukminim2.flixcart.com/image/612/612/watch.jpeg?q=70)](https://www.flipkart.com/smart-watch/p/itmwatch?pid=WATCH123)

Noise

[Smart Watch with AMOLED Display](https://www.flipkart.com/smart-watch/p/itmwatch?pid=WATCH123)

[₹1,299 ₹4,999 74% off](https://www.flipkart.com/smart-watch/p/itmwatch?pid=WATCH123)

[₹999 ₹1,999 50% off](https://www.flipkart.com/orphan-product/p/itmorphan?pid=ORPHAN123)
''';

const _flipkartCategoryMarkdown = r"""
[![Image 5: BOLTT EVO (Sky Blue, 64 GB)](https://rukminim2.flixcart.com/image/312/312/xif0q/mobile/p/t/y/-original-imahs3pdarcqgyzf.jpeg?q=70) - [x] Add to Compare BOLTT EVO (Sky Blue, 64 GB) 4.1![Image 6](blob:http://localhost/21c53851e70e411cc53b436871dc9f91) 5,191 Ratings&1,688 Reviews * 4 GB RAM | 64 GB ROM | Expandable Upto 1 TB * 17.25 cm (6.79 inch) HD+ Display * 50MP + 2MP | 8MP Front Camera * 6000 mAh Lithium ion Battery * T7250 Processor * 6.79'' HD+ punch hole display * 1 Year Manufacturer Warranty for Device and 6 Months Manufacturer Warranty for In-box Accessories. ₹9,999 ₹17,999 44% off Upto ₹7,400 Off on Exchange Bank Offer](https://www.flipkart.com/boltt-evo-sky-blue-64-gb/p/itmf046d663a1fd7?pid=MOBHPP59WKSV4FYG&lid=LSTMOBHPP59WKSV4FYGYPMLV6&marketplace=FLIPKART&q=mobile+phones&store=tyy%2F4io&srno=s_1_1&otracker=search&fm=organic&iid=en_DOvPYxYmFYX0PTRVTTb2qfB1RKmdRrzdG4lwkYIm-_wmxxcA5XyNpA2ZBam-FGleYgqST4UyZ83drr4hTBWkPdCky99QtiUOzd_bah4WOwnlzW4HyoGWDhvhYUYqpGwq&ppt=None&ppn=None&ssid=nsdlzw7sgw0000001793098857009&qH=a81ad6e72f7a2fd1&ov_redirect=true)

[![Image 9: Vivo T4 Lite 5G (Prism Blue 2026) ( 4GB 128GB)](https://rukminim2.flixcart.com/image/312/312/xif0q/mobile/4/r/i/-original-imahnq7mcqxru4nv.jpeg?q=70) - [x] Add to Compare Vivo T4 Lite 5G (Prism Blue 2026) ( 4GB 64GB) 4.3![Image 10](blob:http://localhost/21c53851e70e411cc53b436871dc9f91) 48,158 Ratings&2,270 Reviews * 4 GB RAM | 64 GB ROM | Expandable Upto 2 TB * 17.12 cm (6.74 inch) HD+ Display * 50MP + 2MP | 5MP Front Camera * 6000 mAh Battery * Dimensity 6300 5G Processor * 1 Year Manufacturer Warranty for Device and 6 Months Manufacturer Warranty for Inbox Accessories ₹15,999 ₹27,999 42% off ![Image 11](https://static-assets-web.flixcart.com/fk-p-linchpin-web/fk-cp-zion/img/fa_9e47c1.png) Top Discount of the Sale Upto ₹12,675 Off on Exchange](https://www.flipkart.com/vivo-t4-lite-5g-prism-blue-2026-4gb-64gb/p/itm49fb53d099f3c?pid=MOBHNCRKA4XQFSRM&lid=LSTMOBHNCRKA4XQFSRMKUYMUR&marketplace=FLIPKART&q=mobile+phones&store=tyy%2F4io&srno=s_1_3&otracker=search&fm=organic&iid=fc8f56b9-397e-47d7-995a-9d81529b5360.MOBHNCRKA4XQFSRM.SEARCH&ppt=None&ppn=None&ssid=nsdlzw7sgw0000001793098857009&qH=a81ad6e72f7a2fd1&ov_redirect=true)
""";
