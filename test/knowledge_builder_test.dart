import 'package:test/test.dart';

import '../tool/src/knowledge_builder.dart';

void main() {
  group('mergeWithPrevious', () {
    final previousFile = generateDartConst(
      varName: 'kLayer1Content',
      comment: '// AUTO-GENERATED',
      content: buildLayer1({
        'changelog': 'old changelog body',
        'testing': 'old testing docs',
        'performance': 'old perf docs',
        'constraints': 'old constraints docs',
        'devtools_perf': 'old devtools perf docs',
        'devtools_memory': 'old devtools memory docs',
        'android_deploy': 'old android docs',
        'fetch_data': 'old fetch data docs',
      }),
    );

    test('keeps fresh content when fetch succeeded', () {
      final merged = mergeWithPrevious(
        fresh: {'changelog': 'new changelog', 'testing': 'new testing'},
        previousFile: previousFile,
      );
      expect(merged['changelog'], 'new changelog');
      expect(merged['testing'], 'new testing');
    });

    test('falls back to previous section when fetch failed', () {
      final merged = mergeWithPrevious(
        fresh: {'changelog': 'new changelog', 'testing': ''},
        previousFile: previousFile,
      );
      expect(merged['testing'], contains('old testing docs'));
    });

    test('does not resurrect an (unavailable) placeholder from previous file',
        () {
      final degraded = generateDartConst(
        varName: 'kLayer1Content',
        comment: '// AUTO-GENERATED',
        content: buildLayer1({'changelog': 'old changelog'}),
      );
      final merged = mergeWithPrevious(
        fresh: {'changelog': 'new changelog', 'testing': ''},
        previousFile: degraded,
      );
      expect(merged['testing'], anyOf(isNull, isEmpty));
    });

    test('missing section with no previous content stays empty', () {
      final merged = mergeWithPrevious(
        fresh: {'changelog': '', 'testing': ''},
        previousFile: null,
      );
      expect(merged['changelog'], anyOf(isNull, isEmpty));
    });
  });

  group('missingSections', () {
    test('reports sections that ended up with no content', () {
      final missing = missingSections({
        'changelog': 'real content',
        'testing': '',
        'performance': '(unavailable)',
      });
      expect(missing, containsAll(['testing', 'performance']));
      expect(missing, isNot(contains('changelog')));
    });
  });

  group('renderLayer1FileOrNull', () {
    test('returns null when any section is missing — caller must not write',
        () {
      expect(
          renderLayer1FileOrNull({'changelog': 'real content', 'testing': ''}),
          isNull);
      expect(
          renderLayer1FileOrNull(
              {'changelog': 'real content', 'testing': '(unavailable)'}),
          isNull);
    });

    test('returns the generated file when every section has content', () {
      final file = renderLayer1FileOrNull({
        'changelog': 'CHANGELOG BODY',
        'testing': 'TESTING BODY',
      });
      expect(file, isNotNull);
      expect(file, contains('const String kLayer1Content'));
      expect(file, contains('CHANGELOG BODY'));
      expect(file, contains('AUTO-GENERATED'));
    });
  });

  group('generateDartConst', () {
    test('is deterministic — no timestamps, same input same output', () {
      final a =
          generateDartConst(varName: 'kX', comment: '// c', content: 'body');
      final b =
          generateDartConst(varName: 'kX', comment: '// c', content: 'body');
      expect(a, b);
      expect(a, isNot(matches(RegExp(r'Updated:'))));
    });

    test('escapes content that would break a triple-quoted Dart string', () {
      final out = generateDartConst(
        varName: 'kX',
        comment: '// c',
        content: r"price is $100, path C:\dir, quote ''' done",
      );
      expect(out, contains(r'\$100'));
      expect(out, contains(r'C:\\dir'));
      expect(out, isNot(contains("quote ''' done")));
    });
  });

  group('buildLayer1 / extractSection round-trip', () {
    test('sections written by buildLayer1 can be extracted back', () {
      final content = buildLayer1({
        'changelog': 'CHANGELOG BODY',
        'testing': 'TESTING BODY',
      });
      final file = generateDartConst(
          varName: 'kLayer1Content', comment: '// c', content: content);
      expect(extractSection(file, 'changelog'), contains('CHANGELOG BODY'));
      expect(extractSection(file, 'testing'), contains('TESTING BODY'));
    });
  });

  group('parseChangelog', () {
    const sample = '''
# Changelog

## Flutter 3.41 Changes
- fix one
- fix two

## Flutter 3.38 Changes
- older fix

## Flutter 3.35 Changes
- ancient fix

## Flutter 3.32 Changes
- a

## Flutter 3.29 Changes
- b

## Flutter 3.27 Changes
- should be dropped (6th version)
''';

    test('keeps at most 5 versions and drops the rest', () {
      final out = parseChangelog(sample);
      expect(out, contains('Flutter 3.41'));
      expect(out, contains('Flutter 3.29'));
      expect(out, isNot(contains('3.27')));
    });

    test('caps each version section length', () {
      final long = '## Flutter 3.41 Changes\n${'x' * 5000}\n';
      final out = parseChangelog(long);
      expect(out.length, lessThan(3000));
      expect(out, contains('more fixes not shown'));
    });

    test('handles empty input gracefully', () {
      expect(parseChangelog(''), contains('unavailable'));
    });
  });

  group('trimMarkdown', () {
    test('strips html and jekyll tags and caps length', () {
      final out = trimMarkdown(
          '<img src=x>Hello {% comment %} world [[note]] text', 1000);
      expect(out, isNot(contains('<img')));
      expect(out, isNot(contains('{%')));
      expect(out, contains('Hello'));
    });

    test('empty input becomes (unavailable)', () {
      expect(trimMarkdown('', 100), '(unavailable)');
    });
  });
}
