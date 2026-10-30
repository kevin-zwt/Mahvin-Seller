import 'dart:collection';

/// A photo extracted from a product page.
class ProductPhoto {
  const ProductPhoto({required this.url, this.alt = ''});

  final String url;
  final String alt;
}

/// One specification row extracted from a product page.
class ProductSpec {
  const ProductSpec({required this.label, required this.value});

  final String label;
  final String value;
}

/// Everything the app could read from a pasted e-commerce product link.
class ProductLinkData {
  const ProductLinkData({
    required this.sourceUrl,
    required this.siteName,
    required this.title,
    required this.fetchedAt,
    this.sourceHost = '',
    this.description = '',
    this.brand = '',
    this.price = '',
    this.mrp = '',
    this.discount = '',
    this.rating = '',
    this.reviewCount = '',
    this.availability = '',
    this.seller = '',
    this.category = '',
    this.sku = '',
    this.keywords = const [],
    this.keyFeatures = const [],
    this.photos = const [],
    this.specs = const [],
  });

  final String sourceUrl;
  final String sourceHost;
  final String siteName;
  final String title;
  final String description;
  final String brand;
  final String price;
  final String mrp;
  final String discount;
  final String rating;
  final String reviewCount;
  final String availability;
  final String seller;
  final String category;
  final String sku;
  final List<String> keywords;
  final List<String> keyFeatures;
  final List<ProductPhoto> photos;
  final List<ProductSpec> specs;
  final DateTime fetchedAt;

  bool get hasPhotos => photos.isNotEmpty;
  bool get hasSpecs => specs.isNotEmpty;

  Map<String, String> get quickFacts {
    final facts = <String, String>{};
    if (brand.isNotEmpty) facts['Brand'] = brand;
    if (category.isNotEmpty) facts['Category'] = category;
    if (rating.isNotEmpty) {
      facts['Rating'] = reviewCount.isEmpty
          ? rating
          : '$rating ($reviewCount ratings)';
    }
    if (availability.isNotEmpty) facts['Availability'] = availability;
    if (seller.isNotEmpty) facts['Seller'] = seller;
    if (sku.isNotEmpty) facts['SKU'] = sku;
    return UnmodifiableMapView(facts);
  }
}

class ProductLinkException implements Exception {
  const ProductLinkException(this.message);

  final String message;

  @override
  String toString() => message;
}
