import 'dart:convert';

import 'store_errors.dart';

/// Property-value shapes — the one-shape-per-type invariant (SCHEMA.md
/// "Node-backed text properties" / "Dates"), enforced fail-loud at the
/// apply-time write path (PB2/PC2/PG6) and re-checked
/// defensively at the effective read model (a stored value/default that no
/// longer matches the schema type yields nothing instead of garbage).
/// Port of the monorepo store's `packages/store/src/property-values.ts`
/// (pure half; the graph checks live on the cache repository).
///
/// Write shapes by schema type:
///  - text: a scalar string OR a carrier-block reference `{ "nodeId": … }`
///    (node-backed rich text). Archived data may hold the legacy bare-uuid
///    carrier shape — reads stay lenient, writes go `{nodeId}`.
///  - date / object / asset: a node reference `{ "nodeId": … }`; a bare-uuid
///    string (legacy) normalizes to the reference shape, other strings are
///    rejected. (`asset` is M38: the target must carry the asset class —
///    the implicit filter is a graph check, applied with the rest of the
///    schema-linked integrity on the cache repository.)
///  - date_range: `{ "start": ref|null, "end": ref|null }` — either side
///    open; each present side is a reference (legacy bare uuid normalized).
///  - number: a finite number; a NUMERIC STRING is the migrated legacy
///    encoding (live data carries epoch-millis strings) and normalizes to a
///    number, anything else is rejected.
///  - boolean: a boolean. url / email / select: a string. multi_select: an
///    array of strings (the option-id list).
///  - image: UNCHECKED by design — the type has no defined value shape yet
///    (PG14's zombie row): live data carries migrated asset-payload records
///    and legacy bare uuids, so any shape check would break replay of the
///    migrated log.
final _uuidLike = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// True for the legacy bare-uuid carrier encoding (archived data).
bool isUuidLike(dynamic value) => value is String && _uuidLike.hasMatch(value);

/// The node id a value references, when it is reference-shaped: either the
/// canonical `{ "nodeId": … }` or a legacy bare uuid. Scalar strings that
/// are not uuid-shaped return null (they are text, not references).
String? nodeRefOfValue(dynamic value) {
  if (value is Map<String, dynamic> && value.containsKey('nodeId')) {
    final id = value['nodeId'];
    if (id is String && id.isNotEmpty) return id;
  }
  return isUuidLike(value) ? value as String : null;
}

/// JSON-encode for validation messages; values authored from JSON always
/// encode, anything else degrades to its toString instead of throwing.
String jsonEncodeForMessage(dynamic value) {
  try {
    return jsonEncode(value);
  } catch (_) {
    return '$value';
  }
}

/// Validate a property.set value against the schema type; returns the value
/// to store (a legacy bare-uuid reference is normalized to `{nodeId}`).
/// `null` means "no value" and bypasses shape validation. Throws
/// [PropertyValueShapeError] on mismatch — fail-loud, per the register.
dynamic assertValueShapeForType(String type, dynamic value, String opType) {
  if (value == null) return value;
  switch (type) {
    case 'text':
      if (value is String) return value;
      final ref = nodeRefOfValue(value);
      if (ref != null) return {'nodeId': ref};
      break;
    case 'date':
    case 'object':
    case 'asset':
      final ref = nodeRefOfValue(value);
      if (ref != null) return {'nodeId': ref};
      break;
    case 'date_range':
      if (value is Map<String, dynamic>) {
        // A side is legal when the key is PRESENT with null or a reference;
        // an absent key is the TS `undefined` — the shape requires both
        // keys (either side may be JSON null, the open side).
        const missing = Object();
        Object? sideOf(dynamic v) {
          if (v == null) return null;
          final ref = nodeRefOfValue(v);
          return ref != null ? {'nodeId': ref} : missing;
        }

        final start = value.containsKey('start') ? sideOf(value['start']) : missing;
        final end = value.containsKey('end') ? sideOf(value['end']) : missing;
        if (start != missing && end != missing) {
          return {
            'start': start == null ? null : (start as Map<String, dynamic>),
            'end': end == null ? null : (end as Map<String, dynamic>),
          };
        }
      }
      break;
    default:
      return value;
  }
  throw PropertyValueShapeError(
    '$opType: value for $type schema must be ${switch (type) {
      'text' => 'a string or a node reference { "nodeId": … }',
      'date_range' => '{ "start": ref|null, "end": ref|null } of node references',
      _ => 'a node reference { "nodeId": … }',
    }} — got ${jsonEncodeForMessage(value)}',
    opType,
  );
}

/// PC2: a class-binding defaultValue must be typed per the schema type.
/// Node-typed schemas (date/date_range/object/asset) accept only JSON null —
/// a default that links a node is meaningless. `text` accepts scalar strings,
/// not carrier references. Returns false instead of throwing so the read
/// model can drop silently; the write path (class.property.set) fails loud.
bool isValidDefaultForType(String type, dynamic value) {
  if (value == null) return true;
  switch (type) {
    case 'text':
    case 'url':
    case 'email':
    case 'image':
    case 'select':
      return value is String;
    case 'number':
      return value is num && value.isFinite;
    case 'boolean':
      return value is bool;
    case 'multi_select':
      return value is List && value.every((v) => v is String);
    case 'date':
    case 'date_range':
    case 'object':
    case 'asset':
      return false;
    default:
      return true;
  }
}

/// Shape + scalar typing only (no graph checks) — the PG6 extension of
/// [assertValueShapeForType], keyed off the full schema row. Returns the
/// normalized value to store.
dynamic assertScalarShapeForType(String type, dynamic value, String opType) {
  if (value == null) return value;
  switch (type) {
    case 'number':
      if (value is num && value.isFinite) return value;
      // migrated epoch-millis strings (live-data verified): normalize.
      // JS Number(string) trims whitespace; Dart's num.tryParse does not,
      // so trim first (hex/octal/binary literals parse in JS but not here —
      // decimal digit strings are what the migrated log carries).
      if (value is String) {
        final trimmed = value.trim();
        if (trimmed.isNotEmpty) {
          final parsed = num.tryParse(trimmed);
          if (parsed != null && parsed.isFinite) return parsed;
        }
      }
      break;
    case 'boolean':
      if (value is bool) return value;
      break;
    case 'url':
    case 'email':
    case 'select':
      if (value is String) return value;
      break;
    case 'multi_select':
      if (value is List && value.every((v) => v is String)) return value;
      break;
    default:
      // image, asset (shape-normalized above), and any future type:
      // unchecked (see the file header).
      return value;
  }
  throw PropertyValueShapeError(
    '$opType: value for $type schema must be ${switch (type) {
      'number' => 'a finite number',
      'boolean' => 'a boolean',
      'multi_select' => 'an array of strings (option ids)',
      _ => 'a string',
    }} — got ${jsonEncodeForMessage(value)}',
    opType,
  );
}

/// The SCHEMA.md "Dates" precision rank: "year" < "month" < "day"; a null
/// (or unknown) precision reads as day (rank 3).
int datePrecisionRank(String? precision) => switch (precision) {
      'year' => 1,
      'month' => 2,
      _ => 3,
    };
