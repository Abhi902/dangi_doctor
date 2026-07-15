import 'package:test/test.dart';

import 'package:dangi_doctor/crawler/adb_runner.dart';

void main() {
  group('parseWmSize', () {
    test('parses physical size', () {
      expect(parseWmSize('Physical size: 1080x2400\n'),
          {'width': 1080, 'height': 2400});
    });

    test('prefers Override size when present — taps operate in it', () {
      const out = 'Physical size: 1440x3120\nOverride size: 1080x2340\n';
      expect(parseWmSize(out), {'width': 1080, 'height': 2340});
    });

    test('falls back to a sane default on garbage', () {
      expect(parseWmSize('error: no devices'),
          {'width': 1080, 'height': 2400});
    });
  });

  group('parseForegroundPackage', () {
    test('parses mResumedActivity package', () {
      const out =
          '  mResumedActivity: ActivityRecord{a1b2 u0 com.dangi.app/.MainActivity t42}';
      expect(parseForegroundPackage(out), 'com.dangi.app');
    });

    test('falls back to mCurrentFocus', () {
      const out =
          '  mCurrentFocus=Window{f00 u0 com.example.myapp/com.example.myapp.MainActivity}';
      expect(parseForegroundPackage(out), 'com.example.myapp');
    });

    test('returns null on garbage', () {
      expect(parseForegroundPackage('nothing useful here'), isNull);
    });

    test('recognizes launcher packages', () {
      expect(isLauncherPackage('com.google.android.apps.nexuslauncher'), isTrue);
      expect(isLauncherPackage('com.android.launcher3'), isTrue);
      expect(isLauncherPackage('com.dangi.app'), isFalse);
      expect(isLauncherPackage(null), isFalse);
    });
  });

  group('escapeAdbShellText', () {
    test('encodes spaces the way `input text` expects', () {
      expect(escapeAdbShellText('hello world'), 'hello%s%sworld'
          .replaceFirst('%s%s', '%s')); // one space → one %s
    });

    test('escapes device-shell metacharacters', () {
      final out = escapeAdbShellText(r"O'Brien & co $(reboot) `id`;|<>");
      // Nothing may remain unescaped that the device shell would interpret.
      for (final ch in ["'", '&', r'$', '`', ';', '|', '<', '>', '(', ')']) {
        expect(out.contains('\\$ch'), isTrue,
            reason: '$ch must be backslash-escaped, got: $out');
      }
    });
  });
}
