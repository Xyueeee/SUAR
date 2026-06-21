import 'package:flutter/material.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';

import '../map/offline_download_manager.dart';
import 'region_download_screen.dart';

// No seconds in here on purpose — a seconds-resolution countdown changes
// every single tick and reads as jittery/unstable. Minute resolution only.
String _formatEta(Duration d) {
  if (d == Duration.zero) return 'estimating…';
  if (d.inMinutes < 1) return '<1 minute left';
  if (d.inHours < 1) return '${d.inMinutes}m left';
  return '${d.inHours}h ${d.inMinutes % 60}m left';
}

/// [DownloadProgress] only tracks tile *counts* precisely — there's no
/// known total byte size up front, since average tile size varies. This
/// extrapolates a rough total from the average size of tiles seen so far,
/// which is the same approach the size-based progress bar below uses.
String _formatSizeProgress(DownloadProgress p) {
  if (p.successfulTilesCount == 0) return 'Starting…';
  final avgKib = p.successfulTilesSize / p.successfulTilesCount;
  final estTotalMb = (avgKib * p.maxTilesCount) / 1024;
  final doneMb = p.successfulTilesSize / 1024;
  return '${doneMb.toStringAsFixed(1)}/${estTotalMb.toStringAsFixed(1)} MB';
}

String _formatSpeed(DownloadProgress p) {
  final seconds = p.elapsedDuration.inSeconds;
  if (seconds == 0) return '';
  final mbPerSecond = (p.successfulTilesSize / 1024) / seconds;
  return '${mbPerSecond.toStringAsFixed(2)} MB/s';
}

/// Settings > Offline Map Management. Lists downloaded regions (FMTC
/// stores); a region currently downloading shows live progress inline in
/// its own row instead of a separate section, and stays tappable so it can
/// be edited (resize/rename/delete) while the download is still running.
class OfflineMapManagementScreen extends StatefulWidget {
  const OfflineMapManagementScreen({super.key});

  @override
  State<OfflineMapManagementScreen> createState() =>
      _OfflineMapManagementScreenState();
}

class _OfflineMapManagementScreenState
    extends State<OfflineMapManagementScreen> {
  late Future<List<FMTCStore>> _storesFuture;
  final _manager = OfflineDownloadManager.instance;
  Set<String> _previousActiveNames = {};

  @override
  void initState() {
    super.initState();
    _reload();
    _previousActiveNames = _manager.active.keys.toSet();
    _manager.addListener(_onManagerChanged);
  }

  @override
  void dispose() {
    _manager.removeListener(_onManagerChanged);
    super.dispose();
  }

  void _onManagerChanged() {
    if (!mounted) return;
    final currentNames = _manager.active.keys.toSet();
    // Only refetch the stores list (size/tile count) when a download
    // actually finishes — reloading on every progress tick (many times a
    // second during a download) made the list flicker/spin constantly.
    final finished = _previousActiveNames.difference(currentNames);
    _previousActiveNames = currentNames;
    if (finished.isNotEmpty) setState(_reload);
  }

  void _reload() {
    _storesFuture = FMTCRoot.stats.storesAvailable;
  }

  Future<void> _addRegion() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const RegionDownloadScreen()),
    );
    if (mounted) setState(_reload);
  }

  Future<void> _editRegion(FMTCStore store) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RegionDownloadScreen(existingStore: store),
      ),
    );
    if (mounted) setState(_reload);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        title: const Text('Offline Map Management'),
      ),
      body: FutureBuilder<List<FMTCStore>>(
        future: _storesFuture,
        builder: (context, snapshot) {
          final stores = snapshot.data ?? const [];
          if (snapshot.connectionState == ConnectionState.waiting &&
              stores.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (stores.isEmpty) {
            return const Center(
              child: Text(
                'No downloaded regions yet.',
                style: TextStyle(color: Colors.black54),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: stores.length,
            separatorBuilder: (_, _) => const Divider(
              height: 1,
              color: Colors.black12,
              indent: 16,
              endIndent: 16,
            ),
            itemBuilder: (context, index) {
              final store = stores[index];
              return _StoreRow(
                store: store,
                manager: _manager,
                onTap: () => _editRegion(store),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFFA7C7E7),
        foregroundColor: Colors.black,
        tooltip: 'Add region',
        onPressed: _addRegion,
        child: const Icon(Icons.add_location_alt),
      ),
    );
  }
}

class _StoreRow extends StatefulWidget {
  const _StoreRow({
    required this.store,
    required this.manager,
    required this.onTap,
  });

  final FMTCStore store;
  final OfflineDownloadManager manager;
  final VoidCallback onTap;

  @override
  State<_StoreRow> createState() => _StoreRowState();
}

class _StoreRowState extends State<_StoreRow> {
  // Cached rather than refetched on every manager tick (that was the cause
  // of the list spinning/flickering) — but it must still be refreshed when
  // the parent passes a new widget, otherwise a re-download of an existing
  // store (same storeName, same list position, so the Element/State is
  // reused and initState() never reruns) kept showing the stats captured
  // before the redownload, permanently stuck at the old 0 tiles/0.0MB.
  late Future<({double size, int length, int hits, int misses})> _statsFuture;

  @override
  void initState() {
    super.initState();
    _statsFuture = widget.store.stats.all;
  }

  @override
  void didUpdateWidget(_StoreRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _statsFuture = widget.store.stats.all;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.manager,
      builder: (context, _) {
        final active = widget.manager.active[widget.store.storeName];
        return InkWell(
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.store.storeName,
                        style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    if (active == null)
                      const Icon(Icons.chevron_right, color: Colors.black38)
                    else if (active.isQueued)
                      const Text(
                        'Queued',
                        style: TextStyle(color: Colors.black54, fontSize: 12),
                      )
                    else ...[
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          active.isPaused ? Icons.play_arrow : Icons.pause,
                          color: Colors.black54,
                        ),
                        onPressed: () => active.isPaused
                            ? widget.manager.resume(widget.store.storeName)
                            : widget.manager.pause(widget.store.storeName),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close, color: Colors.black54),
                        onPressed: () =>
                            widget.manager.cancel(widget.store.storeName),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                if (active != null && !active.isQueued) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: active.progress == null
                          ? null
                          : active.progress!.percentageProgress / 100,
                      minHeight: 4,
                      backgroundColor: Colors.black12,
                      color: const Color(0xFFA7C7E7),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    active.progress == null
                        ? 'Starting…'
                        : '${active.progress!.percentageProgress.toStringAsFixed(0)}% · '
                              '${_formatEta(active.progress!.estRemainingDuration)} · '
                              '${_formatSizeProgress(active.progress!)} · '
                              '${_formatSpeed(active.progress!)}',
                    style: const TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                ] else if (active != null && active.isQueued)
                  const Text(
                    'Waiting for another download to finish…',
                    style: TextStyle(color: Colors.black54, fontSize: 12),
                  )
                else
                  FutureBuilder(
                    future: _statsFuture,
                    builder: (context, snapshot) {
                      final stats = snapshot.data;
                      final text = stats == null
                          ? 'Loading…'
                          : '${stats.length} tiles · ${(stats.size / 1024).toStringAsFixed(1)} MB';
                      return Text(
                        text,
                        style: const TextStyle(
                          color: Colors.black54,
                          fontSize: 12,
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
