import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models/growth_strategy.dart';

/// Source for selling growth strategies.
abstract class GrowthStrategySource {
  bool get isConfigured;
  Future<GrowthStrategySnapshot> loadStrategies(String query);
}

class GrowthStrategyException implements Exception {
  const GrowthStrategyException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Fetches seller growth strategies from the web through Serper search when configured,
/// with public e-commerce seller growth resources as fallback.
class WebGrowthStrategyService implements GrowthStrategySource {
  WebGrowthStrategyService(
    this._prefs, {
    http.Client? client,
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       _clock = clock ?? DateTime.now;

  static const _keyPrefs = 'seller.market.serper.v1';
  static const _searchEndpoint = 'https://google.serper.dev/search';

  final SharedPreferences _prefs;
  final http.Client _client;
  final DateTime Function() _clock;

  String get _key => (_prefs.getString(_keyPrefs) ?? '').trim();

  @override
  bool get isConfigured => _key.isNotEmpty;

  @override
  Future<GrowthStrategySnapshot> loadStrategies(String query) async {
    final cleanQuery = query.trim();

    if (isConfigured) {
      try {
        final webStrategies = await _searchWebStrategies(cleanQuery);
        if (webStrategies.isNotEmpty) {
          return GrowthStrategySnapshot(
            strategies: webStrategies,
            query: cleanQuery.isEmpty ? 'All Growth Ideas' : cleanQuery,
            sourceDescription: 'Live Google Web Search via Serper',
            fetchedAt: _clock(),
          );
        }
      } catch (_) {
        // Fall through to fallback strategies on failure
      }
    }

    // Curated & public seller growth strategies fallback
    final fallbackList = _getCuratedStrategies(cleanQuery);
    return GrowthStrategySnapshot(
      strategies: fallbackList,
      query: cleanQuery.isEmpty ? 'All Growth Ideas' : cleanQuery,
      sourceDescription: isConfigured
          ? 'Curated E-Commerce Playbook (Web search fallback)'
          : 'Curated E-Commerce Playbook & Flipkart Seller Guides',
      fetchedAt: _clock(),
    );
  }

  Future<List<GrowthStrategy>> _searchWebStrategies(String query) async {
    final searchQuery = query.isEmpty
        ? 'Flipkart seller business growth strategies best tips boost sales'
        : 'Flipkart seller growth strategy ideas $query';

    final response = await _client
        .post(
          Uri.parse(_searchEndpoint),
          headers: {'X-API-KEY': _key, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'q': searchQuery,
            'gl': 'in',
            'hl': 'en',
            'num': 15,
          }),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw GrowthStrategyException(
        'Could not search web (HTTP ${response.statusCode}).',
      );
    }

    final decoded = jsonDecode(
      utf8.decode(response.bodyBytes, allowMalformed: true),
    );
    if (decoded is! Map) return const [];
    final organic = decoded['organic'];
    if (organic is! List) return const [];

    final strategies = <GrowthStrategy>[];
    for (final item in organic) {
      if (item is! Map) continue;
      final rawTitle = item['title'];
      final rawLink = item['link'];
      final rawSnippet = item['snippet'];
      if (rawTitle is! String || rawLink is! String) continue;

      final title = _cleanTitle(rawTitle);
      final snippet = rawSnippet is String ? _cleanSnippet(rawSnippet) : '';
      if (title.isEmpty || snippet.isEmpty) continue;

      final actionPoints = <String>[];
      final sitelinks = item['sitelinks'];
      if (sitelinks is List) {
        for (final sl in sitelinks) {
          if (sl is Map && sl['title'] is String) {
            final st = (sl['title'] as String).trim();
            if (st.isNotEmpty && st.length < 80) actionPoints.add(st);
          }
        }
      }
      if (actionPoints.isEmpty) {
        final sentences = snippet.split(RegExp(r'\. |\.\n'));
        for (final s in sentences) {
          final trimmed = s.trim();
          if (trimmed.length > 20 && trimmed.length < 120) {
            actionPoints.add(trimmed);
          }
        }
      }

      final category = _categorizeStrategy(title, snippet);
      final impact = _calculateImpact(title, snippet);

      strategies.add(
        GrowthStrategy(
          title: title,
          description: snippet,
          category: category,
          sourceUrl: rawLink,
          sourceTitle: _extractHost(rawLink),
          impactLevel: impact,
          actionPoints: actionPoints.take(3).toList(),
        ),
      );
    }

    return strategies;
  }

  static String _cleanTitle(String raw) {
    var title = raw.trim();
    title = title.replaceFirst(RegExp(r'\s*[-|]\s*.*$'), '');
    return title.trim();
  }

  static String _cleanSnippet(String raw) {
    return raw
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _extractHost(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.replaceFirst('www.', '');
  }

  static String _categorizeStrategy(String title, String snippet) {
    final combined = '$title $snippet'.toLowerCase();
    if (combined.contains('ad') ||
        combined.contains('pla') ||
        combined.contains('campaign') ||
        combined.contains('promot')) {
      return 'Advertising';
    }
    if (combined.contains('seo') ||
        combined.contains('keyword') ||
        combined.contains('title') ||
        combined.contains('catalog') ||
        combined.contains('list')) {
      return 'SEO & Listing';
    }
    if (combined.contains('price') ||
        combined.contains('discount') ||
        combined.contains('margin') ||
        combined.contains('cost')) {
      return 'Pricing';
    }
    if (combined.contains('return') ||
        combined.contains('rto') ||
        combined.contains('refund')) {
      return 'Returns & RTO';
    }
    if (combined.contains('assured') ||
        combined.contains('delivery') ||
        combined.contains('fbf') ||
        combined.contains('stock') ||
        combined.contains('inventory')) {
      return 'Fulfillment & Stock';
    }
    if (combined.contains('review') ||
        combined.contains('rating') ||
        combined.contains('feedback') ||
        combined.contains('customer')) {
      return 'Reviews & Trust';
    }
    return 'Sales Growth';
  }

  static String _calculateImpact(String title, String snippet) {
    final combined = '$title $snippet'.toLowerCase();
    if (combined.contains('boost') ||
        combined.contains('double') ||
        combined.contains('proven') ||
        combined.contains('essential') ||
        combined.contains('assured')) {
      return 'High Impact';
    }
    if (combined.contains('conversion') ||
        combined.contains('click') ||
        combined.contains('traffic')) {
      return 'Conversion Booster';
    }
    return 'ROI Focused';
  }

  List<GrowthStrategy> _getCuratedStrategies(String query) {
    final q = query.toLowerCase().trim();
    final all = <GrowthStrategy>[
      const GrowthStrategy(
        title: 'Qualify for Flipkart Assured Badge to Gain 3x Visibility',
        description: 'Flipkart Assured products receive a prominent trust badge, higher search ranking, and priority placement in customer filters. Assured sellers experience up to 300% higher conversions.',
        category: 'Fulfillment & Stock',
        sourceUrl: 'https://seller.flipkart.com/sell-online/grow-your-business',
        sourceTitle: 'seller.flipkart.com',
        impactLevel: 'High Impact',
        actionPoints: [
          'Maintain order cancellation rate under 0.5%',
          'Ship 95%+ orders within SLA (same-day or next-day dispatch)',
          'Keep return percentage significantly below category benchmarks',
        ],
      ),
      const GrowthStrategy(
        title: 'Run Product Listing Ads (PLA) on High-Search Intent Keywords',
        description: 'Product Listing Ads put your products right at top search slots. Target both generic category keywords and brand keywords to capture ready-to-buy shoppers.',
        category: 'Advertising',
        sourceUrl: 'https://seller.flipkart.com/sell-online/advertise',
        sourceTitle: 'seller.flipkart.com',
        impactLevel: 'Conversion Booster',
        actionPoints: [
          'Set competitive Cost-Per-Click (CPC) bids on top 10 relevant keywords',
          'Optimize campaigns during high-traffic evening hours (6 PM - 11 PM)',
          'Review Ad ROI weekly and pause keywords with low conversion',
        ],
      ),
      const GrowthStrategy(
        title:
            'Title & Bullet Point Keyword Optimization for Flipkart Search SEO',
        description: 'Flipkart algorithm matches searches with product title, brand name, and key features. Use high-volume search phrases rather than generic descriptions.',
        category: 'SEO & Listing',
        sourceUrl: 'https://seller.flipkart.com/sell-online/faqs',
        sourceTitle: 'seller.flipkart.com',
        impactLevel: 'High Impact',
        actionPoints: [
          'Structure titles: [Brand] + [Model/Product] + [Key Feature] + [Color/Size]',
          'Include 5 high-resolution images (minimum 1000x1000) showing every angle',
          'Fill out 100% of product attribute fields to match shopper filter queries',
        ],
      ),
      const GrowthStrategy(
        title: 'Smart Competitive Pricing to Win the Flipkart Buy Zone',
        description: 'Competitive pricing is the number one criteria for Flipkart\'s Buy Zone. Even a small price adjustment can shift sales volume dramatically to your listing.',
        category: 'Pricing',
        sourceUrl: 'https://seller.flipkart.com/sell-online/pricing',
        sourceTitle: 'seller.flipkart.com',
        impactLevel: 'ROI Focused',
        actionPoints: [
          'Track competitor price changes daily using market insights',
          'Offer bundle discounts (Buy 2 Get 10% Off) to raise Average Order Value',
          'Participate in Flipkart Bank offers and festive flash deals',
        ],
      ),
      const GrowthStrategy(
        title: 'Reduce Return-to-Origin (RTO) and Customer Returns',
        description: 'High return rates erode margins and harm seller performance score. Clear sizing guides, accurate color representation, and tamper-evident packaging cut returns by over 30%.',
        category: 'Returns & RTO',
        sourceUrl:
            'https://seller.flipkart.com/sell-online/fees-and-commission',
        sourceTitle: 'seller.flipkart.com',
        impactLevel: 'High Impact',
        actionPoints: [
          'Add detailed size charts with model measurements for fashion items',
          'Include warranty card and setup instructions inside the packaging',
          'Audit top returned items to eliminate recurring product defects',
        ],
      ),
      const GrowthStrategy(
        title: 'Boost 4+ Star Product Ratings and Detailed Customer Reviews',
        description: 'Products with a 4.0+ rating and at least 50 verified buyer reviews convert 4x better than unrated products. Fulfilling quality items builds a sustainable compounding moat.',
        category: 'Reviews & Trust',
        sourceUrl: 'https://seller.flipkart.com/sell-online/grow-your-business',
        sourceTitle: 'seller.flipkart.com',
        impactLevel: 'Conversion Booster',
        actionPoints: [
          'Ensure accurate product descriptions to prevent expectation mismatch',
          'Respond promptly to negative reviews with resolution actions',
          'Maintain consistent product quality across batch replenishments',
        ],
      ),
      const GrowthStrategy(
        title:
            'Leverage Big Billion Days & Festival Sale Preparation Checklist',
        description: 'Flipkart festival sales generate 5x to 10x regular daily volume. Early stock stocking at Flipkart Fulfillment Centers (FBF) prevents stockouts and missed revenue.',
        category: 'Fulfillment & Stock',
        sourceUrl: 'https://seller.flipkart.com/sell-online/events',
        sourceTitle: 'seller.flipkart.com',
        impactLevel: 'High Impact',
        actionPoints: [
          'Stock 3x regular inventory at warehouses 4 weeks before the sale',
          'Opt in early to Flipkart festive promotional pricing tiers',
          'Double check packaging supplies and courier dispatch schedules',
        ],
      ),
      const GrowthStrategy(
        title: 'Create Value-Added Combos and Multi-Pack Listings',
        description: 'Multi-packs and cross-category combos increase customer perceived value while amortizing shipping and packaging costs over a larger basket size.',
        category: 'Pricing',
        sourceUrl: 'https://seller.flipkart.com/sell-online/pricing',
        sourceTitle: 'seller.flipkart.com',
        impactLevel: 'ROI Focused',
        actionPoints: [
          'Pair complementary products (e.g. phone case + screen protector)',
          'Offer multi-quantity variants with progressive percentage discounts',
          'Highlight savings clearly in the main product image graphic',
        ],
      ),
    ];

    if (q.isEmpty || q == 'all ideas') return all;

    return all.where((item) {
      return item.title.toLowerCase().contains(q) ||
          item.description.toLowerCase().contains(q) ||
          item.category.toLowerCase().contains(q) ||
          item.actionPoints.any((ap) => ap.toLowerCase().contains(q));
    }).toList();
  }
}
