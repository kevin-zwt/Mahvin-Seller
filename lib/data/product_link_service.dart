import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models/product_link_data.dart';

const _maxPhotos = 20;
const _maxFeatures = 8;
const _maxKeywords = 12;
const _maxSpecs = 20;

/// Reads a public product page and turns it into structured listing data.
abstract class ProductLinkSource {
  Future<ProductLinkData> load(String link);
}

class WebProductLinkService implements ProductLinkSource {
  WebProductLinkService({
    http.Client? client,
    DateTime Function()? clock,
    this.prefs,
  }) : _client = client ?? http.Client(),
       _clock = clock ?? DateTime.now;

  static const _readerPrefix = 'https://r.jina.ai/';
  static const _serperKeyPrefs = 'seller.market.serper.v1';
  static const _serperScrapeEndpoint = 'https://scrape.serper.dev';

  final http.Client _client;
  final DateTime Function() _clock;
  final SharedPreferences? prefs;

  String get _serperKey => (prefs?.getString(_serperKeyPrefs) ?? '').trim();

  @override
  Future<ProductLinkData> load(String link) async {
    final sourceUrl = normalizeProductLink(link);

    ProductLinkException? readerFailure;
    try {
      return await _loadWithReader(sourceUrl);
    } on ProductLinkException catch (error) {
      readerFailure = error;
    } catch (_) {
      readerFailure = const ProductLinkException(
        'Could not read that product page. Check the link and your connection, then try again.',
      );
    }

    if (_serperKey.isNotEmpty) {
      try {
        return await _loadWithSerper(sourceUrl);
      } on ProductLinkException catch (error) {
        if (error.message.contains('key was rejected')) rethrow;
        readerFailure = ProductLinkException(
          '${readerFailure.message} The Serper fallback also failed: '
          '${error.message}',
        );
      } catch (_) {
        readerFailure = ProductLinkException(
          '${readerFailure.message} The Serper fallback could not read the page.',
        );
      }
    }

    throw readerFailure;
  }

  Future<ProductLinkData> _loadWithReader(String sourceUrl) async {
    final response = await _client
        .get(
          Uri.parse('$_readerPrefix$sourceUrl'),
          headers: const {'X-Return-Format': 'html'},
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode == 429) {
      throw const ProductLinkException(
        'The product reader is rate limited right now. Wait a minute and try again.',
      );
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw _blockedMessage();
    }
    if (response.statusCode == 404) {
      throw const ProductLinkException(
        'Product page not found. Check that the link still opens in a browser.',
      );
    }
    if (response.statusCode != 200) {
      throw ProductLinkException(
        'Could not read the product page (HTTP ${response.statusCode}).',
      );
    }

    final html = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (html.trim().isEmpty) {
      throw const ProductLinkException(
        'The store returned an empty page. Try another product link.',
      );
    }

    final data = parseProductHtml(html, sourceUrl, fetchedAt: _clock());

    if (_looksBlocked(html, data.title)) {
      throw _blockedMessage();
    }
    if (data.title.isEmpty) {
      throw const ProductLinkException(
        'Could not find product details on that page. It may be a search, category, or login page.',
      );
    }

    return data;
  }

  Future<ProductLinkData> _loadWithSerper(String sourceUrl) async {
    final response = await _client
        .post(
          Uri.parse(_serperScrapeEndpoint),
          headers: {
            'X-API-KEY': _serperKey,
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'url': sourceUrl,
            'includeMarkdown': true,
            'includeImages': true,
          }),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const ProductLinkException(
        'That Serper API key was rejected. Check the key in Top Selling.',
      );
    }
    if (response.statusCode == 429) {
      throw const ProductLinkException(
        'The Serper fallback is rate limited right now. Wait a minute and try again.',
      );
    }
    if (response.statusCode != 200) {
      throw ProductLinkException(
        'The Serper fallback could not read the page (HTTP ${response.statusCode}).',
      );
    }

    final decoded = _decodeSerperResponse(response);
    final markdown = decoded['markdown'];
    final text = decoded['text'];
    final content = [
      markdown,
      text,
    ].whereType<String>().where((value) => value.trim().isNotEmpty).join('\n');

    if (content.trim().isEmpty) {
      throw const ProductLinkException(
        'The Serper fallback returned an empty page. Try another product link.',
      );
    }

    final metadata = decoded['metadata'];
    final data = parseProductMarkdown(
      content,
      sourceUrl,
      metadata: metadata is Map<String, dynamic> ? metadata : null,
      images: decoded['images'],
      fetchedAt: _clock(),
    );

