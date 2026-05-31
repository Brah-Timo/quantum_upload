/// Abstract interface for persisting upload-session state.
///
/// `quantum_upload` uses this interface internally to read and write
/// session data. The default implementation is [SharedPrefsStorage], which
/// stores JSON strings in `SharedPreferences`.
///
/// ## Custom implementation
///
/// Provide your own [SessionStorage] when you need:
/// - **Encryption** (e.g. `flutter_secure_storage`)
/// - **Database-backed storage** (e.g. SQLite via `sqflite` or Drift)
/// - **In-memory storage** for tests (see [InMemorySessionStorage] below)
///
/// ```dart
/// class SecureSessionStorage implements SessionStorage {
///   final _storage = FlutterSecureStorage();
///
///   @override
///   Future<void> write(String key, String value) =>
///       _storage.write(key: key, value: value);
///
///   @override
///   Future<String?> read(String key) => _storage.read(key: key);
///
///   @override
///   Future<void> delete(String key) => _storage.delete(key: key);
///
///   @override
///   Future<bool> exists(String key) async =>
///       (await _storage.read(key: key)) != null;
///
///   @override
///   Future<List<String>> listKeys() async =>
///       (await _storage.readAll()).keys.toList();
///
///   @override
///   Future<void> clear() => _storage.deleteAll();
/// }
/// ```
///
/// Then inject it via [UploadConfig.storage]:
/// ```dart
/// final config = UploadConfig(
///   filePath : '…',
///   url      : Uri.parse('…'),
///   storage  : SecureSessionStorage(),
/// );
/// ```
abstract class SessionStorage {
  // ── CRUD ────────────────────────────────────────────────────────────────────

  /// Persists [value] under [key].
  ///
  /// [key] is the session ID; [value] is its JSON-encoded state.
  /// Overwrites any existing value silently.
  Future<void> write(String key, String value);

  /// Returns the value stored under [key], or `null` if absent.
  Future<String?> read(String key);

  /// Removes the entry for [key].
  ///
  /// No-op if [key] does not exist.
  Future<void> delete(String key);

  /// Returns `true` if [key] is present in the store.
  Future<bool> exists(String key);

  // ── Bulk operations ─────────────────────────────────────────────────────────

  /// Returns the list of all session-ID keys currently in the store.
  ///
  /// Useful for a "manage uploads" screen that shows all pending sessions.
  Future<List<String>> listKeys();

  /// Removes all session entries from the store.
  ///
  /// Use with care — this permanently deletes the ability to resume any
  /// in-progress upload.
  Future<void> clear();
}

// ─────────────────────────────────────────────────────────────────────────────
// In-memory implementation (useful for tests and mocking)
// ─────────────────────────────────────────────────────────────────────────────

/// A [SessionStorage] backed by an in-memory [Map].
///
/// **Not suitable for production** — all data is lost when the
/// [Uploader] object is disposed.
///
/// Use in unit tests to avoid touching disk:
/// ```dart
/// final uploader = Uploader(
///   config,
///   storage: InMemorySessionStorage(),
/// );
/// ```
class InMemorySessionStorage implements SessionStorage {
  final _store = <String, String>{};

  @override
  Future<void> write(String key, String value) async {
    _store[key] = value;
  }

  @override
  Future<String?> read(String key) async => _store[key];

  @override
  Future<void> delete(String key) async => _store.remove(key);

  @override
  Future<bool> exists(String key) async => _store.containsKey(key);

  @override
  Future<List<String>> listKeys() async => _store.keys.toList();

  @override
  Future<void> clear() async => _store.clear();

  /// Number of sessions currently held in memory.
  int get length => _store.length;
}

