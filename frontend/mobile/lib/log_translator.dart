// Translation layer: maps raw controller/sub-manager status strings to plain-
// language equivalents shown when Detailed Logging is disabled in Settings.
// Returns null to suppress a line entirely.
//
// Matched by substring — cheaper than regex and each raw line has a unique
// enough prefix. The raw string is always stored in the screen's _rawLog
// regardless, so nothing is ever discarded.

String? translateLog(String raw) {
  // ── Always suppress ────────────────────────────────────────────────────────
  if (_has(raw, 'rssi=') && _has(raw, 'recorded')) return null;
  if (_has(raw, 'Re-testing Wi-Fi Direct initiator capability')) return null;
  if (_has(raw, 'Wi-Fi station not associated')) return null;
  if (_has(raw, 'Wi-Fi Direct initiation works again')) return null;
  if (_has(raw, 'Sent to the nearby helper. Back to wait mode.')) return null;
  if (_has(raw, 'Will retry Wi-Fi Direct handoff')) return null;
  if (_has(raw, 'Unexpected-connection pull returned nothing')) return null;
  if (_has(raw, 'Will retry GATT ACK')) return null;
  if (_has(raw, 'transmitted (pull mode)')) return null;
  if (_has(raw, 'Wi-Fi Direct stack reset')) return null;
  if (_has(raw, 'Location permission:') && !_has(raw, 'not granted')) return null;
  if (_has(raw, 'Location permission after request:')) return null;
  if (_has(raw, 'GPS live fix:') || _has(raw, 'GPS last known fix:')) return null;

  // ── BLE sub-manager: suppress all internal protocol details ───────────────
  // These fire on every scan/connect/discover cycle; the controller emits
  // higher-level equivalents for anything user-visible.
  if (_has(raw, 'BLE advertising started')) return null;
  if (_has(raw, 'BLE advertising stopped')) return null;
  if (_has(raw, 'BLE advertising failed')) return null;
  if (_has(raw, 'BLE scanning started')) return null;
  if (_has(raw, 'BLE scanning stopped')) return null;
  if (_has(raw, 'BLE scan failed')) return null;
  if (_has(raw, 'GATT ACK received from')) return null;
  if (_has(raw, 'for GATT ACK')) return null;
  if (_has(raw, 'discovering services')) return null;
  if (_has(raw, 'service(s) on')) return null;
  if (_has(raw, 'SUAR service')) return null;
  if (_has(raw, 'Status characteristic')) return null;
  if (_has(raw, 'Status read failed')) return null;
  if (_has(raw, 'ACK characteristic')) return null;
  if (_has(raw, 'GATT ACK written to')) return null;
  if (_has(raw, 'GATT write failed')) return null;
  if (_has(raw, 'Stop advertising failed')) return null;
  if (_has(raw, 'Stop scan failed')) return null;
  if (_has(raw, 'setNeedsPull failed')) return null;
  if (_has(raw, 'setRole failed')) return null;
  if (_has(raw, 'setAssociated failed')) return null;

  // ── Wi-Fi Direct sub-manager + native debugLog: suppress technical details ─
  // Includes emitDebug() strings from WifiDirectHelper.kt sent as debugLog
  // events, and internal WiFiDirectManager Dart _emit() calls.
  if (_has(raw, 'Wi-Fi Direct P2P state changed')) return null;
  if (_has(raw, 'Wi-Fi Direct peers-changed broadcast received')) return null;
  if (_has(raw, 'Wi-Fi Direct connection formed:')) return null;
  if (_has(raw, 'WiFi state: staEnabled')) return null;
  if (_has(raw, 'Wi-Fi Direct P2P enabled (last known)')) return null;
  if (_has(raw, 'Wi-Fi Direct peer(s)')) return null;
  if (_has(raw, 'Wi-Fi Direct connected:')) return null;
  if (_has(raw, 'Peer discovery failed')) return null;
  if (raw.startsWith('Connecting to ')) return null;
  if (_has(raw, 'Wi-Fi Direct connect failed')) return null;
  if (_has(raw, 'Could not pair with the peer in time')) return null;
  if (_has(raw, 'Bundle received over Wi-Fi Direct')) return null;
  if (_has(raw, 'A nearby device fetched the cached bundle')) return null;
  if (_has(raw, 'Bundle sent over Wi-Fi Direct')) return null;
  if (_has(raw, 'Bundle send failed')) return null;
  if (_has(raw, 'Pulled bundle over Wi-Fi Direct')) return null;
  if (_has(raw, 'Bundle pull failed')) return null;
  if (_has(raw, 'Wi-Fi Direct server listening')) return null;
  if (_has(raw, 'Start server failed')) return null;
  if (_has(raw, 'Wi-Fi Direct server stopped')) return null;
  if (_has(raw, 'Wi-Fi Direct disconnected')) return null;
  if (_has(raw, 'Disconnect failed')) return null;
  if (_has(raw, 'Now an autonomous Wi-Fi Direct group owner')) return null;
  if (_has(raw, 'createGroup failed')) return null;
  if (_has(raw, 'isServerRunning check failed')) return null;
  if (_has(raw, 'setManifest failed')) return null;
  if (_has(raw, 'setLocalBundle failed')) return null;
  if (_has(raw, 'setRelayBundles failed')) return null;
  if (_has(raw, 'Manifest request failed')) return null;
  if (_has(raw, 'setP2pDeviceName failed')) return null;
  if (_has(raw, 'Sync failed:')) return null;

  // ── DTN sub-manager: suppress internal relay bookkeeping ──────────────────
  if (_has(raw, 'already seen, skipping')) return null;
  if (_has(raw, 'stored for relay')) return null;
  if (_has(raw, 'Sync response from') && _has(raw, 'malformed')) return null;
  if (_has(raw, 'already have the same bundles')) return null;
  if (_has(raw, 'TTL exceeded:')) return null;

  // ── Startup ────────────────────────────────────────────────────────────────
  if (_has(raw, 'Victim mode started')) return 'Victim mode started. Broadcasting distress signal.';
  if (_has(raw, 'Helper mode started')) return 'Helper mode started. Scanning for people who need help.';
  if (_has(raw, 'Victim mode stopped')) return 'Victim mode stopped.';
  if (_has(raw, 'Helper mode stopped')) return 'Helper mode stopped.';
  if (_has(raw, 'Victim mode start failed')) return 'Victim mode failed to start. Please restart the app.';
  if (_has(raw, 'Victim mode stop failed')) return 'Victim mode failed to stop. Please restart the app.';
  if (_has(raw, 'Helper mode start failed')) return 'Helper mode failed to start. Please restart the app.';
  if (_has(raw, 'Helper mode stop failed')) return 'Helper mode failed to stop. Please restart the app.';

  // ── Sensors ────────────────────────────────────────────────────────────────
  if (_has(raw, 'Location tracking started')) return 'GPS location tracking started.';
  if (_has(raw, 'Location unavailable')) return 'GPS not available. Your position will be estimated.';
  if (_has(raw, 'Sensor triage started') && _has(raw, 'microphone enabled')) {
    return 'Health monitoring started. Microphone active.';
  }
  if (_has(raw, 'Sensor triage started') && _has(raw, 'microphone unavailable')) {
    return 'Health monitoring started. Microphone not available. Using other sensors.';
  }
  if (_has(raw, 'Sensor triage failed to start')) return 'Health monitoring failed to start.';
  if (raw.startsWith('Triage updated:')) {
    final rest = raw.substring('Triage updated:'.length).trimLeft();
    final tier = rest.split(' ').first;
    if (tier == 'None') return null;
    return 'Triage updated: $tier.';
  }

  // ── Searching (Victim) ─────────────────────────────────────────────────────
  if (_has(raw, 'No Helper ACKs received')) return 'No helpers detected nearby. Still searching…';
  if (raw.startsWith('Selected Helper')) return 'Helper detected nearby. Attempting to connect…';

  // ── Helper scanning for victims ────────────────────────────────────────────
  if (_has(raw, 'Victim beacon detected')) return 'Detected a person who needs help nearby.';

  // ── Connecting / Sending (Victim) ──────────────────────────────────────────
  if (_has(raw, 'Sensors still initializing')) return 'Sensors still starting up. Holding until ready…';
  if (_has(raw, 'Waiting for a Helper to pull the bundle')) {
    return 'Waiting for a nearby helper to collect your information…';
  }
  if (_has(raw, 'Connection formed (pull mode)')) {
    return 'Sending your information to a nearby helper…';
  }
  if (_has(raw, 'Connected as group owner instead')) {
    return 'Connected. Waiting for helper to collect your information…';
  }
  if (raw.startsWith('Bundle') && _has(raw, 'transmitted to')) {
    return 'Your information was sent to a nearby helper.';
  }
  if (raw.startsWith('Bundle transmission failed')) {
    return 'Failed to send your information. Will retry.';
  }

  // ── Wi-Fi interference / capability (Victim) ───────────────────────────────
  if (_has(raw, 'WARNING: this device is connected to Wi-Fi')) {
    final match = RegExp(r'"([^"]+)"').firstMatch(raw);
    final ssid = match?.group(1) ?? 'a Wi-Fi network';
    return 'Warning: this phone is connected to Wi-Fi "$ssid". This may affect nearby connections.';
  }
  if (_has(raw, 'Learned this device cannot initiate Wi-Fi Direct') ||
      (_has(raw, 'cannot initiate Wi-Fi Direct discovery') &&
          _has(raw, 'switching to pull mode'))) {
    return 'This phone cannot reach helpers directly. Waiting for helpers to connect instead.';
  }
  if (_has(raw, 'A nearby helper is on Wi-Fi and will host')) {
    return 'Nearby helper is hosting the connection. Sending your information…';
  }
  if (_has(raw, 'No nearby helper completed the transfer')) {
    return 'Transfer did not complete. Waiting for helpers again…';
  }
  if (_has(raw, 'Nearby helpers keep checking in but nothing was picked up')) {
    return 'Helpers are nearby but not connecting. Refreshing the connection…';
  }

  // ── Delivery confirmation (already plain — keep verbatim) ──────────────────
  if (_has(raw, 'A nearby helper picked up your information')) return raw;
  if (_has(raw, 'Another nearby helper picked up your information')) return raw;

  // ── Backend sync ───────────────────────────────────────────────────────────
  if (_has(raw, 'Pushed your bundle to the backend')) {
    return 'Your information reached the emergency dashboard.';
  }
  if (raw.startsWith('Synced') && _has(raw, 'bundle') && _has(raw, 'backend')) {
    final m = RegExp(r'Synced (\d+)').firstMatch(raw);
    final n = m?.group(1) ?? '?';
    return "Sent $n person(s)' information to the emergency dashboard.";
  }
  if (raw.startsWith('Pulled') && _has(raw, 'bundle') && _has(raw, 'backend')) {
    final m = RegExp(r'Pulled (\d+)').firstMatch(raw);
    final n = m?.group(1) ?? '?';
    return 'Downloaded $n update(s) from the emergency system.';
  }

  // ── Watchdog ───────────────────────────────────────────────────────────────
  if (_has(raw, 'BLE advertising found stopped unexpectedly') ||
      _has(raw, 'Wi-Fi Direct server found stopped unexpectedly') ||
      _has(raw, 'BLE scan found stopped unexpectedly')) {
    return 'A background service stopped. Restarting automatically…';
  }

  // ── Helper: loading stored bundles ─────────────────────────────────────────
  if (raw.startsWith('Loaded') && _has(raw, 'bundle') && _has(raw, 'storage')) {
    final m = RegExp(r'Loaded (\d+)').firstMatch(raw);
    final n = m?.group(1) ?? '?';
    return "Loaded $n person(s)' information from previous session.";
  }

  // ── Helper: finding victims ────────────────────────────────────────────────
  if (_has(raw, 'Giving up on GATT ACK')) {
    return 'Lost contact with a nearby device. Will retry when seen again.';
  }
  if (_has(raw, 'Connection formed unexpectedly')) {
    return 'Unexpected connection detected. Collecting information…';
  }

  // ── Helper: pulling from victims ───────────────────────────────────────────
  if (_has(raw, 'cannot self-initiate Wi-Fi Direct')) {
    return 'Connecting to a nearby person who needs help…';
  }
  if (_has(raw, 'No Wi-Fi Direct peers discovered while connecting')) {
    return 'Could not reach the nearby person. Will retry.';
  }
  if (_has(raw, 'both ended up as hosts')) {
    return 'Connection failed. Both devices are hosting. Will retry.';
  }
  if (_has(raw, 'Still cannot finish the nearby transfer')) return raw;
  if (_has(raw, 'Pull from') && _has(raw, 'returned nothing')) {
    return 'Reached nearby person but received nothing. Will retry.';
  }
  if (_has(raw, 'On Wi-Fi, so hosting the nearby connection')) {
    return 'Waiting for nearby person to send their information…';
  }
  if (_has(raw, 'Could not start hosting')) return 'Failed to set up connection. Will retry.';

  // ── Helper: receiving ──────────────────────────────────────────────────────
  if (raw.startsWith('Bundle received:')) {
    return 'Received information from a person who needs help.';
  }
  if (raw.startsWith('Failed to process received bundle')) {
    return 'Failed to read received information. Will retry.';
  }

  // ── Helper: DTN relay ──────────────────────────────────────────────────────
  if (_has(raw, 'Elected Wi-Fi Direct group owner for relay') ||
      _has(raw, 'Found peer Helper') ||
      _has(raw, 'attempting DTN relay')) {
    return 'Connecting to another helper to share information…';
  }
  if (_has(raw, 'createGroup failed for relay') ||
      _has(raw, 'No Wi-Fi Direct peers discovered while relaying')) {
    return 'Could not reach nearby helper. Will retry.';
  }
  if (_has(raw, 'Connected to') && _has(raw, 'as group owner') && _has(raw, 'relay')) {
    return 'Waiting for nearby helper to sync…';
  }
  if (raw.startsWith('Relayed') && _has(raw, 'bundle(s) to')) {
    final m = RegExp(r'Relayed (\d+)').firstMatch(raw);
    final n = m?.group(1) ?? '?';
    return "Shared $n person(s)' information with a nearby helper.";
  }
  if (raw.startsWith('Pulled') && _has(raw, 'bundle(s) from')) {
    final m = RegExp(r'Pulled (\d+)').firstMatch(raw);
    final n = m?.group(1) ?? '?';
    return "Received $n person(s)' information from a nearby helper.";
  }
  if (_has(raw, 'Sync with') && _has(raw, 'failed')) {
    return 'Could not sync with a nearby helper. Will retry.';
  }

  // ── "Could not connect" appears in both pull + relay — generic fallback ────
  if (_has(raw, 'Could not connect to Wi-Fi Direct peer')) {
    return 'Could not reach nearby device. Will retry.';
  }

  // ── Generic "No Wi-Fi Direct peers" fallback ───────────────────────────────
  if (_has(raw, 'No Wi-Fi Direct peers discovered')) {
    return 'Could not locate nearby device. Will retry.';
  }

  // ── Helper: Wi-Fi recovery ─────────────────────────────────────────────────
  if (_has(raw, 'Wi-Fi Direct stuck after') && _has(raw, 'resetting')) {
    return 'Connection issues detected. Resetting automatically. Will retry.';
  }

  // ── GPS lines from helper screen ───────────────────────────────────────────
  if (_has(raw, 'Location permission not granted')) {
    return 'GPS location permission denied. Map will not show your position.';
  }
  if (_has(raw, 'Location services (GPS) are off')) {
    return 'GPS is turned off. Turn it on for the map to show your position.';
  }
  if (raw.startsWith('GPS stream error') || raw.startsWith('GPS fix failed')) {
    return 'GPS error. Location tracking may be unavailable.';
  }

  // ── Pass through anything not matched ──────────────────────────────────────
  return raw;
}

bool _has(String s, String sub) => s.contains(sub);
