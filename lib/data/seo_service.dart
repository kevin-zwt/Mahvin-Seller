import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class SeoException implements Exception {
  const SeoException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What the model is given about the product. Everything here has already been
/// cleaned of brand names, marketplace names and links.
class SeoInput {
  const SeoInput({
    required this.title,
    this.description = '',
    this.features = '',
    this.specs = '',
    this.category = '',
  });

  final String title;
  final String description;
  final String features;
  final String specs;
  final String category;
}

/// Which part of the listing to write.
enum SeoPart { both, title, description }

class SeoContent {
  const SeoContent({this.title = '', this.description = ''});

  final String title;
  final String description;
}

/// Writes a search-friendly product title and description with Groq.
///
/// The API key is entered in the app and kept in local preferences. It is never
/// part of the source code.
class SeoService {
  SeoService({this.prefs, this.client});

  static const keyPrefs = 'seller.seo.groq.v1';
  static const _endpoint = 'https://api.groq.com/openai/v1/chat/completions';
  static const model = 'openai/gpt-oss-120b';
  static const maxTitleLength = 100;

  final SharedPreferences? prefs;
  final http.Client? client;

  static http.Client _newClient() => http.Client();

  String get _key => (prefs?.getString(keyPrefs) ?? '').trim();

  bool get isConfigured => _key.isNotEmpty;

  Future<void> connect(String apiKey) async {
    final key = apiKey.trim();
    if (key.length < 20) {
      throw const SeoException('Enter a valid Groq API key.');
    }
    await prefs?.setString(keyPrefs, key);
  }

  Future<void> disconnect() async {
    await prefs?.remove(keyPrefs);
  }

  /// [scrub] removes anything Meesho rejects (brand, marketplace names, links)
  /// from the model's text.
  Future<SeoContent> generate(
    SeoInput input, {
    SeoPart part = SeoPart.both,
    String previous = '',
    String Function(String text)? scrub,
  }) async {
    if (!isConfigured) {
      throw const SeoException('Add your Groq API key first.');
    }
    final http.Client httpClient = client ?? _newClient();
    final http.Response response;
    try {
      response = await httpClient
          .post(
            Uri.parse(_endpoint),
            headers: {
              'Authorization': 'Bearer $_key',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model': model,
              'temperature': previous.isEmpty ? 0.4 : 0.9,
              'response_format': {'type': 'json_object'},
              'messages': [
                {'role': 'system', 'content': _system},
                {'role': 'user', 'content': _prompt(input, part, previous)},
              ],
            }),
          )
          .timeout(const Duration(seconds: 45));
    } on SeoException {
      rethrow;
    } catch (_) {
      throw const SeoException(
        'Could not reach Groq. Check your connection and try again.',
      );
    } finally {
      if (client == null) httpClient.close();
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const SeoException(
        'That Groq API key was rejected. Check the key and try again.',
      );
    }
    if (response.statusCode == 429) {
      throw const SeoException(
        'Groq limit reached. Wait a minute, then try again.',
      );
    }
    if (response.statusCode != 200) {
      throw SeoException(
        'Groq could not write the text (HTTP ${response.statusCode}).',
      );
    }
    return parse(response.body, part: part, scrub: scrub);
  }

  /// Reads the chat completion in [body] into a cleaned title and description.
  static SeoContent parse(
    String body, {
    SeoPart part = SeoPart.both,
    String Function(String)? scrub,
  }) {
    try {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final content =
          (decoded['choices'] as List).first['message']['content'] as String;
      final json = jsonDecode(content) as Map<String, dynamic>;
      String clean(Object? value) {
        var text = '$value'.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
        if (scrub != null) text = scrub(text);
        return text.trim();
      }

      final wantTitle = part != SeoPart.description;
      final wantDescription = part != SeoPart.title;
      var title = wantTitle ? clean(json['title']) : '';
      if (title.length > maxTitleLength + 20) {
        title = title.substring(0, maxTitleLength + 20);
        title = title.substring(0, title.lastIndexOf(' ')).trim();
      }
      final description = wantDescription ? clean(json['description']) : '';
      if ((wantTitle && title.isEmpty) ||
          (wantDescription && description.isEmpty)) {
        throw const FormatException();
      }
      return SeoContent(title: title, description: description);
    } catch (_) {
      throw const SeoException(
        'Groq returned text the app could not read. Try again.',
      );
    }
  }

  static const _system =
      'You write search-optimised product listings for an Indian online '
      'marketplace. Reply only with a JSON object with the keys asked for ("title" and/or '
      '"description"). Rules: the title is at most $maxTitleLength characters, '
      'starts with the product type, and works the most searched words (type, '
      'material, fit or style, colour, size or occasion) in naturally. The '
      'description is plain text of 300 to 700 characters in short sentences '
      'or lines, covering the product, material, fit, use and care, with the '
      'important search words used naturally and no keyword stuffing. Use only '
      'facts from the product details given; never invent materials, sizes, '
      'certifications or claims. Never mention any brand name, any online store '
      'or marketplace name, any website or link, prices, discounts, delivery, '
      'or offers. Do not use emojis or capital-letter shouting.';

  static String _prompt(SeoInput input, SeoPart part, String previous) {
    final buffer = StringBuffer('Product details:\nTitle: ${input.title}\n');
    void add(String label, String value) {
      if (value.trim().isNotEmpty) {
        final text = value.length > 1500 ? value.substring(0, 1500) : value;
        buffer.writeln('$label: $text');
      }
    }

    add('Category', input.category);
    add('Description', input.description);
    add('Key features', input.features);
    add('Specifications', input.specs);
    final what = switch (part) {
      SeoPart.both => 'the "title" and "description"',
      SeoPart.title => 'only the "title" (reply with just that key)',
      SeoPart.description =>
        'only the "description" (reply with just that key)',
    };
    if (previous.trim().isNotEmpty) {
      buffer.writeln('\nEarlier version, write a different one: $previous');
    }
    buffer.write('\nWrite $what now.');
    return buffer.toString();
  }
}
