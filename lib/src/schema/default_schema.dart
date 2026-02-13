import 'package:flutter/widgets.dart';

import '../model/block.dart';
import '../model/block_policies.dart';
import '../model/document.dart';
import '../model/inline_style.dart';
import 'block_def.dart';
import 'editor_schema.dart';
import 'inline_style_def.dart';

/// Builds the standard [EditorSchema] with all built-in block types and
/// inline styles.
EditorSchema buildStandardSchema() {
  return EditorSchema(
    blocks: {
      BlockType.paragraph: const BlockDef(
        label: 'Paragraph',
        policies: BlockPolicies(canBeChild: true, canHaveChildren: false),
      ),
      BlockType.h1: BlockDef(
        label: 'Heading 1',
        policies: const BlockPolicies(
          canBeChild: false,
          canHaveChildren: false,
        ),
        baseStyle: (base) => (base ?? const TextStyle()).copyWith(
          fontSize: 24,
          fontWeight: FontWeight.bold,
          height: 1.3,
        ),
      ),
      BlockType.h2: BlockDef(
        label: 'Heading 2',
        policies: const BlockPolicies(
          canBeChild: false,
          canHaveChildren: false,
        ),
        baseStyle: (base) => (base ?? const TextStyle()).copyWith(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          height: 1.3,
        ),
      ),
      BlockType.h3: BlockDef(
        label: 'Heading 3',
        policies: const BlockPolicies(
          canBeChild: false,
          canHaveChildren: false,
        ),
        baseStyle: (base) => (base ?? const TextStyle()).copyWith(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
      ),
      BlockType.listItem: BlockDef(
        label: 'Bullet List',
        policies: const BlockPolicies(
          canBeChild: true,
          canHaveChildren: true,
          maxDepth: 6,
        ),
        isListLike: true,
        splitInheritsType: true,
        prefixBuilder: _bulletPrefix,
      ),
      BlockType.numberedList: BlockDef(
        label: 'Numbered List',
        policies: const BlockPolicies(
          canBeChild: true,
          canHaveChildren: true,
          maxDepth: 6,
        ),
        isListLike: true,
        splitInheritsType: true,
        prefixBuilder: _numberedPrefix,
      ),
      BlockType.taskItem: BlockDef(
        label: 'Task',
        policies: const BlockPolicies(
          canBeChild: true,
          canHaveChildren: true,
          maxDepth: 6,
        ),
        isListLike: true,
        splitInheritsType: true,
        prefixBuilder: _taskPrefix,
      ),
    },
    inlineStyles: {
      InlineStyle.bold: InlineStyleDef(
        label: 'Bold',
        applyStyle: (base) => base.copyWith(fontWeight: FontWeight.bold),
      ),
      InlineStyle.italic: InlineStyleDef(
        label: 'Italic',
        applyStyle: (base) => base.copyWith(fontStyle: FontStyle.italic),
      ),
      InlineStyle.strikethrough: InlineStyleDef(
        label: 'Strikethrough',
        applyStyle: (base) =>
            base.copyWith(decoration: TextDecoration.lineThrough),
      ),
    },
  );
}

// ---------------------------------------------------------------------------
// Prefix builders — moved from span_builder.dart
// ---------------------------------------------------------------------------

const _prefixStyle = TextStyle(fontSize: 14, color: Color(0xFF666666));

Widget? _bulletPrefix(Document doc, int flatIndex, TextBlock block) {
  return const Text('•  ', textAlign: TextAlign.right, style: _prefixStyle);
}

Widget? _numberedPrefix(Document doc, int flatIndex, TextBlock block) {
  final ordinal = computeOrdinal(doc, flatIndex);
  return Text(
    '$ordinal.  ',
    textAlign: TextAlign.right,
    style: _prefixStyle,
  );
}

Widget? _taskPrefix(Document doc, int flatIndex, TextBlock block) {
  final checked = block.metadata['checked'] == true;
  return Text(
    checked ? '☑  ' : '☐  ',
    textAlign: TextAlign.right,
    style: _prefixStyle,
  );
}

/// Compute the 1-based ordinal for a numbered list item among its siblings.
///
/// Exported so it can be reused by custom numbered-list block defs.
int computeOrdinal(Document doc, int flatIndex) {
  var ordinal = 1;
  final flat = doc.allBlocks;
  final depth = doc.depthOf(flatIndex);

  for (var j = flatIndex - 1; j >= 0; j--) {
    if (doc.depthOf(j) != depth) break;
    if (flat[j].blockType != BlockType.numberedList) break;
    ordinal++;
  }
  return ordinal;
}
