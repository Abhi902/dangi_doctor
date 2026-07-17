import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

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

  group('PerformanceCapture lifecycle (fake VM service)', () {
    late _FakeVm fake;
    late PerformanceCapture capture;

    setUp(() {
      fake = _FakeVm();
      capture = PerformanceCapture(vmService: fake.service, isolateId: 'iso-1');
    });

    tearDown(() async {
      PerformanceCapture.frameBudgetMs = 16.0;
      await fake.close();
    });

    test('startRecording turns the timeline on; abandon turns it back off',
        () async {
      await capture.startRecording();
      expect(fake.calls,
          contains('setVMTimelineFlags(["Dart","Embedder","GC"])'));
      await capture.abandon();
      expect(fake.calls.last, 'setVMTimelineFlags([])');
    });

    test('abandon cancels the Flutter.Frame subscription', () async {
      await capture.startRecording();
      await capture.abandon();
      // Were the subscription still live, this frame would land in the
      // buffer and be analysed below.
      fake.emitFrame();
      await _pump();
      final perf = await capture.stopAndAnalyse('TestScreen');
      expect(perf.totalFrames, 0);
    });

    test('abandon discards frames — a later capture starts clean', () async {
      await capture.startRecording();
      fake.emitFrame(buildUs: 5000, rasterUs: 3000);
      await _pump();
      await capture.abandon();

      await capture.startRecording();
      fake.emitFrame(buildUs: 20000, rasterUs: 1000);
      await _pump();
      final perf = await capture.stopAndAnalyse('TestScreen');
      expect(perf.totalFrames, 1);
      expect(perf.frames.single.buildMs, closeTo(20.0, 0.01));
    });

    test('abandon is safe twice and without startRecording', () async {
      await capture.abandon(); // never started
      await capture.startRecording();
      await capture.abandon();
      await capture.abandon(); // double abandon
      expect(fake.calls.last, 'setVMTimelineFlags([])');
    });

    test('stopAndAnalyse pairs with startRecording and resets the timeline',
        () async {
      await capture.startRecording();
      fake.emitFrame(buildUs: 18000, rasterUs: 4000);
      await _pump();
      final perf = await capture.stopAndAnalyse('HomeScreen');
      expect(perf.totalFrames, 1);
      expect(perf.frames.single.buildMs, closeTo(18.0, 0.01));
      expect(fake.calls, contains('setVMTimelineFlags([])'));
    });
  });
}

/// Minimal in-memory JSON-RPC peer standing in for a real Dart VM.
/// Records every outgoing RPC in [calls] and answers with a well-typed
/// success result; [emitFrame] delivers a `Flutter.Frame` Extension-stream
/// event exactly as the VM would.
class _FakeVm {
  final _incoming = StreamController<String>();
  final calls = <String>[];
  late final VmService service;

  _FakeVm() {
    service = VmService(_incoming.stream, _handleRequest);
  }

  void _handleRequest(String message) {
    final req = jsonDecode(message) as Map<String, dynamic>;
    final method = req['method'] as String;
    final params = (req['params'] as Map?)?.cast<String, dynamic>() ?? {};
    if (method == 'setVMTimelineFlags') {
      calls.add('setVMTimelineFlags(${jsonEncode(params['recordedStreams'])})');
    } else {
      calls.add(method);
    }
    final Map<String, dynamic> result = switch (method) {
      'getVMTimeline' => {
          'type': 'Timeline',
          'traceEvents': <Map<String, dynamic>>[],
          'timeOriginMicros': 0,
          'timeExtentMicros': 0,
        },
      'getMemoryUsage' => {
          'type': 'MemoryUsage',
          'heapUsage': 1024,
          'heapCapacity': 2048,
          'externalUsage': 0,
        },
      _ => {'type': 'Success'},
    };
    _incoming.add(
        jsonEncode({'jsonrpc': '2.0', 'id': req['id'], 'result': result}));
  }

  void emitFrame({int buildUs = 5000, int rasterUs = 3000}) {
    _incoming.add(jsonEncode({
      'jsonrpc': '2.0',
      'method': 'streamNotify',
      'params': {
        'streamId': 'Extension',
        'event': {
          'type': 'Event',
          'kind': 'Extension',
          'timestamp': 0,
          'extensionKind': 'Flutter.Frame',
          'extensionData': {
            'number': 1,
            'startTime': 0,
            'elapsed': buildUs + rasterUs,
            'build': buildUs,
            'raster': rasterUs,
          },
        },
      },
    }));
  }

  Future<void> close() => _incoming.close();
}

/// Let queued stream events and JSON-RPC responses get delivered.
Future<void> _pump() => Future<void>.delayed(Duration.zero);
