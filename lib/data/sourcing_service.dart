import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models/sourcing_supplier.dart';

/// Abstract contract for finding wholesale product suppliers.
abstract class SourcingSource {
  bool get isConfigured;
  Future<SourcingSnapshot> searchSellers(
    String query, {
    SourcingPlatform platform = SourcingPlatform.all,
  });

  /// Reads the public seller profile to add a contact person and phone number.
  Future<SourcingSupplier> fetchContact(SourcingSupplier supplier);
}

class SourcingException implements Exception {
  const SourcingException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Finds wholesale sellers on IndiaMART and TradeIndia.
///
/// The public reader is used first, so no API key is required. If both portal
/// pages cannot be read and a Serper key is saved, a web search is used as a
/// final fallback.
class WebSourcingService implements SourcingSource {
  WebSourcingService(
    this._prefs, {
    http.Client? client,
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       _clock = clock ?? DateTime.now;

  static const _keyPrefs = 'seller.market.serper.v1';
  static const _searchEndpoint = 'https://google.serper.dev/search';
  static const _maxSuppliers = 20;

  final SharedPreferences _prefs;
  final http.Client _client;
  final DateTime Function() _clock;
  final Map<String, SourcingSupplier> _contactCache = {};

  String get _key => (_prefs.getString(_keyPrefs) ?? '').trim();

  @override
  bool get isConfigured => _key.isNotEmpty;

  @override
  Future<SourcingSnapshot> searchSellers(
    String query, {
    SourcingPlatform platform = SourcingPlatform.all,
  }) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) {
      throw const SourcingException('Type a product name to find sellers.');
    }

    final liveSuppliers = await _searchPortalPages(cleanQuery, platform);
    if (liveSuppliers.isNotEmpty) {
      final labels = <String>{
        for (final supplier in liveSuppliers) supplier.platform.label,
      }.join(' & ');
      return SourcingSnapshot(
        suppliers: liveSuppliers,
        query: cleanQuery,
        platform: platform,
        sourceDescription: 'Live $labels seller listings',
        fetchedAt: _clock(),
      );
    }

    if (isConfigured) {
      try {
        final webSuppliers = await _searchWebSuppliers(cleanQuery, platform);
        if (webSuppliers.isNotEmpty) {
          return SourcingSnapshot(
            suppliers: webSuppliers,
            query: cleanQuery,
            platform: platform,
            sourceDescription: 'Live B2B web search (Serper)',
            fetchedAt: _clock(),
          );
        }
      } catch (_) {
        // Fall through to the clear error below.
      }
    }

    throw SourcingException(
      'No seller listings were found for "$cleanQuery". Try a broader product '
      'name or open the IndiaMART/TradeIndia search links.',
    );
  }

  @override
  Future<SourcingSupplier> fetchContact(SourcingSupplier supplier) async {
    if (supplier.hasContact) return supplier;
    final cached = _contactCache[supplier.url];
    if (cached != null) return cached;

    final isIndiaMart = supplier.platform == SourcingPlatform.indiaMart;
    final profileUrl = _contactPageUri(supplier);
    final response = await _client
        .get(
          Uri.parse('https://r.jina.ai/$profileUrl'),
          headers: isIndiaMart ? const {'X-Return-Format': 'html'} : null,
        )
        .timeout(const Duration(seconds: 45));

    if (response.statusCode != 200) {
      throw SourcingException(
        'Could not read contact details (HTTP ${response.statusCode}).',
      );
    }

    final content = utf8.decode(response.bodyBytes, allowMalformed: true);
    final contactPerson = isIndiaMart
        ? _indiaMartContactPerson(content)
        : _tradeIndiaContactPerson(content);
    final contactPhone = isIndiaMart
        ? _indiaMartPhone(content)
        : _tradeIndiaPhone(content);

    final enriched = supplier.copyWith(
      contactPerson: contactPerson.isEmpty
          ? supplier.contactPerson
          : contactPerson,
      contactPhone: contactPhone.isEmpty ? supplier.contactPhone : contactPhone,
    );
    _contactCache[supplier.url] = enriched;
    return enriched;
  }

  static String _contactPageUri(SourcingSupplier supplier) {
    final uri = Uri.tryParse(supplier.url);
    if (uri == null || !uri.hasAuthority) return supplier.url;
    if (supplier.platform == SourcingPlatform.indiaMart &&
        uri.pathSegments.length >= 2 &&
        uri.pathSegments.first == 'company') {
      return Uri.https(
        'www.indiamart.com',
        '/company/${uri.pathSegments[1]}/',
      ).toString();
    }
    return Uri(scheme: uri.scheme, host: uri.host, path: uri.path).toString();
  }