    if (_looksBlocked(content, data.title)) {
      throw _blockedMessage();
    }
    if (data.title.isEmpty) {
      throw const ProductLinkException(
        'The Serper fallback could not find product details on that page.',
      );
    }
    return data;
  }

  static Map<String, dynamic> _decodeSerperResponse(http.Response response) {
    try {
      final decoded = jsonDecode(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {
      // Fall through to the clear error below.
    }
    throw const ProductLinkException(
      'The Serper fallback returned an unreadable response. Try again.',
    );
  }

  ProductLinkException _blockedMessage() {
    final hint = _serperKey.isEmpty
        ? ' Add a free Serper key in Top Selling to use the fallback.'
        : '';
    return ProductLinkException(
      'That store blocked the free reader or asked for a captcha.$hint '
      'You can also open the link in a browser and try again later.',
    );
  }

  static bool _looksBlocked(String html, String title) {
    final lowerTitle = title.toLowerCase();
    if (lowerTitle.contains('too many requests') ||
        lowerTitle.contains('access denied') ||
        lowerTitle.contains('rate limit exceeded') ||
        lowerTitle.contains('captcha') ||
        lowerTitle.contains('robot check') ||
        lowerTitle.contains('just a moment') ||
        lowerTitle.contains('service unavailable') ||
        lowerTitle.contains('request blocked') ||
        lowerTitle.contains('attention required')) {
      return true;
    }

    final lower = html.toLowerCase();
    return lower.contains('looks like all of india is here') ||
        lower.contains('enter the characters you see below') ||
        lower.contains('verify you are human') ||
        lower.contains('unusual traffic') ||
        lower.contains('enable javascript and cookies to continue') ||
        lower.contains('request could not be satisfied') ||
        lower.contains('the request could not be satisfied') ||
        lower.contains('service unavailable error');
  }
}

/// Accepts a URL or share text containing a URL and returns a clean http(s) URL.
String normalizeProductLink(String raw) {
  var value = raw.trim();
  if (value.isEmpty) {
    throw const ProductLinkException('Paste a product link to continue.');
  }

  final urlMatch = RegExp(
    r'https?://[^\s<>"]+',
    caseSensitive: false,
  ).firstMatch(value);
  if (urlMatch != null) {
    value = urlMatch.group(0)!;
  } else {
    final hostMatch = RegExp(
      r'(?:^|\s)((?:www\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)+(?:/[^\s<>"]*)?)',
      caseSensitive: false,
    ).firstMatch(value);
    if (hostMatch == null) {
      throw const ProductLinkException(
        'That does not look like a product link. Paste the full URL from the store.',
      );
    }
    value = hostMatch.group(1)!;
    if (!value.toLowerCase().startsWith('http')) value = 'https://$value';
  }

  value = value.replaceFirst(RegExp(r'[)\].,;!]+$'), '');
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.hasAuthority ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      !uri.host.contains('.')) {
    throw const ProductLinkException(
      'That product link is invalid. Paste the full URL from the store.',
    );
  }
  return uri.toString();
}

/// Parses OpenGraph, JSON-LD Product data, and common store markup.
ProductLinkData parseProductHtml(
  String html,
  String sourceUrl, {
  DateTime? fetchedAt,
}) {
  final document = html_parser.parse(html);
  final meta = _MetaReader(document);
  final product = _findProduct(_jsonLdNodes(document));

  final parsedUrl = Uri.tryParse(sourceUrl);
  final sourceHost = (parsedUrl?.host ?? '').replaceFirst('www.', '');
  final siteName = _siteName(
    meta.get('og:site_name'),
    meta.get('application-name'),
    sourceHost,
  );

  final title = _cleanTitle(
    _firstNonEmpty([
      _string(product?['name']),
      meta.get('og:title'),
      meta.get('twitter:title'),
      _text(document, 'h1'),
      document.querySelector('title')?.text ?? '',
    ]),
    siteName,
  );

  final description = _description(document, product, meta);
  final brand = _firstNonEmpty([
    _string(product?['brand']),
    meta.get('product:brand'),
    _amazonBrand(_text(document, '#bylineInfo')),
  ]);
  final category = _firstNonEmpty([
    _string(product?['category']),
    meta.get('product:category'),
    _breadcrumbCategory(document),
  ]);

  final offer = _firstMap(product?['offers']);
  final rawPrice = _firstNonEmpty([
    _string(offer?['price']),
    _string(offer?['lowPrice']),
    _string(offer?['highPrice']),
    meta.get('product:price:amount'),
    meta.get('og:price:amount'),
    _text(document, '[itemprop="price"]'),
  ]);
  final currency = _firstNonEmpty([
    _string(offer?['priceCurrency']),
    meta.get('product:price:currency'),
    meta.get('og:price:currency'),
  ]);

  final price = _formatPrice(rawPrice, currency);
  final mrpRaw = _firstNonEmpty([
    _smallText(document, '[class*="mrp"]'),
    _smallText(document, 'del'),
    _smallText(document, '[class*="strike"]'),
  ]);
  final mrp = _sameCurrencyAs(price, mrpRaw, currency);
  final discount = _discount(
    _smallText(document, '[class*="discount"]'),
    document,
  );

  final ratingNode = _firstMap(product?['aggregateRating']);
  final rating = _firstNonEmpty([
    _string(ratingNode?['ratingValue']),
    meta.get('product:rating:value'),
  ]);
  final reviewCount = _formatCount(
    _firstNonEmpty([
      _string(ratingNode?['reviewCount']),
      _string(ratingNode?['ratingCount']),
      meta.get('product:rating:count'),
    ]),
  );

  final availability = _availability(
    _firstNonEmpty([
      _string(offer?['availability']),
      meta.get('product:availability'),
      meta.get('og:availability'),
    ]),
  );
  final seller = _firstNonEmpty([
    _string(_firstMap(offer?['seller'])?['name']),
    meta.get('product:seller'),
    _text(document, '#sellerProfileTriggerId'),
    _text(document, '#sellerName'),
  ]);
  final sku = _firstNonEmpty([
    _string(product?['sku']),
    _string(product?['mpn']),
    _string(product?['gtin13']),
    meta.get('product:retailer_item_id'),
  ]);

  final keyFeatures = _features(document, product, title, description);
  final keywords = _keywords(
    title,
    brand,
    category,
    keyFeatures,
    meta,
    product,
    description,
  );
  final photos = _photos(document, product, meta, title, sourceUrl);
  final specs = _specs(document, product);

  return ProductLinkData(
    sourceUrl: sourceUrl,
    sourceHost: sourceHost,
    siteName: siteName,
    title: title,
    description: description,
    brand: brand,
    price: price,
    mrp: mrp,
    discount: discount,
    rating: rating,
    reviewCount: reviewCount,
    availability: availability,
    seller: seller,
    category: category,
    sku: sku,
    keywords: keywords,
    keyFeatures: keyFeatures,
    photos: photos,
    specs: specs,
    fetchedAt: fetchedAt ?? DateTime.now(),
  );
}

