import '../../core/constants/system.dart';
import '../../core/utils/ast_builder.dart';
import '../../core/utils/ast_stringifier.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_cache_repository.dart';
import '../models/relay/operation_envelope.dart';

/// Applies relay operation envelopes to the local [node_cache] derived state.
class RelayAppliers {
  RelayAppliers(this._cache);

  final NodeCacheRepository _cache;

  Future<void> apply(OperationEnvelope envelope) async {
    final payload = envelope.payload;
    // Class operations identify the target via `classId`, not `nodeId`.
    final nodeId = payload['nodeId'] as String? ??
        payload['classId'] as String? ??
        '';
    if (nodeId.isEmpty) return;

    switch (envelope.opType) {
      case 'node.create':
        await _applyCreate(nodeId, payload);
      case 'node.updateContent':
        await _applyUpdateContent(nodeId, payload);
      case 'node.updateIcon':
        await _applyUpdateIcon(nodeId, payload);
      case 'node.updateColor':
        await _applyUpdateColor(nodeId, payload);
      case 'node.archive':
        await _applyArchive(nodeId);
      case 'node.restore':
        await _applyRestore(nodeId);
      case 'node.delete':
        await _applyDelete(nodeId);
      case 'node.move':
        await _applyMove(nodeId, payload);
      case 'property.set':
        await _applyPropertySet(nodeId, payload);
      case 'property.unset':
        await _applyPropertyUnset(nodeId, payload);
      case 'class.assign':
        await _applyClassAssign(nodeId, payload);
      case 'class.unassign':
        await _applyClassUnassign(nodeId, payload);
      case 'class.create':
        await _applyClassCreate(payload);
      case 'class.update':
        await _applyClassUpdate(payload);
      case 'class.delete':
        await _applyClassDelete(payload);
      case 'class.setExtends':
        await _applyClassSetExtends(payload);
      case 'user.favorite.add':
        await _cache.applyFavoriteAdd(
          envelope.workspaceId,
          envelope.actorId,
          nodeId,
        );
      case 'user.favorite.remove':
        await _cache.applyFavoriteRemove(
          envelope.workspaceId,
          envelope.actorId,
          nodeId,
        );
      case 'user.favorite.reorder':
        final nodeIds = (payload['nodeIds'] as List<dynamic>?)?.cast<String>() ?? const <String>[];
        await _cache.applyFavoriteReorder(
          envelope.workspaceId,
          envelope.actorId,
          nodeIds,
        );
      case 'task.recordCompletion':
        await _cache.recordTaskCompletion(
          nodeId,
          payload['completionId'] as String? ?? '',
          completedAt: payload['completedAt'] as String?,
          scheduledDate: payload['scheduledDate'] as String?,
          deadlineDate: payload['deadlineDate'] as String?,
          status: payload['status'] as String?,
        );
      case 'task.deleteCompletion':
        await _cache.deleteTaskCompletion(
          nodeId,
          payload['completionId'] as String? ?? '',
        );
    }
  }

  Future<void> _applyCreate(String nodeId, Map<String, dynamic> payload) async {
    final initialContent = payload['initialContent'];
    final name = initialContent is List<dynamic>
        ? AstBuilder.serialize(initialContent.cast<Map<String, dynamic>>())
        : '';
    final displayName = astToPlainText(name);
    final classIds = _readStringList(payload['classIds']);

    final node = Node(
      id: 0,
      uuid: nodeId,
      name: name,
      displayName: displayName,
      parentUuid: payload['parentId'] as String?,
      classesUuid: classIds,
      isDeleted: false,
      properties: const {},
      isPage: classIds.contains(SystemClassUuids.page),
      isTask: classIds.contains(SystemClassUuids.task),
      isDaily: classIds.contains(SystemClassUuids.day),
      isMonthly: classIds.contains(SystemClassUuids.month),
      isYearly: classIds.contains(SystemClassUuids.year),
    );
    await _cache.upsert(node);
  }

