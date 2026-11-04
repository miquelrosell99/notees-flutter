/// Pure v1→v2 query-AST mapping — a strict Dart port of the monorepo's
/// `scripts/lib/map-query-ast-v1-v2.ts` (the device-side half of the
/// query-AST rewrite the color-group load migration rides). The mapping
/// walks a v1 AST (Group / Not / nested-query trees) and returns its v2
/// image as plain JSON: the v1 family hats (`descendantOf` /
/// `descendantOfAny` / `*Query` / `*Self` / the `*Set` bits) become
/// `member` conditions with the family/op/target axes explicit;
/// `contentSet`, `propertyBetween`, `propertyWithin`, the ten
/// created*/updated* types, and `isClass`/`isEmbedded` fold into their
/// parameterized v2 types. `not` wrappers, group logic, scope, sort, and
/// aggregation pass through unchanged.
///
/// Pure data-in/data-out by design: this file imports NOTHING from the AST
/// model — the migration feeds it stored JSON, and the caller validates
/// the rewritten envelope through the strict parser separately. Unknown
/// shapes FAIL LOUD with the offending type and the tree path; the
/// function is total over the v1 grammar and throws on everything else —
/// including v2 input, which must NOT be re-mapped (the migration is
/// one-time; double-application is a bug, not a no-op).
library;

/// The fail-loud error carrying the tree path, like the TS original.
class QueryAstV1MapError extends Error {
  QueryAstV1MapError(this.path, this.message);

  final String path;
  final String message;

  @override
  String toString() => 'QueryAstV1MapError: $message (at $path)';
}

typedef _Json = Map<String, dynamic>;

Never _fail(String path, String message) =>
    throw QueryAstV1MapError(path, message);

_Json _expectObject(Object? value, String path) {
  if (value is! Map) {
    _fail(path, 'expected an object, got ${value is String ? '"$value"' : value}');
  }
  return Map<String, dynamic>.from(value);
}

String _expectString(Object? value, String path, String what) {
  if (value is! String || value.isEmpty) {
    _fail(path, 'expected a non-empty string for $what');
  }
  return value;
}

List<String> _expectStringArray(Object? value, String path, String what) {
  if (value is! List ||
      value.isEmpty ||
      value.any((v) => v is! String || v.isEmpty)) {
    _fail(path, 'expected a non-empty string array for $what');
  }
  return [...value.cast<String>()];
}

Map<String, dynamic> _expectGroup(Object? value, String path) {
  final group = _expectObject(value, path);
  if (group['type'] != 'group') {
    _fail(path, 'expected a group, got type ${group['type']}');
  }
  return _mapGroup(group, path);
}

// --- member family mapping ---------------------------------------------------

/// The v1 variants per family: ONE id (`class`/`tag`/`linkedTo`/
/// `descendantOf`), ANY-of ids (`*Any` + the explicit `pageOf`/`ancestorIn`/
/// `rootIn`/`parentOf`/`childOf`/`referencePathOf`), `*Query`, `*Self`, and
/// the `*Set` emptiness bit.
class _MemberShape {
  const _MemberShape._(this.kind, this.family, this.idKey, this.idsKey);

  const _MemberShape.one(String family, String idKey)
      : this._('one', family, idKey, null);
  const _MemberShape.many(String family, String idsKey)
      : this._('many', family, null, idsKey);
  const _MemberShape.query(String family) : this._('query', family, null, null);
  const _MemberShape.self(String family) : this._('self', family, null, null);
  const _MemberShape.set(String family) : this._('set', family, null, null);
  const _MemberShape.exact() : this._('exact', 'class', 'classId', null);

  final String kind;
  final String family;
  final String? idKey;
  final String? idsKey;
}

