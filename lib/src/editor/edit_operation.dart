import '../model/block.dart';
import '../model/block_policies.dart';
import '../model/doc_selection.dart';
import '../model/document.dart';

/// Schema-dependent behavior supplied by the controller at apply time.
///
/// Ops are pure caller data (ids, offsets, text, keys, blocks) and carry no
/// configuration — a half-configured op is unrepresentable. Everything an op
/// needs from the schema arrives through this context.
class EditContext {
  const EditContext({
    required this.defaultBlockType,
    required this.splitPolicyOf,
    required this.backspaceAtStartOf,
    required this.newBlockMetadataOf,
    required this.policies,
    required this.isVoid,
  });

  /// The block type for new blocks (schema.defaultBlockType).
  final String defaultBlockType;

  /// What Enter does for a block type.
  final SplitPolicy Function(String blockType) splitPolicyOf;

  /// What backspace at offset 0 does for a text block type.
  final BackspaceAtStartPolicy Function(String blockType) backspaceAtStartOf;

  /// Metadata for the new block created by splitting a block of this type
  /// (e.g. taskItem → `{TaskItemKeys.checked: false}`). Null = empty map.
  final Map<String, dynamic> Function(TextBlock splitBlock)? Function(
    String blockType,
  )
  newBlockMetadataOf;

  /// Structural policies by block type.
  final Map<String, BlockPolicies> policies;

  /// Whether a block type is void (no editable text).
  final bool Function(String blockType) isVoid;

  /// The shared indent gate (G13) — used by BOTH the controller's
  /// all-or-nothing group gate and `IndentBlock.apply`, so gate-pass implies
  /// op-applies by construction.
  ///
  /// [member] is the block being indented, [resolvedTarget] its would-be
  /// parent (the previous sibling), [newDepth] the depth it would land at.
  bool canIndent(TextBlock member, TextBlock resolvedTarget, int newDepth) {
    final memberPolicy = policies[member.blockType] ?? const BlockPolicies();
    if (!memberPolicy.canBeChild) return false;
    final targetPolicy =
        policies[resolvedTarget.blockType] ?? const BlockPolicies();
    if (!targetPolicy.canHaveChildren) return false;
    final maxDepth = memberPolicy.maxDepth;
    if (maxDepth != null && newDepth > maxDepth) return false;
    return true;
  }
}

/// The result of applying a batch of operations.
sealed class EditResult {
  const EditResult();
}

/// Every op applied; the batch was committed.
class EditApplied extends EditResult {
  const EditApplied();
}

/// An op failed to apply (gone id, out-of-bounds offset, or failed gate).
/// The whole batch was rejected pre-commit; the document is unchanged.
class EditRejected extends EditResult {
  const EditRejected(this.rejectedOp);

  final EditOperation rejectedOp;

  @override
  String toString() => 'EditRejected($rejectedOp)';
}

/// A single atomic edit to the document.
///
/// Ops address blocks by [String] id, never by flat index — each op resolves
/// its own id against the document it receives (`doc.idToFlatIndex`, O(1)) at
/// apply time, never earlier, so an op mid-batch always sees the document the
/// previous op produced (resolve-at-apply).
///
/// [apply] returns the new document, or **null to reject**: a gone id, an
/// out-of-bounds offset, or a failed structural gate. The controller's batch
/// loop aborts the whole batch pre-commit on the first null — never a partial
/// document, never a silent wrong block.
sealed class EditOperation {
  Document? apply(Document doc, EditContext ctx);
}

/// Insert [text] into the block [blockId] at [offset].
///
/// If [styles] is provided, the inserted text gets those styles explicitly
/// (from the controller's active styles). If null, inherits from the
/// segment at the insertion point.
class InsertText extends EditOperation {
  InsertText(
    this.blockId,
    this.offset,
    this.text, {
    this.styles,
    this.attributes,
  });

  final String blockId;
  final int offset;
  final String text;
  final Set<Object>? styles;

  /// Attributes for data-carrying styles (e.g. `{'url': '...'}` for links).
  final Map<String, dynamic>? attributes;

