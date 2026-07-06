import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/distress_bundle_model.dart';
import '../models/sensor_reading_model.dart';

class SQLiteRepository {
  static const String _dbName = 'suar_local.db';
  // v2: added the SensorReading table. v3: added DistressBundle.Flags.
  // v4: added DistressBundle.AccuracyMeters (GPS ± radius).
  // v5: added DistressBundle.EstimatedAltitude (GPS altitude).
  // v6: added Guide + PrepPlanT (admin content caches, JSON blobs) and
  //     PrepProgress (per-user prep fill-state). Queried by ContentRepository.
  // v7: added Guide.Section (groups guides into sections, e.g. Basic/Advanced).
  // v8: added AppDoc + DocProgress — the unified content/prep model (one tree
  //     per doc). Supersedes Guide/PrepPlanT/PrepProgress (kept but unused).
  // v9: added AppDoc.OrderIndex — admin-controlled display order.
  // v10: added AppDoc.UsePercent — % card flag moved from structure JSON to DB column.
  // v11: dropped the dead Guide/PrepPlanT/PrepProgress tables (superseded by
  //      AppDoc/DocProgress in v8; nothing has read or written them since).
  // v12: renamed PKs to match their table (BundleId -> DistressBundleId,
  //      ReadingId -> SensorReadingId, DocId -> AppDocId), mirroring the
  //      cloud schema's <table>_id convention. Rebuild + copy per table, not
  //      RENAME COLUMN — minSdk 24 ships SQLite 3.9, RENAME COLUMN needs 3.25.
  static const int _dbVersion = 12;

  Database? _db;

  static const String _createDistressBundle = '''
    CREATE TABLE IF NOT EXISTS DistressBundle (
      DistressBundleId TEXT PRIMARY KEY,
      DeviceId TEXT NOT NULL,
      PriorityScore REAL NOT NULL,
      PriorityTier TEXT NOT NULL,
      EstimatedLat REAL,
      EstimatedLng REAL,
      AccuracyMeters REAL,
      EstimatedAltitude REAL,
      HopCount INTEGER NOT NULL DEFAULT 0,
      IsSynced INTEGER NOT NULL DEFAULT 0,
      CreatedAt TEXT NOT NULL,
      UpdatedAt TEXT NOT NULL,
      Flags TEXT
    )
  ''';

  // No FK clause — mirrors DistressBundle's local-store style; the bundleId
  // link is enforced cloud-side in Supabase, not on-device.
  static const String _createSensorReading = '''
    CREATE TABLE IF NOT EXISTS SensorReading (
      SensorReadingId TEXT PRIMARY KEY,
      DistressBundleId TEXT NOT NULL,
      SensorType TEXT NOT NULL,
      RawValue REAL NOT NULL,
      NormalisedValue REAL NOT NULL,
      RecordedAt TEXT NOT NULL
    )
  ''';

  // Unified content/prep cache (one tree-JSON blob per doc, verbatim in a TEXT
  // column — the tree shape lives inside the blob, not as normalised columns)
  // + per-user fill state keyed by positional node path.
  static const String _createAppDoc = '''
    CREATE TABLE IF NOT EXISTS AppDoc (
      AppDocId TEXT PRIMARY KEY,
      Category TEXT NOT NULL,
      Title TEXT NOT NULL,
      Version INTEGER NOT NULL DEFAULT 1,
      StructureJson TEXT NOT NULL,
      OrderIndex INTEGER NOT NULL DEFAULT 0,
      UsePercent INTEGER NOT NULL DEFAULT 0,
      UpdatedAt TEXT
    )
  ''';

  static const String _createDocProgress = '''
    CREATE TABLE IF NOT EXISTS DocProgress (
      AppDocId TEXT NOT NULL,
      Path TEXT NOT NULL,
      Value TEXT NOT NULL,
      UpdatedAt TEXT,
      PRIMARY KEY (AppDocId, Path)
    )
  ''';

