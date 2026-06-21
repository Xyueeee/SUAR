import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/distress_bundle_model.dart';

class SQLiteRepository {
  static const String _dbName = 'suar_local.db';
  static const int _dbVersion = 1;

  Database? _db;

  Future<Database> _getDb() async {
    final existing = _db;
    if (existing != null) return existing;
    final dbPath = join(await getDatabasesPath(), _dbName);
    final opened = await openDatabase(
      dbPath,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS DistressBundle (
            BundleId TEXT PRIMARY KEY,
            DeviceId TEXT NOT NULL,
            PriorityScore REAL NOT NULL,
            PriorityTier TEXT NOT NULL,
            EstimatedLat REAL,
            EstimatedLng REAL,
            HopCount INTEGER NOT NULL DEFAULT 0,
            IsSynced INTEGER NOT NULL DEFAULT 0,
            CreatedAt TEXT NOT NULL,
            UpdatedAt TEXT NOT NULL
          )
        ''');
      },
    );
    _db = opened;
    return opened;
  }

  Future<void> saveBundle(DistressBundleModel bundle) async {
    final db = await _getDb();
    await db.insert(
      'DistressBundle',
      bundle.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<DistressBundleModel>> getAllBundles() async {
    final db = await _getDb();
    final rows = await db.query('DistressBundle', orderBy: 'CreatedAt DESC');
    return rows.map(DistressBundleModel.fromMap).toList();
  }

  Future<List<DistressBundleModel>> getUnsyncedBundles() async {
    final db = await _getDb();
    final rows = await db.query('DistressBundle', where: 'IsSynced = 0');
    return rows.map(DistressBundleModel.fromMap).toList();
  }

  Future<void> markAsSynced(String bundleId) async {
    final db = await _getDb();
    await db.update(
      'DistressBundle',
      {'IsSynced': 1},
      where: 'BundleId = ?',
      whereArgs: [bundleId],
    );
  }

  // --- Debug-only inspection below: backs the Settings > Debugging Options >
  // Local Database screen, so the on-device SQLite store can be viewed and
  // managed without pulling the .db file off the phone.

  Future<List<String>> listTableNames() async {
    final db = await _getDb();
    final rows = await db.query(
      'sqlite_master',
      columns: ['name'],
      where:
          "type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%'",
    );
    return rows.map((r) => r['name'] as String).toList();
  }

  /// rowid is selected alongside the columns so a row can be identified for
  /// deletion regardless of whatever primary key (if any) the table declares.
  Future<List<Map<String, Object?>>> getTableRows(String table) async {
    final db = await _getDb();
    return db.rawQuery(
      'SELECT rowid AS _rowid, * FROM "$table" ORDER BY rowid DESC',
    );
  }

  Future<void> deleteTableRow(String table, int rowid) async {
    final db = await _getDb();
    await db.delete(table, where: 'rowid = ?', whereArgs: [rowid]);
  }

  Future<void> clearTable(String table) async {
    final db = await _getDb();
    await db.delete(table);
  }
}