/// Parses the markdown returned by the Serper scraper fallback.
ProductLinkData parseProductMarkdown(
  String markdown,
  String sourceUrl, {
  Map<String, dynamic>? metadata,
  dynamic images,
  DateTime? fetchedAt,
}) {
  final parsedUrl = Uri.tryParse(sourceUrl);
  final sourceHost = (parsedUrl?.host ?? '').replaceFirst('www.', '');
  final rawLines = markdown.split(RegExp(r'\r?\n'));
  final headings = <String, List<String>>{};
  var currentHeading = '';
  for (final raw in rawLines) {
    final heading = _markdownHeading(raw);
    if (heading != null) {
      currentHeading = heading.toLowerCase();
      headings.putIfAbsent(currentHeading, () => []);
      continue;
    }
    if (currentHeading.isNotEmpty) {
      headings[currentHeading]!.add(raw);
    }
  }

  final meta = metadata == null
      ? const <String, dynamic>{}
      : metadata.map(
          (key, value) => MapEntry(key.toString().toLowerCase(), value),
        );
  final siteName = _siteName(
    _string(meta['publisher'] ?? meta['site_name'] ?? meta['site']),
    '',
    sourceHost,
  );
  final title = _cleanTitle(
    _firstNonEmpty([
      _string(meta['title']),
      _firstMarkdownHeading(rawLines),
      _firstContentLine(rawLines),
    ]),
    siteName,
  );

  final description = _markdownDescription(rawLines, headings, meta);
  final specs = _markdownSpecs(rawLines, headings, meta);
  final keyFeatures = _markdownFeatures(rawLines, headings, title, description);
  final brand = _firstNonEmpty([
    _string(meta['brand']),
    _specValue(specs, const ['brand']),
  ]);
  final category = _firstNonEmpty([
    _string(meta['category']),
    _specValue(specs, const ['category', 'product category']),
  ]);
  final sku = _firstNonEmpty([
    _string(meta['sku']),
    _specValue(specs, const [
      'sku',
      'asin',
      'model number',
      'item model number',
      'product code',
    ]),
  ]);

  final priceMatches = RegExp(
    r'(?:₹|Rs\.?|INR)\s*([\d,]+(?:\.\d{1,2})?)',
    caseSensitive: false,
  ).allMatches(markdown);
  final prices = <String>[];
  for (final match in priceMatches) {
    final value = match.group(1) ?? '';
    if (value.trim().isNotEmpty && !prices.contains(value)) prices.add(value);
  }
  final price = prices.isEmpty ? '' : _formatPrice(prices.first, 'INR');
  var mrp = '';
  if (prices.length > 1) {
    final first = _priceNumber(prices.first);
    final second = _priceNumber(prices[1]);
    if (second > first) {
      mrp = _formatPrice(prices[1], 'INR');
    }
  }
  final discount =
      RegExp(
        r'(\d{1,2})%\s*off',
        caseSensitive: false,
      ).firstMatch(markdown)?.group(0) ??
      '';

  final rating =
      RegExp(
        r'(?<![\d.])([1-5](?:\.\d)?)\s*(?:★|out of 5|/5)',
        caseSensitive: false,
      ).firstMatch(markdown)?.group(1) ??
      RegExp(
        r'(?<![\d.])([1-5](?:\.\d)?)\s*\n\s*[\d,]{1,12}\s*(?:Ratings|Reviews)',
        caseSensitive: false,
      ).firstMatch(markdown)?.group(1) ??
      '';
  final reviewCount = _formatCount(
    RegExp(
          r'([\d,]+)\s*(?:Ratings|Reviews)',
          caseSensitive: false,
        ).firstMatch(markdown)?.group(1) ??
        '',
  );

  final availability = _availability(
    RegExp(
          r'In stock|Out of stock|Currently unavailable|Sold out',
          caseSensitive: false,
        ).firstMatch(markdown)?.group(0) ??
        '',
  );
  final seller = _cleanText(
    RegExp(
          r'(?:Sold by|Seller)\s*:?\s*([^\n|]{2,80})',
          caseSensitive: false,
        ).firstMatch(markdown)?.group(1) ??
        '',
  );
  final photos = _markdownPhotos(markdown, images, meta, title, sourceUrl);
  final keywords = _keywordsFromParts(
    title: title,
    brand: brand,
    category: category,
    features: keyFeatures,
    description: description,
    extra: [
      _string(meta['keywords']),
      if (meta['tags'] is List)
        for (final tag in meta['tags'] as List) _string(tag),
    ],
  );

  return ProductLinkData(
    sourceUrl: sourceUrl,
    sourceHost: sourceHost,
    siteName: siteName,
    title: title,
    description: description,
    brand: brand,
    price: price,
    mrp: mrp,
    discount: discount,
    rating: rating,
    reviewCount: reviewCount,
    availability: availability,
    seller: seller,
    category: category,
    sku: sku,
    keywords: keywords,
    keyFeatures: keyFeatures,
    photos: photos,
    specs: specs,
    fetchedAt: fetchedAt ?? DateTime.now(),
  );
}

String? _markdownHeading(String raw) {
  final simple = RegExp(r'^\s*#{1,6}\s+(.+?)\s*#*\s*$').firstMatch(raw);
  if (simple != null) return _cleanText(simple.group(1)!);
  final bold = RegExp(r'^\s*\*\*([^*]{2,80})\*\*\s*:?\s*$').firstMatch(raw);
  if (bold != null) return _cleanText(bold.group(1)!);
  return null;
}

String _firstMarkdownHeading(List<String> lines) {
  for (final line in lines) {
    final heading = RegExp(r'^\s*#{1,6}\s+(.+?)\s*#*\s*$').firstMatch(line);
    if (heading != null) return _cleanText(heading.group(1)!);
  }
  return '';
}

String _firstContentLine(List<String> lines) {
  for (final line in lines) {
    final value = _cleanMarkdownLine(line);
    if (value.length < 2 || value.startsWith('<')) continue;
    if (RegExp(
      r'^(image|shop now|add to cart|buy now)$',
      caseSensitive: false,
    ).hasMatch(value)) {
      continue;
    }
    return value;
  }
  return '';
}

