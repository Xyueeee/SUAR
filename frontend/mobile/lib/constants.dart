/// Fixed configuration values shared across the SUAR mesh networking layer.
library;

// "SUAR"/"ACK1" aren't valid hex — UUID.fromString (native) and Guid() (Dart)
// both require hex digits only. Kept the visual mnemonic where hex allows it.
const String suarServiceUuid = "0000F00D-0000-1000-8000-00805F9B34FB";
const String suarGattAckCharacteristicUuid =
    "0000FEED-0000-1000-8000-00805F9B34FB";
// Read-only, 2 bytes: [0]=needsPull (non-zero means the advertiser's chipset
// can't reliably initiate Wi-Fi Direct discovery itself, see below), [1]=role
// (bleRoleVictim/bleRoleHelper) — lets a scanning Helper tell, over the same
// brief GATT connection it already opens, whether it just found a distressed
// Victim (do the RSSI-ack handshake) or another Helper (do a DTN relay
// handshake instead) without needing a second connection. See
// BlePeripheralHelper.kt.
const String suarStatusCharacteristicUuid =
    "0000BEEF-0000-1000-8000-00805F9B34FB";

const int bleRoleVictim = 0;
const int bleRoleHelper = 1;

const String wifiDirectChannel = "suar/wifi_direct";
const int wifiDirectPort = 8988;

// flutter_blue_plus only implements the BLE central role (scan + GATT client).
// Victim-side advertising + GATT server requires native Android peripheral APIs.
const String blePeripheralChannel = "suar/ble_peripheral";
const String blePeripheralEventChannel = "suar/ble_peripheral_events";

// NFR targets ≤5s discovery + ≤2s GATT ACK = ~7s worst case; padded for
// first-time BLE connection overhead (no bonding/cache yet) seen in testing.
const int bleRssiCollectionWindowMs = 8000;

// Not currently sent — legacy advertising's 31-byte cap leaves no room for it
// alongside the 128-bit service UUID. Kept in case a future compact encoding
// revives manufacturer-data based deviceId lookup; currently always falls
// back to BLE remoteId (see BLEManager._decodeVictimDeviceId).
const int bleManufacturerId = 0xFFFF;
// A bundle is a few hundred bytes (hop count itself costs 1 int) — the
// storage/bandwidth cost of carrying it further is negligible next to the
// cost of cutting off propagation too early in a real multi-hop disaster
// mesh where the number of hops between a victim and a Helper with
// connectivity is genuinely unpredictable. Raised from 5 — a stricter TTL
// belongs to a deliberate anti-flood tuning decision, not a default.
const int dtnMaxHopCount = 12;

const String deviceIdPrefKey = "suar_device_id";
const String appVersion = "1.0.0";

/// A short, stable 4-character tag derived from a device's UUID — the
/// human-readable suffix in the Wi-Fi Direct name shown on a peer's connection
/// prompt (e.g. "Helper-1A2B"). Hex from the UUID is unique enough to tell two
/// nearby peers apart while revealing nothing identifying about the device.
String deviceNameSuffix(String deviceId) {
  final hex = deviceId.replaceAll(RegExp('[^0-9a-fA-F]'), '');
  final tag = hex.length >= 4 ? hex.substring(0, 4) : hex.padRight(4, '0');
  return tag.toUpperCase();
}
