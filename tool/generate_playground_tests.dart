import 'dart:io';

import 'package:dangi_doctor/analysis/tree_analyser.dart';
import 'package:dangi_doctor/generator/test_generator.dart';

/// Drives TestGenerator against a Flutter project (default: playground/)
/// WITHOUT a device or live crawl. Used by the fixture-compile CI job to
/// prove the emitted integration tests are analyzer-clean — the package's
/// core promise.
Future<void> main(List<String> args) async {
  final projectPath =
      args.isNotEmpty ? args.first : '${Directory.current.path}/playground';
  if (!File('$projectPath/pubspec.yaml').existsSync()) {
    stderr.writeln('Not a Dart/Flutter project: $projectPath');
    exitCode = 64;
    return;
  }

  final generator = TestGenerator(projectPath: projectPath);
  final files = await generator.generateAndSave(
    screenName: 'PlaygroundHome',
    widgetTree: {},
    interactionResults: [],
    issues: [
      // Point the generator at the project's real main.dart so it harvests
      // keys and tappables the same way a live crawl would.
      WidgetIssue(
        type: 'fixture',
        message: 'CI fixture-compile driver',
        severity: 'info',
        file: 'main.dart',
        line: 1,
      ),
    ],
    // No performance data on purpose — exercises the labeled-skip perf path.
  );
  print('Generated ${files.length} screen test files into '
      '$projectPath/integration_test/dangi_doctor/');
}
