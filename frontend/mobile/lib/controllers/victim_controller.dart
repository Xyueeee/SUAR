import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../communication/ble_manager.dart';
import '../communication/wifi_direct_manager.dart';
import '../constants.dart';
import '../models/distress_bundle_model.dart';
import '../permissions.dart';
import '../sensing/sensor_fusion_engine.dart';
import '../sensing/triage_config.dart';

class VictimController {
  VictimController()
    : bleManager = BLEManager(),
      wifiDirectManager = WiFiDirectManager();

  final BLEManager bleManager;
  final WiFiDirectManager wifiDirectManager;

  // Increment 2: live sensor fusion → triage. Sampled only while Victim mode
  // is active (battery-conscious), recomputed on a fixed cadence. ≤2s compute
  // NFR is met trivially — evaluate() is a synchronous weighted sum.
  final SensorFusionEngine _sensorEngine = SensorFusionEngine();
  static const Duration _triageInterval = Duration(seconds: 5);
  Timer? _triageTimer;

  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  // Once a helper has been sent a bundle, don't re-send to it again for a
  // while — but keep advertising/listening so other (or the same, later)
  // helpers can still pick it up. A successful delivery used to stop
  // advertising outright, which meant exactly one helper ever got the
  // bundle, ever, ending the Victim's participation in the mesh for good.
  static const Duration _helperCooldown = Duration(minutes: 2);
  final Map<String, DateTime> _deliveredTo = {};
  // _deliveredTo only gates a retry after a FULL delivery success — a
  // connectToHelper() that forms a connection but then fails later (ends up
  // group owner itself, or sendBundle fails) deliberately skips it (see the
  // "don't put it on the success cooldown either" comment below) so a
  // genuinely reachable Helper isn't punished for one bad cycle. But ATTEMPTING
  // a connection at all is what pops the OS "Invitation to connect" dialog on
  // the Helper's screen — and the connect MOSTLY TIMES OUT before forming
  // (logs: "Could not pair with the peer in time"), so gating only on a formed
  // connection never fired and the same Helper got re-dialled every ~8s RSSI
  // window, one dialog each. _connectedRecentlyAt is therefore recorded the
  // moment connect() is ATTEMPTED, before it can time out, on its own short
  // cooldown — long enough to stop the ~8s hammering, short enough that a
  // transient pairing failure (common on this hardware, often needs a few
  // tries) still retries soon. Distinct from the 2-min _helperCooldown, which
  // means "already fully delivered, nothing more to send".
  static const Duration _attemptCooldown = Duration(seconds: 45);
  final Map<String, DateTime> _connectedRecentlyAt = {};
  // Consecutive failed connect attempts per Helper. A flat 45s is fine for a
  // Helper that's reachable but slow to pair, but when a Helper NEVER accepts
  // (its user is away, not tapping the OS "Invitation to connect" prompt) the
  // Victim keeps re-dialling and they come back to a stack of prompts. Back
  // off: effective cooldown = 45s doubled per consecutive failure, capped at
  // 4 min. Reset the instant a connection forms. Mirrors HelperController.
  final Map<String, int> _attemptFailStreak = {};
  static const int _attemptBackoffCapSeconds = 240;
  Duration _effectiveAttemptCooldown(String helperId) {
    final streak = (_attemptFailStreak[helperId] ?? 0).clamp(0, 5);
    final secs = (_attemptCooldown.inSeconds << streak)
        .clamp(_attemptCooldown.inSeconds, _attemptBackoffCapSeconds);
    return Duration(seconds: secs);
  }

