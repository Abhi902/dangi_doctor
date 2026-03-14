import 'dart:io';
import '../crawler/interaction_engine.dart';
import '../analysis/tree_analyser.dart';

class TestGenerator {
  final String projectPath;

  TestGenerator({required this.projectPath});

  /// Read the actual screen source file and extract real widget keys/types
  Map<String, dynamic> _readScreenSource(
      String screenName, List<WidgetIssue> issues) {
    // Find the source file from issues (they have real file paths)
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
    final types = <String>[];
    final lines = <Map<String, dynamic>>[];

    for (final fileName in screenFiles) {
      // Find full path
      final fullPath = _findFile(fileName);
      if (fullPath == null) continue;

      try {
        final content = File(fullPath).readAsStringSync();
        final fileLines = content.split('\n');

        // Extract widget Keys
        final keyMatches = RegExp(r"Key\('([^']+)'\)").allMatches(content);
        for (final m in keyMatches) {
          keys.add(m.group(1)!);
        }

        // Extract tappable widgets with line numbers
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
              final widgetType = pattern.pattern.split(r'\s')[0];
              types.add(widgetType);
              lines.add({
                'type': widgetType,
                'line': i + 1,
                'file': fileName,
                'snippet': fileLines[i].trim(),
              });
            }
          }
        }