  static String _indiaMartContactPerson(String content) {
    final footer = RegExp(r'footer__contact-name[^>]*>([^<]+)<')
        .firstMatch(content)
        ?.group(1);
    final owner = RegExp(r'"owner_name"\s*:\s*"([^"]+)"')
        .firstMatch(content)
        ?.group(1);
    final contactPerson = RegExp(r'"contactPerson"\s*:\s*"([^"]+)"')
        .firstMatch(content)
        ?.group(1);
    return _cleanText(footer ?? contactPerson ?? owner ?? '');
  }

  static String _indiaMartPhone(String content) {
    final raw = RegExp(r'"pnsNumber"\s*:\s*"([^"]+)"')
        .firstMatch(content)
        ?.group(1);
    return _cleanPhone(raw ?? '');
  }

  static String _tradeIndiaContactPerson(String content) {
    final owner = _firstGroup(content, r'"owner_name"\s*:\s*"([^"]+)"');
    final designation = _firstGroup(content, r'"desg"\s*:\s*"([^"]+)"');
    if (owner.isNotEmpty) {
      if (designation.isEmpty ||
          owner.toLowerCase().contains(designation.toLowerCase())) {
        return owner;
      }
      return '$owner ($designation)';
    }

    final markdown = RegExp(
      r'(?:Director|Proprietor|Partner|Contact Person)\s*\n+\s*'
      r'((?:Mr|Ms|Mrs|Dr)\.?\s+[^\n<]{2,80})',
      caseSensitive: false,
    ).firstMatch(content)?.group(1);
    if (markdown != null && markdown.trim().isNotEmpty) {
      return _cleanText(markdown);
    }

    final html = RegExp(
      r'Director</p>\s*<p[^>]*>([^<]+)</p>',
      caseSensitive: false,
    ).firstMatch(content)?.group(1);
    return _cleanText(html ?? '');
  }

  static String _tradeIndiaPhone(String content) {
    for (final key in ['mobile', 'whatsapp']) {
      final raw = _firstGroup(content, '"$key"\\s*:\\s*"([^"]+)"');
      if (raw.isEmpty) continue;
      final cleaned = _cleanPhone(raw);
      if (cleaned.isNotEmpty) return cleaned;
    }
    return '';
  }

  static String _cleanPhone(String raw) {
    final value = _cleanText(raw).replaceAll(r'\u002B', '+');
    if (value.isEmpty) return '';
    final digits = value.replaceAll(RegExp(r'[^\d+]'), '');
    final plain = digits.startsWith('+') ? digits.substring(1) : digits;
    if (plain.length == 12 && plain.startsWith('91')) {
      return '+91 ${plain.substring(2)}';
    }
    if (plain.length == 10 && RegExp(r'^[6-9]').hasMatch(plain)) {
      return '+91 $plain';
    }
    if (plain.length == 11 && plain.startsWith('0')) {
      final local = plain.substring(1);
      if (RegExp(r'^[6-9]').hasMatch(local)) return '+91 $local';
    }
    return value;
  }

  Future<List<SourcingSupplier>> _searchPortalPages(
    String query,
    SourcingPlatform platform,
  ) async {
    final requests = <Future<List<SourcingSupplier>>>[];
    if (platform == SourcingPlatform.all ||
        platform == SourcingPlatform.indiaMart) {
      requests.add(
        _ignoreFailure(_readPortal(SourcingPlatform.indiaMart, query)),
      );
    }
    if (platform == SourcingPlatform.all ||
        platform == SourcingPlatform.tradeIndia) {
      requests.add(
        _ignoreFailure(_readPortal(SourcingPlatform.tradeIndia, query)),
      );
    }

    final results = await Future.wait(requests);
    final suppliers = <SourcingSupplier>[];
    final seen = <String>{};
    for (final result in results) {
      for (final supplier in result) {
        final key = supplier.url.isEmpty
            ? '${supplier.platform.name}:${supplier.name}'
            : supplier.url;
        if (!seen.add(key)) continue;
        suppliers.add(supplier);
        if (suppliers.length >= _maxSuppliers) return suppliers;
      }
    }
    return suppliers;
  }

  Future<List<SourcingSupplier>> _ignoreFailure(
    Future<List<SourcingSupplier>> request,
  ) async {
    try {
      return await request;
    } catch (_) {
      return const <SourcingSupplier>[];
    }
  }

