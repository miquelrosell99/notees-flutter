/// Data-level color grammar (owner 2026-10-03) —
/// Dart port of `packages/protocol/src/colors.ts` in the Notees monorepo.
///
/// A node/class `color` is ONE string field carrying either a preset token
/// or a custom `#RRGGBB` hex. This replaces the first encoding — CSS
/// variable references (`var(--color-preset-red)`) — which leaked a web
/// technology onto the wire and drifted between clients. The token/hex split
/// is client-neutral and strictly validatable; the concrete preset hexes live
/// client-side (`ColorPresets` in lib/core/utils), keyed by token.
///
/// `null` on a color field means CLEAR (object.update gained the capability
/// first; class.update documented "null clears" and the schema now
/// accepts it). Payload validators reject the retired `var(--color-preset-*)`
/// encoding outright — old stored logs are rewritten by the one-time
/// monorepo migration (scripts/migrate-color-tokens.mts).
library;

/// The ten preset tokens, hue order (red → pink) then gray. The token SET is
/// normative here; display ORDER and the concrete hexes are a client concern.
const List<String> colorPresetTokens = [
  'red',
  'orange',
  'yellow',
  'green',
  'teal',
  'sky',
  'blue',
  'purple',
  'pink',
  'gray',
];

final RegExp _hexColorPattern = RegExp(r'^#[0-9a-fA-F]{6}$');

/// True when [value] is a stored color: a preset token or a `#RRGGBB` hex.
bool isColorValue(Object? value) =>
    value is String &&
    (colorPresetTokens.contains(value) || _hexColorPattern.hasMatch(value));