  @override
  Document? apply(Document doc, EditContext ctx) {
    final index = doc.idToFlatIndex[blockId];
    if (index == null) return null;
    final block = doc.allBlocks[index];
    assert(
      !ctx.isVoid(block.blockType),
      'Text ops must not address void blocks ($blockId is ${block.blockType})',
    );
    if (offset < 0 || offset > block.length) return null;
    final newSegments = _spliceInsert(
      block.segments,
      offset,
      text,
      styles: styles,
      attributes: attributes,
    );
    final newBlock = block.copyWith(segments: mergeSegments(newSegments));
    return doc.replaceBlock(index, newBlock);
  }

  @override
  String toString() => 'InsertText($blockId, offset: $offset, "$text")';
}

/// Delete [length] characters from block [blockId] starting at [offset].
class DeleteText extends EditOperation {
  DeleteText(this.blockId, this.offset, this.length);

  final String blockId;
  final int offset;
  final int length;

  @override
  Document? apply(Document doc, EditContext ctx) {
    final index = doc.idToFlatIndex[blockId];
    if (index == null) return null;
    final block = doc.allBlocks[index];
    assert(
      !ctx.isVoid(block.blockType),
      'Text ops must not address void blocks ($blockId is ${block.blockType})',
    );
    if (offset < 0 || length < 0 || offset + length > block.length) return null;
    final newSegments = _spliceDelete(block.segments, offset, length);
    final newBlock = block.copyWith(segments: mergeSegments(newSegments));
    return doc.replaceBlock(index, newBlock);
  }

  @override
  String toString() => 'DeleteText($blockId, offset: $offset, len: $length)';
}

/// Toggle [style] on the range [start]..[end] in block [blockId].
///
/// If the entire range already has the style, remove it.
/// Otherwise, apply it to the entire range.
class ToggleStyle extends EditOperation {
  ToggleStyle(
    this.blockId,
    this.start,
    this.end,
    this.style, {
    this.attributes,
  });

  final String blockId;
  final int start;
  final int end;
  final Object style;

  /// Attributes to set when applying a data-carrying style (e.g. link URL).
  /// Ignored when removing a style.
  final Map<String, dynamic>? attributes;

  @override
  Document? apply(Document doc, EditContext ctx) {
    final index = doc.idToFlatIndex[blockId];
    if (index == null) return null;
    final block = doc.allBlocks[index];
    assert(
      !ctx.isVoid(block.blockType),
      'Text ops must not address void blocks ($blockId is ${block.blockType})',
    );
    if (start < 0 || end < start || end > block.length) return null;
    final segments = block.segments;

    // Expand segments into per-character style sets and attribute maps.
    final charStyles = <Set<Object>>[];
    final charAttrs = <Map<String, dynamic>>[];
    for (final seg in segments) {
      for (var i = 0; i < seg.text.length; i++) {
        charStyles.add(Set.of(seg.styles));
        charAttrs.add(Map.of(seg.attributes));
      }
    }

    // Check if the entire range already has the style.
    final allHaveStyle = charStyles
        .skip(start)
        .take(end - start)
        .every((s) => s.contains(style));

    // Toggle: remove if all have it, add if any don't.
    for (var i = start; i < end; i++) {
      if (allHaveStyle) {
        charStyles[i].remove(style);
        // Clear attributes from data-carrying styles when removing.
        if (attributes != null) {
          for (final key in attributes!.keys) {
            charAttrs[i].remove(key);
          }
        }
      } else {
        charStyles[i].add(style);
        // Set attributes when adding a data-carrying style.
        if (attributes != null) {
          charAttrs[i].addAll(attributes!);
        }
      }
    }

    // Rebuild segments from per-character styles + attributes.
    final plainText = block.plainText;
    final newSegments = <StyledSegment>[];
    for (var i = 0; i < plainText.length; i++) {
      newSegments.add(StyledSegment(plainText[i], charStyles[i], charAttrs[i]));
    }

    final newBlock = block.copyWith(segments: mergeSegments(newSegments));
    return doc.replaceBlock(index, newBlock);
  }

  @override
  String toString() => 'ToggleStyle($blockId, $start..$end, $style)';
}

