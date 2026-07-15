import 'dart:io';

import 'package:test/test.dart';

import 'package:dangi_doctor/src/cli_config.dart';

void main() {
  group('parseCliArgs', () {
    test('defaults: interactive run, nothing overridden', () {
      final config = parseCliArgs([]);
      expect(config.showHelp, isFalse);
      expect(config.showVersion, isFalse);
      expect(config.noAi, isFalse);
      expect(config.project, isNull);
      expect(config.vmUrl, isNull);
      expect(config.device, isNull);
    });

    test('parses all supported options', () {
      final config = parseCliArgs([
        '--project',
        '/tmp/my_app',
        '--vm-url',
        'ws://127.0.0.1:8181/abc=/ws',
        '--device',
        'emulator-5554',
        '--no-ai',
      ]);
      expect(config.project, '/tmp/my_app');
      expect(config.vmUrl, 'ws://127.0.0.1:8181/abc=/ws');
      expect(config.device, 'emulator-5554');
      expect(config.noAi, isTrue);
    });

    test('-h and --version set their flags', () {
      expect(parseCliArgs(['-h']).showHelp, isTrue);
      expect(parseCliArgs(['--version']).showVersion, isTrue);
    });

    test('unknown flags throw a FormatException with usage available', () {
      expect(() => parseCliArgs(['--bogus']), throwsFormatException);
      expect(usage(), contains('--project'));
    });
  });

  group('validateProjectDir', () {
    test('rejects a nonexistent directory', () {
      final error = validateProjectDir('/definitely/not/a/dir');
      expect(error, isNotNull);
      expect(error, contains('not found'));
    });

    test('rejects a directory without pubspec.yaml', () {
      final dir = Directory.systemTemp.createTempSync('dangi_cli_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final error = validateProjectDir(dir.path);
      expect(error, isNotNull);
      expect(error, contains('pubspec.yaml'));
    });

    test('accepts a Flutter project directory', () {
      final dir = Directory.systemTemp.createTempSync('dangi_cli_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/pubspec.yaml').writeAsStringSync('''
name: some_app
dependencies:
  flutter:
    sdk: flutter
''');
      expect(validateProjectDir(dir.path), isNull);
    });
  });
}
