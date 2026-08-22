import 'dart:io';

import 'package:test/test.dart';

import 'package:dangi_doctor/crawler/screen_navigator.dart';
import 'package:dangi_doctor/report/html_report.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('dangi_report_'));
  tearDown(() => dir.deleteSync(recursive: true));

  DiscoveredScreen screen() => DiscoveredScreen(
        name: 'HomePage',
        widgetTree: {},
        issues: [],
        totalWidgets: 10,
        maxDepth: 3,
      );

  test('escapes projectName in title and subtitle', () async {
    final path = await HtmlReportGenerator.generate(
      screens: [screen()],
      knownRisks: [],
      projectPath: dir.path,
      projectName: "<Evil>&'Co",
      openInBrowser: false,
    );
    final html = File(path).readAsStringSync();
    expect(html, contains('&lt;Evil&gt;&amp;&#39;Co'));
    expect(html, isNot(contains("<Evil>&'Co")));
  });

  test('report filename includes seconds', () async {
    final path = await HtmlReportGenerator.generate(
      screens: [screen()],
      knownRisks: [],
      projectPath: dir.path,
      projectName: 'app',
      openInBrowser: false,
    );
    expect(RegExp(r'report_\d{8}_\d{6}\.html$').hasMatch(path), isTrue,
        reason: 'two same-minute runs must not overwrite each other: $path');
  });
}