/// Split block [blockId] at [offset], creating a new block after it.
///
/// This is what happens when the user presses Enter. The new block's type
/// comes from `ctx.splitPolicyOf(type).newBlockType` (inherit for list
/// items, the schema default otherwise) and its metadata from the type's
/// `newBlockMetadata` policy (taskItem → unchecked). The policy's
/// `onSplitEmpty` half is the controller's concern, consulted before an op
/// is chosen — this op always splits.
class SplitBlock extends EditOperation {
  SplitBlock(this.blockId, this.offset);

  final String blockId;
  final int offset;

  @override
  Document? apply(Document doc, EditContext ctx) {
    final index = doc.idToFlatIndex[blockId];
    if (index == null) return null;
    final block = doc.allBlocks[index];
    assert(
      !ctx.isVoid(block.blockType),
      'SplitBlock must not address void blocks ($blockId is ${block.blockType})',
    );
    if (offset < 0 || offset > block.length) return null;

    final newBlockType =
        ctx.splitPolicyOf(block.blockType).newBlockType ==
            SplitNewBlockType.inherit
        ? block.blockType
        : ctx.defaultBlockType;

    // Split at start of a non-empty block: insert an empty line BEFORE the
    // current block. The current block keeps its type, content, and children.
    // For empty blocks (e.g. divider rule creating a trailing paragraph),
    // fall through to the normal split which inserts after.
    if (offset == 0 && block.plainText.isNotEmpty) {
      final emptyBlock = TextBlock(
        id: generateBlockId(),
        blockType: newBlockType,
      );
      return doc.insertBeforeFlatIndex(index, emptyBlock);
    }

    final (beforeSegments, afterSegments) = splitSegmentsAt(
      block.segments,
      offset,
    );

    final newMetadata =
        ctx.newBlockMetadataOf(block.blockType)?.call(block) ??
        const <String, dynamic>{};

    final updatedBlock = block.copyWith(
      segments: mergeSegments(beforeSegments),
    );
    final newBlock = TextBlock(
      id: generateBlockId(),
      blockType: newBlockType,
      segments: mergeSegments(afterSegments),
      metadata: newMetadata,
    );

    // Insert the new block as a sibling after the split block in the tree.
    var result = doc.replaceBlock(index, updatedBlock);
    result = result.insertAfterFlatIndex(index, newBlock);
    return result;
  }

  @override
  String toString() => 'SplitBlock($blockId, offset: $offset)';
}

/// Merge block [blockId] into the block before it (in flat document order).
///
/// This is what happens when the user presses Backspace at the start of a
/// block whose `backspaceAtStart` policy is `merge`. The merge target is
/// resolved internally from the document at apply time.
class MergeBlocks extends EditOperation {
  MergeBlocks(this.blockId);

  final String blockId;

  @override
  Document? apply(Document doc, EditContext ctx) {
    final index = doc.idToFlatIndex[blockId];
    if (index == null) return null;
    if (index == 0) return null; // Nothing before the first block.

    final first = doc.allBlocks[index - 1];
    final second = doc.allBlocks[index];
    assert(
      !ctx.isVoid(first.blockType) && !ctx.isVoid(second.blockType),
      'MergeBlocks must not involve void blocks (handle via voidBackspace)',
    );

    final mergedSegments = mergeSegments([
      ...first.segments,
      ...second.segments,
    ]);
    // If the first block is empty, adopt the second block's type so that
    // forward-delete on an empty paragraph doesn't strip the heading/list
    // type of the block below.
    final mergedType = first.plainText.isEmpty
        ? second.blockType
        : first.blockType;
    final mergedBlock = first.copyWith(
      blockType: mergedType,
      segments: mergedSegments,
    );

    var result = doc.replaceBlock(index - 1, mergedBlock);
    // Promote the second block's children before removing it, so they
    // become siblings at the level where the second block was.
    result = result.removeBlockPromoteChildren(index);
    return result;
  }

  @override
  String toString() => 'MergeBlocks($blockId)';
}

/// Change the block type of block [blockId] to [newType].
class ChangeBlockType extends EditOperation {
  ChangeBlockType(this.blockId, this.newType);

  final String blockId;
  final String newType;