  // Real-device testing found some chipsets (confirmed: a budget Oppo unit)
  // can be discovered and connected to over Wi-Fi Direct fine, but can never
  // successfully *initiate* P2P discovery themselves — discoverPeers()
  // genuinely completes its full poll and finds nothing, every time,
  // regardless of permissions/location/AP-association. Rather than retry
  // forever into a dead end, this device learns that about itself after a
  // couple of clean failures and flags it to Helpers (via the BLE status
  // characteristic) so they connect to it instead. TTL'd rather than
  // permanent — the cause could be transient (radio toggled off, OEM power
  // saving), not necessarily the hardware itself.
  //
  // _loadInitiatorCapability's default below defaults this flag to FALSE
  // (start in pull mode) rather than true, on a fresh/no-prior-record
  // state — broadened from "Oppo only" after this session's logs showed
  // even the OTHER test device's very first Victim-initiated discoverPeers()
  // also returned 0 peers, every time it was tried fresh. The likely cause
  // is structural, not per-chipset: the Victim calls discoverPeers() alone,
  // right after BLE handshake, before the Helper has started its own P2P
  // discovery (it only starts after finishing the GATT ACK exchange a few
  // seconds later) — Wi-Fi Direct discovery needs roughly-overlapping
  // search/listen windows on both ends to find each other at all, and a
  // lone Victim probing first has nothing to overlap with yet. Skipping
  // straight to pull mode just stops paying that near-guaranteed-failed
  // first probe's ~12-18s cost on every fresh app start; the periodic
  // self-heal probe below still gives push mode a fair retry later.
  static const String _canInitiateKey = 'suar_wifi_direct_can_initiate';
  static const String _capabilityTestedAtKey =
      'suar_wifi_direct_capability_tested_at';
  static const Duration _capabilityTtl = Duration(hours: 24);
  // Real-device timing: each failed cycle costs up to ~18s (pollPeers' full
  // ceiling) plus a wait for the next BLE ack before it can even retry. 2
  // cycles before flagging meant ~75-80s end-to-end before pull mode ever
  // kicked in, even though the transfer itself completes in under 2s once it
  // does. The periodic self-heal probe (see _retryProbeEveryNCycles) already
  // covers the "was this just a fluke" concern, so 1 is enough here.
  static const int _maxConsecutiveGenuineFailures = 1;
  // A flag with no way back is a trap: a transient failure (heavy P2P churn
  // from back-to-back testing, not an actual hardware limit) gets treated as
  // permanent for a full day, and if the Helper trying to pull from this
  // device *also* can't initiate discovery (seen on real hardware), neither
  // side can ever call connect() — a permanent deadlock with no event to
  // break it. Re-testing periodically even while flagged bad — a half-open
  // circuit breaker — means a wrongly-flagged device self-heals within a
  // few RSSI windows instead of needing the full TTL or a manual data clear.
  //
  // Each cycle here is gated by BLE ack arrival (~12-16s apart in testing),
  // not discoverPeers() timing. Was 2 (re-probe every ~25-30s) until this
  // session's logs showed that on the confirmed-bad Oppo unit (line 31-34
  // above) the re-probe fails 100% of the time, every single time, all
  // session long — there's nothing transient about it on that hardware, so
  // re-testing this often was pure wasted radio time (another ~12-18s dead
  // discoverPeers() poll) and log spam, not a real safety net for THAT
  // device. Bumped 6x so the self-heal (still wanted for hardware that
  // genuinely was transient — radio toggled off, OEM power saving) doesn't
  // disappear, it just stops firing every other delivery cycle.
  static const int _retryProbeEveryNCycles = 12;
  bool _canInitiateWifiDirect = true;
  // True once createGroup() succeeds in startVictimMode — this device is then
  // a discoverable autonomous group owner and must stay passive: it must NOT
  // call its own discoverPeers()/connect()/disconnect(), since disconnect()
  // tears down the very group that makes it discoverable. The Helper does all
  // the active work (discover → join as client → pull). See startVictimMode.
  bool _isAutonomousGroupOwner = false;
  // Self-heal for a wedged autonomous group. The Victim is passive — it only
  // hosts the group and waits to be pulled — so the symptom of its own group
  // going stale (OS power-saving blip, a Helper connect() that half-formed and
  // poisoned the group) is: Helpers keep ACKing over BLE every contact cycle,
  // but no pull is ever served (bundleDeliveredStream never fires). Counting
  // BLE ACKs received since the last delivery and, past a threshold, tearing
  // the group down and re-creating it fresh recovers from that without
  // touching BLE. Reset to 0 on every successful delivery.
  int _acksSinceDelivery = 0;
  static const int _groupRefreshAfterAcks = 5;
  bool _refreshingGroup = false;
  int _consecutiveGenuineFailures = 0;
  int _cyclesSinceCapabilityProbe = 0;
  // Guards the pull-mode reactive push below against overlapping itself if
  // connectionFormed fires more than once for the same connection (the OS
  // broadcast can repeat) — matches the same concern that motivated
  // HelperController's _pullInFlight.
  bool _pushInFlight = false;

  String? deviceId;
  DistressBundleModel? _bundle;
  final Map<String, int> _helperRssiMap = {};
  Timer? _rssiWindowTimer;
  bool _stopped = false;
  StreamSubscription? _ackSub;
  StreamSubscription? _bleStatusSub;
  StreamSubscription? _wifiStatusSub;
  StreamSubscription? _connectionFormedSub;
  StreamSubscription? _bundleDeliveredSub;
  // Set true once any Helper has actually fetched this device's bundle, so the
  // user gets one clear "your info got out" confirmation. A passive group-owner
  // Victim never sees a "sent" event (it waits to be pulled), which previously
  // meant a successful delivery looked identical to total silence on screen.
  bool _deliveredAtLeastOnce = false;
  // True while this free Victim has yielded its group-owner role to an
  // AP-joined Helper that offered to host, and is actively pushing to it
  // instead of waiting to be pulled. A fallback timer (below) restores the
  // autonomous group if no delivery lands, so a Helper that can't actually host
  // can never strand this device — it just reverts to today's behaviour.
  bool _yieldingToHost = false;
  Timer? _yieldFallbackTimer;
  static const Duration _yieldFallback = Duration(seconds: 30);

  // Android can silently kill BLE advertising or the Wi-Fi Direct
  // accept-loop thread in the background on some OEMs — no error, no
  // callback, the radio just stops working. A Victim that looks "active"
  // but has actually gone silent is the single worst failure mode this app
  // can have, so this periodically checks both and restarts whichever died.
  static const Duration _radioWatchdogInterval = Duration(seconds: 30);
  Timer? _radioWatchdog;

