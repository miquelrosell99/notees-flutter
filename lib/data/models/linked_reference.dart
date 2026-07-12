import 'node.dart';

/// A backlink to a node from another node, as returned by
/// `GET /api/nodes/{uuid}/linked-references`.
class LinkedReference {
  const LinkedReference({
    required this.sourceNode,
    this.sourcePage,
    required this.linkType,
    required this.context,
  });

  /// The node that contains the link.
  final Node sourceNode;

  /// The page the source node lives on, when it differs from the source.
  final Node? sourcePage;

  /// Link kind: `node`, `tag`, `class`, `property`, ...
  final String linkType;

  /// Plain-text context around the link.
  final String context;

  factory LinkedReference.fromJson(Map<String, dynamic> json) {
    final pageJson = json['source_page'] as Map<String, dynamic>?;
    return LinkedReference(
      sourceNode: Node.fromJson(json['source_node'] as Map<String, dynamic>),
      sourcePage: pageJson != null ? Node.fromJson(pageJson) : null,
      linkType: json['link_type'] as String? ?? 'node',
      context: json['context'] as String? ?? '',
    );
  }
}

/// Page of linked references plus the server-side total count.
class LinkedReferencesResult {
  const LinkedReferencesResult({
    required this.references,
    required this.totalCount,
  });

  final List<LinkedReference> references;
  final int totalCount;
}