  @override
  Document? apply(Document doc, EditContext ctx) {
    final index = doc.idToFlatIndex[blockId];
    if (index == null) return null;

    // Policy: if the new type can't be a child and the block is nested, reject.
    final newPolicy = ctx.policies[newType];
    if (newPolicy != null && !newPolicy.canBeChild && doc.depthOf(index) > 0) {
      return null;
    }

    final block = doc.allBlocks[index];
    if (block.blockType == newType) return doc;

    var result = doc;

    // If the new type can't have children, outdent existing children first.
    if (newPolicy != null &&
        !newPolicy.canHaveChildren &&
        block.children.isNotEmpty) {
      // Outdent children in reverse order so earlier outdents don't reshape
      // the subtree under later ones.
      for (var i = block.children.length; i > 0; i--) {
        final next = OutdentBlock(block.children[i - 1].id).apply(result, ctx);
        if (next == null) return null;
        result = next;
      }
    }

    // Re-resolve the block after potential outdenting.
    final updatedIndex = result.idToFlatIndex[block.id];
    if (updatedIndex == null) return null;
    final updatedBlock = result.allBlocks[updatedIndex];

    // Clear metadata when changing type — stale metadata from the old type
    // (e.g. task 'checked' state) shouldn't carry over.
    return result.replaceBlock(
      updatedIndex,
      updatedBlock.copyWith(blockType: newType, metadata: const {}),
    );
  }

  @override
  String toString() => 'ChangeBlockType($blockId, $newType)';
}

/// Delete a range of text that may span multiple blocks.
///
/// Endpoints are document positions; their order is resolved internally
/// against the document at apply time. If the range is within a single
/// block, behaves like [DeleteText]. If cross-block: truncates the start
/// block, removes middle blocks entirely, truncates the end block, and
/// merges the remaining end text into the start block.
///
/// Void endpoints are forbidden — the controller's range-op builder snaps
/// void endpoints (remove-whole via [RemoveBlock], no text merge) before
/// emitting this op.
class DeleteRange extends EditOperation {
  DeleteRange(this.start, this.end);

  final DocPosition start;
  final DocPosition end;

  @override
  Document? apply(Document doc, EditContext ctx) {
    final aIndex = doc.idToFlatIndex[start.blockId];
    final bIndex = doc.idToFlatIndex[end.blockId];
    if (aIndex == null || bIndex == null) return null;

    // Resolve document order internally.
    final aFirst =
        aIndex < bIndex || (aIndex == bIndex && start.offset <= end.offset);
    final (startIndex, startOffset) = aFirst
        ? (aIndex, start.offset)
        : (bIndex, end.offset);
    final (endIndex, endOffset) = aFirst
        ? (bIndex, end.offset)
        : (aIndex, start.offset);

    final flat = doc.allBlocks;
    final startBlock = flat[startIndex];
    final endBlock = flat[endIndex];
    assert(
      !ctx.isVoid(startBlock.blockType) && !ctx.isVoid(endBlock.blockType),
      'DeleteRange endpoints must be text blocks — the range-op builder '
      'snaps void endpoints before emitting (architecture §void-endpoint '
      'normalization)',
    );
    if (startOffset < 0 || startOffset > startBlock.length) return null;
    if (endOffset < 0 || endOffset > endBlock.length) return null;

    // Same block — just delete within it.
    if (startIndex == endIndex) {
      final length = endOffset - startOffset;
      if (length < 0) return null;
      if (length == 0) return doc;
      return DeleteText(startBlock.id, startOffset, length).apply(doc, ctx);
    }

    // Cross-block delete.
    // 1. Truncate start block: keep text before startOffset.
    final (startSegs, _) = splitSegmentsAt(startBlock.segments, startOffset);

    // 2. Truncate end block: keep text after endOffset.
    final (_, endSegs) = splitSegmentsAt(endBlock.segments, endOffset);

    // 3. Merge remaining: start block's head + end block's tail.
    final mergedSegments = mergeSegments([...startSegs, ...endSegs]);
    final mergedBlock = startBlock.copyWith(segments: mergedSegments);

    // 4. Apply: replace start block, then remove end block and all middle
    //    blocks. Use removeBlockPromoteChildren so that children of deleted
    //    blocks (that were outside the selection range) are promoted instead
    //    of lost. Remove from high index to low so earlier removals don't
    //    shift the positions of the blocks still to be removed.
    var result = doc.replaceBlock(startIndex, mergedBlock);
    for (var i = endIndex; i > startIndex; i--) {
      if (i < result.allBlocks.length) {
        result = result.removeBlockPromoteChildren(i);
      }
    }

    return result;
  }