  // The RSSI-window retry loop and BLE ops keep running after stopVictimMode
  // resolves but before dispose() closes this stream — guard every emit so
  // that race is a no-op instead of "Bad state: Cannot add new events after
  // calling close".
  void _emit(String line) {
    // Also mirror to logcat (as an I/flutter line) — the in-app activity
    // card alone meant decision logic (capability flag flips, pull-mode
    // switches) was invisible to anyone reading a logcat dump instead of
    // screenshotting the running app.
    debugPrint('[Victim] $line');
    if (!_statusController.isClosed) _statusController.add(line);
  }

  /// One-shot logcat-visible record of whether this device is associated to
  /// a regular Wi-Fi AP — see the call site's comment in startVictimMode.
  Future<void> _logStaAssociation() async {
    final info = await WiFiDirectManager.getStaInfo();
    final associated = info?['associated'] as bool? ?? false;
    if (associated) {
      _emit(
        'WARNING: this device is connected to Wi-Fi "${info?['ssid']}" — '
        'Wi-Fi Direct discovery/group formation is unreliable while '
        'associated to a regular access point on most chipsets.',
      );
    } else {
      _emit('Wi-Fi station not associated to any AP (good for Wi-Fi Direct)');
    }
  }

  /// Pushes this device's current Wi-Fi-AP-join state onto the BLE status
  /// characteristic so a connecting Helper reads it during the ack handshake
  /// and can decide who hosts the Wi-Fi Direct group.
  Future<void> _publishAssociation() async {
    final info = await WiFiDirectManager.getStaInfo();
    if (_stopped) return;
    await bleManager.setAssociated(info?['associated'] as bool? ?? false);
  }

  /// A nearby Helper joined to a Wi-Fi network told this (free) device, over the
  /// BLE ack, that IT will host the Wi-Fi Direct group — on a single-radio
  /// chipset the Helper can host on its own channel but can't reach this
  /// device's group on a different one, so the free side has to be the joiner.
  /// This device gives up its autonomous group-owner role and pushes to the
  /// Helper instead, reusing the normal active-push path (_tryDeliverBundle via
  /// the RSSI window). A fallback timer restores the autonomous group if no
  /// delivery completes, so a Helper whose chipset can't actually host can't
  /// strand this device.
  Future<void> _enterHostYield(String helperDeviceId) async {
    if (_stopped || _yieldingToHost) return;
    // Don't re-yield to a Helper we just delivered to — its repeat acks during
    // the cooldown would otherwise tear our group down again and again.
    final last = _deliveredTo[helperDeviceId];
    if (last != null && DateTime.now().difference(last) < _helperCooldown) {
      return;
    }
    _yieldingToHost = true;
    _emit(
      'A nearby helper is on Wi-Fi and will host the connection — sending to it',
    );
    _isAutonomousGroupOwner = false;
    _canInitiateWifiDirect = true;
    await wifiDirectManager.disconnect(); // give up our own group
    if (_stopped) return;
    await bleManager.setNeedsPull(false); // we push now; don't ask to be pulled
    _yieldFallbackTimer?.cancel();
    _yieldFallbackTimer = Timer(_yieldFallback, () {
      unawaited(
        _revertHostYield(
          'No nearby helper completed the transfer — back to wait mode',
        ),
      );
    });
    // Push promptly instead of waiting out the current RSSI window.
    _rssiWindowTimer?.cancel();
    unawaited(_onRssiWindowClosed());
  }

  /// Undoes [_enterHostYield] — recreates the autonomous group and returns to
  /// the proven discoverable passive default. Called both on a successful push
  /// (return to normal so free Helpers can still pull later) and by the
  /// fallback timer (the host attempt didn't pan out).
  Future<void> _revertHostYield(String reason) async {
    if (_stopped || !_yieldingToHost) return;
    _yieldingToHost = false;
    _yieldFallbackTimer?.cancel();
    _emit(reason);
    _isAutonomousGroupOwner = await wifiDirectManager.createGroup();
    _canInitiateWifiDirect = false;
    if (_stopped) return;
    await bleManager.setNeedsPull(true);
  }

  /// Self-heal a stale autonomous group: Helpers keep ACKing over BLE but no
  /// pull ever lands ([_acksSinceDelivery] crossed the threshold), which on real
  /// hardware means this device's group has gone bad (OS tore it down, or a
  /// Helper connect() half-formed and poisoned it) while still looking present.
  /// disconnect() fully removes the old group (native removeGroup retries past
  /// BUSY) and createGroup() forms a fresh one — the same clean-slate cycle the
  /// Helper's [_recoverWifiDirectStack] does, from the passive side. The
  /// transfer server and BLE both keep running untouched.
  Future<void> _refreshAutonomousGroup() async {
    if (_refreshingGroup || _stopped || !_isAutonomousGroupOwner) return;
    _refreshingGroup = true;
    try {
      _emit(
        'Nearby helpers keep checking in but nothing was picked up — '
        'refreshing the Wi-Fi Direct group',
      );
      _acksSinceDelivery = 0;
      _isAutonomousGroupOwner = false;
      await wifiDirectManager.disconnect();
      if (_stopped) return;
      // Let the single-threaded P2P framework settle the teardown before
      // re-creating, or createGroup() comes back BUSY.
      await Future.delayed(const Duration(milliseconds: 1200));
      if (_stopped) return;
      _isAutonomousGroupOwner = await wifiDirectManager.createGroup();
      // The fresh group's accept loop still needs the cached bundle to answer
      // pulls — disconnect() doesn't touch startServer()'s socket, but the
      // bundle cache is re-asserted here as cheap insurance.
      if (_isAutonomousGroupOwner && _bundle != null) {
        await wifiDirectManager.setLocalBundle(_bundle!.toJson());
      }
    } finally {
      _refreshingGroup = false;
    }
  }

