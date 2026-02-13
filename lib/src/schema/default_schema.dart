import 'package:flutter/widgets.dart';

import '../codec/block_codec.dart';
import '../codec/format.dart';
import '../codec/inline_codec.dart';
import '../model/block.dart';
import '../model/block_policies.dart';
import '../model/document.dart';
import '../model/inline_style.dart';
import 'block_def.dart';
import 'editor_schema.dart';
import 'inline_style_def.dart';

/// Builds the standard [EditorSchema] with all built-in block types and
/// inline styles, including markdown codecs.
///
/// **Block ordering matters for decode.** Longer/more-specific prefixes must
/// come before shorter ones (h3 before h2 before h1, taskItem before listItem)
/// so the decoder tries them first.
EditorSchema buildStandardSchema() {
  return EditorSchema(
    blocks: {
      BlockType.paragraph: BlockDef(
        label: 'Paragraph',
        policies: const BlockPolicies(canBeChild: true, canHaveChildren: false),
        codecs: {
          Format.markdown: BlockCodec(
            encode: (block, ctx) => '${ctx.indent}${ctx.content}',
          ),
        },
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
        codecs: {
          Format.markdown: BlockCodec(
            encode: (block, ctx) => '${ctx.indent}# ${ctx.content}',
            decode: (line) {
              if (!line.startsWith('# ')) return null;
              return DecodeMatch(line.substring(2));
            },
          ),
        },
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
        codecs: {
          Format.markdown: BlockCodec(
            encode: (block, ctx) => '${ctx.indent}## ${ctx.content}',
            decode: (line) {
              if (!line.startsWith('## ')) return null;
              return DecodeMatch(line.substring(3));
            },
          ),
        },
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
        codecs: {
          Format.markdown: BlockCodec(
            encode: (block, ctx) => '${ctx.indent}### ${ctx.content}',
            decode: (line) {
              if (!line.startsWith('### ')) return null;
              return DecodeMatch(line.substring(4));
            },
          ),
        },
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
        codecs: {
          Format.markdown: BlockCodec(
            encode: (block, ctx) => '${ctx.indent}- ${ctx.content}',
            decode: (line) {
              if (!line.startsWith('- ')) return null;
              return DecodeMatch(line.substring(2));
            },
          ),
        },
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
        codecs: {
          Format.markdown: BlockCodec(
            encode: (block, ctx) =>
                '${ctx.indent}${ctx.ordinal}. ${ctx.content}',
            decode: (line) {
              final match = RegExp(r'^\d+\. ').firstMatch(line);
              if (match == null) return null;
              return DecodeMatch(line.substring(match.end));
            },
          ),
        },
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
        codecs: {
          Format.markdown: BlockCodec(
            encode: (block, ctx) {
              final checked = block.metadata['checked'] == true;
              return '${ctx.indent}- [${checked ? 'x' : ' '}] ${ctx.content}';
            },
            decode: (line) {
              if (line.startsWith('- [x] ')) {
                return DecodeMatch(line.substring(6),
                    metadata: {'checked': true});
              }
              if (line.startsWith('- [ ] ')) {
                return DecodeMatch(line.substring(6),
                    metadata: {'checked': false});
              }
              return null;
            },
          ),
        },
      ),
    },
    inlineStyles: {
      InlineStyle.bold: InlineStyleDef(
        label: 'Bold',
        applyStyle: (base) => base.copyWith(fontWeight: FontWeight.bold),
        codecs: {Format.markdown: const InlineCodec(wrap: '**')},
      ),
      InlineStyle.italic: InlineStyleDef(
        label: 'Italic',
        applyStyle: (base) => base.copyWith(fontStyle: FontStyle.italic),
        codecs: {Format.markdown: const InlineCodec(wrap: '*')},
      ),
      InlineStyle.strikethrough: InlineStyleDef(
        label: 'Strikethrough',
        applyStyle: (base) =>
            base.copyWith(decoration: TextDecoration.lineThrough),
        codecs: {Format.markdown: const InlineCodec(wrap: '~~')},
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
