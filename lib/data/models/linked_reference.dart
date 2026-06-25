/// A backlink-style linked reference returned with page content.
class LinkedReference {
  const LinkedReference({
    required this.sourceNodeUuid,
    required this.sourceNodeName,
    this.sourcePageUuid,
    this.sourcePageName,
    required this.context,
  });

  final String sourceNodeUuid;
  final String sourceNodeName;
  final String? sourcePageUuid;
  final String? sourcePageName;
  final String context;

  factory LinkedReference.fromJson(Map<String, dynamic> json) {
    final sourceNode = json['source_node'] as Map<String, dynamic>?;
    final sourcePage = json['source_page'] as Map<String, dynamic>?;
    return LinkedReference(
      sourceNodeUuid: sourceNode?['uuid'] as String? ?? '',
      sourceNodeName: sourceNode?['display_name'] as String? ??
          sourceNode?['name'] as String? ??
          '',
      sourcePageUuid: sourcePage?['uuid'] as String?,
      sourcePageName: sourcePage?['display_name'] as String? ??
          sourcePage?['name'] as String?,
      context: json['context'] as String? ?? '',
    );
  }
}
