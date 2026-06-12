/// The standard gutter prefix widgets used by the built-in block defs.
/// Exported so custom block defs can reuse them.
library;

import 'package:flutter/widgets.dart';

import '../model/block.dart';
import '../schema/block_def.dart';
import '../schema/default_schema.dart' show kFallbackFontSize;

/// Compute prefix width from a resolved font size and factor.
double prefixWidth(double fontSize, [double factor = 1.5]) => fontSize * factor;

/// Bullet-list gutter prefix: a centered bullet character.
Widget bulletPrefix(
  TextStyle resolvedStyle, {
  double prefixWidthFactor = 1.5,
  String bulletChar = '•',
}) {
  final fontSize = resolvedStyle.fontSize ?? kFallbackFontSize;
  return SizedBox(
    width: prefixWidth(fontSize, prefixWidthFactor),
    child: Center(
      child: Text(
        bulletChar,
        style: TextStyle(fontSize: fontSize * 1.2, height: 1),
      ),
    ),
  );
}

/// Numbered-list gutter prefix: the run ordinal from [gutter], dot-suffixed.
Widget numberedPrefix(
  GutterContext gutter,
  TextStyle resolvedStyle, {
  double prefixWidthFactor = 1.5,
}) {
  final fontSize = resolvedStyle.fontSize ?? kFallbackFontSize;
  return SizedBox(
    width: prefixWidth(fontSize, prefixWidthFactor),
    child: Center(
      child: Text(
        '${gutter.ordinal}.',
        style: TextStyle(fontSize: fontSize, height: 1),
      ),
    ),
  );
}

/// Task-item gutter prefix: a checkbox reflecting `TaskItemKeys.checked`.
///
/// [accentColor] null derives a blue from the text color's brightness.
Widget taskPrefix(
  TextBlock block,
  TextStyle resolvedStyle, {
  double prefixWidthFactor = 1.5,
  Color? accentColor,
}) {
  final checked = block.metadata[TaskItemKeys.checked] == true;
  final fontSize = resolvedStyle.fontSize ?? kFallbackFontSize;
  final size = fontSize * 0.85;
  final borderRadius = size * 0.2;
  final textColor = resolvedStyle.color ?? const Color(0xFF333333);
  final Color resolvedAccent;
  if (accentColor != null) {
    resolvedAccent = accentColor;
  } else {
    final isDark = textColor.computeLuminance() > 0.5;
    resolvedAccent = isDark ? const Color(0xFF64B5F6) : const Color(0xFF2196F3);
  }

  return SizedBox(
    width: prefixWidth(fontSize, prefixWidthFactor),
    child: Center(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          border: Border.all(
            color: checked ? resolvedAccent : textColor.withValues(alpha: 0.4),
            width: 1.5,
          ),
          color: checked ? resolvedAccent : null,
        ),
        child: checked
            ? CustomPaint(
                painter: _CheckPainter(color: const Color(0xFFFFFFFF)),
              )
            : null,
      ),
    ),
  );
}

/// Block-quote gutter prefix: a rounded vertical bar.
Widget quoteBarPrefix(TextStyle resolvedStyle, {Color? barColor}) {
  final fontSize = resolvedStyle.fontSize ?? kFallbackFontSize;
  final barHeight = fontSize * 1.4;
  return SizedBox(
    width: 16,
    height: barHeight,
    child: Center(
      child: Container(
        width: 3,
        height: barHeight,
        decoration: BoxDecoration(
          color: barColor ?? const Color(0xFFBDBDBD),
          borderRadius: BorderRadius.circular(1.5),
        ),
      ),
    ),
  );
}

class _CheckPainter extends CustomPainter {
  _CheckPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = size.width * 0.15
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final path = Path()
      ..moveTo(size.width * 0.2, size.height * 0.5)
      ..lineTo(size.width * 0.42, size.height * 0.72)
      ..lineTo(size.width * 0.8, size.height * 0.28);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_CheckPainter old) => color != old.color;
}
