/// A product surfaced by the Flipkart top selling list.
class TrendSuggestion {
  const TrendSuggestion({
    required this.name,
    required this.reason,
    required this.sourceTitle,
    required this.url,
    this.imageUrl,
    this.mentions = 1,
  });

  final String name;
  final String reason;
  final String sourceTitle;
  final String url;
  final String? imageUrl;
  final int mentions;

  String get sourceHost {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.replaceFirst('www.', '');
  }
}

/// A search result that contributed to the suggestion list.
class TrendSourceLink {
  const TrendSourceLink({
    required this.title,
    required this.url,
    this.snippet = '',
  });

  final String title;
  final String url;
  final String snippet;

  String get sourceHost {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.replaceFirst('www.', '');
  }
}
