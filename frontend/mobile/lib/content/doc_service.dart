/// Network + offline cache for the unified content docs. One entry point
/// (DocService): seed once, opportunistically refresh from `GET /docs`, always
/// return the cache. Progress (per-user fill state) persists per doc.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../constants.dart';
import '../storage/sqlite_repository.dart';
import 'doc_models.dart';

const String _seededPrefKey = 'suar_docs_seeded';

class DocApi {
  Future<String?> _baseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final u = prefs.getString(backendSyncUrlPrefKey)?.trim();
    if (u == null || u.isEmpty) return null;
    return u.endsWith('/') ? u.substring(0, u.length - 1) : u;
  }

  /// All published docs. Null on any failure → caller keeps the cache.
  Future<List<Map<String, dynamic>>?> fetchDocs() => _getList('/appdocs');
  Future<List<Map<String, dynamic>>?> fetchNotices() => _getList('/notices');

  Future<List<Map<String, dynamic>>?> _getList(String path) async {
    final base = await _baseUrl();
    if (base == null) return null;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse('$base$path'));
      req.headers.set('ngrok-skip-browser-warning', 'true'); // avoid ngrok HTML interstitial
      final resp = await req.close().timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! List) return null;
      return decoded.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

class DocRepository {
  final SQLiteRepository _sql;
  DocRepository([SQLiteRepository? sql]) : _sql = sql ?? SQLiteRepository();
  Future<Database> get _db => _sql.database;

  /// Replaces cached docs PER CATEGORY: only categories present in [rows] are
  /// cleared + rewritten. Categories the server didn't return keep their cache
  /// / bundled seed, so publishing one category never wipes the others.
  Future<void> replaceDocs(List<Map<String, dynamic>> rows) async {
    final db = await _db;
    final batch = db.batch();
    for (final cat in rows.map((r) => (r['category'] ?? '').toString()).toSet()) {
      batch.delete('AppDoc', where: 'Category = ?', whereArgs: [cat]);
    }
    for (final r in rows) {
      batch.insert('AppDoc', {
        'AppDocId': r['app_doc_id'].toString(),
        'Category': (r['category'] ?? '').toString(),
        'Title': (r['title'] ?? '').toString(),
        'Version': (r['version'] as num?)?.toInt() ?? 1,
        'StructureJson':
            r['structure'] is String ? r['structure'] : jsonEncode(r['structure'] ?? {}),
        'OrderIndex': (r['order_index'] as num?)?.toInt() ?? 0,
        'UsePercent': (r['use_percent'] == true) ? 1 : 0,
        'UpdatedAt': (r['updated_at'] ?? '').toString(),
      });
    }
    await batch.commit(noResult: true);
  }

  Future<List<Doc>> getDocs(String category) async {
    final db = await _db;
    final rows = await db.query('AppDoc',
        where: 'Category = ?', whereArgs: [category], orderBy: 'OrderIndex ASC, UpdatedAt DESC');
    return rows
        .map((m) => Doc.fromRow(
              docId: m['AppDocId'] as String,
              category: m['Category'] as String,
              title: m['Title'] as String,
              version: m['Version'] as int,
              updatedAt: (m['UpdatedAt'] as String?) ?? '',
              structure: m['StructureJson'] as String,
              usePercent: (m['UsePercent'] as int? ?? 0) != 0,
            ))
        .toList();
  }

  Future<Map<String, String>> getProgress(String docId) async {
    final db = await _db;
    final rows = await db.query('DocProgress',
        columns: ['Path', 'Value'], where: 'AppDocId = ?', whereArgs: [docId]);
    return {for (final r in rows) r['Path'] as String: r['Value'] as String};
  }

  Future<void> setProgress(String docId, String path, String value) async {
    final db = await _db;
    if (value.isEmpty) {
      await db.delete('DocProgress', where: 'AppDocId = ? AND Path = ?', whereArgs: [docId, path]);
      return;
    }
    await db.insert(
      'DocProgress',
      {'AppDocId': docId, 'Path': path, 'Value': value, 'UpdatedAt': DateTime.now().toIso8601String()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> ensureSeeded() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_seededPrefKey) == true) return;
    try {
      final raw = await rootBundle.loadString('assets/seed/docs.json');
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      if (list.isNotEmpty) await replaceDocs(list);
    } catch (_) {/* missing/bad seed shouldn't block */}
    await prefs.setBool(_seededPrefKey, true);
  }
}

class DocService {
  final DocApi _api;
  final DocRepository _repo;
  DocService({DocApi? api, DocRepository? repo})
      : _api = api ?? DocApi(),
        _repo = repo ?? DocRepository();

  DocRepository get repo => _repo;

  Future<List<Doc>> loadDocs(String category) async {
    await _repo.ensureSeeded();
    final fresh = await _api.fetchDocs();
    // Only replace when the server actually has docs — a reachable-but-empty
    // backend must not wipe the bundled seed / last good cache.
    if (fresh != null && fresh.isNotEmpty) await _repo.replaceDocs(fresh);
    return _repo.getDocs(category);
  }

  // _v2: the 2026-07-06 schema rename changed the row keys (notice_id,
  // created_at, ...). Bumping the key orphans any cache written with the old
  // keys instead of rendering it with missing ids/dates until first refresh.
  static const _noticesKey = 'suar_notices_cache_v2';

  /// Active admin notices. Refreshes from the backend when online, caches to
  /// prefs, and serves the cache offline.
  Future<List<Map<String, dynamic>>> loadNotices() async {
    final prefs = await SharedPreferences.getInstance();
    final fresh = await _api.fetchNotices();
    if (fresh != null) await prefs.setString(_noticesKey, jsonEncode(fresh));
    final raw = prefs.getString(_noticesKey);
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
  }

  static const _seenKey = 'suar_seen_notices';

  Future<Set<String>> seenNoticeIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_seenKey) ?? const []).toSet();
  }

  Future<void> markNoticesSeen(Iterable<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    final set = (prefs.getStringList(_seenKey) ?? <String>[]).toSet()..addAll(ids);
    await prefs.setStringList(_seenKey, set.toList());
  }

  // Separate from "seen": tracks which notices already fired an OS notification,
  // so warning/critical alerts don't re-fire on every refresh.
  static const _notifiedKey = 'suar_notified_notices';

  Future<Set<String>> notifiedNoticeIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_notifiedKey) ?? const []).toSet();
  }

  Future<void> markNoticesNotified(Iterable<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    final set = (prefs.getStringList(_notifiedKey) ?? <String>[]).toSet()..addAll(ids);
    await prefs.setStringList(_notifiedKey, set.toList());
  }
}
