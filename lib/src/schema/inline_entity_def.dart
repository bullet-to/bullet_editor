import '../model/inline_entity.dart';

/// Schema definition for a public inline entity backed by an internal style.
///
/// This lets the editor expose entity-first APIs while continuing to store
/// entities as styled segments with attributes internally.
class InlineEntityDef<E extends Object, S extends Object> {
  const InlineEntityDef({
    required this.type,
    required this.style,
    required this.label,
    required this.decode,
    required this.encode,
    this.defaultText,
  });

  /// Public entity type, e.g. [InlineEntityType.link].
  final E type;

  /// Internal style key used to store the entity in a segment.
  final S style;

  /// Human-readable label for UI.
  final String label;

  /// Decode stored segment attributes into typed entity data.
  final InlineEntityData Function(Map<String, dynamic> attributes) decode;

  /// Encode typed entity data into stored segment attributes.
  final Map<String, dynamic> Function(InlineEntityData data) encode;

  /// Optional default visible text when inserting a collapsed entity without
  /// explicit text.
  final String? Function(InlineEntityData data)? defaultText;
}
