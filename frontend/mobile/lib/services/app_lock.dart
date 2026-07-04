import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Optional device-lockscreen (PIN / pattern / password / biometric) gate for
/// two sensitive actions: editing medical info and quitting victim mode.
///
/// Fail-open by design: if the device has no lockscreen enrolled (so it cannot
/// authenticate), the action is allowed. This avoids trapping a user in victim
/// mode or permanently locking their own medical edits when no credential
/// exists to satisfy the prompt.
class AppLock {
  AppLock._();

  static const _kMedicalKey = 'lock_medical_edit';
  static const _kExitVictimKey = 'lock_exit_victim';

  /// Require auth before editing medical info (from the dashboard).
  static final ValueNotifier<bool> requireMedicalEdit = ValueNotifier(false);

  /// Require auth before leaving victim mode.
  static final ValueNotifier<bool> requireExitVictim = ValueNotifier(false);

  static final LocalAuthentication _auth = LocalAuthentication();

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    requireMedicalEdit.value = p.getBool(_kMedicalKey) ?? false;
    requireExitVictim.value = p.getBool(_kExitVictimKey) ?? false;
  }

  static Future<void> setRequireMedicalEdit(bool v) async {
    requireMedicalEdit.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kMedicalKey, v);
  }

  static Future<void> setRequireExitVictim(bool v) async {
    requireExitVictim.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kExitVictimKey, v);
  }

  /// Prompt the user. Returns true on success OR when the device cannot
  /// authenticate at all (fail-open). Returns false only on an explicit
  /// failed / cancelled prompt on a device that CAN authenticate.
  static Future<bool> authenticate(String reason) async {
    bool supported;
    try {
      supported = await _auth.isDeviceSupported();
    } catch (_) {
      supported = false;
    }
    if (!supported) return true; // fail-open: nothing to authenticate against

    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: false, // allow PIN / pattern / password fallback
          stickyAuth: true,
        ),
      );
    } catch (_) {
      // e.g. no credential enrolled after all, or a transient platform error.
      // Fail-open so the user is never locked out of these actions.
      return true;
    }
  }
}
