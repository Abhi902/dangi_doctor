import 'package:test/test.dart';

import 'package:dangi_doctor/crawler/screen_crawler.dart';

void main() {
  group('pickFlutterIsolateId', () {
    test('picks the isolate exposing ext.flutter.* extensions', () {
      final picked = pickFlutterIsolateId({
        'isolates/111': ['ext.dart.io.getOpenFiles'], // helper isolate
        'isolates/222': [
          'ext.flutter.debugDumpApp',
          'ext.flutter.inspector.getRootWidgetTree',
        ],
      });
      expect(picked, 'isolates/222');
    });

    test('skips isolates with no extensions even when they come first', () {
      final picked = pickFlutterIsolateId({
        'isolates/background': <String>[],
        'isolates/ui': ['ext.flutter.platformOverride'],
      });
      expect(picked, 'isolates/ui');
    });

    test('returns null when no isolate qualifies', () {
      expect(pickFlutterIsolateId({}), isNull);
      expect(pickFlutterIsolateId({'isolates/1': <String>[]}), isNull);
      expect(
          pickFlutterIsolateId({
            'isolates/1': ['ext.dart.io.httpEnableTimelineLogging'],
          }),
          isNull);
    });
  });
}
