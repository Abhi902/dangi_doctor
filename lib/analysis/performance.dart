import 'package:vm_service/vm_service.dart';

/// A single captured frame
class FrameData {
  final double buildMs;
  final double rasterMs;
  final bool isJanky;

  FrameData({
    required this.buildMs,
    required this.rasterMs,
  }) : isJanky = buildMs > 16.0 || rasterMs > 16.0;

  double get totalMs => buildMs + rasterMs;
}

/// Performance result for one screen
class ScreenPerformance {
  final String screenName;
  final List<FrameData> frames;
  final int memoryKb;

  ScreenPerformance({
    required this.screenName,
    required this.frames,
    required this.memoryKb,
  });

  int get totalFrames => frames.length;
  int get jankyFrames => frames.where((f) => f.isJanky).length;
  double get jankRate => totalFrames == 0 ? 0 : jankyFrames / totalFrames * 100;

  double get avgBuildMs => frames.isEmpty
      ? 0
      : frames.map((f) => f.buildMs).reduce((a, b) => a + b) / frames.length;

  double get avgRasterMs => frames.isEmpty
      ? 0
      : frames.map((f) => f.rasterMs).reduce((a, b) => a + b) / frames.length;

  double get worstFrameMs => frames.isEmpty
      ? 0
      : frames.map((f) => f.totalMs).reduce((a, b) => a > b ? a : b);

  /// Performance grade based on jank rate and avg frame time
  String get grade {
    if (jankRate == 0 && avgBuildMs < 8) return 'A';
    if (jankRate < 5 && avgBuildMs < 12) return 'B';
    if (jankRate < 15 && avgBuildMs < 16) return 'C';
    if (jankRate < 30) return 'D';
    return 'F';
  }

  String get gradeEmoji {
    switch (grade) {
      case 'A':
        return '🟢';
      case 'B':
        return '🟡';
      case 'C':
        return '🟠';
      case 'D':
        return '🔴';
      default:
        return '💀';
    }
  }

  void printReport() {
    print('\n┌─────────────────────────────────────────────┐');
    print('│  PERFORMANCE — $screenName');
    print('├─────────────────────────────────────────────┤');
    print('│  Grade         : ${gradeEmoji} $grade');
    print('│  Total frames  : $totalFrames');
    print('│  Janky frames  : $jankyFrames (${jankRate.toStringAsFixed(1)}%)');
    print('│  Avg build     : ${avgBuildMs.toStringAsFixed(2)}ms  '
        '(budget: 16ms)');
    print('│  Avg raster    : ${avgRasterMs.toStringAsFixed(2)}ms');
    print('│  Worst frame   : ${worstFrameMs.toStringAsFixed(2)}ms');
    print('│  Memory        : ${(memoryKb / 1024).toStringAsFixed(1)}MB');
    print('└─────────────────────────────────────────────┘');

    if (jankyFrames > 0) {
      print(
          '\n  ⚠️  Jank detected — user will feel stuttering on this screen.');
    }
    if (avgBuildMs > 16) {
      print(
          '  ⚠️  Avg build time exceeds 16ms — check for heavy build() work.');
    }
    if (avgRasterMs > 8) {
      print(
          '  ⚠️  High raster time — check for expensive painting operations,');
      print('      clipPath, saveLayer, or large image decoding.');
    }
    if (memoryKb > 200 * 1024) {
      print('  ⚠️  Memory over 200MB — check for image cache or leak.');
    }
  }
}

/// Captures performance data from the running Flutter app via VM service
class PerformanceCapture {
  final VmService vmService;
  final String isolateId;

  PerformanceCapture({
    required this.vmService,
    required this.isolateId,
  });

  /// Start recording — call this before interacting with a screen
  Future<void> startRecording() async {
    await vmService.clearVMTimeline();
    await vmService.setVMTimelineFlags(['Dart', 'Embedder', 'GC']);
    print('  ⏱️  Performance recording started...');
  }

  /// Stop recording and analyse — call this after screen interaction
  Future<ScreenPerformance> stopAndAnalyse(String screenName) async {
    print('  ⏹️  Stopping recording, analysing frames...');

    // Get timeline events
    final timeline = await vmService.getVMTimeline();
    final frames = _extractFrames(timeline);

    // Get memory usage
    final memoryKb = await _getMemoryKb();

    final perf = ScreenPerformance(
      screenName: screenName,
      frames: frames,
      memoryKb: memoryKb,
    );

    return perf;
  }

