/// A lightweight, serializable snapshot of a block in the outliner editor.
///
/// Used by [EditorSaveService] and [OfflineQueue] to persist page edits.
class EditorBlockSnapshot {
  EditorBlockSnapshot({
    required this.id,
    required this.text,
    this.parentId,
    this.children = const [],
  });

  /// Backend node ID. `0` means the block has not been persisted yet.
  final int id;

  /// Raw Markdown-like text content of the block.
  final String text;

  /// Optional parent node ID. For new children of new parents this may be
  /// stale, so [EditorSaveService] relies on the [children] tree structure to
  /// create nodes level-by-level.
  final int? parentId;

  /// Nested child blocks.
  final List<EditorBlockSnapshot> children;

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'parent_id': parentId,
        'children': children.map((c) => c.toJson()).toList(),
      };

  factory EditorBlockSnapshot.fromJson(Map<String, dynamic> json) {
    return EditorBlockSnapshot(
      id: (json['id'] as num?)?.toInt() ?? 0,
      text: json['text'] as String? ?? '',
      parentId: (json['parent_id'] as num?)?.toInt(),
      children: ((json['children'] as List<dynamic>?) ?? [])
          .map((e) => EditorBlockSnapshot.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
