import 'linked_reference.dart';
import 'node.dart';

/// Page content response including the root node and backlink references.
class PageContent {
  const PageContent({
    required this.node,
    required this.linkedReferences,
  });

  final Node node;
  final List<LinkedReference> linkedReferences;

  factory PageContent.fromJson(Map<String, dynamic> json) {
    return PageContent(
      node: Node.fromJson(json),
      linkedReferences: (json['linked_references'] as List<dynamic>?)
              ?.map((e) => LinkedReference.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }
}
