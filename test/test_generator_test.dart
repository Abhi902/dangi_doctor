import 'dart:io';

import 'package:test/test.dart';

import 'package:dangi_doctor/analysis/tree_analyser.dart';
import 'package:dangi_doctor/analysis/performance.dart';
import 'package:dangi_doctor/generator/test_generator.dart';

/// Builds a throwaway Flutter-project skeleton the generator can analyse.
Directory _fixtureProject({required bool constApp}) {
  final dir = Directory.systemTemp.createTempSync('dangi_fixture_');
  File('${dir.path}/pubspec.yaml').writeAsStringSync('''
name: fixture_app
environment:
  sdk: ^3.0.0
''');
  Directory('${dir.path}/lib/pages').createSync(recursive: true);

  File('${dir.path}/lib/main.dart').writeAsStringSync('''
import 'package:flutter/material.dart';

void main() {
  runApp(${constApp ? 'const MyApp()' : 'MyApp()'});
}

class MyApp extends StatelessWidget {
  ${constApp ? 'const MyApp({super.key});' : 'MyApp({super.key});'}
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: EdgeInsets.zero,
          child: Text('hi'),
        ),
      ),
    );
  }
}
''');

  // app_state.dart deliberately in a subfolder, with a `name:` parameter and
  // comment that must NOT be mistaken for a `name` field.
  File('${dir.path}/lib/pages/app_state.dart').writeAsStringSync('''
class FFAppState {
  Future initialize() async {}
  String authToken = '';
  // name of the user is stored server-side, not here
  void greet({String? name}) {}
}
''');

  // Screen source with a dynamic key (common ListView.builder pattern),
  // a static key, a tappable, and a StreamSubscription leak.
  File('${dir.path}/lib/pages/home_screen.dart').writeAsStringSync('''
import 'dart:async';
import 'package:flutter/material.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _sub = Stream.periodic(const Duration(seconds: 1)).listen((_) {});
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      key: const Key('good_key'),
      itemCount: 3,
      itemBuilder: (context, index) => ElevatedButton(
        key: Key('item_\$index'),
        onPressed: () {},
        child: Text('tap \$index'),
      ),
    );
  }
}
''');

  // setState() called directly inside build() — the build_side_effects
  // detector must produce an honest always-failing test, not a dead grep.
  File('${dir.path}/lib/pages/counter_box.dart').writeAsStringSync('''
import 'package:flutter/material.dart';

class CounterBox extends StatefulWidget {
  const CounterBox({super.key});
  @override
  State<CounterBox> createState() => _CounterBoxState();
}

class _CounterBoxState extends State<CounterBox> {
  int n = 0;

  @override
  Widget build(BuildContext context) {
    setState(() => n++);
    return Text('count \$n');
  }
}
''');
  return dir;
}

Future<Map<String, String>> _generate(Directory project) async {
  final generator = TestGenerator(projectPath: project.path);
  await generator.generateAndSave(
    screenName: 'HomeScreen',
    widgetTree: {},
    interactionResults: [],
    issues: [
      WidgetIssue(
        type: 'deep_nesting',
        message: 'test issue',
        severity: 'info',
        file: 'home_screen.dart',
        line: 1,
      ),
    ],
  );
  final outDir = Directory('${project.path}/integration_test/dangi_doctor');
  return {
    for (final f in outDir.listSync().whereType<File>())
      f.path.split('/').last: f.readAsStringSync(),
  };
}