  Future<List<SourcingSupplier>> _readPortal(
    SourcingPlatform platform,
    String query,
  ) async {
    final target = _portalUri(platform, query);
    final response = await _client
        .get(Uri.parse('https://r.jina.ai/$target'))
        .timeout(const Duration(seconds: 45));

    if (response.statusCode != 200) {
      throw SourcingException(
        'Could not read ${platform.label} (HTTP ${response.statusCode}).',
      );
    }

    final content = utf8.decode(response.bodyBytes, allowMalformed: true);
    return switch (platform) {
      SourcingPlatform.indiaMart => _parseIndiaMart(content, query),
      SourcingPlatform.tradeIndia => _parseTradeIndia(content, query),
      SourcingPlatform.all => const <SourcingSupplier>[],
    };
  }

  static Uri _portalUri(SourcingPlatform platform, String query) {
    return switch (platform) {
      SourcingPlatform.indiaMart => Uri.https(
        'dir.indiamart.com',
        '/search.mp',
        {'ss': query},
      ),
      SourcingPlatform.tradeIndia => Uri.https(
        'www.tradeindia.com',
        '/search.html',
        {'keyword': query},
      ),
      SourcingPlatform.all => throw ArgumentError(
        'A specific portal is required.',
      ),
    };
  }

  static List<SourcingSupplier> _parseIndiaMart(String content, String query) {
    final pattern = RegExp(
      r'\[([^\]\n]{2,200})\]'
      r'\((https://dir\.indiamart\.com/company/[^)\s]+)\)',
    );
    final matches = pattern.allMatches(content).toList();
    final suppliers = <SourcingSupplier>[];
    final seen = <String>{};

    for (var i = 0; i < matches.length; i++) {
      final match = matches[i];
      final name = _cleanText(match.group(1) ?? '');
      final url = _cleanSupplierUrl((match.group(2) ?? '').trim());
      if (name.isEmpty || url.isEmpty || !seen.add(url)) continue;

      final nextStart = i + 1 < matches.length
          ? matches[i + 1].start
          : content.length;
      final blockEnd = match.end + 2000 < nextStart
          ? match.end + 2000
          : nextStart;
      final block = content.substring(match.end, blockEnd);

      final businessType = _firstGroup(block, r'Business Type:\s*([^\n]+)');
      final exportingSince = _firstGroup(
        block,
        r'Exporting Since:\s*([^\n]+?)(?:\s+Est\.|\n|$)',
      );
      final exportsTo = _firstGroup(block, r'Exports To:\s*([^\n]+)');
      final details = <String>[
        if (businessType.isNotEmpty) 'Business type: $businessType',
        if (exportingSince.isNotEmpty) 'Exporting since $exportingSince',
        if (exportsTo.isNotEmpty) 'Exports to $exportsTo',
      ];

      suppliers.add(
        SourcingSupplier(
          name: name,
          productTitle: query,
          snippet: details.isEmpty
              ? 'IndiaMART seller for $query.'
              : details.join(' \u00b7 '),
          url: url,
          platform: SourcingPlatform.indiaMart,
          location: _extractLocation(block),
          verifiedBadge: block.contains('TrustSEAL')
              ? 'IndiaMART TrustSEAL'
              : block.contains('Verified Exporter')
              ? 'IndiaMART Verified Exporter'
              : 'IndiaMART Seller',
        ),
      );
      if (suppliers.length >= _maxSuppliers) break;
    }
    return suppliers;
  }