  Future<void> startVictimMode() async {
    try {
      // Defensive against a double-start (e.g. a rapid back-then-reopen on
      // the screen): without cancelling first, a second call leaked the old
      // subscriptions and left every event handled twice.
      await _cancelSubs();
      _stopped = false;
      _deliveredAtLeastOnce = false;
      _yieldingToHost = false;

      deviceId = await _loadOrCreateDeviceId();
      _emit('Victim mode started (deviceId=$deviceId)');

      _bleStatusSub = bleManager.statusStream.listen(_emit);
      _wifiStatusSub = wifiDirectManager.statusStream.listen(_emit);

      // A passive group-owner Victim is pulled, never pushes, so it otherwise
      // gets zero feedback that its distress info actually reached a helper.
      // In a disaster app that silence is the worst case — the person can't
      // tell if they still need help. Surface one plain confirmation the first
      // time, and keep a quieter note for any repeats.
      _bundleDeliveredSub = wifiDirectManager.bundleDeliveredStream.listen((_) {
        if (_stopped) return;
        // A real pull went through — the group is healthy, so clear the
        // stale-group self-heal counter.
        _acksSinceDelivery = 0;
        if (!_deliveredAtLeastOnce) {
          _deliveredAtLeastOnce = true;
          _emit(
            'A nearby helper picked up your information. Stay where you '
            'are if you can — keep this running.',
          );
        } else {
          _emit('Another nearby helper picked up your information.');
        }
      });

      // Starts at None/0 until the first triage cycle fills it in (see
      // _startTriage) — the sensor windows need a moment of data before a
      // score means anything.
      _bundle = DistressBundleModel(
        bundleId: const Uuid().v4(),
        deviceId: deviceId!,
        priorityScore: 0.0,
        priorityTier: 'None',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        sensorReadings: const [],
      );

      await _loadInitiatorCapability();
      // Always run the server + keep the bundle cached natively, regardless
      // of capability — costs nothing idle, covers the case where this
      // device ends up P2P group owner (so a Helper-as-client can dial in
      // and fetch directly), and means a Helper's pull works immediately if
      // this device's capability flips mid-session rather than only after
      // the next startVictimMode() call.
      await wifiDirectManager.startServer();
      await wifiDirectManager.setLocalBundle(_bundle!.toJson());
      // Victim never calls discoverPeers()/connect(), so logWifiState() on
      // the native side (which only fires from those two calls) never runs
      // for this role — meaning a Victim stuck associated to a regular AP
      // (the single biggest real-hardware cause of "Helper finds 0 peers
      // forever" found this session) left literally zero trace in logcat.
      // The on-screen RadioStatusBanner already polls and warns for this,
      // but only if someone's looking at this device's screen at the time.
      unawaited(_logStaAssociation());

      // THE fix for "Helper finds 0 peers forever": a purely passive Victim
      // (TCP server + waiting) is INVISIBLE to a Helper's discoverPeers() —
      // in Wi-Fi P2P a device is only discoverable while itself discovering
      // OR while it is a group owner. Becoming an autonomous group owner
      // makes this Victim a reliably-discoverable soft-AP at 192.168.49.1;
      // the Helper discovers it, joins as client (deterministic role, no
      // glare), and pulls the bundle from this device's already-running
      // server. If createGroup fails (Wi-Fi off, P2P busy), the Victim falls
      // back to the legacy capability-probe path below.
      _isAutonomousGroupOwner = await wifiDirectManager.createGroup();
      // The native BLE peripheral (BlePeripheralHelper) is a singleton that
      // outlives any single mode session — its role field stays whatever it
      // was last set to. Without resetting it here, a device that was
      // previously in Helper mode this app run (role=helper) would still
      // advertise role=helper after switching to Victim mode, and a scanning
      // Helper would misclassify it as a peer Helper instead of a Victim —
      // confirmed on real hardware: it skipped the ack/pull flow entirely and
      // logged "No bundles to relay" instead of ever pulling the bundle.
      await bleManager.setRole(bleRoleVictim);
      // Broadcast a neutral, role-tagged Wi-Fi Direct name so a helper's connect
      // prompt reads "SOS-1A2B" (clearly an incoming distress peer, and
      // anonymous) instead of this phone's real model name. Best-effort — see
      // setP2pDeviceName.
      await wifiDirectManager.setP2pDeviceName(
        'SOS-${deviceNameSuffix(deviceId!)}',
      );
      // As an autonomous group owner this device is purely passive and must
      // be pulled (it never pushes), so needsPull is always true in that
      // case; only the legacy fallback path (createGroup failed) defers to
      // the learned initiator capability.
      await bleManager.setNeedsPull(
        _isAutonomousGroupOwner || !_canInitiateWifiDirect,
      );
      // Publish this device's Wi-Fi-AP-join state on the status characteristic
      // so a connecting Helper can decide who hosts the Wi-Fi Direct group (an
      // AP-joined Helper must host; this free Victim then yields and pushes —
      // see the helperWillHost handling in the ack listener). Kept fresh by the
      // radio watchdog, since association can change mid-session.
      await _publishAssociation();

      // Covers the other half: this device ends up P2P *client* despite not
      // having initiated the connect() call itself (the Helper did, while
      // pulling) — WIFI_P2P_CONNECTION_CHANGED_ACTION fires on both ends
      // regardless of who initiated, so this is how the non-initiating side
      // learns to push. Only acts while in pull mode — the active flow
      // already pushes directly right after its own connect() succeeds, and
      // reacting here too would double-send.
      _connectionFormedSub = wifiDirectManager.connectionFormedStream.listen((
        info,
      ) async {
        if (_stopped || _canInitiateWifiDirect || _pushInFlight) return;
        final isGroupOwner = info['isGroupOwner'] as bool? ?? false;
        if (isGroupOwner) return;
        final groupOwnerAddress = info['groupOwnerAddress'] as String?;
        if (groupOwnerAddress == null) return;
        _pushInFlight = true;
        try {
          _emit(
            'Connection formed (pull mode) — pushing bundle to $groupOwnerAddress',
          );
          final sent = await wifiDirectManager.sendBundle(
            groupOwnerAddress,
            _bundle!.toJson(),
          );
          if (sent) {
            _emit('Bundle ${_bundle!.bundleId} transmitted (pull mode)');
          }
          await wifiDirectManager.disconnect();
        } finally {
          _pushInFlight = false;
        }
      });

      _helperRssiMap.clear();
      _ackSub = bleManager.helperAckStream.listen((ack) {
        final helperDeviceId = ack['helperDeviceId'] as String;
        final rssi = ack['rssi'] as int;
        _helperRssiMap[helperDeviceId] = rssi;
        _emit('Helper $helperDeviceId rssi=$rssi recorded');
        // The Helper is joined to a Wi-Fi network and can't reach this free
        // device's group, so it asked (over the ack) to host instead. Give up
        // our own group-owner role and push to it. See _enterHostYield.
        if (ack['helperWillHost'] == true) {
          unawaited(_enterHostYield(helperDeviceId));
          return;
        }
        // A Helper is in range and ACKing but nothing is being pulled — if this
        // keeps up while we're the autonomous owner, our group is likely stale.
        // Refresh it (see _acksSinceDelivery). Only the passive-owner case: a
        // yielding/non-owner Victim has no group of its own to refresh.
        if (_isAutonomousGroupOwner) {
          _acksSinceDelivery++;
          if (_acksSinceDelivery >= _groupRefreshAfterAcks) {
            unawaited(_refreshAutonomousGroup());
          }
        }
      });

      await bleManager.startAdvertising(deviceId!);

      _rssiWindowTimer?.cancel();
      _rssiWindowTimer = Timer(
        const Duration(milliseconds: bleRssiCollectionWindowMs),
        _onRssiWindowClosed,
      );

      _radioWatchdog?.cancel();
      _radioWatchdog = Timer.periodic(_radioWatchdogInterval, (_) async {
        if (_stopped) return;
        if (!await bleManager.isAdvertising()) {
          _emit('BLE advertising found stopped unexpectedly — restarting it');
          await bleManager.startAdvertising(deviceId!);
        }
        if (_stopped) return;
        if (!await wifiDirectManager.isServerRunning()) {
          _emit(
            'Wi-Fi Direct server found stopped unexpectedly — restarting it',
          );
          await wifiDirectManager.startServer();
          // The server's accept loop needs the cached bundle to still serve
          // pull requests — startServer() doesn't touch that cache, but
          // re-asserting it here is cheap insurance against any future
          // change to that assumption silently breaking pull mode.
          if (_bundle != null) {
            await wifiDirectManager.setLocalBundle(_bundle!.toJson());
          }
        }
        if (_stopped) return;
        // Re-assert the autonomous group if it was created — if the OS tore
        // it down (power saving, Wi-Fi blip) this device would silently go
        // invisible to Helper discovery again. createGroup() is idempotent
        // natively (it reuses an existing group), so this is cheap to call.
        // Skipped while yielding to an AP-joined host (the group is
        // deliberately torn down then — see _enterHostYield).
        if (_isAutonomousGroupOwner) {
          await wifiDirectManager.createGroup();
        }
        if (_stopped) return;
        // Keep the advertised AP-join state fresh — it drives who hosts and can
        // change mid-session (a network joins, drops, or is auto-disabled).
        await _publishAssociation();
      });

      // Kick off sensor fusion + triage AFTER the mesh is live, and don't
      // await it — requesting mic permission pops a dialog, and the SOS
      // broadcast must never wait behind it.
      unawaited(_startTriage());
    } catch (e) {
      _emit('Victim mode start failed: $e');
    }
  }

