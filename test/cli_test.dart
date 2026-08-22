import 'dart:io';

import 'package:test/test.dart';

import 'package:dangi_doctor/src/cli_config.dart';

void main() {
  test('kDangiVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version:\s*(\S+)', multiLine: true)
        .firstMatch(pubspec)!
        .group(1);
    expect(kDangiVersion, version,
        reason: 'lib/src/cli_config.dart kDangiVersion and pubspec.yaml '
            'version must be bumped together.');
  });

  test('positional arguments are rejected with a FormatException', () {
    expect(() => parseCliArgs(['stray']), throwsFormatException);
    expect(() => parseCliArgs(['--no-ai', 'extra', 'args']),
        throwsFormatException);
  });

  test('--rescan flag parses and defaults to false', () {
    expect(parseCliArgs(['--rescan']).rescan, isTrue);
    expect(parseCliArgs([]).rescan, isFalse);
  });
}
