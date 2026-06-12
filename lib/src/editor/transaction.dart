import '../model/doc_selection.dart';
import '../model/document.dart';
import 'edit_operation.dart';

/// A transaction is one logical edit: a list of operations + the desired
/// selection state after the edit is applied.
///
/// Package-private as surface hygiene — the public escape hatch is
/// `controller.apply(List<EditOperation>)`; a transaction is just the
/// committed batch record.
class Transaction {
  Transaction({required this.operations, this.selectionAfter});

  final List<EditOperation> operations;

  /// The selection to restore after this transaction is applied.
  /// If null, the controller keeps the current selection.
  final DocSelection? selectionAfter;

  /// Apply all operations sequentially to [doc], returning the new document,
  /// or null if any operation rejects (gone id, out-of-bounds offset, failed
  /// gate) — the whole batch aborts, never a partial document.
  Document? apply(Document doc, EditContext ctx) {
    var result = doc;
    for (final op in operations) {
      final next = op.apply(result, ctx);
      if (next == null) return null;
      result = next;
    }
    return result;
  }

  @override
  String toString() =>
      'Transaction(${operations.length} ops, selection: $selectionAfter)';
}
