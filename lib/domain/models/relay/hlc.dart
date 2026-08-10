/// Hybrid logical clock used by the Notees operation-relay protocol.
///
/// [physical] is wall-clock time in milliseconds. [logical] is a monotonic
/// counter incremented when multiple operations share the same physical ms.
/// Total order: physical, then logical, then envelope id as a tie-breaker.
class Hlc {
  const Hlc({required this.physical, required this.logical});

  final int physical;
  final int logical;

  factory Hlc.fromJson(Map<String, dynamic> json) => Hlc(
        physical: json['physical'] as int,
        logical: json['logical'] as int,
      );

  Map<String, dynamic> toJson() => {
        'physical': physical,
        'logical': logical,
      };

  /// Compares two HLCs. Returns a negative value if this < other, zero if
  /// equal, positive if this > other.
  int compareTo(Hlc other) {
    if (physical != other.physical) return physical - other.physical;
    return logical - other.logical;
  }

  bool operator <(Hlc other) => compareTo(other) < 0;
  bool operator <=(Hlc other) => compareTo(other) <= 0;
  bool operator >(Hlc other) => compareTo(other) > 0;
  bool operator >=(Hlc other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is Hlc && physical == other.physical && logical == other.logical;

  @override
  int get hashCode => Object.hash(physical, logical);

  @override
  String toString() => 'Hlc($physical, $logical)';
}
