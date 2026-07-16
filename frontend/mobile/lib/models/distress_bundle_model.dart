/// Client-side mirror of the /sync request bounds in backend/models.py
/// (BundleModel + SensorReadingModel). Keep the two in lockstep, field for
/// field — the backend validates the WHOLE /sync request at once, so a single
/// bundle violating any of these gets every bundle in the batch rejected
/// (HTTP 422). Anything failing this check must never be stored, relayed,
/// or pushed.
bool isPlausibleBundle(DistressBundleModel b) {
  // Optional double: null is fine, a present value must be finite + in range.
  bool inRange(double? v, double min, double max) =>
      v == null || (v.isFinite && v >= min && v <= max);

  // bundleId / deviceId: Field(min_length=1, max_length=256)
  if (b.bundleId.isEmpty ||
      b.bundleId.length > 256 ||
      b.bundleId.contains('\u0000')) {
    return false;
  }
  if (b.deviceId.isEmpty ||
      b.deviceId.length > 256 ||
      b.deviceId.contains('\u0000')) {
    return false;
  }
  // priorityScore: Field(ge=0, le=1, allow_inf_nan=False)
  if (!b.priorityScore.isFinite || b.priorityScore < 0 || b.priorityScore > 1) {
    return false;
  }
  // priorityTier: Literal["Critical", "High", "Moderate", "Low", "None"]
  if (!const {
    'Critical',
    'High',
    'Moderate',
    'Low',
    'None',
  }.contains(b.priorityTier)) {
    return false;
  }
  // estimatedLat: Field(ge=-90, le=90) / estimatedLng: Field(ge=-180, le=180)
  if (!inRange(b.estimatedLat, -90, 90)) return false;
  if (!inRange(b.estimatedLng, -180, 180)) return false;
  // accuracyMeters: Field(ge=0, le=100_000_000)
  if (!inRange(b.accuracyMeters, 0, 100000000)) return false;
  // estimatedAltitude: Field(ge=-1_000_000, le=1_000_000)
  if (!inRange(b.estimatedAltitude, -1000000, 1000000)) return false;
  // hopCount: Field(ge=0, le=1_000_000)
  if (b.hopCount < 0 || b.hopCount > 1000000) return false;
  // Python datetime / PostgreSQL TIMESTAMPTZ support years 1..9999. Dart can
  // represent wider years, which would otherwise 422 the complete request.
  bool backendTimestamp(DateTime value) =>
      value.year >= 1 && value.year <= 9999;
  if (!backendTimestamp(b.createdAt) || !backendTimestamp(b.updatedAt)) {
    return false;
  }
  // sensorReadings: Field(max_length=64)
  if (b.sensorReadings.length > 64) return false;
  for (final r in b.sensorReadings) {
    // Local persistence uses this optional transported ID for deduplication.
    // The backend ignores it, but a wrong type would make SQLite save throw.
    final readingId = r['readingId'];
    if (readingId != null && readingId is! String) return false;
    // sensorType: Literal["accelerometer", "barometer", "microphone", "battery"]
    final type = r['sensorType'];
    if (type is! String ||
        !const {
          'accelerometer',
          'barometer',
          'microphone',
          'battery',
        }.contains(type)) {
      return false;
    }
    // rawValue: Field(ge=-1e15, le=1e15, allow_inf_nan=False)
    final raw = r['rawValue'];
    if (raw is! num || !raw.isFinite || raw < -1e15 || raw > 1e15) {
      return false;
    }
    // normalisedValue: Field(ge=0, le=1, allow_inf_nan=False)
    final norm = r['normalisedValue'];
    if (norm is! num || !norm.isFinite || norm < 0 || norm > 1) return false;
    // recordedAt: datetime (required)
    final recordedAt = r['recordedAt'];
    final parsedAt = recordedAt is String
        ? DateTime.tryParse(recordedAt)
        : null;
    if (parsedAt == null || !backendTimestamp(parsedAt)) {
      return false;
    }
  }
  return true;
}

/// Parses one transported bundle without allowing a malformed item to abort
/// the rest of a relay batch. Returns null for both structural parse failures
/// and values outside the backend's accepted bounds.
DistressBundleModel? tryParsePlausibleBundle(Object? raw) {
  if (raw is! Map) return null;
  try {
    final bundle = DistressBundleModel.fromJson(Map<String, dynamic>.from(raw));
    return isPlausibleBundle(bundle) ? bundle : null;
  } catch (_) {
    return null;
  }
}

/// Best-effort identifier for rejection logs; never trusts the payload shape.
String transportedBundleLabel(Object? raw) {
  if (raw is Map) {
    final id = raw['bundleId'];
    if (id is String && id.isNotEmpty && !id.contains('\u0000')) return id;
  }
  return '<malformed>';
}

class DistressBundleModel {
  final String bundleId;
  final String deviceId;
  double priorityScore;
  String priorityTier;
  double? estimatedLat;
  double? estimatedLng;

