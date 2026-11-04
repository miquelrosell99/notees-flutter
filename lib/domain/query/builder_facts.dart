/// The picker-source facts the query builder's condition rows share — a
/// pure-Dart port of the web's `apps/web/src/features/collection/
/// builderFacts.ts` data shape: the bound properties across all classes,
/// enriched with each schema row's options + target filter (the type-aware
/// value controls), plus the class/property name maps. The derivation from
/// the local derived store lives at the service seam
/// (`QueryService.buildFacts`); this file is the pure read model the
/// builder model consumes (no sqflite imports — unit-test friendly).
library;

/// A bound property enriched with its schema row (the web's
/// BuilderFacts.boundProperties entry).
class BuilderPropertyInfo {
  const BuilderPropertyInfo({
    required this.id,
    required this.name,
    required this.type,
    this.options,
    this.targetClassFilter,
  });

  final String id;
  final String name;
  final String type;

  /// The select options (id + label), null when the schema carries none.
  final List<BuilderPropertyOption>? options;

  /// The node-typed target's class filter, null when unfiltered.
  final List<String>? targetClassFilter;
}

/// One select option (id + label).
class BuilderPropertyOption {
  const BuilderPropertyOption({required this.id, required this.label});

  final String id;
  final String label;
}

/// A class row in the picker's read model (name resolved for display).
class BuilderClassInfo {
  const BuilderClassInfo({required this.id, required this.name});

  final String id;
  final String name;
}

/// The picker sources (the web's BuilderFacts): classes for the class pick,
/// bound properties (deduped by schema id) for the property family's
/// operator + value registers, the name maps for honest broken-ref labels.
class BuilderFacts {
  BuilderFacts({required this.classes, required this.boundProperties});

  final List<BuilderClassInfo> classes;
  final List<BuilderPropertyInfo> boundProperties;

  /// The class id → display name map (the web's classNames).
  late final Map<String, String> classNames = {
    for (final cls in classes) cls.id: cls.name,
  };

  /// The property schema id → name map (the web's propertyNames).
  late final Map<String, String> propertyNames = {
    for (final property in boundProperties) property.id: property.name,
  };

  /// The bound property for [schemaId], null when unknown (broken ref).
  BuilderPropertyInfo? propertyById(String schemaId) {
    for (final property in boundProperties) {
      if (property.id == schemaId) return property;
    }
    return null;
  }
}
