import 'package:flutter/widgets.dart';

import '../codec/format.dart';
import '../codec/inline_codec.dart';

/// Defines the behavior and appearance of an inline style.
///
/// Each inline style (bold, italic, etc.) has a corresponding
/// [InlineStyleDef] that describes how it modifies text rendering
/// and serialization. Register inline style defs in an [EditorSchema].
class InlineStyleDef {
  const InlineStyleDef({
    required this.label,
    required this.applyStyle,
    this.codecs,
  });

  /// Human-readable label for toolbars and UI (e.g. "Bold", "Italic").
  final String label;

  /// Applies this style to a base [TextStyle]. Called during span building.
  /// Example: bold returns `base.copyWith(fontWeight: FontWeight.bold)`.
  final TextStyle Function(TextStyle base) applyStyle;

  /// Serialization codecs keyed by [Format]. Each codec defines how this
  /// inline style encodes/decodes in that format.
  final Map<Format, InlineCodec>? codecs;
}
