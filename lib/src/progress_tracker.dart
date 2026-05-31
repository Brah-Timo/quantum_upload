import 'dart:async';
import 'dart:math' as math;

/// Tracks upload progress in real-time and broadcasts measurements
/// through a [Stream].
///
/// Maintains running totals for bytes uploaded, calculates a smoothed
/// speed estimate using an exponential moving average (EMA), and
/// derives an estimated time of arrival (ETA).
///
/// ## Usage
///
/// ```dart
/// final tracker = ProgressTracker(totalBytes: fileSize);
/// tracker.start();
///
/// tracker.progressStream.listen((snapshot) {
///   print('${snapshot.percent.toStringAsFixed(1)}% '
///         '@ ${snapshot.speedMbps} MB/s  '
///         'ETA ${snapshot.etaFormatted}');
/// });
///
/// // After each chunk:
/// tracker.addBytes(chunkSizeBytes);
///
/// await tracker.dispose();
/// ```
class ProgressTracker {
  // ── Configuration ──────────────────────────────────────────────────────────

  /// Total file size in bytes. Set once at construction.
  final int totalBytes;

  /// Smoothing factor for the exponential moving average speed.
  ///
  /// Range: `(0, 1)`. Higher values make the speed estimate react faster
  /// to changes; lower values smooth out short-lived spikes.
  /// Default: `0.2` (gentle smoothing).
  final double emaAlpha;

  // ── Internal state ─────────────────────────────────────────────────────────

  int _uploadedBytes = 0;
  DateTime? _startTime;
  DateTime? _lastTick;

  /// EMA-smoothed upload speed in bytes/s.
  double _smoothedSpeedBps = 0;

  final StreamController<ProgressSnapshot> _controller =
      StreamController<ProgressSnapshot>.broadcast();

  // ── Constructor ────────────────────────────────────────────────────────────

  ProgressTracker({
    required this.totalBytes,
    this.emaAlpha = 0.2,
  }) : assert(totalBytes > 0, 'totalBytes must be positive'),
       assert(emaAlpha > 0 && emaAlpha < 1, 'emaAlpha must be in (0, 1)');

  // ── Public API ─────────────────────────────────────────────────────────────

  /// A broadcast stream of [ProgressSnapshot] objects.
  ///
  /// Emits one snapshot after each call to [addBytes].
  /// Does not emit until [start] has been called.
  Stream<ProgressSnapshot> get progressStream => _controller.stream;

  /// Current progress in the range `[0.0, 100.0]`.
  double get currentPercent =>
      ((_uploadedBytes / totalBytes) * 100.0).clamp(0.0, 100.0);

  /// Instantaneous EMA-smoothed speed in bytes/s.
  double get speedBps => _smoothedSpeedBps;