String _cleanMarkdownLine(String raw) {
  var value = raw.trim();
  value = value.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ');
  value = value.replaceAllMapped(
    RegExp(r'\[([^\]]+)\]\([^)]*\)'),
    (match) => match.group(1) ?? '',
  );
  value = value.replaceAll(RegExp(r'^\s*#{1,6}\s*'), '');
  value = value.replaceAll(RegExp(r'^\s*[-*+]\s+'), '');
  value = value.replaceAll(RegExp(r'^\s*\d+[.)]\s+'), '');
  value = value.replaceAll(RegExp(r'[*_`>]'), '');
  return _cleanText(value);
}

List<String> _sectionLines(
  Map<String, List<String>> headings,
  List<String> names,
) {
  final lines = <String>[];
  for (final entry in headings.entries) {
    if (names.any((name) => entry.key.contains(name))) {
      lines.addAll(entry.value);
    }
  }
  return lines;
}

String _markdownDescription(
  List<String> rawLines,
  Map<String, List<String>> headings,
  Map<String, dynamic> meta,
) {
  final candidates = <String>[_string(meta['description'])];
  final section = _sectionLines(headings, const [
    'description',
    'product description',
    'about this item',
    'product overview',
    'overview',
  ]);
  if (section.isNotEmpty) {
    candidates.add(
      section
          .map(_cleanMarkdownLine)
          .where((line) => line.length > 20)
          .take(8)
          .join(' '),
    );
  }
  var description = '';
  for (final candidate in candidates) {
    final value = _cleanText(candidate);
    if (value.length > description.length) description = value;
    if (description.length >= 120) break;
  }
  if (description.isEmpty) {
    for (final line in rawLines) {
      final value = _cleanMarkdownLine(line);
      if (value.length < 60 || value.length > 1800) continue;
      if (_featureNoise.hasMatch(value) || value.contains('₹')) continue;
      if (value.length > description.length) description = value;
    }
  }
  if (description.length > 1800) {
    description = '${description.substring(0, 1797).trimRight()}...';
  }
  return description;
}

List<String> _markdownFeatures(
  List<String> rawLines,
  Map<String, List<String>> headings,
  String title,
  String description,
) {
  final values = <String>[
    ..._sectionLines(headings, const [
      'key features',
      'features',
      'highlights',
      'product highlights',
      'about this item',
      'why you',
      'usp',
    ]),
  ];
  if (values.isEmpty) {
    for (final line in rawLines) {
      if (!RegExp(r'^\s*[-*+]\s+').hasMatch(line)) continue;
      values.add(line);
    }
  }

  final seen = <String>{};
  final features = <String>[];
  for (final raw in values) {
    final value = _cleanMarkdownLine(raw);
    final key = value.toLowerCase();
    if (value.length < 24 || value.length > 260) continue;
    if (!seen.add(key)) continue;
    if (value.toLowerCase() == title.toLowerCase()) continue;
    if (description.toLowerCase().contains(key)) continue;
    if (_featureNoise.hasMatch(value)) continue;
    if (value.contains('₹') || value.contains('% off')) continue;
    features.add(value);
    if (features.length == _maxFeatures) break;
  }
  return features;
}

List<ProductSpec> _markdownSpecs(
  List<String> rawLines,
  Map<String, List<String>> headings,
  Map<String, dynamic> meta,
) {
  final rows = <ProductSpec>[];
  final seen = <String>{};

  void add(String label, String value) {
    final cleanLabel = _cleanText(label);
    final cleanValue = _cleanText(value);
    final key = cleanLabel.toLowerCase();
    if (cleanLabel.length < 2 || cleanLabel.length > 70) return;
    if (cleanValue.isEmpty || cleanValue.length > 320) return;
    if (cleanValue.toLowerCase() == cleanLabel.toLowerCase()) return;
    if (!seen.add(key)) return;
    rows.add(ProductSpec(label: cleanLabel, value: cleanValue));
  }

  void addLine(String raw) {
    final line = _cleanMarkdownLine(raw);
    if (line.isEmpty) return;
    if (line.contains('|')) {
      final cells = line
          .split('|')
          .map((cell) => cell.trim())
          .where((cell) => cell.isNotEmpty)
          .toList();
      if (cells.length >= 2) {
        add(cells[0], cells[1]);
      }
      return;
    }
    final match = RegExp(r'^([^:]{2,60}):\s*(.{1,300})$').firstMatch(line);
    if (match != null) {
      add(match.group(1)!, match.group(2)!);
    }
  }

  for (final raw in rawLines) {
    if (raw.contains('|')) addLine(raw);
  }
  final specLines = _sectionLines(headings, const [
    'specification',
    'technical details',
    'product information',
    'product details',
    'additional information',
    'general',
    'details',
  ]);
  for (final raw in specLines) {
    addLine(raw);
  }

  for (final key in [
    'brand',
    'category',
    'sku',
    'color',
    'material',
    'weight',
  ]) {
    final value = _string(meta[key]);
    if (value.isNotEmpty) add(_titleCase(key), value);
  }
  return rows.take(_maxSpecs).toList();
}

String _specValue(List<ProductSpec> specs, List<String> labels) {
  for (final label in labels) {
    for (final spec in specs) {
      if (spec.label.toLowerCase() == label) return spec.value;
    }
  }
  return '';
}

List<ProductPhoto> _markdownPhotos(
  String markdown,
  dynamic images,
  Map<String, dynamic> meta,
  String title,
  String sourceUrl,
) {
  final candidates = <String>[];
  void add(dynamic value) {
    if (value is String) {
      candidates.add(value);
    } else if (value is List) {
      for (final item in value) {
        add(item);
      }
    } else if (value is Map) {
      add(
        value['url'] ?? value['src'] ?? value['image'] ?? value['contentUrl'],
      );
    }
  }

  for (final key in const [
    'image',
    'og:image',
    'og:image:url',
    'og:image:secure_url',
    'twitter:image',
    'twitter:image:src',
    'thumbnail',
    'thumbnailurl',
  ]) {
    add(meta[key]);
  }
  add(images);
  for (final match in RegExp(
    r'!\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)',
  ).allMatches(markdown)) {
    add(match.group(1));
  }

  var photos = _collectPhotos(candidates, sourceUrl, title);
  if (photos.length < 3) {
    candidates.addAll(_inlineImageUrls(markdown));
    photos = _collectPhotos(candidates, sourceUrl, title);
  }
  return [
    for (final photo in photos)
      ProductPhoto(url: _upscaleFlipkartImage(photo.url), alt: photo.alt),
  ];
}