  static List<SourcingSupplier> _parseTradeIndia(String content, String query) {
    final sellerPattern = RegExp(
      r'###\s*\[([^\]\n]{2,200})\]'
      r'\((https://www\.tradeindia\.com/(?!products/|fp/)[^)\s]+?)\)',
    );
    final productPattern = RegExp(
      r'\[!\[Image \d+:\s*([^\]]+)\]\([^)]*\)\s*##\s*([^\]]+)\]'
      r'\((https://www\.tradeindia\.com/products/[^)\s]+)\)',
    );
    final matches = sellerPattern.allMatches(content).toList();
    final suppliers = <SourcingSupplier>[];
    final seen = <String>{};

    for (var i = 0; i < matches.length; i++) {
      final match = matches[i];
      final name = _cleanText(match.group(1) ?? '');
      final url = (match.group(2) ?? '').trim();
      if (name.isEmpty || url.isEmpty || !seen.add(url)) continue;

      final windowStart = i == 0 ? 0 : matches[i - 1].end;
      final before = content.substring(windowStart, match.start);
      final productMatches = productPattern.allMatches(before).toList();
      final product = productMatches.isEmpty ? null : productMatches.last;
      final detailBlock = product == null
          ? before
          : before.substring(product.end);

      final nextStart = i + 1 < matches.length
          ? matches[i + 1].start
          : content.length;
      final after = content.substring(match.end, nextStart);
      final businessType = _firstGroup(after, r'Business Type:\s*([^\n]+)');
      final years = _firstGroup(after, r'(\d+)\s*Years?');
      final trusted = after.contains('Trusted') || after.contains('TrustSEAL');
      final location = _tradeIndiaLocation(after);
      final details = <String>[
        if (businessType.isNotEmpty) businessType,
        if (years.isNotEmpty) '$years years',
        if (trusted) 'Trusted seller',
      ];

      suppliers.add(
        SourcingSupplier(
          name: name,
          productTitle: product == null
              ? query
              : _cleanText(product.group(2) ?? ''),
          snippet: details.isEmpty
              ? 'TradeIndia seller for $query.'
              : details.join(' \u00b7 '),
          url: url,
          platform: SourcingPlatform.tradeIndia,
          location: location,
          priceQuote: _extractInrPrice(detailBlock),
          moq: _extractMoq(detailBlock),
          verifiedBadge: trusted ? 'TradeIndia TrustSEAL' : 'TradeIndia Seller',
        ),
      );
      if (suppliers.length >= _maxSuppliers) break;
    }
    return suppliers;
  }

  Future<List<SourcingSupplier>> _searchWebSuppliers(
    String query,
    SourcingPlatform platform,
  ) async {
    final siteQuery = switch (platform) {
      SourcingPlatform.indiaMart => 'site:indiamart.com',
      SourcingPlatform.tradeIndia => 'site:tradeindia.com',
      SourcingPlatform.all => 'site:indiamart.com OR site:tradeindia.com',
    };
    final searchQuery =
        '$siteQuery $query wholesale manufacturer supplier contact';

    final response = await _client
        .post(
          Uri.parse(_searchEndpoint),
          headers: {'X-API-KEY': _key, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'q': searchQuery,
            'gl': 'in',
            'hl': 'en',
            'num': 20,
          }),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw SourcingException(
        'Could not search suppliers (HTTP ${response.statusCode}).',
      );
    }

    final decoded = jsonDecode(
      utf8.decode(response.bodyBytes, allowMalformed: true),
    );
    if (decoded is! Map) return const [];
    final organic = decoded['organic'];
    if (organic is! List) return const [];

    final suppliers = <SourcingSupplier>[];
    for (final item in organic) {
      if (item is! Map) continue;
      final rawTitle = item['title'];
      final rawLink = item['link'];
      final rawSnippet = item['snippet'];
      if (rawTitle is! String || rawLink is! String) continue;

      final url = rawLink.trim();
      final isIndiaMart = url.contains('indiamart.com');
      final isTradeIndia = url.contains('tradeindia.com');
      if (!isIndiaMart && !isTradeIndia) continue;

      final snippet = rawSnippet is String ? _cleanText(rawSnippet) : '';
      final parsedTitle = _parseSupplierTitle(rawTitle);
      final itemPlatform = isIndiaMart
          ? SourcingPlatform.indiaMart
          : SourcingPlatform.tradeIndia;

      suppliers.add(
        SourcingSupplier(
          name: parsedTitle.companyName,
          productTitle: parsedTitle.productName,
          snippet: snippet,
          url: url,
          platform: itemPlatform,
          location: _extractLocation('$rawTitle $snippet'),
          priceQuote: _extractPrice(snippet),
          moq: _extractMoq(snippet),
          verifiedBadge: isIndiaMart ? 'IndiaMART Seller' : 'TradeIndia Seller',
        ),
      );
      if (suppliers.length >= _maxSuppliers) break;
    }
    return suppliers;
  }

