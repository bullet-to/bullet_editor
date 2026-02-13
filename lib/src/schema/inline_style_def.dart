import 'package:flutter/widgets.dart';

import '../codec/format.dart';
import '../codec/inline_codec.dart';

/// Defines the behavior and appearance of an inline style.
///
/// Each inline style (bold, italic, etc.) has a corresponding
/// [InlineStyleDef] that describes how it modifies text rendering
/// and serialization. Register inline style defs in an [EditorSchema].
///
/// Simple styles use [applyStyle]. Data-carrying styles (links, mentions)
/// can also set [isDataCarrying] to true, which signals the toolbar and
/// controller to handle them differently (they need attributes, not just toggle).
class InlineStyleDef {
  const InlineStyleDef({
    required this.label,
    required this.applyStyle,
    this.isDataCarrying = false,
    this.codecs,
  });

  /// Human-readable label for toolbars and UI (e.g. "Bold", "Italic").
  final String label;

  /// Applies this style to a base [TextStyle]. Called during span building.
  /// Receives the segment's [attributes] for data-carrying styles.
  /// Example: bold returns `base.copyWith(fontWeight: FontWeight.bold)`.
  /// Example: link returns `base.copyWith(color: blue, decoration: underline)`.
  final TextStyle Function(TextStyle base,
      {Map<String, dynamic> attributes}) applyStyle;

  /// Whether this style carries data in segment attributes (e.g. link URL).
  /// Data-carrying styles are not simple toggles — they need attributes
  /// to be set when applied.
  final bool isDataCarrying;

  /// Serialization codecs keyed by [Format]. Each codec defines how this
  /// inline style encodes/decodes in that format.
  final Map<Format, InlineCodec>? codecs;
}