/// Every v1 condition `type` → its mapping spec. The table IS the contract.
const Map<String, _MemberShape> _v1MemberSpecs = {
  'class': _MemberShape.one('class', 'classId'),
  'classAny': _MemberShape.many('class', 'classIds'),
  'classAnyQuery': _MemberShape.query('class'),
  'classSelf': _MemberShape.self('class'),
  'classSet': _MemberShape.set('class'),
  'classExact': _MemberShape.exact(),
  'tag': _MemberShape.one('tags', 'tagId'),
  'tagAny': _MemberShape.many('tags', 'tagIds'),
  'tagAnyQuery': _MemberShape.query('tags'),
  'tagSelf': _MemberShape.self('tags'),
  'tagSet': _MemberShape.set('tags'),
  'linkedTo': _MemberShape.one('links', 'nodeId'),
  'linkedToAny': _MemberShape.many('links', 'nodeIds'),
  'linkedToQuery': _MemberShape.query('links'),
  'linkedToSelf': _MemberShape.self('links'),
  'linkSet': _MemberShape.set('links'),
  'referencePathOf': _MemberShape.many('referencePath', 'nodeIds'),
  'referencePathOfQuery': _MemberShape.query('referencePath'),
  'referencePathOfSelf': _MemberShape.self('referencePath'),
  'parentOf': _MemberShape.many('parent', 'nodeIds'),
  'parentOfQuery': _MemberShape.query('parent'),
  'parentOfSelf': _MemberShape.self('parent'),
  'parentSet': _MemberShape.set('parent'),
  'childOf': _MemberShape.many('child', 'nodeIds'),
  'childOfQuery': _MemberShape.query('child'),
  'childOfSelf': _MemberShape.self('child'),
  'childSet': _MemberShape.set('child'),
  'descendantOf': _MemberShape.one('childPath', 'nodeId'),
  'descendantOfAny': _MemberShape.many('childPath', 'nodeIds'),
  'descendantOfQuery': _MemberShape.query('childPath'),
  'descendantOfSelf': _MemberShape.self('childPath'),
  'descendantSet': _MemberShape.set('childPath'),
  'pageOf': _MemberShape.many('page', 'nodeIds'),
  'pageOfQuery': _MemberShape.query('page'),
  'pageOfSelf': _MemberShape.self('page'),
  'pageSet': _MemberShape.set('page'),
  'ancestorIn': _MemberShape.many('parentPath', 'nodeIds'),
  'ancestorInQuery': _MemberShape.query('parentPath'),
  'ancestorInSelf': _MemberShape.self('parentPath'),
  'rootIn': _MemberShape.many('root', 'nodeIds'),
  'rootInQuery': _MemberShape.query('root'),
  'rootInSelf': _MemberShape.self('root'),
};

_Json _mapMember(_MemberShape spec, _Json condition, String path) {
  switch (spec.kind) {
    case 'one':
      final id = _expectString(
          condition[spec.idKey], '$path.${spec.idKey}', spec.idKey!);
      return {
        'type': 'member',
        'family': spec.family,
        'op': 'in',
        'target': {
          'mode': 'ids',
          'ids': [id]
        },
      };
    case 'many':
      final ids = _expectStringArray(
          condition[spec.idsKey], '$path.${spec.idsKey}', spec.idsKey!);
      return {
        'type': 'member',
        'family': spec.family,
        'op': 'in',
        'target': {'mode': 'ids', 'ids': ids}
      };
    case 'query':
      return {
        'type': 'member',
        'family': spec.family,
        'op': 'in',
        'target': {
          'mode': 'query',
          'root': _expectGroup(condition['root'], '$path.root')
        },
      };
    case 'self':
      return {
        'type': 'member',
        'family': spec.family,
        'op': 'in',
        'target': {'mode': 'self'}
      };
    case 'set':
      return {'type': 'member', 'family': spec.family, 'op': 'exists'};
    default: // 'exact'
      final id =
          _expectString(condition['classId'], '$path.classId', 'classId');
      return {
        'type': 'member',
        'family': 'class',
        'op': 'exact',
        'target': {
          'mode': 'ids',
          'ids': [id]
        },
      };
  }
}

_Json _mapCondition(_Json condition, String path) {
  final type = _expectString(condition['type'], '$path.type', 'condition type');
  final spec = _v1MemberSpecs[type];
  if (spec != null) return _mapMember(spec, condition, path);

  switch (type) {
    case 'content':
      return {'type': 'content', 'op': condition['op'], 'value': condition['value']};
    case 'contentSet':
      return {'type': 'content', 'op': 'exists'};
    case 'name':
      return {'type': 'name', 'op': condition['op'], 'value': condition['value']};
    case 'property':
      return {
        'type': 'property',
        'schemaId': condition['schemaId'],
        'op': condition['op'],
        'value': condition['value'],
        'includeDefaults': condition['includeDefaults'],
      };
    case 'propertyBetween':
      return {
        'type': 'property',
        'schemaId': condition['schemaId'],
        'op': 'between',
        'from': condition['from'],
        'to': condition['to'],
      };
    case 'propertyWithin':
      return {
        'type': 'property',
        'schemaId': condition['schemaId'],
        'op': 'within',
        'period': condition['period']
      };
    case 'isClass':
    case 'isEmbedded':
      final value = condition[type];
      if (value is! bool) {
        _fail('$path.$type', 'expected a boolean for $type');
      }
      return {
        'type': 'nodeField',
        'field': type,
        'op': 'eq',
        'value': value ? 'true' : 'false'
      };
    case 'coverAsset':
    case 'bannerAsset':
    case 'aliasedNode':
      return {
        'type': 'nodeField',
        'field': type,
        'op': condition['op'],
        'value': condition['value']
      };
    default:
      _fail(path, 'unknown v1 condition type "$type"');
  }
}

