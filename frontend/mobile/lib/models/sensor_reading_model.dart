import 'package:uuid/uuid.dart';

/// The four triage sensor identifiers. These are the ONLY values the Supabase
/// `SensorReading.SensorType` CHECK constraint accepts (CLAUDE.md §14), so the
/// model below stores one of these as a plain String to mirror the schema 1:1.
/// The Device Test page displays more sensors (gyroscope, proximity, …) but
/// those are diagnostic-only and never persisted as SensorReadings.
class TriageSensor {
  TriageSensor._();
  static const String accelerometer = 'accelerometer';
  static const String barometer = 'barometer';
  static const String microphone = 'microphone';
  static const String battery = 'battery';

  static const List<String> all = [accelerometer, barometer, microphone, battery];
}

/// A single normalised sensor sample attached to a [DistressBundleModel].
/// Mirrors the SensorReading entity (ERD Chapter 4.4 / Supabase schema §14).
class SensorReadingModel {
  final String readingId;
  final String bundleId;

  /// One of [TriageSensor.all].
  final String sensorType;

  /// The raw physical reading (units depend on [sensorType]: m/s² magnitude,
  /// hPa, dB, battery %).
  final double rawValue;

  /// Risk contribution in 0..1, as produced by the triage normaliser.
  final double normalisedValue;
  final DateTime recordedAt;

  SensorReadingModel({
    String? readingId,
    required this.bundleId,
    required this.sensorType,
    required this.rawValue,
    required this.normalisedValue,
    DateTime? recordedAt,
  })  : readingId = readingId ?? const Uuid().v4(),
        recordedAt = recordedAt ?? DateTime.now();

  /// camelCase — rides inside the bundle JSON over the mesh
  /// ([DistressBundleModel.sensorReadings]).
  Map<String, dynamic> toJson() => {
        'readingId': readingId,
        'bundleId': bundleId,
        'sensorType': sensorType,
        'rawValue': rawValue,
        'normalisedValue': normalisedValue,
        // UTC on the wire, same policy as DistressBundleModel.toJson — the
        // backend treats an offset-less timestamp as UTC, so a local one
        // would be stored shifted.
        'recordedAt': recordedAt.toUtc().toIso8601String(),
      };

  factory SensorReadingModel.fromJson(Map<String, dynamic> json) =>
      SensorReadingModel(
        readingId: json['readingId'] as String?,
        bundleId: json['bundleId'] as String,
        sensorType: json['sensorType'] as String,
        rawValue: (json['rawValue'] as num).toDouble(),
        normalisedValue: (json['normalisedValue'] as num).toDouble(),
        recordedAt: json['recordedAt'] != null
            ? DateTime.parse(json['recordedAt'] as String)
            : null,
      );

  /// PascalCase — matches the SQLite SensorReading columns (schema v2).
  Map<String, Object?> toMap() => {
        'SensorReadingId': readingId,
        'DistressBundleId': bundleId,
        'SensorType': sensorType,
        'RawValue': rawValue,
        'NormalisedValue': normalisedValue,
        // UTC in SQLite, same mixed-format reasoning as
        // DistressBundleModel.toMap.
        'RecordedAt': recordedAt.toUtc().toIso8601String(),
      };

  factory SensorReadingModel.fromMap(Map<String, dynamic> map) =>
      SensorReadingModel(
        readingId: map['SensorReadingId'] as String?,
        bundleId: map['DistressBundleId'] as String,
        sensorType: map['SensorType'] as String,
        rawValue: (map['RawValue'] as num).toDouble(),
        normalisedValue: (map['NormalisedValue'] as num).toDouble(),
        recordedAt: DateTime.parse(map['RecordedAt'] as String),
      );
}
