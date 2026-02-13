/// Identifies a serialization format (markdown, HTML, JSON, etc.).
///
/// Open class — third parties can define custom formats:
/// ```dart
/// const myFormat = Format('custom-json');
/// ```
class Format {
  const Format(this.name);

  static const markdown = Format('markdown');

  final String name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Format && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'Format($name)';
}