/// Flipkart's page metadata only carries a 300px thumbnail; the same path
/// serves a listing-sized image.
String _upscaleFlipkartImage(String url) {
  if (!url.contains('flixcart.com/image/')) return url;
  return url.replaceFirstMapped(RegExp(r'/image/(\d+)/(\d+)/'), (match) {
    final width = int.parse(match.group(1)!);
    final height = int.parse(match.group(2)!);
    return width < 832 && height < 832 ? '/image/832/832/' : match.group(0)!;
  });
}

double _priceNumber(String raw) {
  final value = raw.replaceAll(RegExp(r'[^0-9.]'), '');
  return double.tryParse(value) ?? 0;
}

class _MetaReader {
  _MetaReader(dom.Document document) {
    for (final element in document.querySelectorAll('meta')) {
      final key =
          element.attributes['property'] ??
          element.attributes['name'] ??
          element.attributes['itemprop'];
      final content = element.attributes['content'];
      if (key == null || content == null) continue;
      final normalized = key.trim().toLowerCase();
      if (normalized.isEmpty || content.trim().isEmpty) continue;
      _values.putIfAbsent(normalized, () => []).add(content.trim());
    }
  }

  final Map<String, List<String>> _values = {};

  String get(String key) => _values[key.toLowerCase()]?.first ?? '';

  List<String> all(String key) => _values[key.toLowerCase()] ?? const [];
}

List<dynamic> _jsonLdNodes(dom.Document document) {
  final nodes = <dynamic>[];
  for (final script in document.querySelectorAll(
    'script[type="application/ld+json"]',
  )) {
    final raw = script.text.trim();
    if (raw.isEmpty) continue;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        nodes.addAll(decoded);
      } else {
        nodes.add(decoded);
      }
    } catch (_) {
      // Ignore malformed JSON-LD blocks.
    }
  }
  return nodes;
}

Map<String, dynamic>? _findProduct(dynamic node) {
  if (node is Map) {
    if (_isProductType(node['@type'])) {
      return node.map((key, value) => MapEntry(key.toString(), value));
    }
    for (final value in node.values) {
      final found = _findProduct(value);
      if (found != null) return found;
    }
  } else if (node is List) {
    for (final value in node) {
      final found = _findProduct(value);
      if (found != null) return found;
    }
  }
  return null;
}

bool _isProductType(dynamic value) {
  if (value is String) return value.toLowerCase().contains('product');
  if (value is List) {
    return value.any(
      (item) => item is String && item.toLowerCase().contains('product'),
    );
  }
  return false;
}

Map<String, dynamic>? _firstMap(dynamic value) {
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  if (value is List) {
    for (final item in value) {
      final map = _firstMap(item);
      if (map != null) return map;
    }
  }
  return null;
}

String _string(dynamic value) {
  if (value is String) return _cleanText(value);
  if (value is num) return value.toString();
  if (value is Map) {
    return _string(
      value['name'] ?? value['value'] ?? value['url'] ?? value['@id'],
    );
  }
  if (value is List) {
    return value.map(_string).where((item) => item.isNotEmpty).join(', ');
  }
  return '';
}

String _firstNonEmpty(List<String> values) {
  for (final value in values) {
    final cleaned = value.trim();
    if (cleaned.isNotEmpty) return cleaned;
  }
  return '';
}

String _text(dom.Document document, String selector) {
  final element = document.querySelector(selector);
  return element == null ? '' : _cleanText(element.text);
}

String _smallText(dom.Document document, String selector) {
  for (final element in document.querySelectorAll(selector)) {
    final text = _cleanText(element.text);
    if (text.isEmpty || text.length > 24 || !RegExp(r'\d').hasMatch(text)) {
      continue;
    }
    return text;
  }
  return '';
}

