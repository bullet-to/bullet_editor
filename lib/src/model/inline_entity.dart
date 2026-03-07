/// Built-in inline entity keys.
///
/// These are used by [EditorSchema.standard()]. Custom schemas can supply their
/// own entity key type instead.
enum InlineEntityType { link }

/// Marker interface for typed inline entity payloads.
abstract interface class InlineEntityData {
  const InlineEntityData();
}

/// Typed payload for a link inline entity.
final class LinkData implements InlineEntityData {
  const LinkData({required this.url});

  final String url;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is LinkData && url == other.url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'LinkData(url: $url)';
}
