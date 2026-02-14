import 'package:flutter/widgets.dart';

import '../codec/format.dart';
import '../codec/inline_codec.dart';
import '../editor/input_rule.dart';

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
    this.shortcut,
    this.codecs,
    this.inputRules = const [],
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

  /// Optional keyboard shortcut that toggles this style (e.g. Cmd+B for bold).
  /// When set, [BulletEditor] registers it automatically. Data-carrying styles
  /// (links, mentions) typically leave this null since they need app-specific UI.
  final SingleActivator? shortcut;

  /// Serialization codecs keyed by [Format]. Each codec defines how this
  /// inline style encodes/decodes in that format.
  final Map<Format, InlineCodec>? codecs;

  /// Input rules owned by this inline style. Collected by the schema in map
  /// insertion order — define specific rules before general ones.
  final List<InputRule> inputRules;
}