  Future<void> _applyUpdateContent(
    String nodeId,
    Map<String, dynamic> payload,
  ) async {
    final node = await _loadOrCreate(nodeId);
    final content = payload['content'];
    if (content is! List<dynamic>) return;

    final name = AstBuilder.serialize(content.cast<Map<String, dynamic>>());
    final updated = Node(
      id: node.id,
      uuid: node.uuid,
      name: name,
      displayName: astToPlainText(name),
      icon: node.icon,
      color: node.color,
      parentId: node.parentId,
      parentUuid: node.parentUuid,
      pageId: node.pageId,
      pageUuid: node.pageUuid,
      sequence: node.sequence,
      isPage: node.isPage,
      isTask: node.isTask,
      isDaily: node.isDaily,
      isMonthly: node.isMonthly,
      isYearly: node.isYearly,
      isTable: node.isTable,
      isAsset: node.isAsset,
      isComment: node.isComment,
      isDeleted: node.isDeleted,
      isArchived: node.isArchived,
      isPrivate: node.isPrivate,
      classes: node.classes,
      classesUuid: node.classesUuid,
      tags: node.tags,
      tagsUuid: node.tagsUuid,
      properties: node.properties,
      children: node.children,
      createDate: node.createDate,
      writeDate: node.writeDate,
    );
    await _cache.upsert(updated);
  }

  Future<void> _applyUpdateIcon(String nodeId, Map<String, dynamic> payload) async {
    final node = await _loadOrCreate(nodeId);
    await _cache.upsert(
      Node(
        id: node.id,
        uuid: node.uuid,
        name: node.name,
        displayName: node.displayName,
        icon: payload['icon'] as String?,
        color: node.color,
        parentId: node.parentId,
        parentUuid: node.parentUuid,
        pageId: node.pageId,
        pageUuid: node.pageUuid,
        sequence: node.sequence,
        isPage: node.isPage,
        isTask: node.isTask,
        isDaily: node.isDaily,
        isMonthly: node.isMonthly,
        isYearly: node.isYearly,
        isTable: node.isTable,
        isAsset: node.isAsset,
        isComment: node.isComment,
        isDeleted: node.isDeleted,
        isArchived: node.isArchived,
        isPrivate: node.isPrivate,
        classes: node.classes,
        classesUuid: node.classesUuid,
        tags: node.tags,
        tagsUuid: node.tagsUuid,
        properties: node.properties,
        children: node.children,
        createDate: node.createDate,
        writeDate: node.writeDate,
      ),
    );
  }

  Future<void> _applyUpdateColor(String nodeId, Map<String, dynamic> payload) async {
    final node = await _loadOrCreate(nodeId);
    await _cache.upsert(
      Node(
        id: node.id,
        uuid: node.uuid,
        name: node.name,
        displayName: node.displayName,
        icon: node.icon,
        color: payload['color'] as String?,
        parentId: node.parentId,
        parentUuid: node.parentUuid,
        pageId: node.pageId,
        pageUuid: node.pageUuid,
        sequence: node.sequence,
        isPage: node.isPage,
        isTask: node.isTask,
        isDaily: node.isDaily,
        isMonthly: node.isMonthly,
        isYearly: node.isYearly,
        isTable: node.isTable,
        isAsset: node.isAsset,
        isComment: node.isComment,
        isDeleted: node.isDeleted,
        isArchived: node.isArchived,
        isPrivate: node.isPrivate,
        classes: node.classes,
        classesUuid: node.classesUuid,
        tags: node.tags,
        tagsUuid: node.tagsUuid,
        properties: node.properties,
        children: node.children,
        createDate: node.createDate,
        writeDate: node.writeDate,
      ),
    );
  }

  Future<void> _applyArchive(String nodeId) async {
    final node = await _loadOrCreate(nodeId);
    await _cache.upsert(node.copyWithIsArchived(true));
  }

  Future<void> _applyRestore(String nodeId) async {
    final node = await _loadOrCreate(nodeId);
    await _cache.upsert(node.copyWithIsArchived(false));
  }

  Future<void> _applyDelete(String nodeId) async {
    final node = await _loadOrCreate(nodeId);
    await _cache.upsert(node.copyWithIsDeleted(true));
  }

