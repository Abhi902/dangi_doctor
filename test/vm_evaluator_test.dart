import 'package:test/test.dart';

import 'package:dangi_doctor/crawler/vm_evaluator.dart';

void main() {
  group('dartLiteral', () {
    test('leaves plain routes untouched', () {
      expect(dartLiteral('/settings/profile'), '/settings/profile');
    });

    test('escapes single quotes so the literal cannot be closed early', () {
      expect(dartLiteral("/o'brien"), r"/o\'brien");
    });

    test(r'escapes $ so interpolation cannot execute in the isolate', () {
      expect(dartLiteral(r'/user/$id'), r'/user/\$id');
    });

    test('escapes backslashes', () {
      expect(dartLiteral(r'a\b'), r'a\\b');
    });

    test('backslash is escaped FIRST — combined input stays unambiguous', () {
      // Input: \'$  →  \\ then \' then \$  (no double-escaping of added slashes)
      expect(dartLiteral(r"\'$"), r"\\\'\$");
    });

    test('injection attempt becomes inert text', () {
      const evil = "'); Navigator.pop(context); ('";
      expect(dartLiteral(evil), r"\'); Navigator.pop(context); (\'");
    });
  });
}