  /// Requests the (optional) mic permission, starts the sensor engine, and
  /// begins recomputing triage on a fixed cadence. Best-effort throughout —
  /// a denied mic just drops that term; a failure here never breaks the mesh.
  Future<void> _startTriage() async {
    try {
      final micGranted = await requestMicPermission();
      if (_stopped) return;
      await _sensorEngine.start(withMic: micGranted);
      if (_stopped) return;
      _emit(
        micGranted
            ? 'Sensor triage started (microphone enabled)'
            : 'Sensor triage started (microphone unavailable — using other sensors)',
      );
      _triageTimer?.cancel();
      _triageTimer = Timer.periodic(_triageInterval, (_) => _recomputeTriage());
      await _recomputeTriage();
    } catch (e) {
      _emit('Sensor triage failed to start: $e');
    }
  }

  /// Re-scores the bundle from the latest sensor state and re-caches it so the
  /// next Helper pull carries the current triage. Updates the live bundle in
  /// place (priority score/tier + sensor readings).
  Future<void> _recomputeTriage() async {
    final bundle = _bundle;
    if (bundle == null || _stopped) return;
    final outcome = _sensorEngine.evaluate(bundle.bundleId);
    // Score is additive points on a 0..scoreCap scale; the schema's
    // PriorityScore is 0..1, so store the normalised value. The tier carries
    // the real classification.
    final cap = TriageConfig.active.scoreCap;
    bundle.priorityScore =
        cap > 0 ? (outcome.result.score / cap).clamp(0.0, 1.0) : 0.0;
    bundle.priorityTier = outcome.result.tier;
    bundle.sensorReadings = outcome.readings.map((r) => r.toJson()).toList();
    bundle.flags = outcome.result.flags;
    bundle.updatedAt = DateTime.now();
    await wifiDirectManager.setLocalBundle(bundle.toJson());
    if (_stopped) return;
    final note = outcome.result.note;
    _emit(
      'Triage updated: ${outcome.result.tier} '
      '(${outcome.result.score.round()} pts)'
      '${note != null ? ' — $note' : ''}',
    );
  }

