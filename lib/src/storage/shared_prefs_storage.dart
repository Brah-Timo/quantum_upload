import 'package:shared_preferences/shared_preferences.dart';

import 'session_storage.dart';
import '../exceptions/session_exception.dart';

/// A [SessionStorage] implementation backed by `shared_preferences`.
///
/// Session data is stored as JSON strings under namespaced keys of the form:
/// ```
/// _quantum_upload_session_<sessionId>
/// ```
///
/// This implementation is suitable for most Flutter / Dart applications.
/// For apps that handle particularly sensitive data (e.g. signed upload
/// tokens embedded in session JSON), prefer `SecureSessionStorage` backed
/// by `flutter_secure_storage`.
///
/// ### Thread safety
/// `SharedPreferences` serialises all disk I/O through its own internal
/// lock, so concurrent read/write operations from multiple isolates
/// are safe.
///
/// ### Migration note
/// If you later switch to a different [SessionStorage] implementation,
/// call [migrateFrom] to move existing sessions without losing state.
class SharedPrefsStorage implements SessionStorage {
  static const String _prefix = '_quantum_upload_session_';

  // ── Helpers ─────────────────────────────────────────────────────────────────

  String _key(String sessionId) => '$_prefix$sessionId';

  // ── SessionStorage API ───────────────────────────────────────────────────────

  @override
  Future<void> write(String key, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(key), value);
    } catch (e, st) {
      throw SessionException(
        'Failed to write session "$key" to SharedPreferences.',
        sessionId: key,
        cause: e,
        stackTrace: st,
      );
    }
  }

  @override
  Future<String?> read(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_key(key));
    } catch (e, st) {
      throw SessionException(
        'Failed to read session "$key" from SharedPreferences.',
        sessionId: key,
        cause: e,
        stackTrace: st,
      );
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key(key));
    } catch (e, st) {
      throw SessionException(
        'Failed to delete session "$key" from SharedPreferences.',
        sessionId: key,
        cause: e,
        stackTrace: st,
      );
    }
  }

  @override
  Future<bool> exists(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.containsKey(_key(key));
    } catch (e, st) {
      throw SessionException(
        'Failed to check existence of session "$key" in SharedPreferences.',
        sessionId: key,
        cause: e,
        stackTrace: st,
      );
    }
  }

  @override
  Future<List<String>> listKeys() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs
          .getKeys()
          .where((k) => k.startsWith(_prefix))
          .map((k) => k.substring(_prefix.length))
          .toList();
    } catch (e, st) {
      throw SessionException(
        'Failed to list session keys from SharedPreferences.',
        cause: e,
        stackTrace: st,
      );
    }
  }

  @override
  Future<void> clear() async {
    try {
      final keys = await listKeys();
      final prefs = await SharedPreferences.getInstance();
      for (final k in keys) {
        await prefs.remove(_key(k));
      }
    } catch (e, st) {
      throw SessionException(
        'Failed to clear all sessions from SharedPreferences.',
        cause: e,
        stackTrace: st,
      );
    }
  }

  // ── Migration helper ─────────────────────────────────────────────────────────

  /// Copies all sessions from [source] into this store.
  ///
  /// Call this once when upgrading from a custom storage implementation:
  /// ```dart
  /// final newStorage = SharedPrefsStorage();
  /// await newStorage.migrateFrom(oldStorage);
  /// ```
  Future<void> migrateFrom(SessionStorage source) async {
    final keys = await source.listKeys();
    for (final key in keys) {
      final value = await source.read(key);
      if (value != null) {
        await write(key, value);
        await source.delete(key);
      }
    }
  }
}