  @override
  String toString() => 'DeleteRange($start → $end)';
}

/// Remove a block (and its subtree) entirely from the document.
///
/// Used for deleting void blocks (e.g. divider, image) where merging makes
/// no sense. Removing the last remaining block swaps in a single empty
/// default-type paragraph (G9 — the "document never empty" invariant holds,
/// and select-all + delete on an all-void document yields one empty
/// paragraph).
class RemoveBlock extends EditOperation {
  RemoveBlock(this.blockId);

  final String blockId;

  @override
  Document? apply(Document doc, EditContext ctx) {
    final index = doc.idToFlatIndex[blockId];
    if (index == null) return null;
    final result = doc.removeBlock(index);
    if (result.blocks.isEmpty) {
      return Document.empty(ctx.defaultBlockType);
    }
    return result;
  }

  @override
  String toString() => 'RemoveBlock($blockId)';
}

/// Insert [blocks] as siblings after block [afterBlockId], in order.
///
/// Insertion is id-chained: each block is placed after the previously
/// inserted block's id, resolved against the evolving document.
class InsertBlocks extends EditOperation {
  InsertBlocks(this.afterBlockId, this.blocks);

  final String afterBlockId;
  final List<TextBlock> blocks;

  @override
  Document? apply(Document doc, EditContext ctx) {
    if (blocks.isEmpty) return doc;
    var result = doc;
    var anchorId = afterBlockId;
    for (final block in blocks) {
      final anchorIndex = result.idToFlatIndex[anchorId];
      if (anchorIndex == null) return null;
      result = result.insertAfterFlatIndex(anchorIndex, block);
      anchorId = block.id;
    }
    return result;
  }

  @override
  String toString() =>
      'InsertBlocks(after: $afterBlockId, ${blocks.length} blocks)';
}

/// Paste one or more blocks at [blockId]:[offset].
///
/// Single-block paste: merges the pasted block's segments into the target
/// block at the given offset, preserving styles and attributes.
///
/// Multi-block paste: splits the target block at the offset, merges the
/// first pasted block into the first half, inserts middle blocks as
/// id-chained siblings at the target's depth, and merges the last pasted
/// block with the second half.
///
/// Void edges are never merged (architecture §PasteBlocks): a void
/// first/last pasted block is inserted whole, metadata preserved. The last
/// pasted block keeps its id through the tail merge, so the caller can place
/// the post-paste caret by an id it already holds.
class PasteBlocks extends EditOperation {
  PasteBlocks(this.blockId, this.offset, this.blocks);

  final String blockId;
  final int offset;
  final List<TextBlock> blocks;

  @override
  Document? apply(Document doc, EditContext ctx) {
    if (blocks.isEmpty) return doc;
    final index = doc.idToFlatIndex[blockId];
    if (index == null) return null;
    final target = doc.allBlocks[index];
    assert(
      !ctx.isVoid(target.blockType),
      'PasteBlocks must not target void blocks ($blockId is ${target.blockType})',
    );
    if (offset < 0 || offset > target.length) return null;

    if (blocks.length == 1 && !ctx.isVoid(blocks.first.blockType)) {
      return _applySingleBlock(doc, index, target);
    }

    return _applyMultiBlock(doc, ctx, target);
  }

  Document _applySingleBlock(Document doc, int index, TextBlock target) {
    final pasted = blocks[0];
    final (before, after) = splitSegmentsAt(target.segments, offset);
    final merged = mergeSegments([...before, ...pasted.segments, ...after]);
    // If pasting at offset 0 and the target is empty, adopt the pasted
    // block's type so that pasting "- item" creates a list item, not a
    // paragraph with "item" text.
    final useType = offset == 0 && target.plainText.isEmpty
        ? pasted.blockType
        : target.blockType;
    return doc.replaceBlock(
      index,
      target.copyWith(blockType: useType, segments: merged),
    );
  }

