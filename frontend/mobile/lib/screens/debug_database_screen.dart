import 'package:flutter/material.dart';

import '../storage/sqlite_repository.dart';

/// Settings > Debugging Options > Local Database. Lists the on-device
/// SQLite tables so they can be inspected/cleared without pulling the .db
/// file off the phone — there's no cloud equivalent for this, it's purely a
/// way to see what the app has stored locally.
class DebugDatabaseScreen extends StatefulWidget {
  const DebugDatabaseScreen({super.key});

  @override
  State<DebugDatabaseScreen> createState() => _DebugDatabaseScreenState();
}

class _DebugDatabaseScreenState extends State<DebugDatabaseScreen> {
  final _repository = SQLiteRepository();
  late Future<List<String>> _tablesFuture;

  @override
  void initState() {
    super.initState();
    _tablesFuture = _repository.listTableNames();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        title: const Text('Local Database'),
      ),
      body: FutureBuilder<List<String>>(
        future: _tablesFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final tables = snapshot.data!;
          if (tables.isEmpty) {
            return const Center(
              child: Text(
                'No tables found.',
                style: TextStyle(color: Colors.black54),
              ),
            );
          }
          return ListView.separated(
            itemCount: tables.length,
            separatorBuilder: (context, index) => const Divider(
              color: Colors.black12,
              height: 1,
              indent: 16,
              endIndent: 16,
            ),
            itemBuilder: (context, index) {
              final table = tables[index];
              return ListTile(
                leading: const Icon(
                  Icons.table_chart_outlined,
                  color: Colors.black,
                ),
                title: Text(table, style: const TextStyle(color: Colors.black)),
                trailing: const Icon(
                  Icons.chevron_right,
                  color: Colors.black54,
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DebugTableScreen(tableName: table),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class DebugTableScreen extends StatefulWidget {
  const DebugTableScreen({super.key, required this.tableName});

  final String tableName;

  @override
  State<DebugTableScreen> createState() => _DebugTableScreenState();
}

class _DebugTableScreenState extends State<DebugTableScreen> {
  final _repository = SQLiteRepository();
  late Future<List<Map<String, Object?>>> _rowsFuture;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _rowsFuture = _repository.getTableRows(widget.tableName);
  }

  Future<void> _deleteRow(int rowid) async {
    await _repository.deleteTableRow(widget.tableName, rowid);
    if (!mounted) return;
    setState(_reload);
  }

  Future<void> _clearTable() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Clear "${widget.tableName}"?'),
        content: const Text('This deletes every row in this table.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repository.clearTable(widget.tableName);
    if (!mounted) return;
    setState(_reload);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        title: Text(widget.tableName),
        actions: [
          IconButton(
            onPressed: _clearTable,
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Clear table',
          ),
        ],
      ),
      body: FutureBuilder<List<Map<String, Object?>>>(
        future: _rowsFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = snapshot.data!;
          if (rows.isEmpty) {
            return const Center(
              child: Text('No rows.', style: TextStyle(color: Colors.black54)),
            );
          }
          // _rowid is fetched for deletion but isn't a real column — hide it.
          final columns = rows.first.keys.where((k) => k != '_rowid').toList();
          return Scrollbar(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SingleChildScrollView(
                child: DataTable(
                  columns: [
                    for (final column in columns)
                      DataColumn(label: Text(column)),
                    const DataColumn(label: Text('')),
                  ],
                  rows: [
                    for (final row in rows)
                      DataRow(
                        cells: [
                          for (final column in columns)
                            DataCell(Text('${row[column] ?? ''}')),
                          DataCell(
                            IconButton(
                              icon: const Icon(
                                Icons.delete_outline,
                                size: 18,
                                color: Colors.black54,
                              ),
                              onPressed: () => _deleteRow(row['_rowid'] as int),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
