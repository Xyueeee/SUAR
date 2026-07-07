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

// A victim's last-known position/status is only as good as how recently it
// was actually observed. Past this age, a pin showing on the Helper's map
// risks sending someone to a spot the victim (or the situation) has already
// moved on from — DTN relay keeps carrying the bundle regardless (other
// Helpers may still usefully forward it), this only governs whether THIS
// device still shows it as an actionable map pin.
const Duration staleBundleMapThreshold = Duration(hours: 1);

// Admin's "Active (24h)" convention (web ACTIVE_WINDOW_MS, backend's
// active-bundle-reuse window) — a bundle whose original event is older than
// this is presumed resolved. Reads createdAt, not updatedAt: updatedAt gets
// bumped by every relay re-save and every Victim triage refresh, so an old
// event relayed helper-to-helper (or a Victim's app just still running) would
// otherwise keep looking "fresh" on the map forever. This only governs map
// display — the bundle stays in local storage and keeps relaying either way.
const Duration bundleInactiveThreshold = Duration(hours: 24);