  /// ETA in seconds. Returns [double.infinity] before any bytes are sent.
  double get etaSeconds {
    if (_smoothedSpeedBps <= 0) return double.infinity;
    final remaining = totalBytes - _uploadedBytes;
    return remaining / _smoothedSpeedBps;
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  /// Marks the start of the upload and begins time accounting.
  ///
  /// Call once before the first [addBytes].
  void start() {
    _startTime = DateTime.now();
    _lastTick = _startTime;
  }

  /// Notifies the tracker that [bytes] more bytes have been uploaded.
  ///
  /// Updates internal counters, recalculates EMA speed, and emits a
  /// [ProgressSnapshot] on [progressStream].
  ///
  /// Calling before [start] is allowed (for pre-seeding resumed progress)
  /// but speed will be zero until [start] is called.
  void addBytes(int bytes) {
    assert(bytes >= 0, 'bytes must be non-negative');

    final now = DateTime.now();
    _uploadedBytes += bytes;

    // Update EMA speed only if we have timing information.
    if (_lastTick != null && bytes > 0) {
      final elapsedMs = now.difference(_lastTick!).inMilliseconds;
      if (elapsedMs > 0) {
        final instantSpeed = bytes / (elapsedMs / 1000.0);
        _smoothedSpeedBps = _smoothedSpeedBps == 0
            ? instantSpeed
            : _ema(_smoothedSpeedBps, instantSpeed);
      }
    }

    _lastTick = now;

    if (!_controller.isClosed) {
      _controller.add(_buildSnapshot());
    }
  }

  /// Closes the [progressStream]. Must be called when the upload ends.
  Future<void> dispose() async {
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  // ── Snapshot builder ───────────────────────────────────────────────────────

  ProgressSnapshot _buildSnapshot() => ProgressSnapshot(
        percent: currentPercent,
        uploadedBytes: _uploadedBytes,
        totalBytes: totalBytes,
        speedBps: _smoothedSpeedBps,
        etaSeconds: etaSeconds,
        elapsed: _startTime != null
            ? DateTime.now().difference(_startTime!)
            : Duration.zero,
      );

  // ── EMA helper ─────────────────────────────────────────────────────────────

  double _ema(double previous, double current) =>
      emaAlpha * current + (1 - emaAlpha) * previous;
}

// ─────────────────────────────────────────────────────────────────────────────
// Immutable snapshot emitted on every progress update
// ─────────────────────────────────────────────────────────────────────────────

/// An immutable snapshot of the upload's state at a single point in time.
///
/// Emitted by [ProgressTracker.progressStream] after each [addBytes] call.
class ProgressSnapshot {
  /// Current progress in the range `[0.0, 100.0]`.
  final double percent;

  /// Bytes uploaded so far.
  final int uploadedBytes;

  /// Total bytes to upload.
  final int totalBytes;

  /// EMA-smoothed upload speed in bytes/s.
  final double speedBps;

  /// Estimated seconds remaining. [double.infinity] if speed is unknown.
  final double etaSeconds;

  /// Wall-clock time elapsed since [ProgressTracker.start].
  final Duration elapsed;

  const ProgressSnapshot({
    required this.percent,
    required this.uploadedBytes,
    required this.totalBytes,
    required this.speedBps,
    required this.etaSeconds,
    required this.elapsed,
  });

  // ── Derived helpers ────────────────────────────────────────────────────────

  /// Speed formatted as `"X.XX MB/s"`.
  String get speedMbps =>
      '${(speedBps / (1024 * 1024)).toStringAsFixed(2)} MB/s';

  /// Speed formatted as `"X.X KB/s"` for slow connections.
  String get speedKbps =>
      '${(speedBps / 1024).toStringAsFixed(1)} KB/s';

  /// ETA formatted as `"mm:ss"` or `"--:--"` when unknown.
  String get etaFormatted {
    if (etaSeconds.isInfinite || etaSeconds.isNaN) return '--:--';
    final total = etaSeconds.round();
    final mm = total ~/ 60;
    final ss = total % 60;
    return '${mm.toString().padLeft(2, '0')}:${ss.toString().padLeft(2, '0')}';
  }

  /// `uploadedBytes` formatted as `"X.XX MiB"` or `"X.X KiB"`.
  String get uploadedFormatted => _formatBytes(uploadedBytes);

  /// `totalBytes` formatted as `"X.XX MiB"` or `"X.X KiB"`.
  String get totalFormatted => _formatBytes(totalBytes);

  /// Remaining bytes to upload.
  int get remainingBytes => math.max(0, totalBytes - uploadedBytes);

  String _formatBytes(int b) {
    if (b >= 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(2)} MiB';
    } else if (b >= 1024) {
      return '${(b / 1024).toStringAsFixed(1)} KiB';
    }
    return '${b} B';
  }

  @override
  String toString() =>
      'ProgressSnapshot('
      '${percent.toStringAsFixed(1)}%, '
      '$uploadedFormatted / $totalFormatted, '
      '$speedMbps, '
      'ETA $etaFormatted'
      ')';
}

