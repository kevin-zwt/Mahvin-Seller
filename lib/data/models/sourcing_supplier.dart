/// Supported B2B sourcing platforms.
enum SourcingPlatform {
  all('All Platforms', 'IndiaMART & TradeIndia'),
  indiaMart('IndiaMART', 'indiamart.com'),
  tradeIndia('TradeIndia', 'tradeindia.com');

  const SourcingPlatform(this.label, this.domain);
  final String label;
  final String domain;
}

/// A wholesale seller/manufacturer listing from IndiaMART or TradeIndia.
class SourcingSupplier {
  const SourcingSupplier({
    required this.name,
    required this.productTitle,
    required this.snippet,
    required this.url,
    required this.platform,
    this.location = 'India',
    this.priceQuote = '',
    this.verifiedBadge = 'Verified Supplier',
    this.moq = '',
    this.contactPerson = '',
    this.contactPhone = '',
  });

  final String name;
  final String productTitle;
  final String snippet;
  final String url;
  final SourcingPlatform platform;
  final String location;
  final String priceQuote;
  final String verifiedBadge;
  final String moq;
  final String contactPerson;
  final String contactPhone;

  bool get hasContact => contactPerson.isNotEmpty || contactPhone.isNotEmpty;

  SourcingSupplier copyWith({String? contactPerson, String? contactPhone}) {
    return SourcingSupplier(
      name: name,
      productTitle: productTitle,
      snippet: snippet,
      url: url,
      platform: platform,
      location: location,
      priceQuote: priceQuote,
      verifiedBadge: verifiedBadge,
      moq: moq,
      contactPerson: contactPerson ?? this.contactPerson,
      contactPhone: contactPhone ?? this.contactPhone,
    );
  }

  String get sourceHost {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.replaceFirst('www.', '');
  }
}

/// A snapshot of sourcing suppliers for a product query.
class SourcingSnapshot {
  const SourcingSnapshot({
    required this.suppliers,
    required this.query,
    required this.platform,
    required this.sourceDescription,
    required this.fetchedAt,
  });

  final List<SourcingSupplier> suppliers;
  final String query;
  final SourcingPlatform platform;
  final String sourceDescription;
  final DateTime fetchedAt;

  SourcingSnapshot copyWith({List<SourcingSupplier>? suppliers}) {
    return SourcingSnapshot(
      suppliers: suppliers ?? this.suppliers,
      query: query,
      platform: platform,
      sourceDescription: sourceDescription,
      fetchedAt: fetchedAt,
    );
  }
}
