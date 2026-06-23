/// A backlink-style linked reference returned with page content.
class LinkedReference {
  const LinkedReference({
    required this.sourceNodeId,
    required this.sourceNodeName,
    this.sourcePageId,
    this.sourcePageName,
    required this.context,
  });

  final int sourceNodeId;
  final String sourceNodeName;
  final int? sourcePageId;
  final String? sourcePageName;
  final String context;

  factory LinkedReference.fromJson(Map<String, dynamic> json) {
    final sourceNode = json['source_node'] as Map<String, dynamic>?;
    final sourcePage = json['source_page'] as Map<String, dynamic>?;
    return LinkedReference(
      sourceNodeId: sourceNode?['id'] as int? ?? 0,
      sourceNodeName: sourceNode?['display_name'] as String? ??
          sourceNode?['name'] as String? ??
          '',
      sourcePageId: sourcePage?['id'] as int?,
      sourcePageName: sourcePage?['display_name'] as String? ??
          sourcePage?['name'] as String?,
      context: json['context'] as String? ?? '',
    );
  }
}
