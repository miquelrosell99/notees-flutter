import 'dart:convert';

import '../../../core/utils/date_uuid.dart';
import 'store_errors.dart';

/// Property-value shapes — the one-shape-per-type invariant (SCHEMA.md
/// "Node-backed text properties" / "Datetime"), enforced fail-loud at the
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
///  - datetime: the unified date value union (SCHEMA.md "Datetime") — a
///    POINT `{ "nodeId": …, "time"?: "HH:MM" }` (a bare-uuid string, the
///    legacy date encoding, normalizes to the reference shape) OR a RANGE
///    `{ "start": slot|null, "end": slot|null }` — either side open; each
///    present slot is `{ "nodeId": …, "time"?: "HH:MM" }` (legacy bare-uuid
///    sides normalized). A value carrying BOTH `nodeId` and `start`/`end`
///    is rejected outright; a `time` must match `HH:MM` (24h, minute
///    precision) and ride a DAY-precision date-node ref.
///  - object / asset: a node reference `{ "nodeId": … }`; a bare-uuid string
///    (legacy) normalizes to the reference shape, other strings are
///    rejected. (`asset` is M38: the target must carry the asset class —
///    the implicit filter is a graph check, applied with the rest of the
///    schema-linked integrity on the cache repository.)
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

/// 24h wall-clock `HH:MM`, minute precision, no timezone (the no-timezone
/// law stands — times are local wall-clock, never an offset or a zone).
final _timeOfDay = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');

/// Defensive acceptance: any input, true only for a well-formed `HH:MM`.
bool isValidTimeOfDay(dynamic value) =>
    value is String && _timeOfDay.hasMatch(value);

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
    case 'object':
    case 'asset':
      final ref = nodeRefOfValue(value);
      if (ref != null) return {'nodeId': ref};
      break;
    case 'datetime':
      // The unified date union (SCHEMA.md "Datetime"): a point
      // { "nodeId": …, "time"?: "HH:MM" } or a range { "start", "end" } of
      // slots ({ "nodeId": …, "time"?: "HH:MM" }), either side open.
      if (value is String) {
        // Legacy bare-uuid point (the archived date encoding) normalizes.
        if (isUuidLike(value)) return {'nodeId': value};
        break;
      }
      if (value is Map<String, dynamic>) {
        final pointKey = value.containsKey('nodeId');
        final rangeKey = value.containsKey('start') || value.containsKey('end');
        // A value carrying BOTH shapes is rejected outright (fail loud).
        if (pointKey && rangeKey) break;
        // A slot: node reference + optional wall-clock time. `time` must be
        // a well-formed HH:MM and ride a DAY-precision date-node anchor (a
        // year/month ref — or a non-date id — has no wall-clock time). A
        // legacy bare-uuid string side normalizes to {nodeId}.
        const missing = Object();
        Object? slotOf(dynamic v) {
          if (v == null) return null;
          if (v is String) return isUuidLike(v) ? {'nodeId': v} : missing;
          if (v is! Map<String, dynamic>) return missing;
          final ref = nodeRefOfValue(v);
          if (ref == null) return missing;
          final out = <String, dynamic>{'nodeId': ref};
          if (v.containsKey('time')) {
            final time = v['time'];
            if (!isValidTimeOfDay(time)) return missing;
            if (parseDateNodeId(ref)?.precision != DateNodePrecision.day) {
              return missing;
            }
            out['time'] = time;
          }
          return out;
        }

        if (pointKey) {
          final out = slotOf(value);
          if (!identical(out, missing) && out != null) return out;
        } else if (rangeKey) {
          // A side is legal when the key is PRESENT with null or a slot;
          // an absent key is the TS `undefined` — the shape requires both
          // keys (either side may be JSON null, the open side).
          final start = value.containsKey('start') ? slotOf(value['start']) : missing;
          final end = value.containsKey('end') ? slotOf(value['end']) : missing;
          if (!identical(start, missing) && !identical(end, missing)) {
            return {
              'start': start == null ? null : start as Map<String, dynamic>,
              'end': end == null ? null : end as Map<String, dynamic>,
            };
          }
        }
      }
      break;
    default:
      return value;
  }
  throw PropertyValueShapeError(
    '$opType: value for $type schema must be ${switch (type) {
      'text' => 'a string or a node reference { "nodeId": … }',
      'datetime' => 'a datetime point { "nodeId": …, "time"?: "HH:MM" } or '
          'range { "start": slot|null, "end": slot|null } — "time" '
          'requires a day-precision date anchor',
      _ => 'a node reference { "nodeId": … }',
    }} — got ${jsonEncodeForMessage(value)}',
    opType,
  );
}

/// PC2: a class-binding defaultValue must be typed per the schema type.
/// Node-typed schemas (datetime/object/asset) accept only JSON null —
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
    case 'datetime':
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

/// The SCHEMA.md "Datetime" precision rank: "year" < "month" < "day"; a
/// null (or unknown) precision reads as day (rank 3).
int datePrecisionRank(String? precision) => switch (precision) {
      'year' => 1,
      'month' => 2,
      _ => 3,
    };
