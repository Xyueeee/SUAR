import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../help/help_tour.dart';
import '../map/map_constants.dart';
import '../map/offline_download_manager.dart';
import '../widgets/back_chevron.dart';
import '../widgets/validated_text_dialog.dart';

const double _handleSize = 14;
const double _minBoxSize = 60;
const double _defaultBoxSize = 220;

enum _Handle {
  topLeft,
  topCenter,
  topRight,
  centerRight,
  bottomRight,
  bottomCenter,
  bottomLeft,
  centerLeft,
}

/// Lets the user pan/zoom the map, then resize a selection box (drag its
/// bottom-right handle) to frame the area to download.
///
/// Two modes:
///  - new region (no [existingStore]): name it, download, pop back.
///  - editing [existingStore]: box preloads the store's saved bounds; the
///    floating action button re-downloads with the (possibly resized) area,
///    and the app bar offers rename/delete.
class RegionDownloadScreen extends StatefulWidget {
  const RegionDownloadScreen({super.key, this.existingStore});

  final FMTCStore? existingStore;

  @override
  State<RegionDownloadScreen> createState() => _RegionDownloadScreenState();
}

class _RegionDownloadScreenState extends State<RegionDownloadScreen> {
  final MapController _mapController = MapController();
  Rect? _selectionRect;
  bool _initialized = false;
  // Null until a fix is in hand — the blue dot and the recenter button both
  // gate on this, so neither shows unless location is actually on.
  LatLng? _userLocation;

  bool get _isEditing => widget.existingStore != null;

  // Help tour targets
  final _kBox = GlobalKey();
  final _kDownload = GlobalKey();
  late final HelpTourController _help = HelpTourController([
    HelpStep(
      targetKey: _kBox,
      title: 'Pick your area',
      body: const [
        'Drag inside this red box to move it, or drag a handle to resize.',
        'Pan and zoom the map underneath to frame the area you want.',
      ],
    ),
    HelpStep(
      targetKey: _kDownload,
      circle: true,
      title: 'Download it',
      body: const [
        'Tap to save the map tiles inside the box for offline use.',
        'The download runs in the background, you can leave this screen.',
      ],
    ),
  ]);

