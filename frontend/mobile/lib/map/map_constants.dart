import 'package:latlong2/latlong.dart';

/// OSM's standard tile server. Bulk/offline downloads must stay within its
/// usage policy (https://operations.osmfoundation.org/policies/tiles/) —
/// only explicit, user-initiated region downloads, no automatic bulk caching.
const String osmTileUrlTemplate =
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const String osmUserAgentPackageName = 'com.example.suar_mobile';
const String osmAttribution = '© OpenStreetMap contributors';

const LatLng defaultMapCenter = LatLng(3.1390, 101.6869); // Kuala Lumpur
const double defaultMapZoom = 12.0;
const double minDownloadZoom = 10.0;
const double maxDownloadZoom = 17.0;

// Camera zoom bounds shared by every interactive FlutterMap. Without these,
// flutter_map lets the user pinch out to whole-globe (z0, tiny) and in past
// OSM's native z19 (blank/blurry over-scaled tiles). z3 ≈ continent view is as
// far out as this app ever needs; z19 is OSM's deepest real tile.
const double minMapZoom = 3.0;
const double maxMapZoom = 19.0;

// Shared with the admin console's "Active (24h)" rule: a bundle remains active
// while the Victim has supplied an update in the last 24 hours. This governs
// cloud pulls, local cleanup, and Helper-map visibility.
const Duration bundleInactiveThreshold = Duration(hours: 24);

bool isBundleActive(DateTime updatedAt, {DateTime? now}) {
  final cutoff =
      (now ?? DateTime.now()).toUtc().subtract(bundleInactiveThreshold);
  return updatedAt.toUtc().isAfter(cutoff);
}