  Future<Database> _getDb() async {
    final existing = _db;
    if (existing != null) return existing;
    final dbPath = join(await getDatabasesPath(), _dbName);
    final opened = await openDatabase(
      dbPath,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute(_createDistressBundle);
        await db.execute(_createSensorReading);
        await db.execute(_createAppDoc);
        await db.execute(_createDocProgress);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(_createSensorReading);
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE DistressBundle ADD COLUMN Flags TEXT');
        }
        if (oldVersion < 4) {
          await db.execute(
            'ALTER TABLE DistressBundle ADD COLUMN AccuracyMeters REAL',
          );
        }
        if (oldVersion < 5) {
          await db.execute(
            'ALTER TABLE DistressBundle ADD COLUMN EstimatedAltitude REAL',
          );
        }
        // v6 (create Guide/PrepPlanT/PrepProgress) and v7 (Guide.Section) are
        // intentionally no longer replayed — those tables are dropped at v11
        // below, so creating them on the way up would be pointless churn.
        if (oldVersion < 8) {
          await db.execute(_createAppDoc);
          await db.execute(_createDocProgress);
        }
        if (oldVersion >= 8 && oldVersion < 9) {
          await db.execute('ALTER TABLE AppDoc ADD COLUMN OrderIndex INTEGER NOT NULL DEFAULT 0');
        }
        // Covers v8 too: a v8 device jumping straight to v10 never runs the
        // v9 step, so gate on the full range the column was absent for (v8+v9),
        // not just v9. OrderIndex above stays ==8 because v9 tables already have it.
        if (oldVersion >= 8 && oldVersion < 10) {
          await db.execute('ALTER TABLE AppDoc ADD COLUMN UsePercent INTEGER NOT NULL DEFAULT 0');
        }
        if (oldVersion < 11) {
          // Dead since v8's AppDoc/DocProgress unification — reclaim the space.
          await db.execute('DROP TABLE IF EXISTS Guide');
          await db.execute('DROP TABLE IF EXISTS PrepPlanT');
          await db.execute('DROP TABLE IF EXISTS PrepProgress');
        }
        if (oldVersion < 12) {
          // PK renames (see the version-history note above). Each table is
          // rebuilt under its own name and the rows copied across. Tables
          // that an EARLIER block in this same upgrade run just created
          // already have the new column names, so only rebuild the ones that
          // actually predate this run (the oldVersion gates).
          Future<void> rebuild(String table, String createSql,
              String newCols, String oldCols) async {
            await db.execute('ALTER TABLE $table RENAME TO ${table}_v11');
            await db.execute(createSql);
            await db.execute('INSERT INTO $table ($newCols) '
                'SELECT $oldCols FROM ${table}_v11');
            await db.execute('DROP TABLE ${table}_v11');
          }

          await rebuild(
            'DistressBundle',
            _createDistressBundle,
            'DistressBundleId, DeviceId, PriorityScore, PriorityTier, '
                'EstimatedLat, EstimatedLng, AccuracyMeters, EstimatedAltitude, '
                'HopCount, IsSynced, CreatedAt, UpdatedAt, Flags',
            'BundleId, DeviceId, PriorityScore, PriorityTier, '
                'EstimatedLat, EstimatedLng, AccuracyMeters, EstimatedAltitude, '
                'HopCount, IsSynced, CreatedAt, UpdatedAt, Flags',
          );
          if (oldVersion >= 2) {
            await rebuild(
              'SensorReading',
              _createSensorReading,
              'SensorReadingId, DistressBundleId, SensorType, RawValue, '
                  'NormalisedValue, RecordedAt',
              'ReadingId, BundleId, SensorType, RawValue, '
                  'NormalisedValue, RecordedAt',
            );
          }
          if (oldVersion >= 8) {
            await rebuild(
              'AppDoc',
              _createAppDoc,
              'AppDocId, Category, Title, Version, StructureJson, '
                  'OrderIndex, UsePercent, UpdatedAt',
              'DocId, Category, Title, Version, StructureJson, '
                  'OrderIndex, UsePercent, UpdatedAt',
            );
            await rebuild(
              'DocProgress',
              _createDocProgress,
              'AppDocId, Path, Value, UpdatedAt',
              'DocId, Path, Value, UpdatedAt',
            );
          }
        }
      },
    );
    _db = opened;
    return opened;
  }

  /// Shared database handle. DocRepository uses this instead of opening its
  /// own connection so SQLiteRepository stays the single owner of versioning.
  Future<Database> get database => _getDb();

  /// Saves a bundle and its sensor readings together — wherever a bundle is
  /// persisted, its readings follow, so callers don't have to remember both.
  ///
  /// Timestamp-based conflict resolution (CLAUDE.md §5): a bundle we already
  /// have is OVERWRITTEN only when the incoming copy is strictly newer. This is
  /// what lets a re-pull carrying updated triage (same bundleId, newer
  /// UpdatedAt) refresh the stored record — and the map pin — instead of being
  /// silently dropped as a duplicate.
  Future<void> saveBundle(DistressBundleModel bundle) async {
    final db = await _getDb();
    // One transaction: the bundle row and its readings snapshot land (or
    // don't) together — a crash between the readings delete and re-insert
    // otherwise left a bundle with no readings.
    await db.transaction((txn) async {
      final existing = await txn.query(
        'DistressBundle',
        columns: ['UpdatedAt'],
        where: 'DistressBundleId = ?',
        whereArgs: [bundle.bundleId],
        limit: 1,
      );
      if (existing.isEmpty) {
        await txn.insert('DistressBundle', bundle.toMap());
      } else {
        final existingUpdated =
            DateTime.tryParse(existing.first['UpdatedAt'] as String? ?? '');
        if (existingUpdated != null &&
            !bundle.updatedAt.isAfter(existingUpdated)) {
          return; // stale or identical — keep what we have
        }
        await txn.update(
          'DistressBundle',
          bundle.toMap(),
          where: 'DistressBundleId = ?',
          whereArgs: [bundle.bundleId],
        );
        // Replace the readings snapshot with the newer one.
        await txn.delete('SensorReading',
            where: 'DistressBundleId = ?', whereArgs: [bundle.bundleId]);
      }
      for (final raw in bundle.sensorReadings) {
        // Re-stamp the FK to this bundle in case the transported reading's
        // bundleId drifted; dedup on SensorReadingId.
        final reading = SensorReadingModel.fromJson({
          ...raw,
          'bundleId': bundle.bundleId,
        });
        await txn.insert(
          'SensorReading',
          reading.toMap(),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
  }

  Future<List<SensorReadingModel>> getReadingsForBundle(String bundleId) async {
    final db = await _getDb();
    final rows = await db.query(
      'SensorReading',
      where: 'DistressBundleId = ?',
      whereArgs: [bundleId],
      orderBy: 'RecordedAt',
    );
    return rows.map(SensorReadingModel.fromMap).toList();
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
      where: 'DistressBundleId = ?',
      whereArgs: [bundleId],
    );
  }

  /// Drops a bundle (and its readings) once the backend has it and it's old
  /// enough to no longer matter locally — see SyncService.syncLocalBundles.
  Future<void> deleteBundle(String bundleId) async {
    final db = await _getDb();
    await db.transaction((txn) async {
      await txn.delete('SensorReading', where: 'DistressBundleId = ?', whereArgs: [bundleId]);
      await txn.delete('DistressBundle', where: 'DistressBundleId = ?', whereArgs: [bundleId]);
    });
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
