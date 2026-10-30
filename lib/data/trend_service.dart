import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models/flipkart_category.dart';
import 'models/trend_suggestion.dart';

/// Fetches top selling products for a Flipkart category or product search.
abstract class TrendSource {
  bool get isConfigured;
  String? get maskedKey;
  Future<void> connect(String apiKey);
  Future<void> disconnect();
  Future<TrendSnapshot> load(FlipkartQuery target);
}

class TrendException implements Exception {
  const TrendException(this.message, {this.fatal = false});

  final String message;
  final bool fatal;

  @override
  String toString() => message;
}

class TrendSnapshot {
  const TrendSnapshot({
    required this.suggestions,
    required this.sources,
    required this.fetchedAt,
  });

  final List<TrendSuggestion> suggestions;
  final List<TrendSourceLink> sources;
  final DateTime fetchedAt;
}

/// Loads Flipkart's category or product search results through Serper when a key is
/// configured, with a public reader as the no-key fallback, and turns the
/// product cards into an in-app list.
class WebTrendService implements TrendSource {
  WebTrendService(
    this._prefs, {
    http.Client? client,
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       _clock = clock ?? DateTime.now;

  static const _keyPrefs = 'seller.market.serper.v1';
  static const _scrapeEndpoint = 'https://scrape.serper.dev';
  static const _searchEndpoint = 'https://google.serper.dev/search';
  static const _maxProducts = 20;

  final SharedPreferences _prefs;
  final http.Client _client;
  final DateTime Function() _clock;

  String get _key => (_prefs.getString(_keyPrefs) ?? '').trim();

  @override
  bool get isConfigured => _key.isNotEmpty;

  @override
  String? get maskedKey {
    final key = _key;
    if (key.isEmpty) return null;
    final suffix = key.length <= 4 ? key : key.substring(key.length - 4);
    return '\u2022\u2022\u2022\u2022$suffix';
  }

  @override
  Future<void> connect(String apiKey) async {
    final key = apiKey.trim();
    if (key.length < 8) {
      throw const TrendException('Enter a valid Serper API key.');
    }
    await _prefs.setString(_keyPrefs, key);
  }

  @override
  Future<void> disconnect() async {
    await _prefs.remove(_keyPrefs);
  }

  @override
  Future<TrendSnapshot> load(FlipkartQuery target) async {
    TrendException? firstFailure;

    if (isConfigured) {
      try {
        final page = await _loadFlipkartPage(target);
        final products = _parseFlipkartProducts(page.content);
        if (products.isNotEmpty) {
          return _buildSnapshot(
            products,
            pageTitle: page.title,
            pageUrl: target.pageUrl,
            pageSnippet:
                '${products.length} products loaded from Flipkart\'s '
                '"${target.query}" search, sorted by popularity.',
          );
        }
        firstFailure = const TrendException(
          'Flipkart returned a page, but no product cards could be read. '
          'Try again.',
        );
      } on TrendException catch (error) {
        firstFailure = error;
      } catch (_) {
        firstFailure = const TrendException(
          'Could not load Flipkart. Check your connection and try again.',
        );
      }
    }

    try {
      final page = await _loadJinaPage(target);
      final products = _parseFlipkartProducts(page.content);
      if (products.isNotEmpty) {
        return _buildSnapshot(
          products,
          pageTitle: page.title,
          pageUrl: target.pageUrl,
          pageSnippet:
              '${products.length} products loaded from Flipkart\'s '
              '"${target.query}" search, sorted by popularity.',
        );
      }
      firstFailure ??= const TrendException(
        'Flipkart returned a page, but no product cards could be read. '
        'Try again.',
      );
    } on TrendException catch (error) {
      firstFailure ??= error;
    } catch (_) {
      firstFailure ??= const TrendException(
        'Could not load Flipkart. Check your connection and try again.',
      );
    }

    if (isConfigured) {
      try {
        final products = await _searchFlipkartProducts(target);
        if (products.isNotEmpty) {
          return _buildSnapshot(
            products,
            pageTitle: 'Flipkart product pages',
            pageUrl: target.pageUrl,
            pageSnippet:
                'Fallback search used because the Flipkart search page '
                'could not be read.',
          );
        }
      } on TrendException {
        // Ignore fallback failures and show the primary error below.
      } catch (_) {
        // Ignore fallback failures and show the primary error below.
      }
    }

    throw firstFailure;
  }

  Future<_FlipkartPage> _loadJinaPage(FlipkartQuery target) async {
    final response = await _client
        .get(Uri.parse('https://r.jina.ai/${target.pageUrl}'))
        .timeout(const Duration(seconds: 45));

    _throwForStatus(response, 'Flipkart reader');

    final content = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (content.trim().isEmpty) {
      throw const TrendException('Flipkart returned an empty page. Try again.');
    }

    var title = 'Flipkart top selling products';
    final titleMatch = RegExp(
      r'^Title:\s*(.+)$',
      multiLine: true,
    ).firstMatch(content);
    if (titleMatch != null) {
      final rawTitle = titleMatch.group(1)?.trim() ?? '';
      if (rawTitle.isNotEmpty) title = _cleanText(rawTitle);
    }

    return _FlipkartPage(title: title, content: content);
  }

  Future<_FlipkartPage> _loadFlipkartPage(FlipkartQuery target) async {
    final response = await _client
        .post(
          Uri.parse(_scrapeEndpoint),
          headers: {'X-API-KEY': _key, 'Content-Type': 'application/json'},
          body: jsonEncode({'url': target.pageUrl, 'includeMarkdown': true}),
        )
        .timeout(const Duration(seconds: 30));

    _throwForStatus(response, 'Flipkart', serper: true);

    final decoded = _decodeMap(response);
    final markdown = decoded['markdown'];
    final text = decoded['text'];
    final content = [
      markdown,
      text,
    ].whereType<String>().where((value) => value.trim().isNotEmpty).join('\n');

    if (content.trim().isEmpty) {
      throw const TrendException('Flipkart returned an empty page. Try again.');
    }

    var title = 'Flipkart top selling products';
    final metadata = decoded['metadata'];
    if (metadata is Map) {
      final rawTitle = metadata['title'] ?? metadata['Title'];
      if (rawTitle is String && rawTitle.trim().isNotEmpty) {
        title = _cleanText(rawTitle);
      }
    }

    return _FlipkartPage(title: title, content: content);
  }

  Future<List<_Product>> _searchFlipkartProducts(FlipkartQuery target) async {
    final response = await _client
        .post(
          Uri.parse(_searchEndpoint),
          headers: {'X-API-KEY': _key, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'q': 'site:flipkart.com/p/ ${target.query} top selling',
            'gl': 'in',
            'hl': 'en',
            'num': 20,
          }),
        )
        .timeout(const Duration(seconds: 20));

    _throwForStatus(response, 'Flipkart search', serper: true);

    final decoded = _decodeMap(response);
    final organic = decoded['organic'];
    if (organic is! List) return const [];

    final products = <_Product>[];
    final seen = <String>{};
    for (final item in organic) {
      if (item is! Map) continue;
      final rawTitle = item['title'];
      final rawLink = item['link'];
      final rawSnippet = item['snippet'];
      if (rawTitle is! String || rawLink is! String) continue;
      if (!rawLink.contains('flipkart.com/') || !rawLink.contains('/p/')) {
        continue;
      }

      final title = _cleanProductTitle(rawTitle);
      if (title.isEmpty || !seen.add(_productId(rawLink))) continue;
      final snippet = rawSnippet is String ? _cleanText(rawSnippet) : '';
      final rawImageUrl = item['imageUrl'] ?? item['thumbnail'];
      final imageUrl = rawImageUrl is String ? _cleanImageUrl(rawImageUrl) : '';
      products.add(
        _Product(
          title: title,
          url: rawLink,
          imageUrl: imageUrl.isNotEmpty ? imageUrl : null,
          reason: snippet.isEmpty
              ? 'Flipkart product page returned by search.'
              : snippet,
          sourceTitle: 'Flipkart product page',
        ),
      );
      if (products.length >= _maxProducts) break;
    }
    return products;
  }

  TrendSnapshot _buildSnapshot(
    List<_Product> products, {
    required String pageTitle,
    required String pageUrl,
    required String pageSnippet,
  }) {
    return TrendSnapshot(
      suggestions: [
        for (final product in products.take(_maxProducts))
          TrendSuggestion(
            name: product.title,
            reason: product.reason,
            sourceTitle: product.sourceTitle,
            url: product.url,
            imageUrl: product.imageUrl,
          ),
      ],
      sources: [
        TrendSourceLink(title: pageTitle, url: pageUrl, snippet: pageSnippet),
      ],
      fetchedAt: _clock(),
    );
  }

  static Map<String, dynamic> _decodeMap(http.Response response) {
    try {
      final decoded = jsonDecode(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {
      // Fall through to the clear error below.
    }
    throw const TrendException(
      'The data service returned an unreadable response. Try again.',
    );
  }

  static void _throwForStatus(
    http.Response response,
    String source, {
    bool serper = false,
  }) {
    if (response.statusCode == 200) return;
    if (serper && (response.statusCode == 401 || response.statusCode == 403)) {
      throw const TrendException(
        'That Serper API key was rejected. Check the key and try again.',
        fatal: true,
      );
    }
    if (response.statusCode == 429) {
      throw TrendException(
        serper
            ? 'Serper limit reached. Wait a moment, then try again.'
            : '$source is rate limited. Wait a moment, then try again.',
        fatal: true,
      );
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw TrendException(
        '$source blocked the request (HTTP ${response.statusCode}). '
        'Try again.',
      );
    }
    throw TrendException(
      'Could not load $source (HTTP ${response.statusCode}). Try again.',
    );
  }

  static List<_Product> _parseFlipkartProducts(String content) {
    final titleLinkPattern = RegExp(
      r'\[([^\]\n]{2,300})\]'
      r'\((https://www\.flipkart\.com/[^)\s]+?/p/[^)\s]+?)'
      r'(?:\s+"[^"]*")?\)',
    );
    final imageCardPattern = RegExp(
      r'!\[Image \d+:\s*([^\]\n]{2,300})\]\([^)]*\)'
      r'[^\n]*?\]\('
      r'(https://www\.flipkart\.com/[^)\s]+?/p/[^)\s]+?)'
      r'(?:\s+"[^"]*")?\)',
    );
    final linkedImagePattern = RegExp(
      r'!\[[^\]\n]*\]\((https?://[^)\s]+)\)\]\('
      r'(https://www\.flipkart\.com/[^)\s]+?/p/[^)\s]+?)'
      r'(?:\s+"[^"]*")?\)',
    );

    final imagesByProduct = <String, String>{};
    for (final match in linkedImagePattern.allMatches(content)) {
      final url = match.group(2) ?? '';
      final imageUrl = _cleanImageUrl(match.group(1) ?? '');
      if (url.isEmpty || imageUrl.isEmpty) continue;
      imagesByProduct.putIfAbsent(_productId(url), () => imageUrl);
    }

    final candidates = <_ProductCandidate>[
      for (final match in titleLinkPattern.allMatches(content))
        _ProductCandidate(
          start: match.start,
          rawTitle: match.group(1) ?? '',
          url: match.group(2) ?? '',
        ),
      for (final match in imageCardPattern.allMatches(content))
        _ProductCandidate(
          start: match.start,
          rawTitle: match.group(1) ?? '',
          url: match.group(2) ?? '',
          extraText: match.group(0) ?? '',
        ),
    ]..sort((a, b) => a.start.compareTo(b.start));

    final products = <_Product>[];
    final seen = <String>{};

    for (var i = 0; i < candidates.length; i++) {
      final candidate = candidates[i];
      final extractedTitle = _combinedCardTitle(candidate.extraText);
      final rawTitle = extractedTitle.isNotEmpty
          ? extractedTitle
          : candidate.rawTitle;
      if (rawTitle.startsWith('!') || rawTitle.startsWith('Image ')) continue;
      if (rawTitle.contains('₹') || rawTitle.toLowerCase().contains('% off')) {
        continue;
      }
      final title = _cleanProductTitle(rawTitle);
      if (title.isEmpty) continue;

      final url = candidate.url;
      final id = _productId(url);
      if (!seen.add(id)) continue;

      var imageUrl = _firstImageUrl(candidate.extraText);
      if (imageUrl.isEmpty) {
        imageUrl = imagesByProduct[id] ?? '';
      }

      var end = content.length;
      for (var j = i + 1; j < candidates.length; j++) {
        final nextId = _productId(candidates[j].url);
        if (nextId != id) {
          end = candidates[j].start;
          break;
        }
      }
      final block = [
        candidate.extraText,
        content.substring(candidate.start, end),
      ].where((value) => value.isNotEmpty).join('\n');
      if (imageUrl.isEmpty) {
        imageUrl = _firstImageUrl(block);
      }
      products.add(
        _Product(
          title: title,
          url: url,
          imageUrl: imageUrl.isNotEmpty ? imageUrl : null,
          reason: _priceLabel(block),
          sourceTitle: 'Flipkart \u00b7 sorted by popularity',
        ),
      );
      if (products.length >= _maxProducts) break;
    }
    return products;
  }

  static String _combinedCardTitle(String card) {
    if (card.isEmpty) return '';
    final match = RegExp(r'Add to Compare\s+(.+?)\s+\d+(?:\.\d+)?!\[Image')
        .firstMatch(card);
    return match?.group(1)?.trim() ?? '';
  }

  static String _priceLabel(String block) {
    final pair = RegExp(r'₹\s*([\d,]+)\s*₹\s*([\d,]+)').firstMatch(block);
    if (pair != null) {
      final discount = RegExp(r'(\d{1,2})%\s*off').firstMatch(block)?.group(1);
      final label = '₹${pair.group(1)} \u00b7 MRP ₹${pair.group(2)}';
      return discount == null ? label : '$label \u00b7 $discount% off';
    }

    final single = RegExp(r'₹\s*([\d,]+)').firstMatch(block);
    if (single != null) return '₹${single.group(1)}';
    return 'Flipkart product';
  }

  static String _cleanProductTitle(String raw) {
    var value = _cleanText(raw);
    value = value.replaceFirst(
      RegExp(r'\s*[-|]\s*Buy .*$', caseSensitive: false),
      '',
    );
    value = value.replaceFirst(
      RegExp(r'\s*\|\s*Flipkart\.com$', caseSensitive: false),
      '',
    );
    value = value.replaceFirst(
      RegExp(r'\s*-\s*Flipkart\.com$', caseSensitive: false),
      '',
    );
    value = value.replaceFirst(RegExp(r'(\.\.\.|…)+$'), '').trim();
    if (value.length > 200) {
      value = '${value.substring(0, 200).trimRight()}...';
    }
    return value.length < 2 ? '' : value;
  }

  static String _cleanImageUrl(String raw) {
    var trimmed = raw.trim();
    if (trimmed.startsWith('//')) {
      trimmed = 'https:$trimmed';
    }
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      return '';
    }
    if (trimmed.startsWith('blob:') || trimmed.startsWith('data:')) {
      return '';
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      return '';
    }
    return trimmed;
  }

  static String _firstImageUrl(String text) {
    if (text.isEmpty) return '';
    final matches = RegExp(r'!\[[^\]]*\]\((https?://[^)\s]+|//[^)\s]+)\)')
        .allMatches(text);
    String fallback = '';
    for (final match in matches) {
      final url = _cleanImageUrl(match.group(1) ?? '');
      if (url.isEmpty) continue;
      if (url.contains('fa_') ||
          url.contains('plus-icon') ||
          url.contains('favicon') ||
          url.contains('icon')) {
        continue;
      }
      if (url.contains('/image/') ||
          url.contains('rukminim') ||
          url.contains('flixcart.com')) {
        return url;
      }
      if (fallback.isEmpty) {
        fallback = url;
      }
    }
    return fallback;
  }

  static String _cleanText(String value) {
    return value
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _productId(String url) {
    final match = RegExp(r'/p/([^/?#]+)').firstMatch(url);
    return match?.group(1) ?? url;
  }
}

class _FlipkartPage {
  const _FlipkartPage({required this.title, required this.content});

  final String title;
  final String content;
}

class _Product {
  const _Product({
    required this.title,
    required this.url,
    required this.reason,
    required this.sourceTitle,
    this.imageUrl,
  });

  final String title;
  final String url;
  final String reason;
  final String sourceTitle;
  final String? imageUrl;
}

class _ProductCandidate {
  const _ProductCandidate({
    required this.start,
    required this.rawTitle,
    required this.url,
    this.extraText = '',
  });

  final int start;
  final String rawTitle;
  final String url;
  final String extraText;
}