  List<FrameData> _extractFrames(Timeline timeline) {
    final frames = <FrameData>[];
    final events = timeline.traceEvents ?? [];

    // Flutter emits 'Frame' events with build and raster phases
    // We look for pairs of begin/end events
    final buildBegin = <int, int>{}; // frameNumber -> timestamp
    final buildEnd = <int, int>{};
    final rasterBegin = <int, int>{};
    final rasterEnd = <int, int>{};

    for (final event in events) {
      final args = event.json?['args'] as Map?;
      final name = event.json?['name'] as String? ?? '';
      final tsRaw = event.json?['ts'];
      final ts =
          tsRaw is int ? tsRaw : int.tryParse(tsRaw?.toString() ?? '0') ?? 0;
      final ph = event.json?['ph'] as String? ?? ''; // B=begin, E=end
      final frameNumRaw = args?['frame_number'];
      final frameNum = frameNumRaw is int
          ? frameNumRaw
          : int.tryParse(frameNumRaw?.toString() ?? '') ??
              events.indexOf(event);

      if (name.contains('Build') || name == 'Frame') {
        if (ph == 'B') buildBegin[frameNum] = ts;
        if (ph == 'E') buildEnd[frameNum] = ts;
      }

      if (name.contains('Rasterize') || name.contains('GPURasterizer')) {
        if (ph == 'B') rasterBegin[frameNum] = ts;
        if (ph == 'E') rasterEnd[frameNum] = ts;
      }
    }

    // Pair up begin/end events into frame data
    final frameNums =
        buildBegin.keys.toSet().intersection(buildEnd.keys.toSet());

    for (final num in frameNums) {
      final buildUs = (buildEnd[num]! - buildBegin[num]!);
      final rasterUs =
          rasterBegin.containsKey(num) && rasterEnd.containsKey(num)
              ? (rasterEnd[num]! - rasterBegin[num]!)
              : 0;

      // Convert microseconds to milliseconds
      final buildMs = buildUs / 1000.0;
      final rasterMs = rasterUs / 1000.0;

      // Filter out noise — ignore frames under 0.1ms
      if (buildMs > 0.1) {
        frames.add(FrameData(buildMs: buildMs, rasterMs: rasterMs.toDouble()));
      }
    }

    // If timeline parsing yields nothing (common in some Flutter versions),
    // fall back to Flutter's built-in frame stats
    if (frames.isEmpty) {
      return _fallbackFrameStats(events);
    }

    return frames;
  }

  /// Fallback: use Flutter's _flutter.frameRasterized events
  List<FrameData> _fallbackFrameStats(List<TimelineEvent> events) {
    final frames = <FrameData>[];

    for (final event in events) {
      final name = event.json?['name'] as String? ?? '';
      if (name == 'Frame' || name.contains('flutter.frame')) {
        final args = event.json?['args'] as Map? ?? {};
        final buildDuration = args['build_duration_us'] as int?;
        final rasterDuration = args['raster_duration_us'] as int?;

        if (buildDuration != null) {
          frames.add(FrameData(
            buildMs: buildDuration / 1000.0,
            rasterMs: (rasterDuration ?? 0) / 1000.0,
          ));
        }
      }
    }

    return frames;
  }

  Future<int> _getMemoryKb() async {
    try {
      final isolate = await vmService.getIsolate(isolateId);
      final heapUsage = isolate.pauseEvent?.json?['heapUsage'] as int?;
      if (heapUsage != null) return (heapUsage / 1024).round();

      // Fallback: use memory usage from isolate
      final memUsage = await vmService.callServiceExtension(
        'ext.flutter.profileMemory',
        isolateId: isolateId,
        args: {},
      );
      final rss = memUsage.json?['rss'] as int? ?? 0;
      return (rss / 1024).round();
    } catch (_) {
      // Memory capture not critical — return 0 if unavailable
      return 0;
    }
  }

  /// Quick snapshot — captures a 2 second window of frames
  Future<ScreenPerformance> captureWindow({
    required String screenName,
    int durationMs = 2000,
  }) async {
    await startRecording();
    await Future.delayed(Duration(milliseconds: durationMs));
    return await stopAndAnalyse(screenName);
  }
}