String _cleanText(String raw) {
  if (raw.isEmpty) return '';
  final text = html_parser.parseFragment(raw).text ?? raw;
  return text.replaceAll('\u00a0', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _cleanTitle(String raw, String siteName) {
  var title = _cleanText(raw);
  final suffixes = <String>{
    if (siteName.isNotEmpty) siteName,
    'flipkart.com',
    'flipkart',
    'amazon.in',
    'amazon.com',
    'meesho',
    'myntra',
    'ajio',
    'jiomart',
    'snapdeal',
    'nykaa',
    'tatacliq',
  };
  for (final suffix in suffixes) {
    title = title.replaceFirst(
      RegExp(
        r'\s*[|\-:]\s*' + RegExp.escape(suffix) + r'\s*$',
        caseSensitive: false,
      ),
      '',
    );
  }
  return title.trim();
}

String _siteName(String ogSiteName, String appName, String host) {
  final explicit = _firstNonEmpty([ogSiteName, appName]);
  if (explicit.isNotEmpty) return explicit;
  final lower = host.toLowerCase();
  if (lower.contains('flipkart')) return 'Flipkart';
  if (lower.contains('amazon')) return 'Amazon';
  if (lower.contains('meesho')) return 'Meesho';
  if (lower.contains('myntra')) return 'Myntra';
  if (lower.contains('ajio')) return 'AJIO';
  if (lower.contains('jiomart')) return 'JioMart';
  if (lower.contains('snapdeal')) return 'Snapdeal';
  if (lower.contains('nykaa')) return 'Nykaa';
  if (lower.contains('tatacliq')) return 'Tata CLiQ';
  if (host.isEmpty) return 'Product store';
  return host;
}

String _description(
  dom.Document document,
  Map<String, dynamic>? product,
  _MetaReader meta,
) {
  final candidates = <String>[
    _string(product?['description']),
    meta.get('og:description'),
    meta.get('description'),
    meta.get('twitter:description'),
    _text(document, '#productDescription'),
    _text(document, '[data-testid="product-description"]'),
    _text(document, '[class*="product-description"]'),
    _text(document, '[class*="productDescription"]'),
  ];
  var description = '';
  for (final candidate in candidates) {
    if (candidate.length > description.length) description = candidate;
    if (description.length >= 120) break;
  }
  if (description.length > 1800) {
    description = '${description.substring(0, 1797).trimRight()}...';
  }
  return description;
}

List<String> _features(
  dom.Document document,
  Map<String, dynamic>? product,
  String title,
  String description,
) {
  final values = <String>[];
  final jsonFeatures = product?['featureList'];
  if (jsonFeatures is String) {
    values.addAll(jsonFeatures.split(RegExp(r'[\n|•]')));
  } else if (jsonFeatures is List) {
    values.addAll(jsonFeatures.map(_string));
  }

  const selectors = [
    '#feature-bullets li',
    '#feature-bullets span.a-list-item',
    '[class*="feature"] li',
    '[class*="Feature"] li',
    '[class*="highlight"] li',
    '[class*="Highlight"] li',
    '[class*="usp"] li',
    '[class*="key-feature"] li',
    '[data-testid*="feature"] li',
  ];
  for (final selector in selectors) {
    for (final element in document.querySelectorAll(selector)) {
      values.add(element.text);
    }
  }

  if (values.length < 2) {
    for (final element in document.querySelectorAll('li')) {
      if (_insideNavigation(element)) continue;
      if (element.querySelectorAll('a').length > 1) continue;
      values.add(element.text);
    }
  }

  final seen = <String>{};
  final features = <String>[];
  for (final raw in values) {
    final value = _cleanText(raw);
    final key = value.toLowerCase();
    if (value.length < 24 || value.length > 260) continue;
    if (!seen.add(key)) continue;
    if (value.toLowerCase() == title.toLowerCase()) continue;
    if (description.toLowerCase().contains(key)) continue;
    if (_featureNoise.hasMatch(value)) continue;
    features.add(value);
    if (features.length == _maxFeatures) break;
  }
  return features;
}

final _featureNoise = RegExp(
  r'add to cart|buy now|view all|see more|terms|privacy|copyright|'
  r'customer service|return policy|share|wishlist|login|sign up',
  caseSensitive: false,
);

bool _insideNavigation(dom.Element element) {
  dom.Node? node = element.parent;
  while (node != null) {
    if (node is dom.Element) {
      final name = node.localName;
      if (name == 'nav' || name == 'header' || name == 'footer') return true;
    }
    node = node.parent;
  }
  return false;
}

List<String> _keywords(
  String title,
  String brand,
  String category,
  List<String> features,
  _MetaReader meta,
  Map<String, dynamic>? product,
  String description,
) {
  final fromPage = <String>[];
  void addRaw(String raw) {
    for (final item in raw.split(',')) {
      final value = item.trim();
      if (value.length >= 2 && value.length <= 48) fromPage.add(value);
    }
  }

  addRaw(meta.get('keywords'));
  addRaw(meta.get('news_keywords'));
  final jsonKeywords = product?['keywords'];
  if (jsonKeywords is String) addRaw(jsonKeywords);
  if (jsonKeywords is List) {
    for (final item in jsonKeywords) {
      addRaw(_string(item));
    }
  }
  for (final tag in meta.all('article:tag')) {
    addRaw(tag);
  }

  return _keywordsFromParts(
    title: title,
    brand: brand,
    category: category,
    features: features,
    description: description,
    extra: fromPage,
  );
}

List<String> _keywordsFromParts({
  required String title,
  required String brand,
  required String category,
  required List<String> features,
  required String description,
  required List<String> extra,
}) {
  final seen = <String>{};
  final keywords = <String>[];
  void add(String value) {
    final cleaned = value.trim();
    final key = cleaned.toLowerCase();
    if (cleaned.isEmpty || !seen.add(key)) return;
    if (_keywordNoise.contains(key)) return;
    keywords.add(cleaned);
  }

  for (final raw in extra) {
    for (final item in raw.split(',')) {
      add(item);
      if (keywords.length == _maxKeywords) return keywords;
    }
  }

  final weighted = <String, int>{};
  void weigh(String text, int weight) {
    for (final match in RegExp(
      r"[a-z][a-z0-9+]{2,}",
      caseSensitive: false,
    ).allMatches(text.toLowerCase())) {
      final word = match.group(0)!;
      if (_keywordNoise.contains(word)) continue;
      weighted.update(word, (count) => count + weight, ifAbsent: () => weight);
    }
  }

  weigh(title, 4);
  weigh(brand, 4);
  weigh(category, 2);
  for (final feature in features.take(5)) {
    weigh(feature, 1);
  }
  weigh(description, 1);

  final generated = weighted.entries.toList()
    ..sort((a, b) {
      final byWeight = b.value.compareTo(a.value);
      return byWeight == 0 ? a.key.compareTo(b.key) : byWeight;
    });
  for (final entry in generated) {
    add(entry.key);
    if (keywords.length == _maxKeywords) break;
  }
  return keywords;
}

const _keywordNoise = <String>{
  'add',
  'buy',
  'cart',
  'cod',
  'delivery',
  'details',
  'discount',
  'free',
  'from',
  'india',
  'online',
  'price',
  'product',
  'products',
  'rating',
  'ratings',
  'review',
  'reviews',
  'sale',
  'seller',
  'shop',
  'shopping',
  'specification',
  'specifications',
  'the',
  'this',
  'with',
  'and',
  'for',
  'you',
  'your',
  'was',
  'are',
  'that',
  'have',
  'has',
  'not',
  'all',
  'new',
  'best',
  'top',
  'more',
  'off',
  'get',
  'set',
  'per',
  'www',
  'com',
  'flipkart',
  'amazon',
  'meesho',
  'myntra',
};

List<ProductPhoto> _photos(
  dom.Document document,
  Map<String, dynamic>? product,
  _MetaReader meta,
  String title,
  String sourceUrl,
) {
  final candidates = <String>[];
  void add(dynamic value) {
    if (value is String) {
      candidates.add(value);
    } else if (value is List) {
      for (final item in value) {
        add(item);
      }
    } else if (value is Map) {
      add(value['url'] ?? value['contentUrl'] ?? value['@id']);
    }
  }

  add(product?['image']);
  for (final key in [
    'og:image',
    'og:image:url',
    'og:image:secure_url',
    'twitter:image',
    'twitter:image:src',
    'image',
    'thumbnail',
    'thumbnailurl',
  ]) {
    for (final value in meta.all(key)) {
      candidates.add(value);
    }
  }
  for (final link in document.querySelectorAll('link[rel="image_src"]')) {
    final href = link.attributes['href'];
    if (href != null && href.trim().isNotEmpty) candidates.add(href);
  }

  for (final image in document.querySelectorAll('img')) {
    for (final attribute in [
      'src',
      'data-src',
      'data-old-hires',
      'data-lazy-src',
    ]) {
      final value = image.attributes[attribute];
      if (value != null && value.trim().isNotEmpty) candidates.add(value);
    }
    final srcset = image.attributes['srcset'];
    if (srcset != null && srcset.trim().isNotEmpty) {
      candidates.add(srcset.split(',').first.trim().split(' ').first);
    }
    final dynamicImage = image.attributes['data-a-dynamic-image'];
    if (dynamicImage != null && dynamicImage.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(dynamicImage);
        if (decoded is Map) {
          candidates.addAll(decoded.keys.map((key) => '$key'));
        }
      } catch (_) {
        // Ignore malformed image attributes.
      }
    }
  }

  var photos = _collectPhotos(candidates, sourceUrl, title);
  if (photos.length < 3) {
    candidates.addAll(_inlineImageUrls(document.outerHtml));
    photos = _collectPhotos(candidates, sourceUrl, title);
  }
  return photos;
}

List<String> _inlineImageUrls(String raw) {
  final text = raw
      .replaceAll('\\/', '/')
      .replaceAll('\\u002F', '/')
      .replaceAll('\\u002f', '/')
      .replaceAll('&#x2F;', '/')
      .replaceAll('&#47;', '/')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"');
  final patterns = [
    RegExp(
      r'''https?://[^\s"'<>\\]+?\.(?:jpe?g|png|webp|gif|avif)(?:\?[^\s"'<>\\]*)?''',
      caseSensitive: false,
    ),
    RegExp(
      r'''https?://(?:rukminim\d*\.flixcart\.com|m\.media-amazon\.com|images\.meesho\.com|assets\.myntassets\.com|assets\.ajio\.com|images-static\.nykaa\.com|img\.tatacliq\.com|www\.jiomart\.com/images)[^\s"'<>\\]+''',
      caseSensitive: false,
    ),
  ];

  final urls = <String>[];
  final seen = <String>{};
  for (final pattern in patterns) {
    for (final match in pattern.allMatches(text)) {
      var url = match.group(0) ?? '';
      url = url.replaceFirst(RegExp(r'[)\].,;!]+$'), '');
      if (url.isEmpty || !seen.add(url)) continue;
      urls.add(url);
    }
  }
  return urls;
}

String _normalizeImageUrl(String raw, String baseUrl) {
  var value = raw.trim();
  if (value.isEmpty) return '';
  if (value.startsWith('//')) value = 'https:$value';
  if (value.startsWith('data:')) return '';
  final uri = Uri.tryParse(value);
  if (uri == null) return '';
  if (uri.hasScheme) return uri.toString();
  final base = Uri.tryParse(baseUrl);
  if (base == null) return '';
  return base.resolveUri(uri).toString();
}

List<ProductPhoto> _collectPhotos(
  List<String> candidates,
  String sourceUrl,
  String title,
) {
  final photos = <ProductPhoto>[];
  final indexes = <String, int>{};
  final scores = <String, int>{};

  for (final raw in candidates) {
    final url = _normalizeImageUrl(raw, sourceUrl);
    if (url.isEmpty) continue;
    final lower = url.toLowerCase();
    if (lower.startsWith('data:') ||
        lower.startsWith('blob:') ||
        lower.contains('sprite') ||
        lower.contains('/logo') ||
        lower.contains('logo.') ||
        lower.contains('icon') ||
        lower.contains('avatar') ||
        lower.contains('placeholder') ||
        lower.contains('loading') ||
        lower.contains('pixel') ||
        lower.contains('tracking') ||
        lower.contains('banner') ||
        lower.contains('promo') ||
        lower.contains('surge') ||
        lower.endsWith('.svg')) {
      continue;
    }

    final key = _photoKey(url);
    final score = _photoScore(url);
    final existing = indexes[key];
    if (existing != null) {
      if (score > (scores[key] ?? 0)) {
        photos[existing] = ProductPhoto(url: url, alt: title);
        scores[key] = score;
      }
      continue;
    }
    if (photos.length >= _maxPhotos) continue;
    indexes[key] = photos.length;
    scores[key] = score;
    photos.add(ProductPhoto(url: url, alt: title));
  }
  return photos;
}

String _photoKey(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  var path = uri.path.replaceFirst(RegExp(r'/image/\d+/\d+/'), '/image/');
  final file = path.split('/').last;
  final amazon = RegExp(
    r'^(.*?)\._[A-Z0-9_,]+_\.(jpe?g|png|webp)$',
    caseSensitive: false,
  ).firstMatch(file);
  if (amazon != null) {
    path = path.replaceFirst(file, '${amazon.group(1)}.${amazon.group(2)}');
  }
  return '${uri.host.toLowerCase()}$path';
}

int _photoScore(String url) {
  final uri = Uri.tryParse(url);
  final path = uri?.path ?? url;
  final flipkart = RegExp(r'/image/(\d+)/(\d+)/').firstMatch(path);
  if (flipkart != null) {
    final width = int.tryParse(flipkart.group(1) ?? '') ?? 0;
    final height = int.tryParse(flipkart.group(2) ?? '') ?? 0;
    return width * height;
  }

  final file = path.split('/').last;
  final amazon = RegExp(
    r'\._([A-Z0-9_,]+)_\.',
    caseSensitive: false,
  ).firstMatch(file);
  if (amazon == null) return 0;
  var best = 0;
  for (final match in RegExp(r'\d{2,5}').allMatches(amazon.group(1) ?? '')) {
    final value = int.tryParse(match.group(0) ?? '') ?? 0;
    if (value > best) best = value;
  }
  return best;
}

List<ProductSpec> _specs(dom.Document document, Map<String, dynamic>? product) {
  final rows = <ProductSpec>[];
  final seen = <String>{};

  void add(String label, String value) {
    final cleanLabel = _cleanText(label);
    final cleanValue = _cleanText(value);
    final key = cleanLabel.toLowerCase();
    if (cleanLabel.length < 2 || cleanLabel.length > 70) return;
    if (cleanValue.isEmpty || cleanValue.length > 320) return;
    if (cleanValue.toLowerCase() == cleanLabel.toLowerCase()) return;
    if (!seen.add(key)) return;
    rows.add(ProductSpec(label: cleanLabel, value: cleanValue));
  }

  final additional = product?['additionalProperty'];
  final additionalItems = additional is List ? additional : [additional];
  for (final item in additionalItems) {
    final map = _firstMap(item);
    if (map != null) add(_string(map['name']), _string(map['value']));
  }
  for (final key in ['color', 'material', 'size', 'weight', 'model']) {
    final value = product?[key];
    if (value != null) add(_titleCase(key), _string(value));
  }

  for (final table in document.querySelectorAll('table')) {
    if (_insideNavigation(table)) continue;
    for (final row in table.querySelectorAll('tr')) {
      final cells = row.children
          .where((cell) => cell.localName == 'th' || cell.localName == 'td')
          .toList();
      if (cells.length == 2) {
        add(cells[0].text, cells[1].text);
      } else if (cells.length == 4) {
        add(cells[0].text, cells[1].text);
        add(cells[2].text, cells[3].text);
      }
    }
  }

  for (final term in document.querySelectorAll('dt')) {
    final definition = term.nextElementSibling;
    if (definition != null && definition.localName == 'dd') {
      add(term.text, definition.text);
    }
  }

  return rows.take(_maxSpecs).toList();
}

String _breadcrumbCategory(dom.Document document) {
  final items = document.querySelectorAll(
    '[class*="breadcrumb"] a, nav[aria-label*="readcrumb"] a',
  );
  if (items.length < 2) return '';
  return _cleanText(items[items.length - 2].text);
}

String _amazonBrand(String byline) {
  final text = _cleanText(byline);
  if (text.isEmpty) return '';
  return text
      .replaceFirst(RegExp(r'^visit the\s+', caseSensitive: false), '')
      .replaceFirst(RegExp(r'\s+store$', caseSensitive: false), '')
      .trim();
}

String _availability(String raw) {
  final lower = raw.toLowerCase();
  if (lower.contains('instock') || lower.contains('in stock')) {
    return 'In stock';
  }
  if (lower.contains('outofstock') || lower.contains('out of stock')) {
    return 'Out of stock';
  }
  if (lower.contains('preorder') || lower.contains('pre-order')) {
    return 'Pre-order';
  }
  if (lower.contains('backorder') || lower.contains('back-order')) {
    return 'Backorder';
  }
  return raw;
}

String _formatPrice(String raw, String currency) {
  var value = _cleanText(raw);
  if (value.isEmpty) return '';
  value = value.replaceAll(RegExp(r'[^\d.,]'), '');
  if (value.isEmpty) return '';
  final parts = value.split('.');
  final whole = parts.first.replaceAll(',', '');
  final decimals = parts.length > 1 ? parts[1] : '';
  if (whole.isEmpty) return '';
  final code = currency.toUpperCase();
  final symbol = switch (code) {
    'INR' || '' => '\u20b9',
    'USD' => '\$',
    'EUR' => '\u20ac',
    'GBP' => '\u00a3',
    _ => '',
  };
  final amount = code == 'INR' || code.isEmpty
      ? _groupIndian(whole)
      : _groupWestern(whole);
  final fraction = decimals.isEmpty || RegExp(r'^0+$').hasMatch(decimals)
      ? ''
      : '.${decimals.length > 2 ? decimals.substring(0, 2) : decimals}';
  if (symbol.isEmpty) return '$code $amount$fraction';
  return '$symbol$amount$fraction';
}

String _sameCurrencyAs(String price, String raw, String currency) {
  if (price.isEmpty || raw.isEmpty) return '';
  final formatted = _formatPrice(raw, currency);
  return formatted == price ? '' : formatted;
}

String _discount(String value, dom.Document document) {
  if (value.contains('%')) return value;
  final text = _text(document, '[class*="discount"]');
  if (text.contains('%') && text.length <= 24) return text;
  return '';
}

String _formatCount(String raw) {
  final value = _cleanText(raw);
  if (value.isEmpty) return '';
  final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty || digits.length > 9) return value;
  final numeric = int.tryParse(digits);
  if (numeric == null) return value;
  return _groupIndian('$numeric');
}

String _groupIndian(String digits) {
  if (digits.length <= 3) return digits;
  final last = digits.substring(digits.length - 3);
  var rest = digits.substring(0, digits.length - 3);
  final groups = <String>[];
  while (rest.length > 2) {
    groups.insert(0, rest.substring(rest.length - 2));
    rest = rest.substring(0, rest.length - 2);
  }
  if (rest.isNotEmpty) groups.insert(0, rest);
  return '${groups.join(',')},$last';
}

String _groupWestern(String digits) {
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

String _titleCase(String value) {
  if (value.isEmpty) return value;
  return value[0].toUpperCase() + value.substring(1);
}
