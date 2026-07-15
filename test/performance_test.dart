import 'package:test/test.dart';

import 'package:dangi_doctor/analysis/performance.dart';

void main() {
  group('parseDisplayRefreshRate', () {
    test('parses fps from dumpsys display output', () {
      const out = '''
DisplayDeviceInfo{..., 1080 x 2400, modeId 2, renderFrameRate 120.000000,
   supportedModes ..., fps=120.0, ...}
''';
      expect(parseDisplayRefreshRate(out), 120.0);
    });

    test('returns null on garbage', () {
      expect(parseDisplayRefreshRate('error: no devices'), isNull);
    });
  });

  group('frame budget', () {
    tearDown(() => PerformanceCapture.frameBudgetMs = 16.0);

    test('budgetMsForRefreshRate maps 60/90/120 Hz correctly', () {
      expect(budgetMsForRefreshRate(60), closeTo(16.7, 0.1));
      expect(budgetMsForRefreshRate(90), closeTo(11.1, 0.1));
      expect(budgetMsForRefreshRate(120), closeTo(8.3, 0.1));
    });

    test('a 12ms build is fine at 60Hz but janky at 120Hz', () {
      PerformanceCapture.frameBudgetMs = budgetMsForRefreshRate(60);
      expect(FrameData(buildMs: 12, rasterMs: 2).isJanky, isFalse);
      PerformanceCapture.frameBudgetMs = budgetMsForRefreshRate(120);
      expect(FrameData(buildMs: 12, rasterMs: 2).isJanky, isTrue);
    });
  });

  group('frameFromFlutterFrameEvent', () {
    test('converts Flutter.Frame extension data (microseconds) to ms', () {
      final frame = frameFromFlutterFrameEvent({
        'number': 41,
        'startTime': 1000,
        'elapsed': 22000,
        'build': 18000,
        'raster': 4000,
      });
      expect(frame, isNotNull);
      expect(frame!.buildMs, closeTo(18.0, 0.01));
      expect(frame.rasterMs, closeTo(4.0, 0.01));
    });

    test('returns null for malformed data', () {
      expect(frameFromFlutterFrameEvent({'number': 1}), isNull);
    });
  });

  group('parseTimelineFrames (fallback path)', () {
    test('pairs complete (ph=X) build and raster events by order', () {
      final frames = parseTimelineFrames([
        {'name': 'Frame', 'ph': 'X', 'ts': 0, 'dur': 12000},
        {'name': 'GPURasterizer::Draw', 'ph': 'X', 'ts': 100, 'dur': 5000},
        {'name': 'Frame', 'ph': 'X', 'ts': 20000, 'dur': 30000},
        {'name': 'Rasterizer::DoDraw', 'ph': 'X', 'ts': 20100, 'dur': 4000},
        {'name': 'unrelated', 'ph': 'X', 'ts': 5, 'dur': 99999},
      ]);
      expect(frames, hasLength(2));
      expect(frames[0].buildMs, closeTo(12.0, 0.01));
      expect(frames[0].rasterMs, closeTo(5.0, 0.01));
      expect(frames[1].buildMs, closeTo(30.0, 0.01));
    });

    test('ignores begin/end style events it cannot pair', () {
      expect(
          parseTimelineFrames([
            {'name': 'Frame', 'ph': 'B', 'ts': 0},
            {'name': 'Frame', 'ph': 'E', 'ts': 12000},
          ]),
          isEmpty);
    });
  });
}
