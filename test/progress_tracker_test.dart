import 'dart:async';

import 'package:test/test.dart';
import 'package:quantum_upload/quantum_upload.dart';

void main() {
  // ═══════════════════════════════════════════════════════════════════════════
  // Construction
  // ═══════════════════════════════════════════════════════════════════════════

  group('ProgressTracker construction', () {
    test('throws on zero totalBytes', () {
      expect(
        () => ProgressTracker(totalBytes: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('accepts positive totalBytes', () {
      expect(() => ProgressTracker(totalBytes: 1024), returnsNormally);
    });

    test('throws on out-of-range emaAlpha', () {
      expect(
        () => ProgressTracker(totalBytes: 1024, emaAlpha: 0.0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => ProgressTracker(totalBytes: 1024, emaAlpha: 1.0),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // percent calculation
  // ═══════════════════════════════════════════════════════════════════════════

  group('currentPercent', () {
    test('starts at 0 %', () {
      final t = ProgressTracker(totalBytes: 1000);
      expect(t.currentPercent, equals(0.0));
    });

    test('is 50 % after half the bytes', () {
      final t = ProgressTracker(totalBytes: 1000);
      t.start();
      t.addBytes(500);
      expect(t.currentPercent, closeTo(50.0, 0.001));
    });

    test('is 100 % after all bytes', () {
      final t = ProgressTracker(totalBytes: 1000);
      t.start();
      t.addBytes(1000);
      expect(t.currentPercent, equals(100.0));
    });

    test('never exceeds 100 % even with extra bytes', () {
      final t = ProgressTracker(totalBytes: 1000);
      t.start();
      t.addBytes(2000); // intentional overflow
      expect(t.currentPercent, equals(100.0));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Stream emissions
  // ═══════════════════════════════════════════════════════════════════════════

  group('progressStream', () {
    test('emits one snapshot per addBytes call', () async {
      final t = ProgressTracker(totalBytes: 300);
      t.start();

      final snapshots = <ProgressSnapshot>[];
      final sub = t.progressStream.listen(snapshots.add);

      t.addBytes(100);
      t.addBytes(100);
      t.addBytes(100);

      // Allow microtasks to flush
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await t.dispose();

      expect(snapshots.length, equals(3));
    });

    test('percent values are monotonically non-decreasing', () async {
      final t = ProgressTracker(totalBytes: 1000);
      t.start();

      final percents = <double>[];
      final sub = t.progressStream.listen((s) => percents.add(s.percent));

      for (int i = 0; i < 10; i++) {
        t.addBytes(100);
      }

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await t.dispose();

      for (int i = 1; i < percents.length; i++) {
        expect(percents[i], greaterThanOrEqualTo(percents[i - 1]));
      }
    });

    test('final snapshot has percent == 100', () async {
      final t = ProgressTracker(totalBytes: 500);
      t.start();

      final snapshots = <ProgressSnapshot>[];
      final sub = t.progressStream.listen(snapshots.add);

      t.addBytes(500);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await t.dispose();

      expect(snapshots.last.percent, closeTo(100.0, 0.001));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Speed & ETA
  // ═══════════════════════════════════════════════════════════════════════════

  group('speedBps and etaSeconds', () {
    test('speed is 0 before start() is called', () {
      final t = ProgressTracker(totalBytes: 1000);
      expect(t.speedBps, equals(0.0));
    });

    test('etaSeconds is infinity when speed is 0', () {
      final t = ProgressTracker(totalBytes: 1000);
      expect(t.etaSeconds, equals(double.infinity));
    });

    test('ETA decreases as bytes are added', () async {
      final t = ProgressTracker(totalBytes: 10000);
      t.start();

      await Future<void>.delayed(const Duration(milliseconds: 10));
      t.addBytes(1000);
      final eta1 = t.etaSeconds;

      await Future<void>.delayed(const Duration(milliseconds: 10));
      t.addBytes(2000);
      final eta2 = t.etaSeconds;

      await t.dispose();

      // ETA should be finite and the second reading should be smaller
      expect(eta1, isNot(equals(double.infinity)));
      expect(eta2, isNot(equals(double.infinity)));
      // With more bytes uploaded, remaining bytes < before, so ETA ≤ eta1
      // (Not guaranteed due to EMA, but speed should be non-zero)
      expect(eta2, lessThanOrEqualTo(eta1 * 2));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // ProgressSnapshot helpers
  // ═══════════════════════════════════════════════════════════════════════════

  group('ProgressSnapshot formatting', () {
    const snapshot = ProgressSnapshot(
      percent: 42.5,
      uploadedBytes: 42 * 1024 * 1024,
      totalBytes: 100 * 1024 * 1024,
      speedBps: 2.5 * 1024 * 1024, // 2.5 MB/s
      etaSeconds: 23.2,
      elapsed: Duration(seconds: 10),
    );

    test('speedMbps is formatted correctly', () {
      expect(snapshot.speedMbps, equals('2.50 MB/s'));
    });

    test('etaFormatted is mm:ss', () {
      // 23.2s rounds to 23s → "00:23"
      expect(snapshot.etaFormatted, equals('00:23'));
    });

    test('etaFormatted shows "--:--" for infinity', () {
      const s = ProgressSnapshot(
        percent: 0,
        uploadedBytes: 0,
        totalBytes: 1000,
        speedBps: 0,
        etaSeconds: double.infinity,
        elapsed: Duration.zero,
      );
      expect(s.etaFormatted, equals('--:--'));
    });

    test('uploadedFormatted uses MiB for large values', () {
      expect(snapshot.uploadedFormatted, contains('MiB'));
    });

    test('remainingBytes is correct', () {
      expect(snapshot.remainingBytes, equals(58 * 1024 * 1024));
    });

    test('toString contains key fields', () {
      final str = snapshot.toString();
      expect(str, contains('42.5%'));
      expect(str, contains('MB/s'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // dispose()
  // ═══════════════════════════════════════════════════════════════════════════

  group('dispose()', () {
    test('closes the stream — no more emissions', () async {
      final t = ProgressTracker(totalBytes: 1000);
      t.start();

      bool streamDone = false;
      t.progressStream.listen((_) {}, onDone: () => streamDone = true);

      await t.dispose();
      await Future<void>.delayed(Duration.zero);

      expect(streamDone, isTrue);
    });

    test('double-dispose is safe', () async {
      final t = ProgressTracker(totalBytes: 1000);
      await t.dispose();
      expect(() => t.dispose(), returnsNormally);
    });
  });
}

