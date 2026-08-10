import 'package:uuid/uuid.dart';
import 'package:uuid/v7.dart' as uuid_v7;

/// Generates time-ordered UUIDv7 identifiers used for operation envelopes.
class Uuid7 {
  Uuid7._();

  static final _generator = uuid_v7.UuidV7();

  static String generate() => _generator.generate();
}

/// Legacy UUIDv4 helper kept for code that does not need ordering.
class Uuid4 {
  Uuid4._();

  static const _uuid = Uuid();

  static String generate() => _uuid.v4();
}
