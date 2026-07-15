import 'dart:async';

import 'package:vm_service/vm_service.dart';

/// Parse the display refresh rate out of `adb shell dumpsys display` output.
/// Returns null when nothing parseable is present.
double? parseDisplayRefreshRate(String dumpsysOutput) {
  final match = RegExp(r'renderFrameRate\s+(\d+(?:\.\d+)?)')
          .firstMatch(dumpsysOutput) ??
      RegExp(r'fps=(\d+(?:\.\d+)?)').firstMatch(dumpsysOutput);
  if (match == null) return null;
  final hz = double.parse(match.group(1)!);
  return hz > 0 ? hz : null;
}

/// The per-frame budget for a display refresh rate: 16.7ms at 60Hz,
/// 11.1ms at 90Hz, 8.3ms at 120Hz. Judging a 120Hz phone against 16ms
/// grades a visibly janky app as "A".
double budgetMsForRefreshRate(double hz) => 1000.0 / hz;

/// Convert one `Flutter.Frame` extension-stream event's data (all fields in
/// microseconds — the same interface DevTools consumes) into a [FrameData].
FrameData? frameFromFlutterFrameEvent(Map<String, dynamic> data) {
  final build = data['build'];
  final raster = data['raster'];
  if (build is! int || raster is! int) return null;
  return FrameData(buildMs: build / 1000.0, rasterMs: raster / 1000.0);
}

/// Fallback timeline parsing: modern engines emit frame phases as COMPLETE
/// events (`ph: "X"` with a `dur`), not the Begin/End pairs keyed by
/// frame_number that older code assumed. Build ("Frame") and raster
/// ("GPURasterizer::Draw"/"Rasterizer::DoDraw") run pipelined on separate
/// threads, so we pair them by order of appearance.
List<FrameData> parseTimelineFrames(List<Map<String, dynamic>> events) {
  final buildsUs = <int>[];
  final rastersUs = <int>[];

  for (final event in events) {
    if (event['ph'] != 'X') continue;
    final dur = event['dur'];
    if (dur is! int) continue;
    final name = event['name'] as String? ?? '';
    if (name == 'Frame') {
      buildsUs.add(dur);
    } else if (name == 'GPURasterizer::Draw' || name == 'Rasterizer::DoDraw') {
      rastersUs.add(dur);
    }
  }

  return [
    for (var i = 0; i < buildsUs.length; i++)
      FrameData(
        buildMs: buildsUs[i] / 1000.0,
        rasterMs: i < rastersUs.length ? rastersUs[i] / 1000.0 : 0,
      ),
  ];
}

/// A single captured frame. Jank is judged against the device's actual
/// frame budget ([PerformanceCapture.frameBudgetMs]), captured at
/// construction time.
class FrameData {
  final double buildMs;
  final double rasterMs;
  final bool isJanky;

  FrameData({
    required this.buildMs,
    required this.rasterMs,
  }) : isJanky = buildMs > PerformanceCapture.frameBudgetMs ||
            rasterMs > PerformanceCapture.frameBudgetMs;

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

  /// Performance grade based on jank rate and avg build time relative to
  /// the device's frame budget (0.5x/0.75x/1x — at 60Hz that's the classic
  /// 8/12/16ms thresholds).
  String get grade {
    final budget = PerformanceCapture.frameBudgetMs;
    if (jankRate == 0 && avgBuildMs < budget * 0.5) return 'A';
    if (jankRate < 5 && avgBuildMs < budget * 0.75) return 'B';
    if (jankRate < 15 && avgBuildMs < budget) return 'C';
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
    final budget = PerformanceCapture.frameBudgetMs.toStringAsFixed(1);
    print('\n┌─────────────────────────────────────────────┐');
    print('│  PERFORMANCE — $screenName');
    print('├─────────────────────────────────────────────┤');
    print('│  Grade         : $gradeEmoji $grade');
    print('│  Total frames  : $totalFrames');
    print('│  Janky frames  : $jankyFrames (${jankRate.toStringAsFixed(1)}%)');
    print('│  Avg build     : ${avgBuildMs.toStringAsFixed(2)}ms  '
        '(budget: ${budget}ms)');
    print('│  Avg raster    : ${avgRasterMs.toStringAsFixed(2)}ms');
    print('│  Worst frame   : ${worstFrameMs.toStringAsFixed(2)}ms');
    if (memoryKb > 0) {
      print('│  Memory        : ${(memoryKb / 1024).toStringAsFixed(1)}MB');
    }
    print('└─────────────────────────────────────────────┘');

    if (jankyFrames > 0) {
      print(
          '\n  ⚠️  Jank detected — user will feel stuttering on this screen.');
    }
    if (avgBuildMs > PerformanceCapture.frameBudgetMs) {
      print(
          '  ⚠️  Avg build time exceeds the ${budget}ms frame budget — check for heavy build() work.');
    }
    if (avgRasterMs > PerformanceCapture.frameBudgetMs / 2) {
      print(
          '  ⚠️  High raster time — check for expensive painting operations,');
      print('      clipPath, saveLayer, or large image decoding.');
    }
    if (memoryKb > 200 * 1024) {
      print('  ⚠️  Memory over 200MB — check for image cache or leak.');
    }
  }
}

