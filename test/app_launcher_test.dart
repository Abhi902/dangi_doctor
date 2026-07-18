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
}