  Future<void> _applyMove(String nodeId, Map<String, dynamic> payload) async {
    final node = await _loadOrCreate(nodeId);
    final newIndex = payload['newIndex'];
    final updated = Node(
      id: node.id,
      uuid: node.uuid,
      name: node.name,
      displayName: node.displayName,
      icon: node.icon,
      color: node.color,
      parentId: node.parentId,
      parentUuid: payload['newParentId'] as String?,
      pageId: node.pageId,
      pageUuid: node.pageUuid,
      sequence: newIndex is num ? newIndex.toDouble() : node.sequence,
      isPage: node.isPage,
      isTask: node.isTask,
      isDaily: node.isDaily,
      isMonthly: node.isMonthly,
      isYearly: node.isYearly,
      isTable: node.isTable,
      isAsset: node.isAsset,
      isComment: node.isComment,
      isDeleted: node.isDeleted,
      isArchived: node.isArchived,
      isPrivate: node.isPrivate,
      classes: node.classes,
      classesUuid: node.classesUuid,
      tags: node.tags,
      tagsUuid: node.tagsUuid,
      properties: node.properties,
      children: node.children,
      createDate: node.createDate,
      writeDate: node.writeDate,
    );
    await _cache.upsert(updated);
  }

  Future<void> _applyPropertySet(
    String nodeId,
    Map<String, dynamic> payload,
  ) async {
    final node = await _loadOrCreate(nodeId);
    final schemaId = payload['schemaId'] as String?;
    if (schemaId == null) return;
    final updatedProperties = Map<String, dynamic>.from(node.properties);
    updatedProperties[schemaId] = payload['value'];
    await _cache.upsert(node.copyWithProperties(updatedProperties));
  }

  Future<void> _applyPropertyUnset(
    String nodeId,
    Map<String, dynamic> payload,
  ) async {
    final node = await _loadOrCreate(nodeId);
    final schemaId = payload['schemaId'] as String?;
    if (schemaId == null) return;
    final updatedProperties = Map<String, dynamic>.from(node.properties);
    updatedProperties.remove(schemaId);
    await _cache.upsert(node.copyWithProperties(updatedProperties));
  }

  Future<void> _applyClassAssign(
    String nodeId,
    Map<String, dynamic> payload,
  ) async {
    final node = await _loadOrCreate(nodeId);
    final classId = payload['classId'] as String?;
    if (classId == null) return;
    final classesUuid = List<String>.from(node.classesUuid);
    if (!classesUuid.contains(classId)) {
      classesUuid.add(classId);
    }
    await _cache.upsert(node.copyWithClassesUuid(classesUuid));
  }

  Future<void> _applyClassUnassign(
    String nodeId,
    Map<String, dynamic> payload,
  ) async {
    final node = await _loadOrCreate(nodeId);
    final classId = payload['classId'] as String?;
    if (classId == null) return;
    final classesUuid = node.classesUuid.where((id) => id != classId).toList();
    await _cache.upsert(node.copyWithClassesUuid(classesUuid));
  }

  Future<void> _applyClassCreate(Map<String, dynamic> payload) async {
    final classId = payload['classId'] as String?;
    if (classId == null) return;
    await _cache.upsertClass(
      uuid: classId,
      name: payload['name'] as String? ?? '',
      icon: payload['icon'] as String?,
      color: payload['color'] as String?,
      description: payload['description'] as String?,
      extendsUuids: _readStringList(payload['extends']),
      active: true,
    );
  }

  Future<void> _applyClassUpdate(Map<String, dynamic> payload) async {
    final classId = payload['classId'] as String?;
    if (classId == null) return;
    final existing = await _cache.getClassByUuid(classId);
    await _cache.upsertClass(
      uuid: classId,
      name: payload.containsKey('name')
          ? payload['name'] as String?
          : existing?.name,
      icon: payload.containsKey('icon')
          ? payload['icon'] as String?
          : existing?.icon,
      color: payload.containsKey('color')
          ? payload['color'] as String?
          : existing?.color,
      description: payload['description'] as String?,
    );
  }