/// Captures performance data from the running Flutter app via VM service.
///
/// Primary source: `Flutter.Frame` events on the VM's Extension stream —
/// the stable, documented interface DevTools itself uses (`build`, `raster`,
/// `elapsed` in microseconds per frame). Timeline parsing is kept only as a
/// fallback for engines that don't emit them.
class PerformanceCapture {
  final VmService vmService;
  final String isolateId;

  /// Per-frame budget in ms. 16.0 (60Hz) unless the device's real refresh
  /// rate was detected (see [parseDisplayRefreshRate]) — set once at startup.
  static double frameBudgetMs = 16.0;

  final List<FrameData> _frameEvents = [];
  StreamSubscription<Event>? _subscription;

  PerformanceCapture({
    required this.vmService,
    required this.isolateId,
  });

  /// Start recording — call this before interacting with a screen
  Future<void> startRecording() async {
    _frameEvents.clear();

    // Subscribe to Flutter.Frame extension events. streamListen throws
    // RPCError 103 when the stream is already subscribed (another capture,
    // or a previous run) — that's fine, our listener still receives events.
    try {
      await vmService.streamListen(EventStreams.kExtension);
    } on RPCError catch (e) {
      if (e.code != 103) rethrow;
    }
    _subscription ??= vmService.onExtensionEvent.listen((event) {
      if (event.extensionKind != 'Flutter.Frame') return;
      final data = event.extensionData?.data;
      if (data == null) return;
      final frame = frameFromFlutterFrameEvent(data);
      if (frame != null) _frameEvents.add(frame);
    });

    // Timeline recording stays on as the fallback source.
    await vmService.clearVMTimeline();
    await vmService.setVMTimelineFlags(['Dart', 'Embedder', 'GC']);
    print('  ⏱️  Performance recording started...');
  }

  /// Stop recording and analyse — call this after screen interaction
  Future<ScreenPerformance> stopAndAnalyse(String screenName) async {
    print('  ⏹️  Stopping recording, analysing frames...');

    List<FrameData> frames;
    try {
      frames = List.of(_frameEvents);
      if (frames.isEmpty) {
        // No Flutter.Frame events — fall back to timeline parsing.
        final timeline = await vmService.getVMTimeline();
        frames = parseTimelineFrames([
          for (final e in timeline.traceEvents ?? <TimelineEvent>[])
            if (e.json != null) e.json!.cast<String, dynamic>(),
        ]);
      }
    } finally {
      await _stopListening();
      // Always turn timeline recording back off — leaving it running burns
      // ring-buffer and CPU on-device for the rest of the session.
      try {
        await vmService.setVMTimelineFlags([]);
      } catch (_) {}
    }

    final memoryKb = await _getMemoryKb();

    return ScreenPerformance(
      screenName: screenName,
      frames: frames,
      memoryKb: memoryKb,
    );
  }

  Future<void> _stopListening() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<int> _getMemoryKb() async {
    try {
      // The first-class RPC — pauseEvent.heapUsage only exists on actual
      // pause events, so the old approach always returned 0 on a running
      // app, and ext.flutter.profileMemory does not exist.
      final usage = await vmService.getMemoryUsage(isolateId);
      final bytes = (usage.heapUsage ?? 0) + (usage.externalUsage ?? 0);
      return (bytes / 1024).round();
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
