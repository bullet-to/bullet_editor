import 'package:flutter/widgets.dart';

import '../model/document.dart';
import 'edit_operation.dart';

/// A transaction is one logical edit: a list of operations + the desired
/// selection state after the edit is applied.
///
/// The controller creates a transaction from a TextField diff, runs it
/// through input rules (which may transform it), then applies it to the
/// document.
class Transaction {
  Transaction({required this.operations, this.selectionAfter});

  final List<EditOperation> operations;

  /// The TextField selection to restore after this transaction is applied.
  /// If null, the controller keeps the current selection.
  final TextSelection? selectionAfter;

  /// Apply all operations sequentially to [doc], returning the new document.
  /// Generic on [B] so the document's block type parameter is preserved.
  Document<B> apply<B>(Document<B> doc) {
    var result = doc;
    for (final op in operations) {
      result = op.apply(result);
    }
    return result;
  }

  @override
  String toString() =>
      'Transaction(${operations.length} ops, selection: $selectionAfter)';
}