  Future<void> _applyClassDelete(Map<String, dynamic> payload) async {
    final classId = payload['classId'] as String?;
    if (classId == null) return;
    await _cache.deleteClass(classId);
  }

  Future<void> _applyClassSetExtends(Map<String, dynamic> payload) async {
    final classId = payload['classId'] as String?;
    if (classId == null) return;
    final extendsList = _readStringList(
      payload['extendsClassIds'] ?? payload['extends'],
    );
    await _cache.setClassExtends(classId, extendsList);
  }

  Future<Node> _loadOrCreate(String nodeId) async {
    final existing = await _cache.getByUuid(nodeId);
    if (existing != null) return existing;
    return Node(
      id: 0,
      uuid: nodeId,
      name: '',
      displayName: '',
      classesUuid: const [],
      properties: const {},
    );
  }

  List<String> _readStringList(dynamic value) {
    if (value is List<dynamic>) {
      return value.cast<String>();
    }
    return const [];
  }
}

extension _NodeCopyWith on Node {
  Node copyWithIsDeleted(bool value) => Node(
        id: id,
        uuid: uuid,
        name: name,
        displayName: displayName,
        icon: icon,
        color: color,
        parentId: parentId,
        parentUuid: parentUuid,
        pageId: pageId,
        pageUuid: pageUuid,
        sequence: sequence,
        isPage: isPage,
        isTask: isTask,
        isDaily: isDaily,
        isMonthly: isMonthly,
        isYearly: isYearly,
        isTable: isTable,
        isAsset: isAsset,
        isComment: isComment,
        isDeleted: value,
        isArchived: isArchived,
        isPrivate: isPrivate,
        classes: classes,
        classesUuid: classesUuid,
        tags: tags,
        tagsUuid: tagsUuid,
        properties: properties,
        children: children,
        createDate: createDate,
        writeDate: writeDate,
      );

  Node copyWithProperties(Map<String, dynamic> value) => Node(
        id: id,
        uuid: uuid,
        name: name,
        displayName: displayName,
        icon: icon,
        color: color,
        parentId: parentId,
        parentUuid: parentUuid,
        pageId: pageId,
        pageUuid: pageUuid,
        sequence: sequence,
        isPage: isPage,
        isTask: isTask,
        isDaily: isDaily,
        isMonthly: isMonthly,
        isYearly: isYearly,
        isTable: isTable,
        isAsset: isAsset,
        isComment: isComment,
        isDeleted: isDeleted,
        isArchived: isArchived,
        isPrivate: isPrivate,
        classes: classes,
        classesUuid: classesUuid,
        tags: tags,
        tagsUuid: tagsUuid,
        properties: value,
        children: children,
        createDate: createDate,
        writeDate: writeDate,
      );

  Node copyWithClassesUuid(List<String> value) {
    final flags = _deriveFlags(value);
    return Node(
      id: id,
      uuid: uuid,
      name: name,
      displayName: displayName,
      icon: icon,
      color: color,
      parentId: parentId,
      parentUuid: parentUuid,
      pageId: pageId,
      pageUuid: pageUuid,
      sequence: sequence,
      isPage: flags.isPage,
      isTask: flags.isTask,
      isDaily: flags.isDaily,
      isMonthly: flags.isMonthly,
      isYearly: flags.isYearly,
      isTable: isTable,
      isAsset: isAsset,
      isComment: isComment,
      isDeleted: isDeleted,
      isArchived: isArchived,
      isPrivate: isPrivate,
      classes: classes,
      classesUuid: value,
      tags: tags,
      tagsUuid: tagsUuid,
      properties: properties,
      children: children,
      createDate: createDate,
      writeDate: writeDate,
    );
  }
}

({bool isPage, bool isTask, bool isDaily, bool isMonthly, bool isYearly})
    _deriveFlags(List<String> classIds) {
  return (
    isPage: classIds.contains(SystemClassUuids.page),
    isTask: classIds.contains(SystemClassUuids.task),
    isDaily: classIds.contains(SystemClassUuids.day),
    isMonthly: classIds.contains(SystemClassUuids.month),
    isYearly: classIds.contains(SystemClassUuids.year),
  );
}
