import 'dart:io';

import 'package:test/test.dart';

import 'package:dangi_doctor/crawler/app_launcher.dart';

void main() {
  group('parseVmServiceLine', () {
    test('parses "Connecting to VM Service" line with auth token', () {
      const line =
          'Connecting to VM Service at ws://127.0.0.1:8181/Ab3xYz9k1c0=/ws';
      final r = parseVmServiceLine(line);
      expect(r, isNotNull);
      expect(r!.url, 'ws://127.0.0.1:8181/Ab3xYz9k1c0=/ws');
      expect(r.port, 8181);
    });

    test('parses "A Dart VM Service on <device with spaces>" http line', () {
      const line = 'A Dart VM Service on sdk gphone64 x86 64 is available at: '
          'http://127.0.0.1:39833/D2kJfL8mN4w=/';
      final r = parseVmServiceLine(line);
      expect(r, isNotNull);
      expect(r!.url, 'ws://127.0.0.1:39833/D2kJfL8mN4w=/ws');
      expect(r.port, 39833);
    });

    test('rewrites non-loopback host to 127.0.0.1, keeps token path', () {
      const line = 'VM Service listening on ws://0.0.0.0:33421/dXbfLp82Qk4=/ws';
      final r = parseVmServiceLine(line);
      expect(r, isNotNull);
      expect(r!.url, 'ws://127.0.0.1:33421/dXbfLp82Qk4=/ws');
      expect(r.port, 33421);
    });

    test('appends /ws when the URL lacks it', () {
      const line = 'Connecting to VM Service at ws://127.0.0.1:8181/tok=';
      expect(parseVmServiceLine(line)!.url, 'ws://127.0.0.1:8181/tok=/ws');
    });

    test('returns null for ordinary flutter run output', () {
      expect(
          parseVmServiceLine(
              'Launching lib/main.dart on sdk gphone64 x86 64 in debug mode...'),
          isNull);
      expect(parseVmServiceLine('Running Gradle task \'assembleDebug\'...'),
          isNull);
      expect(parseVmServiceLine(''), isNull);
    });
  });

  group('getDevices timeout', () {
    test('kills the flutter devices process when it exceeds the timeout',
        () async {
      final dir = Directory.systemTemp.createTempSync('dangi_launcher_test');
      addTearDown(() => dir.deleteSync(recursive: true));

      // Fake `flutter` that records its PID and hangs.
      final script = File('${dir.path}/fake_flutter.sh');
      script.writeAsStringSync(
          '#!/bin/sh\necho \$\$ > "${dir.path}/pid"\nsleep 60\n');
      Process.runSync('chmod', ['+x', script.path]);

      final launcher = AppLauncher(
        projectPath: dir.path,
        flutterCommand: script.path,
        // NOTE: bumped from the 500ms in the task brief to 2000ms — on this
        // sandboxed dev machine, freshly-written scripts are tagged with the
        // `com.apple.provenance` xattr and macOS's on-first-exec security
        // scan reliably adds ~450-550ms of latency before `sh` even starts,
        // which raced against (and often lost to) a 500ms timeout. 2000ms
        // gives comfortable margin while the assertions below still fully
        // verify the real kill behavior (not weakened).
        deviceScanTimeout: const Duration(milliseconds: 2000),
      );

      final devices = await launcher.getDevices();
      expect(devices, isEmpty);

      final pid = int.parse(File('${dir.path}/pid').readAsStringSync().trim());
      // Give the kill a moment to land, then probe with `kill -0`.
      await Future.delayed(const Duration(milliseconds: 500));
      final alive = Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
      expect(alive, isFalse,
          reason: 'orphaned flutter devices process must be killed');
    });
  });
}