  Document? _applyMultiBlock(Document doc, EditContext ctx, TextBlock target) {
    // 1. Split target into head (before offset) and tail (after offset).
    final (headSegs, tailSegs) = splitSegmentsAt(target.segments, offset);

    final firstPasted = blocks.first;
    final lastPasted = blocks.last;
    final firstIsVoid = ctx.isVoid(firstPasted.blockType);
    final lastIsVoid = ctx.isVoid(lastPasted.blockType);
    final headAndTailDistinct = blocks.length > 1;

    // 2. Head edge. A text first block merges into the target's head; a void
    //    first block is never merged — it inserts whole after the head.
    final TextBlock headBlock;
    if (firstIsVoid) {
      headBlock = target.copyWith(segments: mergeSegments(headSegs));
    } else {
      final headType = offset == 0 ? firstPasted.blockType : target.blockType;
      headBlock = target.copyWith(
        blockType: headType,
        segments: mergeSegments([...headSegs, ...firstPasted.segments]),
        children: firstPasted.children.isNotEmpty
            ? firstPasted.children
            : target.children,
      );
    }

    // 3. Tail edge. A text last block absorbs the target's tail and keeps
    //    its own id; a void last block is inserted whole and the tail text
    //    becomes a fresh block of the target's type after it.
    final TextBlock tailBlock;
    if (lastIsVoid || !headAndTailDistinct) {
      tailBlock = TextBlock(
        id: generateBlockId(),
        blockType: target.blockType,
        segments: mergeSegments(tailSegs),
      );
    } else {
      tailBlock = lastPasted.copyWith(
        segments: mergeSegments([...lastPasted.segments, ...tailSegs]),
      );
    }

    // 4. The id-chained sibling sequence after the head:
    //    [first if void] + middles + [last if void or same as first] + tail.
    final toInsert = <TextBlock>[
      if (firstIsVoid) firstPasted,
      if (blocks.length > 2) ...blocks.sublist(1, blocks.length - 1),
      if (headAndTailDistinct && lastIsVoid) lastPasted,
      tailBlock,
    ];

    // 5. Replace target with head, then chain-insert each block after the
    //    previous inserted block's id, resolved against the evolving doc —
    //    siblings land at the target's depth regardless of nesting.
    var result = doc.replaceBlock(doc.idToFlatIndex[target.id]!, headBlock);
    var anchorId = headBlock.id;
    for (final block in toInsert) {
      final anchorIndex = result.idToFlatIndex[anchorId];
      if (anchorIndex == null) return null;
      result = result.insertAfterFlatIndex(anchorIndex, block);
      anchorId = block.id;
    }
    return result;
  }

  @override
  String toString() =>
      'PasteBlocks($blockId, offset: $offset, ${blocks.length} blocks)';
}

/// Set a metadata field on block [blockId].
///
/// Used for toggling task checked state, etc.
class SetMetadata extends EditOperation {
  SetMetadata(this.blockId, this.key, this.value);

  final String blockId;
  final String key;
  final dynamic value;

  @override
  Document? apply(Document doc, EditContext ctx) {
    final index = doc.idToFlatIndex[blockId];
    if (index == null) return null;
    final block = doc.allBlocks[index];
    final newMeta = Map<String, dynamic>.of(block.metadata);
    newMeta[key] = value;
    return doc.replaceBlock(index, block.copyWith(metadata: newMeta));
  }

  @override
  String toString() => 'SetMetadata($blockId, $key: $value)';
}

/// Indent block [blockId]: make it the last child of its previous sibling.
///
/// The G13 gate (`ctx.canIndent` — the same predicate the controller's
/// all-or-nothing group gate uses) is evaluated here; failure rejects the
/// whole batch rather than silently no-oping, so a consumer batch can never
/// reproduce the silent-re-parent trap.
class IndentBlock extends EditOperation {
  IndentBlock(this.blockId);

  final String blockId;