/// The v1 date-condition name → [field, op].
const Map<String, List<String>> _v1DateTypes = {
  'createdAfter': ['created', 'after'],
  'createdBefore': ['created', 'before'],
  'createdCmp': ['created', 'cmp'],
  'createdBetween': ['created', 'between'],
  'createdWithin': ['created', 'within'],
  'updatedAfter': ['updated', 'after'],
  'updatedBefore': ['updated', 'before'],
  'updatedCmp': ['updated', 'cmp'],
  'updatedBetween': ['updated', 'between'],
  'updatedWithin': ['updated', 'within'],
};

_Json _mapConditionByType(_Json condition, String path) {
  final type = _expectString(condition['type'], '$path.type', 'condition type');
  final dateShape = _v1DateTypes[type];
  if (dateShape != null) {
    final field = dateShape[0];
    final op = dateShape[1];
    final mapped = <String, dynamic>{'type': 'date', 'field': field};
    if (op == 'cmp') {
      mapped['op'] = condition['op'];
      mapped['timestamp'] = condition['timestamp'];
    } else {
      mapped['op'] = op;
      if (op == 'between') {
        mapped['from'] = condition['from'];
        mapped['to'] = condition['to'];
      } else if (op == 'within') {
        mapped['period'] = condition['period'];
      } else {
        mapped['timestamp'] = condition['timestamp'];
      }
    }
    return mapped;
  }
  return _mapCondition(condition, path);
}

Object? _mapChild(Object? child, String path) {
  final node = _expectObject(child, path);
  final type = _expectString(node['type'], '$path.type', 'child type');
  if (type == 'group') return _mapGroup(node, path);
  if (type == 'not') {
    final inner = _expectObject(node['child'], '$path.child');
    final innerType =
        _expectString(inner['type'], '$path.child.type', 'not child type');
    return {
      'type': 'not',
      'child': innerType == 'group'
          ? _mapGroup(inner, '$path.child')
          : _mapConditionByType(inner, '$path.child'),
    };
  }
  return _mapConditionByType(node, path);
}

_Json _mapGroup(_Json group, String path) {
  if (group['logic'] != 'and' && group['logic'] != 'or') {
    _fail('$path.logic', 'expected "and" | "or", got ${group['logic']}');
  }
  final children = group['children'];
  if (children is! List) _fail('$path.children', 'expected a children array');
  return {
    'type': 'group',
    'logic': group['logic'],
    'children': [
      for (var i = 0; i < children.length; i++)
        _mapChild(children[i], '$path.children[$i]'),
    ],
  };
}

/// Structural v1 guard — true only for an object that IS a v1 AST shape.
bool isQueryAstV1(Object? ast) {
  if (ast is! Map || ast['version'] != 1) return false;
  final root = ast['root'];
  return ast['scope'] is Map &&
      root is Map &&
      root['type'] == 'group' &&
      root['children'] is List;
}

/// Map a v1 query AST to its v2 image. Pure and total over the v1 grammar:
/// throws [QueryAstV1MapError] (with the tree path) on anything else —
/// including v2 input, which must NOT be re-mapped.
Map<String, dynamic> mapQueryAstV1ToV2(Object? ast) {
  if (ast is! Map) _fail(r'$', 'expected a query AST object');
  if (ast['version'] != 1) {
    _fail(r'$.version', 'expected version 1, got ${ast['version']}');
  }
  final scope = ast['scope'];
  if (scope is! Map) _fail(r'$.scope', 'expected a scope object');
  if (scope.isEmpty) _fail(r'$.scope', 'scope must not be empty');
  final mapped = <String, dynamic>{
    'version': 2,
    'scope': Map<String, dynamic>.from(scope),
    'root': _expectGroup(ast['root'], r'$.root'),
  };
  if (ast.containsKey('sort')) mapped['sort'] = ast['sort'];
  if (ast.containsKey('aggregation')) {
    mapped['aggregation'] = ast['aggregation'];
  }
  return mapped;
}