  @override
  void initState() {
    super.initState();
    // Runs every time this screen opens, not just on first ever launch — so
    // a permission denied last time gets asked again, and a since-enabled
    // GPS toggle picks up a fix without needing app restart.
    WidgetsBinding.instance.addPostFrameCallback((_) => _initLocation());
    if (_isEditing) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _loadExistingBounds(),
      );
    }
  }

  /// Best-effort only — the selection box stays screen-centered regardless
  /// (see _initSelectionRect), so a failed/slow fix just means the blue dot
  /// and recenter button simply never appear; the user can still pan
  /// manually as before.
  Future<void> _initLocation() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      if (!await Geolocator.isLocationServiceEnabled()) return;
      // Last-known only (no live stream) — this screen is a one-time area
      // picker, not a live-tracking map, so an instant cached fix (or
      // nothing) is all it needs.
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown == null || !mounted) return;
      final loc = LatLng(lastKnown.latitude, lastKnown.longitude);
      setState(() => _userLocation = loc);
      // Only the new-region flow recenters the camera on the user — editing
      // an existing region instead fits the view to its saved bounds (see
      // _loadExistingBounds), which would otherwise get clobbered by this.
      if (!_isEditing) {
        // Without this the selection box always starts on Kuala Lumpur
        // (defaultMapCenter) regardless of where the user actually is,
        // forcing them to pan/search for their own surroundings before they
        // can even start picking an area — most of the time they just want
        // to download the area they're standing in right now.
        _mapController.move(loc, defaultMapZoom);
      }
    } catch (_) {
      // Best-effort, see doc comment above.
    }
  }

  @override
  void dispose() {
    _help.dispose();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _loadExistingBounds() async {
    final metadata = await widget.existingStore!.metadata.read;
    final north = double.tryParse(metadata['north'] ?? '');
    final south = double.tryParse(metadata['south'] ?? '');
    final east = double.tryParse(metadata['east'] ?? '');
    final west = double.tryParse(metadata['west'] ?? '');
    if (north == null || south == null || east == null || west == null) {
      setState(() => _initialized = true);
      return;
    }

    final bounds = LatLngBounds(LatLng(north, east), LatLng(south, west));
    // CameraFit.center is the Web Mercator pixel midpoint of the box (NOT
    // bounds.center, which is the great-circle center — its latitude sits
    // south of the on-screen midpoint, which is what shifted the reopened
    // view south of where the box was actually drawn). That midpoint is the
    // same lat/lng no matter what zoom the fit computes it at, so it's safe
    // to pair with the saved viewZoom instead of the fit's own zoom, which
    // is only used as a fallback for stores saved before viewZoom existed.
    final fitted = CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(40))
        .fit(_mapController.camera);
    final viewZoom = double.tryParse(metadata['viewZoom'] ?? '');
    _mapController.move(fitted.center, viewZoom ?? fitted.zoom);
    if (!mounted) return;
    // move() applies synchronously — _mapController.camera reflects the new
    // center/zoom immediately, no frame wait needed. Projecting off this
    // SAME live camera means the box can never disagree with what's rendered.
    final camera = _mapController.camera;
    final p1 = camera.latLngToScreenOffset(LatLng(north, east));
    final p2 = camera.latLngToScreenOffset(LatLng(south, west));
    setState(() {
      _selectionRect = Rect.fromPoints(p1, p2);
      _initialized = true;
    });
  }

  void _initSelectionRect(Size mapSize) {
    if (_initialized) return;
    final center = mapSize.center(Offset.zero);
    _selectionRect = Rect.fromCenter(
      center: center,
      width: _defaultBoxSize,
      height: _defaultBoxSize,
    );
    _initialized = true;
  }

  void _onBodyDrag(DragUpdateDetails details, Size mapSize) {
    final rect = _selectionRect!;
    final newLeft = (rect.left + details.delta.dx).clamp(
      0.0,
      mapSize.width - rect.width,
    );
    final newTop = (rect.top + details.delta.dy).clamp(
      0.0,
      mapSize.height - rect.height,
    );
    setState(
      () => _selectionRect = Rect.fromLTWH(
        newLeft,
        newTop,
        rect.width,
        rect.height,
      ),
    );
  }

  /// Corner handles resize both edges they touch; the four edge-midpoint
  /// handles resize only the one edge they sit on (a "straight" resize).
  void _onHandleDrag(_Handle handle, DragUpdateDetails details, Size mapSize) {
    final rect = _selectionRect!;
    var left = rect.left;
    var top = rect.top;
    var right = rect.right;
    var bottom = rect.bottom;

    const adjustsLeft = {
      _Handle.topLeft,
      _Handle.centerLeft,
      _Handle.bottomLeft,
    };
    const adjustsRight = {
      _Handle.topRight,
      _Handle.centerRight,
      _Handle.bottomRight,
    };
    const adjustsTop = {_Handle.topLeft, _Handle.topCenter, _Handle.topRight};
    const adjustsBottom = {
      _Handle.bottomLeft,
      _Handle.bottomCenter,
      _Handle.bottomRight,
    };

    if (adjustsLeft.contains(handle)) {
      left = (left + details.delta.dx).clamp(0.0, right - _minBoxSize);
    }
    if (adjustsRight.contains(handle)) {
      right = (right + details.delta.dx).clamp(
        left + _minBoxSize,
        mapSize.width,
      );
    }
    if (adjustsTop.contains(handle)) {
      top = (top + details.delta.dy).clamp(0.0, bottom - _minBoxSize);
    }
    if (adjustsBottom.contains(handle)) {
      bottom = (bottom + details.delta.dy).clamp(
        top + _minBoxSize,
        mapSize.height,
      );
    }

    setState(() => _selectionRect = Rect.fromLTRB(left, top, right, bottom));
  }

  LatLngBounds _currentBounds() {
    final camera = _mapController.camera;
    final rect = _selectionRect!;
    return LatLngBounds(
      camera.screenOffsetToLatLng(rect.topLeft),
      camera.screenOffsetToLatLng(rect.bottomRight),
    );
  }

  Future<void> _saveNewRegion() async {
    final rect = _selectionRect;
    if (rect == null) return;
    // Captured BEFORE the naming dialog opens, not after: the dialog's
    // keyboard shrinks this Scaffold's body (resizeToAvoidBottomInset
    // defaults to true), so _mapController.camera briefly reports a much
    // shorter viewport while it's up — reading the camera after the dialog
    // closed bounds to that squished size, not the real one, shifting every
    // saved region south.
    final bounds = _currentBounds();
    final viewZoom = _mapController.camera.zoom;

    final name = await showValidatedTextDialog(
      context: context,
      title: 'Name this area',
      confirmLabel: 'Download',
      hintText: 'e.g. Klang Valley',
      validate: (value) async {
        if (await FMTCStore(value).manage.ready) {
          return 'Cannot be the same name as an existing map.';
        }
        return null;
      },
    );
    if (name == null) return;

    await OfflineDownloadManager.instance.startNewRegion(
      storeName: name,
      bounds: bounds,
      minZoom: minDownloadZoom.round(),
      maxZoom: maxDownloadZoom.round(),
      viewZoom: viewZoom,
    );
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _saveEditedBounds() async {
    final rect = _selectionRect;
    if (rect == null) return;
    await OfflineDownloadManager.instance.updateBounds(
      storeName: widget.existingStore!.storeName,
      bounds: _currentBounds(),
      minZoom: minDownloadZoom.round(),
      maxZoom: maxDownloadZoom.round(),
      viewZoom: _mapController.camera.zoom,
    );
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _rename() async {
    final store = widget.existingStore!;
    final newName = await showValidatedTextDialog(
      context: context,
      title: 'Rename region',
      confirmLabel: 'Save',
      initialValue: store.storeName,
      validate: (value) async {
        if (value == store.storeName) return null;
        if (await FMTCStore(value).manage.ready) {
          return 'Cannot be the same name as an existing map.';
        }
        return null;
      },
    );
    if (newName == null || newName == store.storeName) return;
    await store.manage.rename(newName);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final store = widget.existingStore!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${store.storeName}"?'),
        content: const Text(
          'This removes all downloaded tiles for this region.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await store.manage.delete();
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackChevron(),
        title: Text(
          _isEditing ? widget.existingStore!.storeName : 'Download Map Area',
        ),
        actions: [
          HelpButton(controller: _help),
          if (_isEditing) ...[
            IconButton(
              onPressed: _rename,
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final mapSize = Size(constraints.maxWidth, constraints.maxHeight);
          if (!_isEditing) _initSelectionRect(mapSize);
          final rect = _selectionRect;
          return Stack(
            children: [
              FlutterMap(
                mapController: _mapController,
                options: const MapOptions(
                  initialCenter: defaultMapCenter,
                  initialZoom: defaultMapZoom,
                  // Keeps screenOffsetToLatLng (used to convert the box's
                  // corners) accurate — that math assumes a north-up map.
                  interactionOptions: InteractionOptions(
                    flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                  ),
                ),
                children: [
                  TileLayer(
                    urlTemplate: osmTileUrlTemplate,
                    userAgentPackageName: osmUserAgentPackageName,
                    tileProvider: FMTCTileProvider.allStores(
                      allStoresStrategy: BrowseStoreStrategy.read,
                      loadingStrategy: BrowseLoadingStrategy.cacheFirst,
                    ),
                  ),
                  // Same blue-dot styling as the Helper mode map's self marker.
                  if (_userLocation != null)
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: _userLocation!,
                          width: 22,
                          height: 22,
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.blue,
                              border: Border.all(color: Colors.white, width: 2),
                              boxShadow: const [
                                BoxShadow(color: Colors.black38, blurRadius: 4),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
              if (rect != null) ...[
                // Box body — drag anywhere inside (away from a handle) to move it.
                Positioned(
                  key: _kBox,
                  left: rect.left,
                  top: rect.top,
                  width: rect.width,
                  height: rect.height,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (details) => _onBodyDrag(details, mapSize),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.red, width: 3),
                      ),
                    ),
                  ),
                ),
                for (final handle in _Handle.values)
                  _buildHandle(handle, rect, mapSize),
              ],
              const Positioned(
                top: 12,
                left: 12,
                right: 12,
                child: Text(
                  'Pan & zoom the map. Drag inside the box to move it, or a handle to resize.',
                  style: TextStyle(
                    color: Colors.white,
                    backgroundColor: Colors.black54,
                    fontSize: 13,
                  ),
                ),
              ),
              if (_userLocation != null)
                Positioned(
                  bottom: 16,
                  left: 16,
                  child: GestureDetector(
                    // Pans only — keeps whatever zoom the user was already
                    // at, instead of snapping to a fixed recenter zoom.
                    onTap: () => _mapController.move(
                      _userLocation!,
                      _mapController.camera.zoom,
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        // Same icon as Helper mode's recenter button, but a
                        // light/dark-matching fill (instead of Helper mode's
                        // fixed black54) so it reads against a light map too.
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.black
                            : Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: const [
                          BoxShadow(color: Colors.black38, blurRadius: 4),
                        ],
                      ),
                      child: Icon(
                        Icons.my_location,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.white
                            : Colors.black,
                        size: 20,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        key: _kDownload,
        backgroundColor: const Color(0xFFA7C7E7),
        foregroundColor: Colors.black,
        tooltip: _isEditing ? 'Save & re-download' : 'Download this area',
        onPressed: _isEditing ? _saveEditedBounds : _saveNewRegion,
        child: Icon(_isEditing ? Icons.save : Icons.download),
      ),
    );
  }

  Widget _buildHandle(_Handle handle, Rect rect, Size mapSize) {
    final double cx = switch (handle) {
      _Handle.topLeft || _Handle.centerLeft || _Handle.bottomLeft => rect.left,
      _Handle.topCenter || _Handle.bottomCenter => rect.center.dx,
      _Handle.topRight ||
      _Handle.centerRight ||
      _Handle.bottomRight => rect.right,
    };
    final double cy = switch (handle) {
      _Handle.topLeft || _Handle.topCenter || _Handle.topRight => rect.top,
      _Handle.centerLeft || _Handle.centerRight => rect.center.dy,
      _Handle.bottomLeft ||
      _Handle.bottomCenter ||
      _Handle.bottomRight => rect.bottom,
    };
    const hitSize = _handleSize + 18;
    return Positioned(
      left: cx - hitSize / 2,
      top: cy - hitSize / 2,
      // Hit target is bigger than the visible dot — a 14px circle is too
      // small to reliably grab with a finger.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) => _onHandleDrag(handle, details, mapSize),
        child: SizedBox(
          width: hitSize,
          height: hitSize,
          child: Center(
            child: Container(
              width: _handleSize,
              height: _handleSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                border: Border.all(color: Colors.red, width: 2),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 3,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
