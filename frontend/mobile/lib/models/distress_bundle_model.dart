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
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
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
      'BundleId': bundleId,
      'DeviceId': deviceId,
      'PriorityScore': priorityScore,
      'PriorityTier': priorityTier,
      'EstimatedLat': estimatedLat,
      'EstimatedLng': estimatedLng,
      'AccuracyMeters': accuracyMeters,
      'EstimatedAltitude': estimatedAltitude,
      'HopCount': hopCount,
      'IsSynced': isSynced ? 1 : 0,
      'CreatedAt': createdAt.toIso8601String(),
      'UpdatedAt': updatedAt.toIso8601String(),
      'Flags': flags.join(','),
    };
  }

  factory DistressBundleModel.fromMap(Map<String, dynamic> map) {
    return DistressBundleModel(
      bundleId: map['BundleId'] as String,
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
      flags: (map['Flags'] as String?)
              ?.split(',')
              .where((s) => s.isNotEmpty)
              .toList() ??
          const [],
    );
  }
}
