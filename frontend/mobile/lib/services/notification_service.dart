/// Thin wrapper over flutter_local_notifications for OS notifications:
/// warning/critical notices, danger-zone entry, and background status (map
/// downloads). Two channels — high-importance alerts vs low-importance status.
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _id = 100;

  Future<void> init() async {
    if (_ready) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(const InitializationSettings(android: android));
    final impl = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await impl?.createNotificationChannel(const AndroidNotificationChannel(
      'suar_alerts', 'Alerts',
      description: 'Warnings, danger zones and critical notices',
      importance: Importance.high,
    ));
    await impl?.createNotificationChannel(const AndroidNotificationChannel(
      'suar_status', 'Status',
      description: 'Background status such as map downloads',
      importance: Importance.low,
    ));
    await impl?.requestNotificationsPermission();
    _ready = true;
  }

  /// [high] = alerts channel (heads-up); otherwise the quiet status channel.
  Future<void> show(String title, String body, {bool high = true}) async {
    if (!_ready) await init();
    final ch = high ? 'suar_alerts' : 'suar_status';
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        ch, high ? 'Alerts' : 'Status',
        importance: high ? Importance.high : Importance.low,
        priority: high ? Priority.high : Priority.low,
        styleInformation: BigTextStyleInformation(body),
      ),
    );
    await _plugin.show(_id++, title, body, details);
  }
}