  static ({String companyName, String productName}) _parseSupplierTitle(
    String raw,
  ) {
    final cleaned = raw
        .replaceAll(RegExp(r'\s*[-|]\s*IndiaMART.*$', caseSensitive: false), '')
        .replaceAll(
          RegExp(r'\s*[-|]\s*TradeIndia.*$', caseSensitive: false),
          '',
        )
        .trim();

    if (cleaned.contains(' - ')) {
      final parts = cleaned.split(' - ');
      if (parts.length >= 2) {
        final first = parts[0].trim();
        final second = parts[1].trim();
        if (first.toLowerCase().contains('manufacturer') ||
            first.toLowerCase().contains('supplier') ||
            first.toLowerCase().contains('wholesale')) {
          return (companyName: second, productName: first);
        }
        return (companyName: first, productName: second);
      }
    }

    if (cleaned.contains(' by ')) {
      final parts = cleaned.split(' by ');
      return (companyName: parts.last.trim(), productName: parts.first.trim());
    }

    return (companyName: cleaned, productName: cleaned);
  }

  static String _tradeIndiaLocation(String block) {
    final match = RegExp(r'Business Type:[^\n]*\n+\s*([^\n]+)')
        .firstMatch(block);
    final candidate = _cleanText(match?.group(1) ?? '');
    final lower = candidate.toLowerCase();
    final isNoise =
        candidate.isEmpty ||
        lower.contains('call now') ||
        lower.contains('view number') ||
        lower.contains('send inquiry') ||
        lower.contains('response rate') ||
        lower.contains('indian inquiries') ||
        lower.contains('made in india') ||
        lower.contains('trusted') ||
        lower.contains('seller');
    if (isNoise) return 'India';
    return _normalizeLocation(candidate);
  }

  static String _normalizeLocation(String raw) {
    final cleaned = _cleanText(raw);
    if (cleaned.isEmpty) return 'India';
    final mapped = _extractLocation(cleaned);
    return mapped == 'Pan India Delivery' ? cleaned : mapped;
  }

  static String _extractLocation(String text) {
    final hubs = <String, String>{
      'surat': 'Surat, Gujarat',
      'ahmedabad': 'Ahmedabad, Gujarat',
      'rajkot': 'Rajkot, Gujarat',
      'jaipur': 'Jaipur, Rajasthan',
      'jodhpur': 'Jodhpur, Rajasthan',
      'tirupur': 'Tirupur, Tamil Nadu',
      'coimbatore': 'Coimbatore, Tamil Nadu',
      'chennai': 'Chennai, Tamil Nadu',
      'ludhiana': 'Ludhiana, Punjab',
      'delhi': 'Delhi NCR',
      'noida': 'Noida, UP',
      'faridabad': 'Faridabad, Haryana',
      'panipat': 'Panipat, Haryana',
      'mumbai': 'Mumbai, Maharashtra',
      'pune': 'Pune, Maharashtra',
      'bengaluru': 'Bengaluru, Karnataka',
      'bangalore': 'Bengaluru, Karnataka',
      'kolkata': 'Kolkata, West Bengal',
      'hyderabad': 'Hyderabad, Telangana',
      'kanpur': 'Kanpur, UP',
      'agra': 'Agra, UP',
      'moradabad': 'Moradabad, UP',
      'indore': 'Indore, MP',
      'lucknow': 'Lucknow, UP',
    };

    final lower = text.toLowerCase();
    for (final entry in hubs.entries) {
      if (lower.contains(entry.key)) return entry.value;
    }
    return 'Pan India Delivery';
  }

  static String _extractInrPrice(String text) {
    final match = RegExp(
      r'([\d,]+(?:\.\d+)?(?:\s*-\s*[\d,]+(?:\.\d+)?)?)\s*INR',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return '';
    final amount = (match.group(1) ?? '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll('.00', '');
    return amount.isEmpty ? '' : '\u20b9$amount';
  }

  static String _extractPrice(String text) {
    final match = RegExp(
      r'(?:\u20b9|Rs\.?)\s*'
      r'([\d,]+(?:\s*-\s*(?:\u20b9|Rs\.?)?\s*[\d,]+)?'
      r'(?:\s*/\s*[a-zA-Z]+)?)',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return '';
    return '\u20b9${match.group(1)}';
  }

  static String _extractMoq(String text) {
    final match = RegExp(
      r'MOQ\s*[-:]\s*([^\n]+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return '';
    return 'MOQ: ${_cleanText(match.group(1) ?? '')}';
  }

  static String _firstGroup(String text, String pattern) {
    final match = RegExp(pattern).firstMatch(text);
    return _cleanText(match?.group(1) ?? '');
  }

  static String _cleanSupplierUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasAuthority) return raw;
    if (!uri.host.endsWith('indiamart.com')) return raw;
    return Uri(scheme: uri.scheme, host: uri.host, path: uri.path).toString();
  }

  static String _cleanText(String raw) {
    return raw
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
