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

  group('pickVmPortFromProcNetTcp', () {
    // Real-shaped /proc/net/tcp: header + entries. 0xA28D=41613 (loopback
    // LISTEN), 0x829F=33439 (loopback LISTEN), 0x1F90=8080 (wildcard LISTEN,
    // must be ignored), one ESTABLISHED (state 01), one low port (0x0050=80).
    const fixture = '''
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:A28D 00000000:0000 0A 00000000:00000000 00:00000000 00000000 10190        0 3810203 1 0000000000000000 100 0 0 10 0
   1: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 2299841 1 0000000000000000 100 0 0 10 0
   2: 0100007F:829F 00000000:0000 0A 00000000:00000000 00:00000000 00000000 10190        0 3810377 1 0000000000000000 100 0 0 10 0
   3: 0100007F:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1834550 1 0000000000000000 100 0 0 10 0
   4: 0100007F:A28D 0100007F:D3A1 01 00000000:00000000 00:00000000 00000000 10190        0 3810442 1 0000000000000000 20 4 30 10 -1
''';

    test('finds loopback LISTEN ports and prefers the one nearest the hint',
        () {
      expect(pickVmPortFromProcNetTcp(fixture, hintPort: 33500), 33439);
      expect(pickVmPortFromProcNetTcp(fixture, hintPort: 41000), 41613);
    });

    test('ignores wildcard-bound, established, and privileged ports', () {
      const only = '''
   0: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1 1
   1: 0100007F:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 2 1
   2: 0100007F:A28D 0100007F:D3A1 01 00000000:00000000 00:00000000 00000000 10190        0 3 1
''';
      expect(pickVmPortFromProcNetTcp(only), isNull);
    });

    test('single candidate wins without a hint; garbage yields null', () {
      const single =
          '   0: 0100007F:A28D 00000000:0000 0A 00000000:00000000 00:00000000 00000000 10190        0 3810203 1';
      expect(pickVmPortFromProcNetTcp(single), 41613);
      expect(pickVmPortFromProcNetTcp(''), isNull);
      expect(pickVmPortFromProcNetTcp('cat: /proc/net/tcp: Permission denied'),
          isNull);
    });
  });
}
