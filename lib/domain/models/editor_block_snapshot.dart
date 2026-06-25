/// A lightweight, serializable snapshot of a block in the outliner editor.
///
/// Used by [EditorSaveService] and [OfflineQueue] to persist page edits.
class EditorBlockSnapshot {
  EditorBlockSnapshot({
    required this.uuid,
    required this.text,
    this.parentUuid,
    this.children = const [],
  });

  /// Backend node UUID. An empty string means the block has not been persisted yet.
  final String uuid;

  /// Raw Markdown-like text content of the block.
  final String text;

  /// Optional parent node UUID. For new children of new parents this may be
  /// stale, so [EditorSaveService] relies on the [children] tree structure to
  /// create nodes level-by-level.
  final String? parentUuid;

  /// Nested child blocks.
  final List<EditorBlockSnapshot> children;

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'text': text,
        'parent_uuid': parentUuid,
        'children': children.map((c) => c.toJson()).toList(),
      };

  factory EditorBlockSnapshot.fromJson(Map<String, dynamic> json) {
    return EditorBlockSnapshot(
      uuid: json['uuid'] as String? ?? '',
      text: json['text'] as String? ?? '',
      parentUuid: json['parent_uuid'] as String?,
      children: ((json['children'] as List<dynamic>?) ?? [])
          .map((e) => EditorBlockSnapshot.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