  @override
  Document? apply(Document doc, EditContext ctx) {
    final index = doc.idToFlatIndex[blockId];
    if (index == null) return null;
    final prevSibling = doc.previousSibling(index);
    if (prevSibling == null) return null; // No previous sibling — gate fails.

    final block = doc.allBlocks[index];
    final newDepth = doc.depthOf(index) + 1;
    if (!ctx.canIndent(block, prevSibling, newDepth)) return null;

    // Remove block from current position, then add as last child of the
    // previous sibling.
    var result = doc.removeBlockByFlatIndex(index);
    final prevIndex = result.idToFlatIndex[prevSibling.id];
    if (prevIndex == null) return null;
    result = result.addChild(prevIndex, block);
    return result;
  }

  @override
  String toString() => 'IndentBlock($blockId)';
}

/// Outdent block [blockId]: move it from its parent's children to be a
/// sibling after its parent.
///
/// Root-depth blocks reject (the symmetric G13 gate) rather than silently
/// no-oping, so a mixed-depth Shift-Tab group can never partially apply.
///
/// When the block has subsequent siblings, those siblings become children
/// of the outdented block (standard behavior matching Notion / Google Docs).
/// This preserves visual ordering: the outdented block appears right after
/// its former parent, and its former later siblings stay below it.
class OutdentBlock extends EditOperation {
  OutdentBlock(this.blockId);

  final String blockId;

  @override
  Document? apply(Document doc, EditContext ctx) {
    final index = doc.idToFlatIndex[blockId];
    if (index == null) return null;
    final parent = doc.parentOf(index);
    if (parent == null) return null; // Already at root — gate fails.

    final block = doc.allBlocks[index];
    final sibIdx = doc.siblingIndex(index);
    final siblings = parent.children;

    // Collect subsequent siblings (they'll become children of the
    // outdented block to preserve visual order).
    final subsequentSiblings = siblings.sublist(sibIdx + 1);

    // Build the outdented block with its existing children + adopted siblings.
    final updatedBlock = block.copyWith(
      children: [...block.children, ...subsequentSiblings],
    );

    // Remove the block and all subsequent siblings from the parent.
    final trimmedChildren = siblings.sublist(0, sibIdx);
    final parentIndex = doc.idToFlatIndex[parent.id];
    if (parentIndex == null) return null;
    final updatedParent = parent.copyWith(children: trimmedChildren);
    var result = doc.replaceBlockByFlatIndex(parentIndex, updatedParent);

    // Insert the outdented block as a sibling after the (now trimmed) parent.
    final newParentIndex = result.idToFlatIndex[parent.id];
    if (newParentIndex == null) return null;
    result = result.insertAfterFlatIndex(newParentIndex, updatedBlock);
    return result;
  }

  @override
  String toString() => 'OutdentBlock($blockId)';
}

/// Direction for [MoveBlock].
enum MoveDirection { up, down }

/// Move block [blockId] (with its subtree intact) one position up or down
/// among its siblings.
///
/// Launch boundary policy (recorded decision): movement is within the
/// current parent only — moving a first sibling up or a last sibling down is
/// a no-op (not a rejection: a boundary hit must not abort an Alt+↑ batch).
/// Cross-parent hoisting rides the post-launch drag-reorder work.
class MoveBlock extends EditOperation {
  MoveBlock(this.blockId, this.direction);

  final String blockId;
  final MoveDirection direction;

  @override
  Document? apply(Document doc, EditContext ctx) {
    final index = doc.idToFlatIndex[blockId];
    if (index == null) return null;

    final sibIdx = doc.siblingIndex(index);
    final parent = doc.parentOf(index);
    final siblings = parent?.children ?? doc.blocks;

    final targetIdx = direction == MoveDirection.up ? sibIdx - 1 : sibIdx + 1;
    if (targetIdx < 0 || targetIdx >= siblings.length) {
      return doc; // Boundary no-op.
    }

    final reordered = List<TextBlock>.of(siblings);
    final block = reordered.removeAt(sibIdx);
    reordered.insert(targetIdx, block);

    if (parent == null) {
      return Document(reordered);
    }
    final parentIndex = doc.idToFlatIndex[parent.id]!;
    return doc.replaceBlockByFlatIndex(
      parentIndex,
      parent.copyWith(children: reordered),
    );
  }

