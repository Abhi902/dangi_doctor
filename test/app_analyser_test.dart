import 'dart:io';

import 'package:test/test.dart';

import 'package:dangi_doctor/generator/app_analyser.dart';

Directory _project(String appStateContent) {
  final dir = Directory.systemTemp.createTempSync('dangi_analyser_');
  File('${dir.path}/pubspec.yaml').writeAsStringSync('name: fixture_app\n');
  Directory('${dir.path}/lib').createSync(recursive: true);
  File('${dir.path}/lib/main.dart').writeAsStringSync('''
import 'package:flutter/material.dart';
void main() { runApp(const MyApp()); }
class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp();
}
''');
  File('${dir.path}/lib/app_state.dart').writeAsStringSync(appStateContent);
  return dir;
}

void main() {
  group('_analyseAppState fallback (#20)', () {
    test('uses the actual class name when it does not contain "AppState"',
        () async {
      final dir = _project('''
class GlobalStore {
  String authToken = '';
}
''');
      addTearDown(() => dir.deleteSync(recursive: true));
      final a = await AppAnalyser(projectPath: dir.path).analyse();
      expect(a.appStateClass, 'GlobalStore');
      expect(a.appStateTokenField, 'authToken');
    });

    test('skips state-priming when the file declares no class at all',
        () async {
      final dir = _project("String authToken = '';\n");
      addTearDown(() => dir.deleteSync(recursive: true));
      final a = await AppAnalyser(projectPath: dir.path).analyse();
      expect(a.appStateTokenField, isNull,
          reason: 'no class exists — priming would emit AppState() which '
              'does not compile');
      expect(a.appStateInitMethod, isNull);
    });
  });
}
