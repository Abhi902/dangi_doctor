import 'dart:io';
import '../analysis/performance.dart';
import '../crawler/interaction_engine.dart';
import '../analysis/tree_analyser.dart';
import 'app_analyser.dart';

class TestGenerator {
  final String projectPath;
  AppAnalysis? _analysis;
  bool _sharedFilesGenerated = false;

  TestGenerator({required this.projectPath});

  /// Exposes the cached AppAnalysis (available after the first generateAndSave call).
  AppAnalysis? get cachedAnalysis => _analysis;

  /// Escapes [s] for safe embedding inside a single-quoted Dart string
  /// literal in generated code.
  static String dartEsc(String s) => s
      .replaceAll('\\', '\\\\')
      .replaceAll("'", "\\'")
      .replaceAll('\$', '\\\$')
      .replaceAll('\n', '\\n');

  Future<List<String>> generateAndSave({
    required String screenName,
    required Map<String, dynamic> widgetTree,
    required List<InteractionResult> interactionResults,
    required List<WidgetIssue> issues,
    ScreenPerformance? performance,
  }) async {
    print('\n📝 Generating Flutter test scripts for $screenName...');

    // Auto-analyse the project if not done yet
    _analysis ??= await AppAnalyser(projectPath: projectPath).analyse();
    final analysis = _analysis!;

    final sourceInfo = _readScreenSource(screenName, issues);
    print('  📂 Screen files: ${(sourceInfo['files'] as List).join(', ')}');
    print('  🔑 Keys found: ${(sourceInfo['keys'] as List).length}');
    print(
        '  👆 Tappable widgets: ${(sourceInfo['tappable_lines'] as List).length}');

    final outputDir = Directory('$projectPath/integration_test/dangi_doctor');
    if (!outputDir.existsSync()) outputDir.createSync(recursive: true);

    // Shared files (helper, project-wide bug tests, README) once per run
    if (!_sharedFilesGenerated) {
      _sharedFilesGenerated = true;
      final pubspecFile = File('$projectPath/pubspec.yaml');
      final missingDeps = pubspecFile.existsSync()
          ? missingTestDepsStanza(pubspecFile.readAsStringSync())
          : null;
      if (missingDeps != null) {
        print('  ⚠️  Missing dev-dependencies — the generated tests will NOT '
            'compile until you add this to pubspec.yaml and run '
            '`flutter pub get`:\n');
        print(missingDeps.split('\n').map((l) => '      $l').join('\n'));
        print('');
      }
      _generateTestHelper(outputDir.path, analysis);
      _generateKnownBugsTest(outputDir.path, analysis);
      _saveReadme(outputDir.path, analysis, missingDeps);
    }

    final screenSnake = _toSnakeCase(screenName);
    final savedFiles = <String>[];

    print('  ✍️  Smoke test...');
    final smokeFile = '${outputDir.path}/${screenSnake}_smoke_test.dart';
    File(smokeFile).writeAsStringSync(
        _generateSmokeTest(screenName, sourceInfo, analysis));
    savedFiles.add(smokeFile);
    print('  ✅ ${smokeFile.split('/').last}');

    print('  ✍️  Interaction test...');
    final intFile = '${outputDir.path}/${screenSnake}_interaction_test.dart';
    File(intFile).writeAsStringSync(_generateInteractionTest(
        screenName, sourceInfo, interactionResults, analysis));
    savedFiles.add(intFile);
    print('  ✅ ${intFile.split('/').last}');

    print('  ✍️  Performance test...');
    final perfFile = '${outputDir.path}/${screenSnake}_perf_test.dart';
    File(perfFile).writeAsStringSync(
        _generatePerfTest(screenName, performance, analysis));
    savedFiles.add(perfFile);
    print('  ✅ ${perfFile.split('/').last}');

    print('\n  📁 Saved to: integration_test/dangi_doctor/');
    print(
        '  Run: flutter test integration_test/dangi_doctor/ -d <device_id>\n');

    return savedFiles;
  }