  @override
  String toString() => 'MoveBlock($blockId, $direction)';
}

// --- Helpers ---

/// Insert [text] at [offset] in [segments].
///
/// If [styles] is provided, the new text gets those styles explicitly.
/// If null, inherits from the segment at the insertion point.
/// [attributes] is passed through for data-carrying styles.
List<StyledSegment> _spliceInsert(
  List<StyledSegment> segments,
  int offset,
  String text, {
  Set<Object>? styles,
  Map<String, dynamic>? attributes,
}) {
  if (segments.isEmpty) {
    return [StyledSegment(text, styles ?? const {}, attributes ?? const {})];
  }

  final result = <StyledSegment>[];
  var pos = 0;
  var inserted = false;

  for (final seg in segments) {
    final segStart = pos;
    final segEnd = pos + seg.text.length;

    if (!inserted && offset <= segEnd) {
      final localOffset = offset - segStart;
      final before = seg.text.substring(0, localOffset);
      final after = seg.text.substring(localOffset);
      final insertStyles = styles ?? seg.styles;
      final insertAttrs =
          attributes ??
          (styles != null ? const <String, dynamic>{} : seg.attributes);
      if (before.isNotEmpty) {
        result.add(StyledSegment(before, seg.styles, seg.attributes));
      }
      result.add(StyledSegment(text, insertStyles, insertAttrs));
      if (after.isNotEmpty) {
        result.add(StyledSegment(after, seg.styles, seg.attributes));
      }
      inserted = true;
    } else {
      result.add(seg);
    }

    pos = segEnd;
  }

  if (!inserted) {
    result.add(
      StyledSegment(
        text,
        styles ?? segments.last.styles,
        attributes ?? const {},
      ),
    );
  }

  return result;
}

/// Delete [length] characters starting at [offset] from segments,
/// preserving styles on remaining text.
List<StyledSegment> _spliceDelete(
  List<StyledSegment> segments,
  int offset,
  int length,
) {
  final result = <StyledSegment>[];
  var pos = 0;
  final deleteStart = offset;
  final deleteEnd = offset + length;

  for (final seg in segments) {
    final segStart = pos;
    final segEnd = pos + seg.text.length;

    if (segEnd <= deleteStart || segStart >= deleteEnd) {
      // Entirely outside the delete range — keep as-is.
      result.add(seg);
    } else {
      // Partially or fully inside the delete range.
      final keepBefore = seg.text.substring(
        0,
        (deleteStart - segStart).clamp(0, seg.text.length),
      );
      final keepAfter = seg.text.substring(
        (deleteEnd - segStart).clamp(0, seg.text.length),
      );
      if (keepBefore.isNotEmpty) {
        result.add(StyledSegment(keepBefore, seg.styles, seg.attributes));
      }
      if (keepAfter.isNotEmpty) {
        result.add(StyledSegment(keepAfter, seg.styles, seg.attributes));
      }
    }

    pos = segEnd;
  }

  return result;
}

/// Split segment list at [offset], returning both halves.
///
/// Returns a record `(before, after)` where `before` contains segments
/// up to [offset] and `after` contains segments from [offset] onward.
(List<StyledSegment>, List<StyledSegment>) splitSegmentsAt(
  List<StyledSegment> segments,
  int offset,
) {
  var pos = 0;
  final before = <StyledSegment>[];
  final after = <StyledSegment>[];

  for (final seg in segments) {
    final segStart = pos;
    final segEnd = pos + seg.text.length;

    if (segEnd <= offset) {
      before.add(seg);
    } else if (segStart >= offset) {
      after.add(seg);
    } else {
      // Split point is inside this segment.
      final splitAt = offset - segStart;
      before.add(
        StyledSegment(
          seg.text.substring(0, splitAt),
          seg.styles,
          seg.attributes,
        ),
      );
      after.add(
        StyledSegment(seg.text.substring(splitAt), seg.styles, seg.attributes),
      );
    }

    pos = segEnd;
  }

  return (before, after);
}
