import 'package:flutter/widgets.dart';

import '../../model/block.dart';
import '../block_component_context.dart';

/// Component for the void image block: full-width image, atomic selection,
/// delete-as-unit (D3).
///
/// The image URL lives in `metadata[ImageKeys.url]`; alt text is the block's
/// plain text (the v2 markdown-codec shape: `![alt](url)`).
class ImageBlockComponent extends StatelessWidget {
  const ImageBlockComponent(this.context_, {super.key});

  final BlockComponentContext context_;

  @override
  Widget build(BuildContext context) {
    final block = context_.block;
    final url = block.metadata[ImageKeys.url] as String? ?? '';
    final alt = block.plainText;

    final Widget child;
    if (url.isEmpty) {
      child = _placeholder(alt.isNotEmpty ? alt : 'Image');
    } else {
      child = Image.network(
        url,
        width: double.infinity,
        fit: BoxFit.fitWidth,
        // Placeholder until the first decoded frame, so the block occupies
        // image-shaped space while loading instead of collapsing.
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
            wasSynchronouslyLoaded || frame != null
            ? child
            : _placeholder(alt.isNotEmpty ? alt : url),
        errorBuilder: (context, error, stackTrace) =>
            _placeholder(alt.isNotEmpty ? alt : url),
      );
    }

    // One image node carrying the alt label — the placeholder's visible alt
    // text must not double-read under screen readers.
    return Semantics(
      image: true,
      label: alt.isNotEmpty ? alt : url,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: child,
        ),
      ),
    );
  }

  /// An image-shaped (16:9) slot, so a missing/failed image still occupies
  /// image-block real estate instead of collapsing to a text line
  /// (checkpoint-1 finding).
  Widget _placeholder(String label) {
    final style = context_.resolvedStyle;
    final fontSize = style.fontSize ?? 16.0;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0x15808080),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: const Color(0x30808080)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              const IconData(0xe3f4, fontFamily: 'MaterialIcons'),
              size: fontSize * 2,
              color: style.color?.withValues(alpha: 0.35),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: fontSize * 0.85,
                color: style.color?.withValues(alpha: 0.5),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
