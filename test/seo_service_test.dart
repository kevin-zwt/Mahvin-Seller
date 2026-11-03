import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/data/seo_service.dart';

String _completion(Map<String, String> content) => jsonEncode({
  'choices': [
    {
      'message': {'content': jsonEncode(content)},
    },
  ],
});

void main() {
  const input = SeoInput(title: 'Cotton Kurti', description: 'Soft kurti');

  Future<SeoService> service(http.Client client, {bool key = true}) async {
    SharedPreferences.setMockInitialValues({
      if (key) SeoService.keyPrefs: 'gsk_test_key_for_unit_tests_only',
    });
    return SeoService(
      prefs: await SharedPreferences.getInstance(),
      client: client,
    );
  }

  test('writes a title and description and removes banned words', () async {
    late http.Request sent;
    final client = MockClient((request) async {
      sent = request;
      return http.Response(
        _completion({
          'title': 'Cotton Kurti for Women Acme Daily Wear',
          'description': 'Soft cotton kurti. Buy on Flipkart.',
        }),
        200,
      );
    });
    final seo = await service(client);
    final result = await seo.generate(
      input,
      scrub: (text) => text
          .replaceAll(RegExp('acme|flipkart', caseSensitive: false), '')
          .replaceAll(RegExp(r'\s{2,}'), ' ')
          .trim(),
    );

    expect(result.title, 'Cotton Kurti for Women Daily Wear');
    expect(result.description, 'Soft cotton kurti. Buy on .');
    expect(sent.headers['Authorization'], startsWith('Bearer gsk_'));
    expect(jsonDecode(sent.body)['model'], SeoService.model);
  });

  test('needs a key and reports a rejected key', () async {
    final none = await service(
      MockClient((_) async => http.Response('', 200)),
      key: false,
    );
    expect(none.isConfigured, isFalse);
    expect(none.generate(input), throwsA(isA<SeoException>()));

    final rejected = await service(
      MockClient((_) async => http.Response('', 401)),
    );
    expect(
      rejected.generate(input),
      throwsA(
        isA<SeoException>().having(
          (e) => e.message,
          'message',
          contains('rejected'),
        ),
      ),
    );
  });

  test('writes only the title or only the description', () async {
    final prompts = <String>[];
    final client = MockClient((request) async {
      final messages = jsonDecode(request.body)['messages'] as List;
      prompts.add(messages.last['content'] as String);
      return http.Response(_completion({'title': 'New Cotton Kurti'}), 200);
    });
    final seo = await service(client);
    final title = await seo.generate(
      input,
      part: SeoPart.title,
      previous: 'Old Cotton Kurti',
    );
    expect(title.title, 'New Cotton Kurti');
    expect(title.description, isEmpty);
    expect(prompts.single, contains('only the "title"'));
    expect(prompts.single, contains('Old Cotton Kurti'));

    final other = await service(
      MockClient(
        (_) async =>
            http.Response(_completion({'description': 'Soft cotton.'}), 200),
      ),
    );
    final description = await other.generate(input, part: SeoPart.description);
    expect(description.description, 'Soft cotton.');
    expect(description.title, isEmpty);
  });

  test('rejects an unreadable reply', () {
    expect(
      () => SeoService.parse('{"choices": []}'),
      throwsA(isA<SeoException>()),
    );
  });
}
