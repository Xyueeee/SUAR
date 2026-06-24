/// Catalogue of sensors shown on the Device Test page (4.1.6), grouped into the
/// three Figma cards. This is the diagnostic view — broader than the four
/// triage sensors (see [TriageSensor]). Each entry knows its display label,
/// unit, and how it is read so the UI stays declarative.
library;

enum SensorCategory { motion, environment, connectivity }

extension SensorCategoryMeta on SensorCategory {
  String get title => switch (this) {
        SensorCategory.motion => 'Motion',
        SensorCategory.environment => 'Environment',
        SensorCategory.connectivity => 'Connectivity',
      };

  String get description => switch (this) {
        SensorCategory.motion =>
          'Motion sensors detect movement, orientation and rotation. '
              'Used for fall detection and immobility.',
        SensorCategory.environment =>
          'Environment sensors detect properties of the surroundings, such '
              'as air pressure, light and sound.',
        SensorCategory.connectivity =>
          'Connectivity lets the device locate itself and reach other devices '
              'in the mesh.',
      };
}

/// How a sensor's live value is obtained — drives which engine path the UI
/// subscribes to when a row is expanded.
enum SensorSource {
  /// accelerometer/gyroscope/magnetometer/barometer — sensors_plus stream.
  sensorsPlus,

  /// proximity/light — native one-shot poll over the suar/sensors channel.
  nativePoll,

  /// microphone — noise_meter dB stream (needs RECORD_AUDIO).
  microphone,

  /// gps/bluetooth/wifi — one-shot enabled/available status, no live value.
  connectivity,
}

enum DeviceSensor {
  // Motion
  accelerometer,
  gyroscope,
  // Environment
  barometer,
  magnetometer,
  proximity,
  light,
  microphone,
  // Connectivity
  gps,
  bluetooth,
  wifi,
}

extension DeviceSensorMeta on DeviceSensor {
  String get label => switch (this) {
        DeviceSensor.accelerometer => 'Accelerometer',
        DeviceSensor.gyroscope => 'Gyroscope',
        DeviceSensor.barometer => 'Barometer',
        DeviceSensor.magnetometer => 'Magnetometer',
        DeviceSensor.proximity => 'Proximity Sensor',
        DeviceSensor.light => 'Ambient Light Sensor',
        DeviceSensor.microphone => 'Microphone',
        DeviceSensor.gps => 'GPS / Location',
        DeviceSensor.bluetooth => 'Bluetooth',
        DeviceSensor.wifi => 'Wi-Fi',
      };

  /// One-line plain-language description shown in gray under the label.
  String get description => switch (this) {
        DeviceSensor.accelerometer =>
          'Measures movement and g-force for fall detection.',
        DeviceSensor.gyroscope => 'Measures how fast the device is rotating.',
        DeviceSensor.barometer => 'Measures air pressure to estimate altitude.',
        DeviceSensor.magnetometer =>
          'Measures the magnetic field for compass heading.',
        DeviceSensor.proximity => 'Detects an object close to the screen.',
        DeviceSensor.light => 'Measures how bright the surroundings are.',
        DeviceSensor.microphone => 'Measures ambient sound level (no recording).',
        DeviceSensor.gps => 'Provides location when satellites are visible.',
        DeviceSensor.bluetooth => 'Discovers nearby devices for the BLE mesh.',
        DeviceSensor.wifi => 'Carries bundle transfers over Wi-Fi Direct.',
      };

  String get unit => switch (this) {
        DeviceSensor.accelerometer => 'm/s²',
        DeviceSensor.gyroscope => 'rad/s',
        DeviceSensor.barometer => 'hPa',
        DeviceSensor.magnetometer => 'µT',
        DeviceSensor.proximity => 'cm',
        DeviceSensor.light => 'lx',
        DeviceSensor.microphone => 'dB',
        DeviceSensor.gps || DeviceSensor.bluetooth || DeviceSensor.wifi => '',
      };

  SensorCategory get category => switch (this) {
        DeviceSensor.accelerometer || DeviceSensor.gyroscope =>
          SensorCategory.motion,
        DeviceSensor.barometer ||
        DeviceSensor.magnetometer ||
        DeviceSensor.proximity ||
        DeviceSensor.light ||
        DeviceSensor.microphone =>
          SensorCategory.environment,
        DeviceSensor.gps || DeviceSensor.bluetooth || DeviceSensor.wifi =>
          SensorCategory.connectivity,
      };

  SensorSource get source => switch (this) {
        DeviceSensor.accelerometer ||
        DeviceSensor.gyroscope ||
        DeviceSensor.barometer ||
        DeviceSensor.magnetometer =>
          SensorSource.sensorsPlus,
        DeviceSensor.proximity || DeviceSensor.light => SensorSource.nativePoll,
        DeviceSensor.microphone => SensorSource.microphone,
        DeviceSensor.gps || DeviceSensor.bluetooth || DeviceSensor.wifi =>
          SensorSource.connectivity,
      };

  /// Native availability/poll key (suar/sensors channel), or null for sensors
  /// not backed by SensorManager.
  String? get nativeKey => switch (this) {
        DeviceSensor.accelerometer => 'accelerometer',
        DeviceSensor.gyroscope => 'gyroscope',
        DeviceSensor.barometer => 'barometer',
        DeviceSensor.magnetometer => 'magnetometer',
        DeviceSensor.proximity => 'proximity',
        DeviceSensor.light => 'light',
        _ => null,
      };
}