  Future<void> _onRssiWindowClosed() async {
    try {
      final now = DateTime.now();
      _helperRssiMap.removeWhere((helperId, _) {
        final last = _deliveredTo[helperId];
        return last != null && now.difference(last) < _helperCooldown;
      });

      if (_helperRssiMap.isEmpty) {
        if (_stopped) return;
        // Keep listening — a single failed/empty window used to give up
        // permanently, leaving the Victim stuck broadcasting with nothing
        // ever acting on a late-arriving ACK. Re-arm and keep trying for as
        // long as Victim mode stays active.
        _emit('No Helper ACKs received in RSSI window — still listening…');
        _rearm();
        return;
      }
      final bestHelper = _helperRssiMap.entries.reduce(
        (a, b) => a.value > b.value ? a : b,
      );
      _emit('Selected Helper ${bestHelper.key} (rssi=${bestHelper.value})');

      final sent = await _tryDeliverBundle(bestHelper.key);
      if (sent) {
        _deliveredTo[bestHelper.key] = DateTime.now();
        _helperRssiMap.remove(bestHelper.key);
        // Pushed to an AP-joined host while yielding — return to the normal
        // discoverable group-owner state so other (free) Helpers can still pull.
        if (_yieldingToHost) {
          unawaited(
            _revertHostYield('Sent to the nearby helper — back to wait mode'),
          );
        }
      } else {
        // The helper that ACKed may have moved out of range or wasn't
        // actually reachable over Wi-Fi Direct — drop it so the next window
        // doesn't immediately retry against stale data, but don't put it on
        // the success cooldown either.
        _helperRssiMap.remove(bestHelper.key);
        // A passive group-owner Victim ALWAYS returns false here — it never
        // "sends", it waits to be pulled — so saying "will retry the handoff"
        // every cycle read like a repeated failure when nothing had failed.
        // Only the active push paths can actually fail and warrant that line.
        if (!_isAutonomousGroupOwner) {
          _emit('Will retry Wi-Fi Direct handoff…');
        }
      }
      if (!_stopped) _rearm();
    } catch (e) {
      _emit('Bundle transmission failed: $e');
      if (!_stopped) _rearm();
    }
  }

  void _rearm() {
    _rssiWindowTimer = Timer(
      const Duration(milliseconds: bleRssiCollectionWindowMs),
      _onRssiWindowClosed,
    );
  }