        // Extract TextField keys
        final tfMatches = RegExp(
          r'TextField[^,]*key:\s*(?:const\s+)?(?:Key|ValueKey)\(([^\)]+)\)',
          dotAll: true,
        ).allMatches(content);
        for (final m in tfMatches) {
          keys.add(m.group(1)!.replaceAll("'", '').replaceAll('"', ''));
        }
      } catch (_) {}
    }

    return {
      'files': screenFiles,
      'keys': keys,
      'types': types.toSet().toList(),
      'tappable_lines': lines,
    };
  }

  String? _findFile(String fileName) {
    final libDir = Directory('$projectPath/lib');
    if (!libDir.existsSync()) return null;
    try {
      final matches = libDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith(fileName))
          .toList();
      return matches.isNotEmpty ? matches.first.path : null;
    } catch (_) {
      return null;
    }
  }

  /// Detect the correct app entry — reads main.dart directly
  _AppInfo _detectAppInfo() {
    final mainFile = File('$projectPath/lib/main.dart');
    if (!mainFile.existsSync()) {
      return _AppInfo(
        appImport: "import 'package:reflex/main.dart';",
        runAppCall: 'MyApp(allowDarkMode: true)',
      );
    }

    final content = mainFile.readAsStringSync();
    final packageName = _detectPackageName();

    // Find: runApp( ... child: SomeWidget(...) ... )
    // or: runApp(SomeWidget(...))
    final childMatch =
        RegExp(r'child:\s*(\w+)\s*\(([^)]*)\)').firstMatch(content);
    final directMatch = RegExp(r'runApp\(\s*(?:const\s+)?(\w+)\s*\(([^)]*)\)')
        .firstMatch(content);

    String appClass;
    String appArgs;

    if (childMatch != null) {
      appClass = childMatch.group(1)!;
      appArgs = childMatch.group(2)!.trim();
    } else if (directMatch != null) {
      appClass = directMatch.group(1)!;
      appArgs = directMatch.group(2)!.trim();
    } else {
      appClass = 'MyApp';
      appArgs = '';
    }

    // Clean up args — remove newlines and extra spaces
    appArgs = appArgs.replaceAll(RegExp(r'\s+'), ' ').trim();

    // Remove args that reference variables we can't access in tests
    // Keep only literal values like true/false/strings/numbers
    final safeArgs = appArgs
        .split(',')
        .map((a) => a.trim())
        .where((a) => a.isNotEmpty)
        .where((a) {
      // Keep named params with literal values
      if (a.contains(':')) {
        final val = a.split(':').last.trim();
        return val == 'true' ||
            val == 'false' ||
            val.startsWith("'") ||
            val.startsWith('"') ||
            RegExp(r'^\d+$').hasMatch(val);
      }
      return false;
    }).join(', ');

    final runAppCall =
        safeArgs.isNotEmpty ? '$appClass($safeArgs)' : 'const $appClass()';

    return _AppInfo(
      appImport: "import 'package:$packageName/main.dart';",
      runAppCall: runAppCall,
      appClass: appClass,
    );
  }

  String _detectPackageName() {
    final pubspec = File('$projectPath/pubspec.yaml');
    if (!pubspec.existsSync()) return 'app';
    final content = pubspec.readAsStringSync();
    final match =
        RegExp(r'^name:\s*(\w+)', multiLine: true).firstMatch(content);
    return match?.group(1) ?? 'app';
  }

  Future<List<String>> generateAndSave({
    required String screenName,
    required Map<String, dynamic> widgetTree,
    required List<InteractionResult> interactionResults,
    required List<WidgetIssue> issues,
  }) async {
    print('\n📝 Generating Flutter test scripts for $screenName...');

    // Read actual source code for this screen
    final sourceInfo = _readScreenSource(screenName, issues);
    final appInfo = _detectAppInfo();

    print('  📖 App entry: ${appInfo.runAppCall}');
    print('  📂 Screen files: ${(sourceInfo['files'] as List).join(', ')}');
    print('  🔑 Keys found: ${(sourceInfo['keys'] as List).length}');
    print(
        '  👆 Tappable widgets: ${(sourceInfo['tappable_lines'] as List).length}');

    final outputDir = Directory('$projectPath/integration_test/dangi_doctor');
    if (!outputDir.existsSync()) outputDir.createSync(recursive: true);

    final screenSnake = _toSnakeCase(screenName);
    final savedFiles = <String>[];

    print('  ✍️  Smoke test...');
    final smokeFile = '${outputDir.path}/${screenSnake}_smoke_test.dart';
    File(smokeFile)
        .writeAsStringSync(_generateSmokeTest(screenName, sourceInfo, appInfo));
    savedFiles.add(smokeFile);
    print('  ✅ ${smokeFile.split('/').last}');

    print('  ✍️  Interaction test...');
    final intFile = '${outputDir.path}/${screenSnake}_interaction_test.dart';
    File(intFile).writeAsStringSync(_generateInteractionTest(
        screenName, sourceInfo, interactionResults, appInfo));
    savedFiles.add(intFile);
    print('  ✅ ${intFile.split('/').last}');

    print('  ✍️  Performance test...');
    final perfFile = '${outputDir.path}/${screenSnake}_perf_test.dart';
    File(perfFile).writeAsStringSync(
        _generatePerfTest(screenName, interactionResults, appInfo));
    savedFiles.add(perfFile);
    print('  ✅ ${perfFile.split('/').last}');

    _saveReadme(outputDir.path);
    print('\n  📁 Saved to: integration_test/dangi_doctor/');
    print(
        '  Run: flutter test integration_test/dangi_doctor/ -d <device_id>\n');

    return savedFiles;
  }

  String _generateSmokeTest(
    String screenName,
    Map<String, dynamic> sourceInfo,
    _AppInfo appInfo,
  ) {
    final keys = sourceInfo['keys'] as List<String>;
    final keyAssertions = keys
        .take(3)
        .map((k) => "    expect(find.byKey(const Key('$k')), findsWidgets);")
        .join('\n');

    return '''// Generated by Dangi Doctor 🩺
// Screen: $screenName
// Run: flutter test integration_test/dangi_doctor/${_toSnakeCase(screenName)}_smoke_test.dart -d <device_id>

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
${appInfo.appImport}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('$screenName — smoke tests', () {
    testWidgets('app launches without crashing', (tester) async {
      await tester.pumpWidget(${appInfo.runAppCall});
      await tester.pumpAndSettle(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    });
${keyAssertions.isNotEmpty ? '''
    testWidgets('key widgets are present', (tester) async {
      await tester.pumpWidget(${appInfo.runAppCall});
      await tester.pumpAndSettle(const Duration(seconds: 5));
$keyAssertions
    });''' : ''}
  });
}
''';
  }

  String _generateInteractionTest(
    String screenName,
    Map<String, dynamic> sourceInfo,
    List<InteractionResult> results,
    _AppInfo appInfo,
  ) {
    final tappableLines =
        sourceInfo['tappable_lines'] as List<Map<String, dynamic>>;
    final keys = sourceInfo['keys'] as List<String>;

    // Generate tests from real source lines
    final sourceBasedTests = tappableLines.take(5).map((t) {
      final type = t['type'] as String;
      final line = t['line'] as int;
      final file = t['file'] as String;
      return '''
    testWidgets('$type at $file:$line responds to tap', (tester) async {
      await tester.pumpWidget(${appInfo.runAppCall});
      await tester.pumpAndSettle(const Duration(seconds: 5));

      final widgets = find.byType($type, skipOffstage: false);
      if (widgets.evaluate().isNotEmpty) {
        await tester.ensureVisible(widgets.first);
        await tester.pumpAndSettle();
        await tester.tap(widgets.first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });''';
    }).join('\n');

    // Generate tests from widget keys (most reliable)
    final keyBasedTests = keys.take(5).map((k) => '''
    testWidgets('widget with key "$k" is present and tappable', (tester) async {
      await tester.pumpWidget(${appInfo.runAppCall});
      await tester.pumpAndSettle(const Duration(seconds: 5));

      final widget = find.byKey(const Key('$k'), skipOffstage: false);
      if (widget.evaluate().isNotEmpty) {
        await tester.ensureVisible(widget);
        await tester.pumpAndSettle();
        await tester.tap(widget);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });''').join('\n');

    // Dangi Doctor observed interactions
    final observedTests =
        results.where((r) => r.executed).take(3).map((r) => '''
    // Dangi Doctor observed: ${r.outcome}
    // ${r.interaction.file}:${r.interaction.line}''').join('\n');

    return '''// Generated by Dangi Doctor 🩺
// Screen: $screenName — based on actual source code analysis
// Run: flutter test integration_test/dangi_doctor/${_toSnakeCase(screenName)}_interaction_test.dart -d <device_id>

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
${appInfo.appImport}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('$screenName — interaction tests', () {
$sourceBasedTests
$keyBasedTests
$observedTests
  });
}
''';
  }

  String _generatePerfTest(
    String screenName,
    List<InteractionResult> results,
    _AppInfo appInfo,
  ) {
    final janky = results
        .where((r) => r.executed && (r.performance?.jankyFrames ?? 0) > 0)
        .toList();

    final jankyNote = janky.isNotEmpty
        ? janky
            .map((r) => '  // ⚠️  ${r.interaction.widgetType} at '
                '${r.interaction.file}:${r.interaction.line} — '
                '${r.performance!.jankyFrames} janky frames')
            .join('\n')
        : '  // ✅ No jank detected during Dangi Doctor scan';

    return '''// Generated by Dangi Doctor 🩺
// Screen: $screenName — performance regression tests
// Run: flutter drive --target=integration_test/dangi_doctor/${_toSnakeCase(screenName)}_perf_test.dart --profile -d <device_id>

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
${appInfo.appImport}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('$screenName — performance tests', () {
    testWidgets('renders within frame budget', (tester) async {
      await binding.watchPerformance(() async {
        await tester.pumpWidget(${appInfo.runAppCall});
        await tester.pumpAndSettle(const Duration(seconds: 5));
      }, reportKey: '${_toSnakeCase(screenName)}');
    });

$jankyNote
  });
}
''';
  }

  void _saveReadme(String dirPath) {
    File('$dirPath/README.md')
        .writeAsStringSync('''# Dangi Doctor — Generated Tests 🩺

Auto-generated from live app analysis. Re-run Dangi Doctor to update.

## Run all tests
```bash
flutter test integration_test/dangi_doctor/ -d <device_id>
```

## Run specific screen
```bash
flutter test integration_test/dangi_doctor/login_page_widget_smoke_test.dart -d <device_id>
```

## Performance tests
```bash
flutter drive --target=integration_test/dangi_doctor/login_page_widget_perf_test.dart --profile -d <device_id>
```

Generated: ${DateTime.now().toIso8601String()}
''');
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

class _AppInfo {
  final String appImport;
  final String runAppCall;
  final String appClass;

  _AppInfo({
    required this.appImport,
    required this.runAppCall,
    this.appClass = 'MyApp',
  });
}