  void _generateTestHelper(String dirPath, AppAnalysis a) {
    // Always regenerate — this is fully auto-generated code, never manually edited
    final helperFile = File('$dirPath/test_helper.dart');

    final initBlock = a.appStateInitMethod != null
        ? '\n  await ${a.appStateClass}().${a.appStateInitMethod}();\n'
        : '';

    final tokenLine = a.appStateTokenField != null
        ? '    ${a.appStateClass}().${a.appStateTokenField} = testToken;'
        : '';
    final jwtLine =
        a.appStateJwtField != null && a.appStateJwtField != a.appStateTokenField
            ? '    ${a.appStateClass}().${a.appStateJwtField} = testToken;'
            : '';
    final userIdLine = a.appStateUserIdField != null
        ? '    ${a.appStateClass}().${a.appStateUserIdField} = 1;'
        : '';
    final userNameLine = a.appStateUserNameField != null
        ? "    ${a.appStateClass}().${a.appStateUserNameField} = 'Dangi Doctor Test';"
        : '';
    final emailLine = a.appStateEmailField != null
        ? "    ${a.appStateClass}().${a.appStateEmailField} = 'test@dangidoctor.dev';"
        : '';

    final authBlock = tokenLine.isNotEmpty
        ? '''
  const testToken = String.fromEnvironment('TEST_TOKEN', defaultValue: '');
  if (testToken.isNotEmpty) {
$tokenLine
$jwtLine
$userIdLine
$userNameLine
$emailLine
    print('✅ Auth injected via ${a.appStateClass}');
  } else {
    print('⚠️  No TEST_TOKEN — run with --dart-define=TEST_TOKEN=your_token');
  }'''
        : "  // No global state class detected — auth handled by your app's own mechanism";

    // Import wherever app_state.dart actually lives; needed by both the
    // auth block (token field) and the init block (init method).
    final needsStateImport =
        a.appStateTokenField != null || a.appStateInitMethod != null;
    final stateImport = needsStateImport && a.appStateImportPath != null
        ? "import 'package:${a.packageName}/${a.appStateImportPath}';"
        : '';

    final firebaseImports = a.hasFirebase
        ? '''
import 'package:firebase_core/firebase_core.dart';
${a.firebaseOptionsImport ?? ''}'''
        : '';

    helperFile.writeAsStringSync('''// Generated by Dangi Doctor 🩺
// Shared test helper — auto-generated, do not edit manually.
// Re-run Dangi Doctor to regenerate after source changes.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
$firebaseImports
$stateImport

bool _initialized = false;

/// Initialize project dependencies and inject test auth state.
Future<void> setupTest() async {
  if (_initialized) return;
  _initialized = true;
${a.hasFirebase ? '''  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );''' : '  // No Firebase detected in this project'}
$initBlock$authBlock
}

/// Pump the app and collect ALL Flutter errors thrown during rendering.
///
/// Uses [FlutterError.onError] to capture every error across all frames,
/// not just the first one (which is all tester.takeException() gives you).
/// The tester exception queue is drained at the end so the framework does
/// not re-fail the test — we want to control the failure message ourselves.
Future<List<FlutterErrorDetails>> pumpAppCollecting(
    WidgetTester tester, Widget app) async {
  final errors = <FlutterErrorDetails>[];
  final original = FlutterError.onError;
  FlutterError.onError = (details) {
    errors.add(details);
    original?.call(details); // still print full stack to console
  };
  try {
    await tester.pumpWidget(app);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
  } finally {
    FlutterError.onError = original;
    tester.takeException(); // drain so framework does not re-fail us
  }
  return errors;
}

/// Format a list of errors into a human-readable diagnostic report.
String formatErrors(List<FlutterErrorDetails> errors) {
  return errors.asMap().entries.map((entry) {
    final i = entry.key + 1;
    final e = entry.value;
    final msg = e.exception.toString().split('\\n').first;
    final stack =
        e.stack?.toString().split('\\n').take(4).join('\\n    ') ?? '';
    return '[\$i] \$msg\\n    \$stack';
  }).join('\\n\\n');
}

/// Pump the app and let async content settle — for interaction and
/// performance tests that don't need per-frame error collection.
Future<void> pumpApp(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(app);
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}
''');
    print('  ✅ test_helper.dart');
  }

  String _generateSmokeTest(
    String screenName,
    Map<String, dynamic> sourceInfo,
    AppAnalysis a,
  ) {
    final nameEsc = dartEsc(screenName);
    final keys = (sourceInfo['keys'] as List<String>)
        .where((k) => !RegExp(r'^[a-f0-9]{20,}$').hasMatch(k))
        .where((k) => k.length < 50)
        .toList();

    final keyAssertions = keys
        .take(3)
        .map((k) =>
            "      if (find.byKey(const Key('$k'), skipOffstage: false).evaluate().isNotEmpty)\n"
            "        expect(find.byKey(const Key('$k')), findsWidgets);")
        .join('\n');

    return '''// Generated by Dangi Doctor 🩺
// Screen: $screenName — smoke tests
// Run: flutter test integration_test/dangi_doctor/${_toSnakeCase(screenName)}_smoke_test.dart -d <device_id>

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:${a.packageName}/main.dart';
import 'test_helper.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('$nameEsc — smoke tests', () {
    testWidgets('app launches without crashing', (tester) async {
      await setupTest();
      final errors = await pumpAppCollecting(tester, ${a.runAppCall});

      if (errors.isNotEmpty) {
        fail(
          'App threw \${errors.length} error(s) during launch. '
          'These are real bugs — fix them before running further tests:\\n\\n'
          '\${formatErrors(errors)}\\n\\n'
          'Tip: Run Dangi Doctor again after fixing to see targeted bug tests.',
        );
      }

      // WidgetsApp underlies MaterialApp AND CupertinoApp, so a healthy
      // Cupertino app passes this too.
      expect(find.byType(WidgetsApp), findsWidgets);
    });

${keyAssertions.isNotEmpty ? '''    testWidgets('key widgets are present', (tester) async {
      await setupTest();
      final errors = await pumpAppCollecting(tester, ${a.runAppCall});
      if (errors.isEmpty) {
$keyAssertions
      }
    });''' : ''}
  });
}
''';
  }

  /// Project-wide bug tests detected by static analysis — generated ONCE
  /// into known_bugs_test.dart instead of being duplicated into every
  /// screen's smoke test (10 screens × 5 risks used to mean 50 copies).
  void _generateKnownBugsTest(String dirPath, AppAnalysis a) {
    if (a.knownRisks.isEmpty) return;
    final riskTests = _generateRiskTests(a.knownRisks, a.runAppCall);
    File('$dirPath/known_bugs_test.dart')
        .writeAsStringSync('''// Generated by Dangi Doctor 🩺
// Project-wide bug tests from static analysis.
// Run: flutter test integration_test/dangi_doctor/known_bugs_test.dart -d <device_id>

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:${a.packageName}/main.dart';
import 'test_helper.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Known bugs — static analysis', () {
$riskTests
  });
}
''');
    print('  ✅ known_bugs_test.dart (${a.knownRisks.length} detected bugs)');
  }

  /// Generates one targeted test per detected [KnownRisk].
  /// Each test explicitly names the bug, its location, and the exact fix.
  String _generateRiskTests(List<KnownRisk> risks, String runAppCall) {
    if (risks.isEmpty) return '';

    final buffer = StringBuffer();
    buffer.writeln(
        '    // ─── Bug-specific tests detected by Dangi Doctor static analysis ───');

    for (final risk in risks) {
      final descEsc = dartEsc(risk.description);
      final fixEsc = dartEsc(risk.suggestedFix);
      final fileLine = '${risk.file}:${risk.line}';

      switch (risk.type) {
        case 'late_field_double_init':
          final fieldEsc = dartEsc(risk.fieldName);
          final methodEsc = dartEsc(risk.callerMethod);
          buffer.writeln(
            '\n'
            "    testWidgets(\n"
            "        'BUG: $fileLine — '\n"
            "        'late field `$fieldEsc` double-init in `$methodEsc()`',\n"
            '        (tester) async {\n'
            '      await setupTest();\n'
            '      final errors = await pumpAppCollecting(tester, $runAppCall);\n'
            '\n'
            '      final matching = errors.where((e) {\n'
            '        final msg = e.exception.toString();\n'
            "        return (msg.contains('LateInitializationError') ||\n"
            "                msg.contains('already been initialized')) &&\n"
            "            msg.contains('$fieldEsc');\n"
            '      }).toList();\n'
            '\n'
            '      expect(\n'
            '        matching,\n'
            '        isEmpty,\n'
            "        reason: '━━━ BUG DETECTED ━━━\\n'\n"
            "            'File: $fileLine\\n'\n"
            "            '\\n'\n"
            "            'Problem:\\n'\n"
            "            '$descEsc\\n'\n"
            "            '\\n'\n"
            "            'Fix:\\n'\n"
            "            '$fixEsc\\n'\n"
            "            '━━━━━━━━━━━━━━━━━━━',\n"
            '      );\n'
            '    });\n',
          );

        case 'setState_after_dispose':
          buffer.writeln(
            '\n'
            "    testWidgets(\n"
            "        'BUG: $fileLine — setState() called without mounted guard',\n"
            '        (tester) async {\n'
            '      await setupTest();\n'
            '      final errors = await pumpAppCollecting(tester, $runAppCall);\n'
            '\n'
            '      final matching = errors.where((e) {\n'
            '        final msg = e.exception.toString();\n'
            "        return msg.contains('setState') &&\n"
            "            (msg.contains('disposed') || msg.contains('after dispose'));\n"
            '      }).toList();\n'
            '\n'
            '      expect(\n'
            '        matching,\n'
            '        isEmpty,\n'
            "        reason: '━━━ BUG DETECTED ━━━\\n'\n"
            "            'File: $fileLine\\n'\n"
            "            '\\n'\n"
            "            'Problem:\\n'\n"
            "            '$descEsc\\n'\n"
            "            '\\n'\n"
            "            'Fix:\\n'\n"
            "            '$fixEsc\\n'\n"
            "            '━━━━━━━━━━━━━━━━━━━',\n"
            '      );\n'
            '    });\n',
          );

        case 'build_side_effects':
          // A side effect inside build() cannot be reliably provoked from a
          // pumpWidget grep — the old error-message match never fired.
          // Generate an honest always-failing test instead ("delete once
          // fixed"), same pattern as the leak test below.
          final fieldEsc = dartEsc(risk.fieldName);
          buffer.writeln(
            '\n'
            "    test(\n"
            "        'BUG: $fileLine — side effect (`$fieldEsc`) inside build()',\n"
            '        () {\n'
            "      fail(\n"
            "        '━━━ BUILD SIDE EFFECT DETECTED ━━━\\n'\n"
            "        'File: $fileLine\\n'\n"
            "        '\\n'\n"
            "        'Problem:\\n'\n"
            "        '$descEsc\\n'\n"
            "        '\\n'\n"
            "        'Fix:\\n'\n"
            "        '$fixEsc\\n'\n"
            "        '━━━━━━━━━━━━━━━━━━━\\n'\n"
            "        'Delete this test once the fix is applied.',\n"
            '      );\n'
            '    });\n',
          );

        case 'stream_subscription_leak':
          // Leaks can't be caught via pumpWidget — generate a reminder test
          // that always fails so the developer must acknowledge the fix.
          final fieldEsc = dartEsc(risk.fieldName);
          buffer.writeln(
            '\n'
            "    test(\n"
            "        'BUG: $fileLine — StreamSubscription `$fieldEsc` not cancelled in dispose()',\n"
            '        () {\n'
            "      fail(\n"
            "        '━━━ MEMORY LEAK DETECTED ━━━\\n'\n"
            "        'File: $fileLine\\n'\n"
            "        '\\n'\n"
            "        'Problem:\\n'\n"
            "        '$descEsc\\n'\n"
            "        '\\n'\n"
            "        'Fix:\\n'\n"
            "        '$fixEsc\\n'\n"
            "        '━━━━━━━━━━━━━━━━━━━\\n'\n"
            "        'Delete this test once the fix is applied.',\n"
            '      );\n'
            '    });\n',
          );
      }
    }

    return buffer.toString();
  }

  String _generateInteractionTest(
    String screenName,
    Map<String, dynamic> sourceInfo,
    List<InteractionResult> results,
    AppAnalysis a,
  ) {
    final nameEsc = dartEsc(screenName);
    final tappableLines =
        sourceInfo['tappable_lines'] as List<Map<String, dynamic>>;
    final keys = (sourceInfo['keys'] as List<String>)
        .where((k) => !RegExp(r'^[a-f0-9]{20,}$').hasMatch(k))
        .toList();

    final sourceTests = tappableLines.take(6).map((t) {
      final type = t['type'] as String;
      final line = t['line'] as int;
      final file = t['file'] as String;
      return '''
    testWidgets('$type at $file:$line responds to tap', (tester) async {
      await setupTest();
      await pumpApp(tester, ${a.runAppCall});
      final widgets = find.byType($type, skipOffstage: false);
      if (widgets.evaluate().isNotEmpty) {
        await tester.ensureVisible(widgets.first);
        await tester.pump();
        await tester.tap(widgets.first);
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(tester.takeException(), isNull);
      }
    });''';
    }).join('\n');

    final keyTests = keys.take(4).map((k) => '''
    testWidgets('widget "$k" is tappable', (tester) async {
      await setupTest();
      await pumpApp(tester, ${a.runAppCall});
      final widget = find.byKey(const Key('$k'), skipOffstage: false);
      if (widget.evaluate().isNotEmpty) {
        await tester.ensureVisible(widget);
        await tester.pump();
        await tester.tap(widget);
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(tester.takeException(), isNull);
      }
    });''').join('\n');

    return '''// Generated by Dangi Doctor 🩺
// Screen: $screenName — interaction tests
// Run: flutter test integration_test/dangi_doctor/${_toSnakeCase(screenName)}_interaction_test.dart -d <device_id>

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:${a.packageName}/main.dart';
import 'test_helper.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('$nameEsc — interaction tests', () {
$sourceTests
$keyTests
  });
}
''';
  }

  String _generatePerfTest(
    String screenName,
    ScreenPerformance? crawlPerf,
    AppAnalysis a,
  ) {
    final snake = _toSnakeCase(screenName);
    final nameEsc = dartEsc(screenName);
    final budget = PerformanceCapture.frameBudgetMs.toStringAsFixed(1);
    final hasData = crawlPerf != null && crawlPerf.totalFrames > 0;

    final header = '''// Generated by Dangi Doctor 🩺
// Screen: $screenName — performance regression tests
// Run: flutter test integration_test/dangi_doctor/${snake}_perf_test.dart -d <device_id>

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
''';

    if (!hasData) {
      return '''$header
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('$nameEsc — performance tests', () {
    test(
      'renders within frame budget — SKIPPED (no crawl data)',
      () {},
      skip: 'No performance data was collected for $nameEsc during the '
          'Dangi Doctor crawl, so there is no honest baseline to assert '
          'against. Re-run Dangi Doctor with a device attached to generate '
          'a real frame-budget assertion here.',
    );
  });
}
''';
    }

    final baseline = 'avg build ${crawlPerf.avgBuildMs.toStringAsFixed(1)}ms, '
        '${crawlPerf.jankyFrames} janky of ${crawlPerf.totalFrames} frames';

    return '''$header
import 'package:${a.packageName}/main.dart';
import 'test_helper.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('$nameEsc — performance tests', () {
    // Crawl baseline: $baseline (budget ${budget}ms).
    testWidgets('renders within the ${budget}ms frame budget', (tester) async {
      await setupTest();
      await binding.watchPerformance(() async {
        await pumpApp(tester, ${a.runAppCall});
      }, reportKey: '$snake');

      final summary = binding.reportData?['$snake'] as Map<String, dynamic>?;
      expect(
        summary,
        isNotNull,
        reason: 'watchPerformance produced no report — run this test on a '
            'device or emulator via `flutter test ... -d <device_id>`.',
      );
      final avgBuildMs =
          (summary!['average_frame_build_time_millis'] as num).toDouble();
      expect(
        avgBuildMs,
        lessThan($budget),
        reason: 'Average frame build time \${avgBuildMs.toStringAsFixed(1)}ms '
            'exceeds the ${budget}ms budget measured for the crawl device '
            '(crawl baseline: $baseline).',
      );
    });
  });
}
''';
  }

  Map<String, dynamic> _readScreenSource(
      String screenName, List<WidgetIssue> issues) {
    final screenFiles = issues
        .where((i) => i.file != null)
        .map((i) => i.file!)
        .toSet()
        .where((f) =>
            !f.contains('nested.dart') &&
            !f.contains('router.dart') &&
            !f.contains('builder.dart') &&
            !f.contains('vector_graphics.dart'))
        .toList();

    final keys = <String>[];
    final lines = <Map<String, dynamic>>[];

    for (final fileName in screenFiles) {
      final fullPath = _findFile(fileName);
      if (fullPath == null) continue;
      try {
        final content = File(fullPath).readAsStringSync();
        final fileLines = content.split('\n');

        final keyMatches = RegExp(r"Key\('([^']+)'\)").allMatches(content);
        for (final m in keyMatches) {
          final key = m.group(1)!;
          // Keys with interpolation (Key('item_$index')) are dynamic — the
          // literal would reference an undefined variable in generated code.
          if (key.contains(r'$')) continue;
          keys.add(key);
        }

        final tappablePatterns = [
          RegExp(r'ElevatedButton\s*\('),
          RegExp(r'TextButton\s*\('),
          RegExp(r'InkWell\s*\('),
          RegExp(r'GestureDetector\s*\('),
          RegExp(r'IconButton\s*\('),
          RegExp(r'FloatingActionButton\s*\('),
        ];

        for (var i = 0; i < fileLines.length; i++) {
          for (final pattern in tappablePatterns) {
            if (pattern.hasMatch(fileLines[i])) {
              lines.add({
                'type': pattern.pattern.split(r'\s')[0],
                'line': i + 1,
                'file': fileName,
              });
            }
          }
        }
      } catch (_) {}
    }

    return {
      'files': screenFiles,
      'keys': keys,
      'tappable_lines': lines,
    };
  }

  String? _findFile(String fileName) {
    final libDir = Directory('$projectPath/lib');
    if (!libDir.existsSync()) return null;
    try {
      return libDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith(fileName))
          .map((f) => f.path)
          .firstOrNull;
    } catch (_) {
      return null;
    }
  }

  void _saveReadme(String dirPath, AppAnalysis a, String? missingDeps) {
    final depsWarning = missingDeps == null
        ? ''
        : '''## ⚠️ Before running: add missing dev-dependencies

These tests will NOT compile until your `pubspec.yaml` declares:

```yaml
$missingDeps
```

Then run `flutter pub get`.

''';
    File('$dirPath/README.md')
        .writeAsStringSync('''# Dangi Doctor — Generated Tests 🩺

Auto-generated from live app analysis. Re-run Dangi Doctor after UI changes.

$depsWarning## Quick start

```bash
flutter test integration_test/dangi_doctor/ \\
  --dart-define=TEST_TOKEN=your_backend_token \\
  -d <device_id>
```

${a.appStateTokenField != null ? '''## How auth bypass works
Dangi Doctor detected your auth setup:
- App state class: `${a.appStateClass}`
- Init method: `${a.appStateInitMethod ?? 'none detected'}`
- Token field: `${a.appStateTokenField}`

Tests inject the token directly into `${a.appStateClass}` — no OAuth popup needed.

## Getting a test token
Log in to ${a.packageName} manually once, then copy the token from your app logs.
''' : '''## Auth
No global app-state token field was detected — tests run against your app's
own auth flow. If your app needs login, run tests against a build with a
test backend or seed auth state before running.
'''}''');
  }

  String _toSnakeCase(String input) {
    return input
        .replaceAllMapped(
            RegExp(r'[A-Z]'), (m) => '_${m.group(0)!.toLowerCase()}')
        .replaceAll(RegExp(r'^_'), '')
        .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
        .toLowerCase();
  }
}

/// Returns the exact `dev_dependencies` stanza the target project is missing
/// (`flutter_test` / `integration_test`), or null when both are declared.
/// The generated tests cannot compile without them.
String? missingTestDepsStanza(String pubspecContent) {
  final missing = <String>[];
  if (!RegExp(r'^\s*flutter_test\s*:', multiLine: true)
      .hasMatch(pubspecContent)) {
    missing.add('  flutter_test:\n    sdk: flutter');
  }
  if (!RegExp(r'^\s*integration_test\s*:', multiLine: true)
      .hasMatch(pubspecContent)) {
    missing.add('  integration_test:\n    sdk: flutter');
  }
  if (missing.isEmpty) return null;
  return 'dev_dependencies:\n${missing.join('\n')}';
}