  /// Discover the Wi-Fi Direct peer, connect, and send the bundle. Returns
  /// false (not an exception) for the "nothing worked, but nothing broke
  /// either" cases — no peers found, or connect failed — so the caller can
  /// retry instead of silently doing nothing forever (the previous behaviour:
  /// a Helper ACK had been received fine, but the Victim just gave up at the
  /// very next step and never told anyone).
  ///
  /// Does NOT stop BLE advertising on success any more — one helper picking
  /// up the bundle doesn't mean no one else should. The Victim keeps
  /// broadcasting (subject to the per-helper cooldown above) until the user
  /// manually leaves Victim mode.
  Future<bool> _tryDeliverBundle(String helperDeviceId) async {
    if (_isAutonomousGroupOwner) {
      // This device is a discoverable group owner — it must NOT run its own
      // discover/connect/disconnect (disconnect() would remove the group and
      // make it invisible again). The Helper discovers this GO, joins as
      // client, and pulls from the already-running server. Nothing to do here
      // but stay advertised and keep serving.
      _emit('Waiting for a Helper to pull the bundle (group owner — passive)');
      return false;
    }
    if (!_canInitiateWifiDirect) {
      _cyclesSinceCapabilityProbe++;
      if (_cyclesSinceCapabilityProbe < _retryProbeEveryNCycles) {
        // Already learned this device can't discover peers itself — don't
        // keep hammering a dead end every retry cycle. The Helper sees
        // needsPull via the BLE status characteristic and connects instead;
        // this device just needs to stay advertised and keep its server +
        // cached bundle ready (already done in startVictimMode).
        _emit('Waiting for a Helper to pull the bundle (cannot self-initiate)');
        return false;
      }
      // Every Nth cycle, test anyway — see the class-level comment on
      // _retryProbeEveryNCycles for why a flag with no way back is a trap.
      _cyclesSinceCapabilityProbe = 0;
      _emit('Re-testing Wi-Fi Direct initiator capability…');
    }

    final lastAttempt = _connectedRecentlyAt[helperDeviceId];
    if (lastAttempt != null &&
        DateTime.now().difference(lastAttempt) <
            _effectiveAttemptCooldown(helperDeviceId)) {
      return false;
    }

    final peers = await wifiDirectManager.discoverPeers();
    if (peers.isEmpty) {
      await _recordDiscoveryOutcome(succeeded: false);
      _emit('No Wi-Fi Direct peers discovered');
      // Same reset HelperController's discovery paths now do — a stuck
      // P2P discovery state never otherwise gets a disconnect()/
      // stopPeerDiscovery() call on this path, since that used to only
      // happen after a connect attempt, not after discovery itself comes
      // up empty.
      await wifiDirectManager.disconnect();
      return false;
    }
    await _recordDiscoveryOutcome(succeeded: true);
    final peerAddress = peers.first['deviceAddress'] as String;
    // Record the attempt NOW, before connect() — the OS dialog fires on the
    // connect() call itself, and the call commonly TIMES OUT below (returning
    // null) without ever forming a connection. Setting it here (not after a
    // formed connection) is the whole point: it's the only place that runs on
    // both the timed-out and the failed-later paths, so a Helper this device
    // can't pair with isn't re-dialled/re-prompted every ~8s RSSI window. See
    // _attemptCooldown.
    _connectedRecentlyAt[helperDeviceId] = DateTime.now();
    final connectionInfo = await wifiDirectManager.connectToHelper(
      peerAddress,
      myDeviceId: deviceId ?? '',
    );
    if (connectionInfo == null) {
      _emit('Could not connect to Wi-Fi Direct peer');
      // Helper didn't pair — grow its backoff so we don't keep re-prompting.
      _attemptFailStreak[helperDeviceId] =
          (_attemptFailStreak[helperDeviceId] ?? 0) + 1;
      // A failed connect() (commonly NO_GROUP) can still leave the P2P stack
      // mid-negotiation — confirmed on real hardware: the very next
      // discoverPeers() call came back BUSY (reason=2) because of this.
      // Only the success path used to clean up; do it here too so the next
      // retry starts from an actually-clean slate instead of colliding.
      await wifiDirectManager.disconnect();
      return false;
    }
    // Connection formed — Helper is reachable, reset its backoff.
    _attemptFailStreak.remove(helperDeviceId);

    final isGroupOwner = connectionInfo['isGroupOwner'] as bool? ?? false;
    if (isGroupOwner) {
      // groupOwnerIntent only biases negotiation, it doesn't guarantee an
      // outcome — confirmed on real hardware: this device's own connect()
      // call can still leave IT as group owner instead of $helperDeviceId.
      // groupOwnerAddress in that case is this device's OWN address, so
      // blindly sendBundle()-ing to it was a self-loop: this device's native
      // server (which always has the bundle cached) just served it straight
      // back to itself, logged as a false "transmitted" success, while
      // $helperDeviceId — now the actual P2P client — never received
      // anything. The Helper's own reactive connectionFormedStream listener
      // notices it unexpectedly became a client and pulls from this
      // already-running, already-cached server instead.
      _emit(
        'Connected as group owner instead of $helperDeviceId — waiting for it to pull',
      );
      return false;
    }
    final groupOwnerAddress = connectionInfo['groupOwnerAddress'] as String;
    final sent = await wifiDirectManager.sendBundle(
      groupOwnerAddress,
      _bundle!.toJson(),
    );
    if (sent) {
      _emit('Bundle ${_bundle!.bundleId} transmitted to $helperDeviceId');
    }
    // Tear down the Wi-Fi Direct group either way — leaving it formed was
    // letting stale group state carry into the next connect() attempt
    // (a likely contributor to the groupFormed=false races seen on retry).
    // Each delivery attempt now starts from a clean slate.
    await wifiDirectManager.disconnect();
    return sent;
  }

