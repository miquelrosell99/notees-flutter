import '../../data/models/node.dart';
import 'ast_stringifier.dart';

/// Splits text into normalized lowercase search terms.
///
/// Terms are split on whitespace and punctuation, lowercased, and filtered to
/// remove tokens shorter than [minLength]. The result is a set so each term is
/// indexed at most once per node/field.
Set<String> tokenize(String text, {int minLength = 2}) {
  if (text.isEmpty) return const {};
  return text
      .toLowerCase()
      .split(_wordBoundary)
      .where((term) => term.length >= minLength)
      .toSet();
}

final _wordBoundary = RegExp(
  r"[\s.,;:!?'()\[\]{}<>/\\|@#$%^&*~`+=_—–-]+",
);

/// A row ready to be inserted into the local `search_index` table.
class SearchIndexRow {
  const SearchIndexRow({
    required this.term,
    required this.nodeUuid,
    required this.field,
    required this.rank,
  });

  final String term;
  final String nodeUuid;
  final String field;
  final int rank;

  Map<String, dynamic> toMap() => {
        'term': term,
        'node_uuid': nodeUuid,
        'field': field,
        'rank': rank,
      };
}

/// Builds search index rows for [node].
///
/// Terms from the resolved [Node.displayName] are weighted more heavily (rank 2)
/// than terms extracted from the raw [Node.name] AST (rank 1). Deleted nodes
/// still produce rows; callers should clear the index for deleted nodes before
/// calling this.
List<SearchIndexRow> buildSearchIndexRows(Node node) {
  final rows = <SearchIndexRow>[];

  for (final term in tokenize(node.displayName)) {
    rows.add(SearchIndexRow(
      term: term,
      nodeUuid: node.uuid,
      field: 'display_name',
      rank: 2,
    ));
  }

  final namePlainText = astToPlainText(node.name);
  for (final term in tokenize(namePlainText)) {
    rows.add(SearchIndexRow(
      term: term,
      nodeUuid: node.uuid,
      field: 'name',
      rank: 1,
    ));
  }

  return rows;
}

/// Ranks [rows] by relevance to [query] using the same scoring rule as the
/// local SQL search: each matching term contributes its rank, and nodes with
/// the highest total score come first.
List<String> rankSearchResults(List<SearchIndexRow> rows, String query) {
  final queryTerms = tokenize(query);
  if (queryTerms.isEmpty) return const [];

  final scores = <String, int>{};
  for (final row in rows) {
    if (!queryTerms.contains(row.term)) continue;
    scores[row.nodeUuid] = (scores[row.nodeUuid] ?? 0) + row.rank;
  }

  final sorted = scores.entries.toList()
    ..sort((a, b) {
      final scoreCompare = b.value.compareTo(a.value);
      if (scoreCompare != 0) return scoreCompare;
      // Tie-break deterministically by UUID so tests are stable.
      return a.key.compareTo(b.key);
    });

  return sorted.map((e) => e.key).toList();
}
