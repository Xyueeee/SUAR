/// Serialised access to the device microphone stream.
///
/// audio_streamer (the plugin under noise_meter) keeps ONE shared native
/// AudioRecord field and ONE `recording` flag across all sessions, but every
/// listen() spawns a fresh reader thread that overwrites that shared field.
/// Overlapping readers can therefore release each other's recorder and crash
/// the process in native code.
library;

import 'dart:async';

import 'package:noise_meter/noise_meter.dart';

enum MicrophoneSessionOwner {
  victimTriage,
  deviceTest,
  triageLogic,
}

String microphoneOwnerLabel(MicrophoneSessionOwner owner) => switch (owner) {
      MicrophoneSessionOwner.victimTriage => 'Victim triage',
      MicrophoneSessionOwner.deviceTest => 'Device Test',
      MicrophoneSessionOwner.triageLogic => 'Triage Logic',
    };

class MicrophoneBusyException implements Exception {
  const MicrophoneBusyException(this.activeOwner);

  final MicrophoneSessionOwner activeOwner;

  String get message =>
      'Microphone is already in use by ${microphoneOwnerLabel(activeOwner)}.';

  @override
  String toString() => message;
}

DateTime _lastMicStop = DateTime.fromMillisecondsSinceEpoch(0);
const Duration _micRestartGap = Duration(milliseconds: 1500);
MicrophoneSessionOwner? _activeOwner;

MicrophoneSessionOwner? get activeMicrophoneOwner => _activeOwner;

String? microphoneBusyMessageFor(MicrophoneSessionOwner requester) {
  final owner = _activeOwner;
  if (owner == null) return null;
  return owner == requester
      ? '${microphoneOwnerLabel(requester)} is already using the microphone.'
      : 'Microphone is in use by ${microphoneOwnerLabel(owner)}. '
          'Stop that session before running this test.';
}

/// The noise_meter stream wrapped in both an exclusive owner lease and the
/// existing restart-spacing guard. Ownership is claimed synchronously so two
/// callers cannot both begin native AudioRecord sessions.
Stream<NoiseReading> guardedNoiseStream({
  required MicrophoneSessionOwner owner,
}) {
  final currentOwner = _activeOwner;
  if (currentOwner != null) {
    throw MicrophoneBusyException(currentOwner);
  }
  _activeOwner = owner;

  StreamSubscription<NoiseReading>? sub;
  var cancelled = false;
  var released = false;

  void release() {
    if (released) return;
    released = true;
    if (_activeOwner == owner) _activeOwner = null;
    _lastMicStop = DateTime.now();
  }

  late final StreamController<NoiseReading> controller;
  controller = StreamController<NoiseReading>(
    onListen: () async {
      try {
        final wait = _micRestartGap - DateTime.now().difference(_lastMicStop);
        if (wait > Duration.zero) await Future.delayed(wait);
        if (cancelled) {
          release();
          return;
        }
        sub = NoiseMeter().noise.listen(
          controller.add,
          onError: (Object e, StackTrace s) {
            release();
            if (!controller.isClosed) controller.addError(e, s);
          },
          onDone: () {
            release();
            if (!controller.isClosed) unawaited(controller.close());
          },
          cancelOnError: true,
        );
      } catch (e, s) {
        release();
        if (!controller.isClosed) {
          controller.addError(e, s);
          await controller.close();
        }
      }
    },
    onCancel: () async {
      cancelled = true;
      try {
        await sub?.cancel();
      } finally {
        release();
      }
    },
  );
  return controller.stream;
}
