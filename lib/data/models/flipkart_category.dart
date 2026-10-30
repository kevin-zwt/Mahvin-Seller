/// A Flipkart search target: a category or an ad-hoc product query.
class FlipkartQuery {
  const FlipkartQuery({
    required this.key,
    required this.label,
    required this.query,
  });

  final String key;
  final String label;
  final String query;

  bool get isProductSearch => key.startsWith('search:');

  String get pageUrl {
    return Uri.https('www.flipkart.com', '/search', {
      'q': query,
      'sort': 'popularity',
    }).toString();
  }

  static FlipkartQuery search(String raw) {
    final query = raw.trim();
    return FlipkartQuery(
      key: 'search:${query.toLowerCase()}',
      label: query,
      query: query,
    );
  }
}

class FlipkartCategory extends FlipkartQuery {
  const FlipkartCategory({
    required super.key,
    required super.label,
    required super.query,
  });
}

const flipkartCategories = [
  FlipkartCategory(key: 'mobiles', label: 'Mobiles', query: 'mobile phones'),
  FlipkartCategory(
    key: 'electronics',
    label: 'Electronics',
    query: 'electronics',
  ),
  FlipkartCategory(key: 'laptops', label: 'Laptops', query: 'laptops'),
  FlipkartCategory(key: 'fashion', label: 'Fashion', query: 'clothing'),
  FlipkartCategory(key: 'footwear', label: 'Footwear', query: 'shoes'),
  FlipkartCategory(
    key: 'home',
    label: 'Home & Kitchen',
    query: 'home and kitchen',
  ),
  FlipkartCategory(
    key: 'appliances',
    label: 'Appliances',
    query: 'home appliances',
  ),
  FlipkartCategory(
    key: 'beauty',
    label: 'Beauty',
    query: 'beauty and grooming',
  ),
  FlipkartCategory(key: 'toys', label: 'Toys', query: 'toys'),
  FlipkartCategory(key: 'sports', label: 'Sports', query: 'sports and fitness'),
];