  Future<void> _loadInitiatorCapability() async {
    final prefs = await SharedPreferences.getInstance();
    final canInitiate = prefs.getBool(_canInitiateKey);
    final testedAtMs = prefs.getInt(_capabilityTestedAtKey);
    if (canInitiate == false && testedAtMs != null) {
      final testedAt = DateTime.fromMillisecondsSinceEpoch(testedAtMs);
      if (DateTime.now().difference(testedAt) < _capabilityTtl) {
        _canInitiateWifiDirect = false;
        _emit(
          'Learned this device cannot initiate Wi-Fi Direct (last confirmed '
          '${DateTime.now().difference(testedAt).inHours}h ago) — will wait '
          'for Helpers to pull instead',
        );
        return;
      }
      // Stale — give it another fair try; the cause may have been transient.
    }
    // Defaults to pull mode (false), not push mode — see the class-level
    // comment above _canInitiateKey for why: a fresh Victim-initiated
    // discoverPeers() has consistently failed its very first try on every
    // device tested so far, so starting optimistic just buys a guaranteed
    // ~12-18s loss before falling back anyway. The self-heal probe (see
    // _retryProbeEveryNCycles) still runs periodically from here exactly
    // the same as if this had been set by a real recorded failure, so push
    // mode is never permanently ruled out for hardware that genuinely can.
    _canInitiateWifiDirect = false;
  }

  /// Only a genuinely-empty *completed* discoverPeers() poll counts toward
  /// the capability verdict — a thrown exception (LOCATION_DISABLED,
  /// P2P_DISABLED, PERMISSION_DENIED, etc.) is a separate, already-banner-
  /// surfaced configuration problem, not evidence about this chipset.
  Future<void> _recordDiscoveryOutcome({required bool succeeded}) async {
    if (succeeded) {
      _consecutiveGenuineFailures = 0;
      if (!_canInitiateWifiDirect) {
        // A periodic probe (see _tryDeliverBundle) just succeeded despite
        // the flag — the earlier failure was transient, not a real chipset
        // limit. Clear it immediately rather than waiting out the TTL.
        _canInitiateWifiDirect = true;
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_canInitiateKey);
        await prefs.remove(_capabilityTestedAtKey);
        await bleManager.setNeedsPull(false);
        _emit(
          'Wi-Fi Direct initiation works again — cleared the cannot-initiate flag',
        );
      }
      return;
    }
    if (!wifiDirectManager.lastDiscoveryGenuinelyEmpty) return;
    _consecutiveGenuineFailures++;
    if (_consecutiveGenuineFailures < _maxConsecutiveGenuineFailures) return;

    _canInitiateWifiDirect = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_canInitiateKey, false);
    await prefs.setInt(
      _capabilityTestedAtKey,
      DateTime.now().millisecondsSinceEpoch,
    );
    await bleManager.setNeedsPull(true);
    _emit(
      'This device cannot initiate Wi-Fi Direct discovery ($_consecutiveGenuineFailures '
      'consecutive empty results) — flagged to Helpers, switching to pull mode',
    );
  }

  Future<String> _loadOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(deviceIdPrefKey);
    if (existing != null) return existing;
    final generated = const Uuid().v4();
    await prefs.setString(deviceIdPrefKey, generated);
    return generated;
  }

  Future<void> _cancelSubs() async {
    await _ackSub?.cancel();
    await _bleStatusSub?.cancel();
    await _wifiStatusSub?.cancel();
    await _connectionFormedSub?.cancel();
    await _bundleDeliveredSub?.cancel();
  }

  Future<void> stopVictimMode() async {
    try {
      _stopped = true;
      _rssiWindowTimer?.cancel();
      _radioWatchdog?.cancel();
      _yieldFallbackTimer?.cancel();
      _triageTimer?.cancel();
      await _sensorEngine.stop();
      await _cancelSubs();
      await bleManager.stopAdvertising();
      await bleManager.setNeedsPull(false);
      await wifiDirectManager.setLocalBundle(null);
      await wifiDirectManager.stopServer();
      await wifiDirectManager.disconnect();
      _emit('Victim mode stopped');
    } catch (e) {
      _emit('Victim mode stop failed: $e');
    }
  }

  void dispose() {
    _rssiWindowTimer?.cancel();
    _radioWatchdog?.cancel();
    _yieldFallbackTimer?.cancel();
    _triageTimer?.cancel();
    _sensorEngine.dispose();
    _ackSub?.cancel();
    _bleStatusSub?.cancel();
    _wifiStatusSub?.cancel();
    _connectionFormedSub?.cancel();
    _bundleDeliveredSub?.cancel();
    bleManager.dispose();
    wifiDirectManager.dispose();
    _statusController.close();
  }
}