void main() {
  late Directory project;
  late Map<String, String> files;

  setUpAll(() async {
    project = _fixtureProject(constApp: true);
    files = await _generate(project);
  });

  tearDownAll(() => project.deleteSync(recursive: true));

  group('generated helper', () {
    test('defines the pumpApp used by interaction and perf tests', () {
      final helper = files['test_helper.dart']!;
      expect(helper, contains('Future<void> pumpApp('));
    });

    test('imports app_state.dart from its actual subfolder', () {
      final helper = files['test_helper.dart']!;
      expect(helper,
          contains("import 'package:fixture_app/pages/app_state.dart';"));
      expect(helper,
          isNot(contains("import 'package:fixture_app/app_state.dart';")));
    });

    test('injects the declared authToken field', () {
      final helper = files['test_helper.dart']!;
      expect(helper, contains('FFAppState().authToken = testToken;'));
    });

    test('does not invent a `name` field from comments/named params', () {
      final helper = files['test_helper.dart']!;
      expect(helper, isNot(contains('.name =')));
    });
  });

  group('generated tests', () {
    test('smoke test pumps the real app class, not a nested child widget', () {
      final smoke = files['home_screen_smoke_test.dart']!;
      expect(smoke, contains('pumpAppCollecting(tester, const MyApp())'));
      expect(smoke, isNot(contains('Text(')));
    });

    test('smoke test asserts on WidgetsApp so Cupertino apps pass too', () {
      final smoke = files['home_screen_smoke_test.dart']!;
      expect(smoke, contains('find.byType(WidgetsApp)'));
      expect(smoke, isNot(contains('find.byType(MaterialApp)')));
    });

    test('dynamic \$-interpolated keys are never emitted into test code', () {
      for (final entry in files.entries) {
        expect(entry.value, isNot(contains(r'item_$index')),
            reason: '${entry.key} contains a raw interpolated key');
      }
    });

    test('static keys are still used', () {
      final interaction = files['home_screen_interaction_test.dart']!;
      expect(interaction, contains("Key('good_key')"));
    });

    test('risk tests live in known_bugs_test.dart, not in every smoke test',
        () {
      expect(files.keys, contains('known_bugs_test.dart'));
      expect(files['known_bugs_test.dart'], contains('MEMORY LEAK'));
      expect(
          files['home_screen_smoke_test.dart'], isNot(contains('MEMORY LEAK')));
    });

    test('perf test header does not recommend the broken flutter drive', () {
      final perf = files['home_screen_perf_test.dart']!;
      expect(perf, isNot(contains('flutter drive')));
      expect(perf, contains('flutter test'));
    });
  });

  group('non-const app class', () {
    test('does not emit `const` for a non-const constructor', () async {
      final p = _fixtureProject(constApp: false);
      addTearDown(() => p.deleteSync(recursive: true));
      final f = await _generate(p);
      final smoke = f['home_screen_smoke_test.dart']!;
      expect(smoke, contains('pumpAppCollecting(tester, MyApp())'));
      expect(smoke, isNot(contains('const MyApp()')));
    });
  });

  group('missing test dependencies (#15)', () {
    test('missingTestDepsStanza reports both deps when neither is declared',
        () {
      final stanza = missingTestDepsStanza('name: app\n');
      expect(stanza, isNotNull);
      expect(stanza, contains('dev_dependencies:'));
      expect(stanza, contains('flutter_test:'));
      expect(stanza, contains('integration_test:'));
    });

    test('missingTestDepsStanza is null when both are present', () {
      expect(missingTestDepsStanza('''
name: app
dev_dependencies:
  flutter_test:
    sdk: flutter
  integration_test:
    sdk: flutter
'''), isNull);
    });

    test('generated README warns prominently about the missing stanza', () {
      final readme = files['README.md']!;
      expect(readme, contains('integration_test:'));
      expect(readme, contains('flutter pub get'));
      expect(readme, contains('will NOT compile'));
    });
  });

  group('honest perf test (#16)', () {
    test('emits a clearly-labeled skip when no crawl perf data exists', () {
      final perf = files['home_screen_perf_test.dart']!;
      expect(perf, contains('skip:'));
      expect(perf, contains('No performance data was collected'));
      expect(perf, isNot(contains('watchPerformance')));
      expect(perf, isNot(contains("import 'package:flutter/material.dart';")));
    });

    test('asserts a frame-budget threshold when crawl data exists', () async {
      final p = _fixtureProject(constApp: true);
      addTearDown(() => p.deleteSync(recursive: true));
      final generator = TestGenerator(projectPath: p.path);
      await generator.generateAndSave(
        screenName: 'HomeScreen',
        widgetTree: {},
        interactionResults: [],
        issues: [
          WidgetIssue(
              type: 'deep_nesting',
              message: 'test issue',
              severity: 'info',
              file: 'home_screen.dart',
              line: 1),
        ],
        performance: ScreenPerformance(
          screenName: 'HomeScreen',
          frames: [
            FrameData(buildMs: 5.0, rasterMs: 3.0),
            FrameData(buildMs: 20.0, rasterMs: 3.0),
          ],
          memoryKb: 0,
        ),
      );
      final perf = File(
              '${p.path}/integration_test/dangi_doctor/home_screen_perf_test.dart')
          .readAsStringSync();
      expect(perf, contains('watchPerformance'));
      expect(perf, contains('average_frame_build_time_millis'));
      expect(perf, contains('lessThan(16.0)')); // default frameBudgetMs
      expect(perf, contains('Crawl baseline'));
    });
  });

  group('build_side_effects honest test (#17)', () {
    test('generates an always-failing test instead of a dead error grep', () {
      final bugs = files['known_bugs_test.dart']!;
      expect(bugs, contains('BUILD SIDE EFFECT DETECTED'));
      expect(bugs, contains('counter_box.dart'));
      expect(bugs, contains('Delete this test once the fix is applied.'));
      expect(
          bugs,
          isNot(contains(
              "msg.contains('setState() or markNeedsBuild() called during build')")));
    });
  });

  group('escaping and lint cleanliness (#18, #19)', () {
    test('for-loops in generated interaction tests have braces', () {
      final interaction = files['home_screen_interaction_test.dart']!;
      expect(interaction, contains('for (var i = 0; i < 4; i++) {'));
      expect(interaction, isNot(contains('i++) await')));
    });

    test('screenName is escaped in generated group descriptions', () async {
      final p = _fixtureProject(constApp: true);
      addTearDown(() => p.deleteSync(recursive: true));
      final generator = TestGenerator(projectPath: p.path);
      await generator.generateAndSave(
        screenName: "Detail's \$creen",
        widgetTree: {},
        interactionResults: [],
        issues: [
          WidgetIssue(
              type: 'deep_nesting',
              message: 'test issue',
              severity: 'info',
              file: 'home_screen.dart',
              line: 1),
        ],
      );
      final smoke = File(
              '${p.path}/integration_test/dangi_doctor/detail_s__creen_smoke_test.dart')
          .readAsStringSync();
      expect(smoke, contains(r"group('Detail\'s \$creen — smoke tests'"));
    });
  });
}
