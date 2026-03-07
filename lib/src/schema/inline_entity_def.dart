import '../model/inline_entity.dart';
import 'inline_style_def.dart';

/// Schema definition for a public inline entity.
///
/// The entity key itself is stored on segments; [style] defines how that
/// entity renders and serializes.
class InlineEntityDef<E extends Object> {
  const InlineEntityDef({
    required this.type,
    required this.style,
    required this.label,
    required this.decode,
    required this.encode,
    this.defaultText,
  });

  /// Public entity key, e.g. [InlineEntityType.link].
  final E type;

  /// Rendering and codec definition for this entity.
  final InlineStyleDef style;

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
