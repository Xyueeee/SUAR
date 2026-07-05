/// Serialised access to the device microphone stream.
///
/// audio_streamer (the plugin under noise_meter) keeps ONE shared native
/// AudioRecord field and ONE `recording` flag across all sessions, but every
/// listen() spawns a fresh reader thread that overwrites that shared field.
/// If a new listen() overlaps the previous session's still-exiting thread,
/// the old thread ends up calling stop()/release() on the NEW thread's
/// recorder while it is blocked in AudioRecord.read() — a native SIGABRT
/// ('releaseBuffer: mUnreleased out of range') that kills the whole app and
/// cannot be caught from Dart. Confirmed on the S926B (Android 16) during a
/// quick Victim-mode exit → re-entry.
///
/// Fix: every mic subscription in the app goes through [guardedNoiseStream],
/// which waits out a spacing gap from the previous session's cancel before
/// subscribing. The gap only bites on rapid stop→start; a first start is
/// instant.
///
/// ponytail: sequential restarts only — two SIMULTANEOUS listeners (Victim
/// triage running while the Device Test mic row is open) still share the
/// plugin's single flag and would collide on cancel. Rare debug-only overlap;
/// add a session-owner lock here if it ever shows up in a crash log.
library;

import 'dart:async';

import 'package:noise_meter/noise_meter.dart';

DateTime _lastMicStop = DateTime.fromMillisecondsSinceEpoch(0);
const Duration _micRestartGap = Duration(milliseconds: 1500);

/// The noise_meter stream wrapped in the session guard: delays the subscribe
/// until the previous session's native thread must be gone, and stamps the
/// stop time on cancel/error so the NEXT session knows how long to wait.
Stream<NoiseReading> guardedNoiseStream() {
  StreamSubscription<NoiseReading>? sub;
  var cancelled = false;
  late final StreamController<NoiseReading> controller;
  controller = StreamController<NoiseReading>(
    onListen: () async {
      final wait = _micRestartGap - DateTime.now().difference(_lastMicStop);
      if (wait > Duration.zero) await Future.delayed(wait);
      if (cancelled) return;
      sub = NoiseMeter().noise.listen(
        controller.add,
        onError: (Object e, StackTrace s) {
          _lastMicStop = DateTime.now();
          controller.addError(e, s);
        },
        cancelOnError: true,
      );
    },
    onCancel: () async {
      cancelled = true;
      await sub?.cancel();
      _lastMicStop = DateTime.now();
    },
  );
  return controller.stream;
}
