/// Reactive state for one rendered Doc: the user's fill-state + the live
/// roll-up, persisted to SQLite. Shared by the category page and every drill-in
/// so percentages update everywhere at once.
library;

import 'package:flutter/foundation.dart';

import 'doc_models.dart';
import 'doc_service.dart';

class DocController extends ChangeNotifier {
  final DocRepository repo;
  DocController(this.repo);

  Doc? doc;
  Map<String, String> _values = {};

  Set<String> get _done => _values.keys.toSet();
  DocRollup get rollup => DocRollup(_done);

  Future<void> load(Doc d) async {
    doc = d;
    _values = await repo.getProgress(d.docid);
    notifyListeners();
  }

  bool isChecked(String path) => _values.containsKey(path);
  String valueOf(String path) => _values[path] ?? '';

  double get overallPercent =>
      doc == null ? 0 : rollup.overallPercent(doc!.nodes);

  // Incomplete items grouped under their section, capped; plus the true total
  // so the dashboard can show "…and more".
  List<MapEntry<String, List<String>>> get incompleteGroups =>
      doc == null ? const [] : rollup.incompleteGrouped(doc!.nodes, 6);
  int get incompleteTotal => doc == null ? 0 : rollup.incompleteCount(doc!.nodes);

  Future<void> toggle(String path, bool checked) async {
    if (checked) {
      _values[path] = '1';
    } else {
      _values.remove(path);
    }
    notifyListeners();
    await repo.setProgress(doc!.docid, path, checked ? '1' : '');
  }

  Future<void> setText(String path, String text) async {
    final t = text.trim();
    if (t.isEmpty) {
      _values.remove(path);
    } else {
      _values[path] = t;
    }
    notifyListeners();
    await repo.setProgress(doc!.docid, path, t);
  }
}
