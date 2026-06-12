/// A resolved view of one inline entity occurrence inside a block: its key,
/// the block-local text range it covers, its visible text, and its stored
/// attributes. Returned by entity queries and handed to link-tap callbacks.
class InlineEntitySnapshot {
  const InlineEntitySnapshot({
    required this.key,
    required this.start,
    required this.end,
    required this.text,
    required this.attributes,
  });

  final String key;

  /// Block-local range `[start, end)` the entity covers.
  final int start;
  final int end;

  final String text;
  final Map<String, dynamic> attributes;

  @override
  String toString() => 'InlineEntitySnapshot($key, $start..$end, "$text")';
}

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