  /// GPS-reported ± radius in metres for ([estimatedLat], [estimatedLng]) —
  /// drawn as the uncertainty circle on the Helper map. Null when there's no
  /// fix, or when the chip didn't report a usable accuracy.
  double? accuracyMeters;

  /// GPS altitude in metres — a coarse hint for victims stacked at the same
  /// lat/lng but different floors (collapsed building). Null when unknown.
  double? estimatedAltitude;
  int hopCount;
  bool isSynced;
  final DateTime createdAt;
  DateTime updatedAt;
  List<Map<String, dynamic>> sensorReadings;

  /// Active triage safety flags ([TriageFlag] keys: fall/faint/lowBattery/
  /// criticalBattery) so a Helper can surface them on the victim's detail card.
  List<String> flags;

  DistressBundleModel({
    required this.bundleId,
    required this.deviceId,
    required this.priorityScore,
    required this.priorityTier,
    this.estimatedLat,
    this.estimatedLng,
    this.accuracyMeters,
    this.estimatedAltitude,
    this.hopCount = 0,
    this.isSynced = false,
    required this.createdAt,
    required this.updatedAt,
    this.sensorReadings = const [],
    this.flags = const [],
  });

  Map<String, dynamic> toJson() {
    return {
      'bundleId': bundleId,
      'deviceId': deviceId,
      'priorityScore': priorityScore,
      'priorityTier': priorityTier,
      'estimatedLat': estimatedLat,
      'estimatedLng': estimatedLng,
      'accuracyMeters': accuracyMeters,
      'estimatedAltitude': estimatedAltitude,
      'hopCount': hopCount,
      'isSynced': isSynced,
      // Always UTC on the wire — a local-time string with no offset would be
      // re-interpreted in the RECEIVING device's timezone, skewing the
      // timestamp-based conflict resolution across zones.
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
      'sensorReadings': sensorReadings,
      'flags': flags,
    };
  }

  factory DistressBundleModel.fromJson(Map<String, dynamic> json) {
    return DistressBundleModel(
      bundleId: json['bundleId'] as String,
      deviceId: json['deviceId'] as String,
      priorityScore: (json['priorityScore'] as num).toDouble(),
      priorityTier: json['priorityTier'] as String,
      estimatedLat: (json['estimatedLat'] as num?)?.toDouble(),
      estimatedLng: (json['estimatedLng'] as num?)?.toDouble(),
      accuracyMeters: (json['accuracyMeters'] as num?)?.toDouble(),
      estimatedAltitude: (json['estimatedAltitude'] as num?)?.toDouble(),
      hopCount: json['hopCount'] as int,
      isSynced: json['isSynced'] as bool,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      sensorReadings:
          (json['sensorReadings'] as List?)?.cast<Map<String, dynamic>>() ??
          const [],
      flags: (json['flags'] as List?)?.cast<String>() ?? const [],
    );
  }

  /// sqflite DistressBundle table has no SensorReading column in Increment 1.
  Map<String, dynamic> toMap() {
    return {
      'DistressBundleId': bundleId,
      'DeviceId': deviceId,
      'PriorityScore': priorityScore,
      'PriorityTier': priorityTier,
      'EstimatedLat': estimatedLat,
      'EstimatedLng': estimatedLng,
      'AccuracyMeters': accuracyMeters,
      'EstimatedAltitude': estimatedAltitude,
      'HopCount': hopCount,
      'IsSynced': isSynced ? 1 : 0,
      // UTC in SQLite too: mesh-received bundles parse as UTC DateTimes while
      // own bundles are local — serialising each as-is would mix "…Z" and
      // offset-less strings in one column and break CreatedAt string ordering.
      'CreatedAt': createdAt.toUtc().toIso8601String(),
      'UpdatedAt': updatedAt.toUtc().toIso8601String(),
      'Flags': flags.join(','),
    };
  }

  factory DistressBundleModel.fromMap(Map<String, dynamic> map) {
    return DistressBundleModel(
      bundleId: map['DistressBundleId'] as String,
      deviceId: map['DeviceId'] as String,
      priorityScore: (map['PriorityScore'] as num).toDouble(),
      priorityTier: map['PriorityTier'] as String,
      estimatedLat: (map['EstimatedLat'] as num?)?.toDouble(),
      estimatedLng: (map['EstimatedLng'] as num?)?.toDouble(),
      accuracyMeters: (map['AccuracyMeters'] as num?)?.toDouble(),
      estimatedAltitude: (map['EstimatedAltitude'] as num?)?.toDouble(),
      hopCount: map['HopCount'] as int,
      isSynced: (map['IsSynced'] as int) == 1,
      createdAt: DateTime.parse(map['CreatedAt'] as String),
      updatedAt: DateTime.parse(map['UpdatedAt'] as String),
      flags:
          (map['Flags'] as String?)
              ?.split(',')
              .where((s) => s.isNotEmpty)
              .toList() ??
          const [],
    );
  }
}
