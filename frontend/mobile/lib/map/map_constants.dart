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

// A victim's last-known position/status is only as good as how recently it
// was actually observed. Past this age, a pin showing on the Helper's map
// risks sending someone to a spot the victim (or the situation) has already
// moved on from — DTN relay keeps carrying the bundle regardless (other
// Helpers may still usefully forward it), this only governs whether THIS
// device still shows it as an actionable map pin.
const Duration staleBundleMapThreshold = Duration(hours: 1);
