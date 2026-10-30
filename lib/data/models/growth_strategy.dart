/// A selling growth strategy idea surfaced from web guides and search.
class GrowthStrategy {
  const GrowthStrategy({
    required this.title,
    required this.description,
    required this.category,
    required this.sourceUrl,
    required this.sourceTitle,
    this.impactLevel = 'High Impact',
    this.actionPoints = const [],
  });

  final String title;
  final String description;
  final String category;
  final String sourceUrl;
  final String sourceTitle;
  final String impactLevel;
  final List<String> actionPoints;

  String get sourceHost {
    final host = Uri.tryParse(sourceUrl)?.host ?? '';
    return host.replaceFirst('www.', '');
  }
}

/// A snapshot of strategy ideas for a specific topic or web search.
class GrowthStrategySnapshot {
  const GrowthStrategySnapshot({
    required this.strategies,
    required this.query,
    required this.sourceDescription,
    required this.fetchedAt,
  });

  final List<GrowthStrategy> strategies;
  final String query;
  final String sourceDescription;
  final DateTime fetchedAt;
}
