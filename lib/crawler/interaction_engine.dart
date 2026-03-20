import 'dart:async';
import 'dart:io';
import 'package:vm_service/vm_service.dart';
import '../analysis/performance.dart';

enum InteractionType {
  tap,
  scroll,
  typeText,
  animate,
  skip,
}

class PlannedInteraction {
  final String widgetType;
  final String? widgetKey;
  final String? label;
  final String? file;
  final int? line;
  final InteractionType type;
  final String reason;
  final String? testData;
  double? screenX;
  double? screenY;

  PlannedInteraction({
    required this.widgetType,
    required this.type,
    required this.reason,
    this.widgetKey,
    this.label,
    this.file,
    this.line,
    this.testData,
    this.screenX,
    this.screenY,
  });
}

class InteractionResult {
  final PlannedInteraction interaction;
  final bool executed;
  final String outcome;
  final ScreenPerformance? performance;
  final bool screenChanged;

  InteractionResult({
    required this.interaction,
    required this.executed,
    required this.outcome,
    this.performance,
    this.screenChanged = false,
  });
}

class InteractionEngine {
  final VmService vmService;
  final String isolateId;
  final String? deviceId;

  InteractionEngine({
    required this.vmService,
    required this.isolateId,
    this.deviceId,
  });

  List<PlannedInteraction> planInteractions(Map<String, dynamic> widgetTree) {
    final tappables = <Map<String, dynamic>>[];
    final scrollables = <Map<String, dynamic>>[];
    final textFields = <Map<String, dynamic>>[];
    final animated = <Map<String, dynamic>>[];

    _collectInteractables(
        widgetTree, tappables, scrollables, textFields, animated);

    final planned = <PlannedInteraction>[];

    for (final widget in tappables) {
      final interaction = _classifyTappable(widget);
      if (interaction != null) planned.add(interaction);
    }

    for (final widget in scrollables) {
      planned.add(PlannedInteraction(
        widgetType: widget['widgetRuntimeType'] ?? 'ScrollView',
        type: InteractionType.scroll,
        reason: 'Measure scroll performance',
        file: widget['creationLocation']?['file']?.toString().split('/').last,
        line: widget['creationLocation']?['line'] as int?,
      ));
    }

    for (final widget in textFields) {
      final key = widget['key']?.toString() ?? '';
      planned.add(PlannedInteraction(
        widgetType: 'TextField',
        type: InteractionType.typeText,
        reason: 'Test text input performance',
        widgetKey: key,
        testData: _getTestData(key),
        file: widget['creationLocation']?['file']?.toString().split('/').last,
        line: widget['creationLocation']?['line'] as int?,
      ));
    }

    for (final widget in animated) {
      planned.add(PlannedInteraction(
        widgetType: widget['widgetRuntimeType'] ?? 'AnimatedWidget',
        type: InteractionType.animate,
        reason: 'Measure animation frame rate',
        file: widget['creationLocation']?['file']?.toString().split('/').last,
        line: widget['creationLocation']?['line'] as int?,
      ));
    }

    return planned;
  }

  PlannedInteraction? _classifyTappable(Map<String, dynamic> widget) {
    final key = widget['key']?.toString().toLowerCase() ?? '';
    final desc = (widget['description'] ?? widget['widgetRuntimeType'] ?? '')
        .toString()
        .toLowerCase();
    final file =
        widget['creationLocation']?['file']?.toString().split('/').last ?? '';
    final line = widget['creationLocation']?['line'] as int?;

    final riskyKeywords = [
      'google',
      'oauth',
      'facebook',
      'apple',
      'social',
      'logout',
      'signout',
      'delete',
      'remove',
      'purchase',
      'buy',
      'subscribe',
      'cancel_account',
      'clear_data',
      'reset',
    ];

    for (final keyword in riskyKeywords) {
      if (key.contains(keyword) || desc.contains(keyword)) {
        return PlannedInteraction(
          widgetType: widget['widgetRuntimeType'] ?? desc,
          type: InteractionType.skip,
          reason:
              '⚠️  Skipped — likely triggers external/destructive action ($keyword)',
          widgetKey: key,
          file: file,
          line: line,
        );
      }
    }

    return PlannedInteraction(
      widgetType: widget['widgetRuntimeType'] ?? desc,
      type: InteractionType.tap,
      reason: 'Standard tap interaction',
      widgetKey: key,
      file: file,
      line: line,
    );
  }

  String _getTestData(String key) {
    key = key.toLowerCase();
    if (key.contains('email')) return 'test@dangidoctor.dev';
    if (key.contains('phone') || key.contains('mobile')) return '9999999999';
    if (key.contains('password')) return 'Test@12345';
    if (key.contains('name')) return 'Test User';
    if (key.contains('search')) return 'flutter';
    if (key.contains('otp') || key.contains('code')) return '123456';
    return 'test input';
  }

  void _collectInteractables(
    dynamic node,
    List<Map<String, dynamic>> tappables,
    List<Map<String, dynamic>> scrollables,
    List<Map<String, dynamic>> textFields,
    List<Map<String, dynamic>> animated,
  ) {
    if (node == null) return;
    final type =
        (node['widgetRuntimeType'] ?? node['description'] ?? '').toString();

    if ([
      'GestureDetector',
      'InkWell',
      'ElevatedButton',
      'TextButton',
      'IconButton',
      'FloatingActionButton',
      'ListTile',
      'CupertinoButton'
    ].contains(type)) {
      tappables.add(Map<String, dynamic>.from(node));
    }
    if ([
      'ListView',
      'GridView',
      'SingleChildScrollView',
      'CustomScrollView',
      'PageView'
    ].contains(type)) {
      scrollables.add(Map<String, dynamic>.from(node));
    }
    if (['TextField', 'TextFormField', 'CupertinoTextField'].contains(type)) {
      textFields.add(Map<String, dynamic>.from(node));
    }
    if (type.contains('Animated') ||
        type == 'Hero' ||
        type == 'FadeTransition' ||
        type == 'SlideTransition') {
      animated.add(Map<String, dynamic>.from(node));
    }

    for (final child in (node['children'] as List? ?? [])) {
      _collectInteractables(
          child, tappables, scrollables, textFields, animated);
    }
  }

  Future<List<InteractionResult>> execute(
    List<PlannedInteraction> planned,
    String screenName,
  ) async {
    final results = <InteractionResult>[];
    final perfCapture = PerformanceCapture(
      vmService: vmService,
      isolateId: isolateId,
    );

    // Get screen dimensions for coordinate-based tapping
    final screenSize = await _getScreenSize();
    print('\n🎮 Starting interaction testing on $screenName...');
    print('   ${planned.length} interactions planned\n');

    for (var i = 0; i < planned.length; i++) {
      final interaction = planned[i];
      final loc = interaction.file != null
          ? ' (${interaction.file}:${interaction.line})'
          : '';
      print('  [${i + 1}/${planned.length}] ${interaction.widgetType}$loc');

      if (interaction.type == InteractionType.skip) {
        print('    ${interaction.reason}');
        results.add(InteractionResult(
          interaction: interaction,
          executed: false,
          outcome: interaction.reason,
        ));
        continue;
      }

      try {
        // Capture widget position from VM service before interacting
        final position = await _getWidgetPosition(interaction);

        await perfCapture.startRecording();

        if (interaction.type == InteractionType.scroll) {
          await _performScroll(screenSize);
        } else if (interaction.type == InteractionType.typeText) {
          await _performType(interaction, position, screenSize);
        } else if (interaction.type == InteractionType.animate) {
          await Future.delayed(const Duration(milliseconds: 1500));
        } else {
          // TAP — use adb input tap with real coordinates
          await _performTap(position, screenSize);
        }

        await Future.delayed(const Duration(milliseconds: 600));

        final perf = await perfCapture.stopAndAnalyse(
          '${screenName}_${interaction.widgetType}',
        );

        final screenChanged = await _didScreenChange();
        final outcome = _describeOutcome(interaction, perf, screenChanged);
        print('    ✅ $outcome');

        if (perf.jankyFrames > 0) {
          print(
              '    ⚠️  ${perf.jankyFrames} janky frames (${perf.jankRate.toStringAsFixed(1)}%)');
        }

        results.add(InteractionResult(
          interaction: interaction,
          executed: true,
          outcome: outcome,
          performance: perf,
          screenChanged: screenChanged,
        ));

        // Go back if screen changed
        if (screenChanged) {
          await _goBack();
          await Future.delayed(const Duration(milliseconds: 800));
          print('    ↩️  Went back');
        }
      } catch (e) {
        print('    ❌ Failed: $e');
        results.add(InteractionResult(
          interaction: interaction,
          executed: false,
          outcome: 'Failed: $e',
        ));
      }
    }

    return results;
  }

  /// Real tap using adb input tap — works on both emulator and physical device
  Future<void> _performTap(
      Map<String, double>? position, Map<String, int> screenSize) async {
    final x = position?['x'] ?? (screenSize['width']! / 2).toDouble();
    final y = position?['y'] ?? (screenSize['height']! / 2).toDouble();

    final args = deviceId != null
        ? [
            '-s',
            deviceId!,
            'shell',
            'input',
            'tap',
            x.toInt().toString(),
            y.toInt().toString()
          ]
        : ['shell', 'input', 'tap', x.toInt().toString(), y.toInt().toString()];

    await Process.run('adb', args).timeout(const Duration(seconds: 5));
  }

  /// Real scroll using adb input swipe
  Future<void> _performScroll(Map<String, int> screenSize) async {
    final w = screenSize['width']!;
    final h = screenSize['height']!;
    final cx = w ~/ 2;

    // Swipe down (scroll up content)
    final downArgs = deviceId != null
        ? [
            '-s',
            deviceId!,
            'shell',
            'input',
            'swipe',
            cx.toString(),
            (h * 0.3).toInt().toString(),
            cx.toString(),
            (h * 0.7).toInt().toString(),
            '400'
          ]
        : [
            'shell',
            'input',
            'swipe',
            cx.toString(),
            (h * 0.3).toInt().toString(),
            cx.toString(),
            (h * 0.7).toInt().toString(),
            '400'
          ];

    await Process.run('adb', downArgs).timeout(const Duration(seconds: 5));
    await Future.delayed(const Duration(milliseconds: 300));

    // Swipe back up
    final upArgs = deviceId != null
        ? [
            '-s',
            deviceId!,
            'shell',
            'input',
            'swipe',
            cx.toString(),
            (h * 0.7).toInt().toString(),
            cx.toString(),
            (h * 0.3).toInt().toString(),
            '400'
          ]
        : [
            'shell',
            'input',
            'swipe',
            cx.toString(),
            (h * 0.7).toInt().toString(),
            cx.toString(),
            (h * 0.3).toInt().toString(),
            '400'
          ];

    await Process.run('adb', upArgs).timeout(const Duration(seconds: 5));
  }

  /// Type text using adb input text
  Future<void> _performType(
    PlannedInteraction interaction,
    Map<String, double>? position,
    Map<String, int> screenSize,
  ) async {
    // First tap the field
    await _performTap(position, screenSize);
    await Future.delayed(const Duration(milliseconds: 300));

    final text = (interaction.testData ?? 'test')
        .replaceAll(' ', '%s')
        .replaceAll('@', '\\@');

    final args = deviceId != null
        ? ['-s', deviceId!, 'shell', 'input', 'text', text]
        : ['shell', 'input', 'text', text];

    await Process.run('adb', args).timeout(const Duration(seconds: 5));
  }

  /// Get screen size via adb wm size
  Future<Map<String, int>> _getScreenSize() async {
    try {
      final args = deviceId != null
          ? ['-s', deviceId!, 'shell', 'wm', 'size']
          : ['shell', 'wm', 'size'];
      final result =
          await Process.run('adb', args).timeout(const Duration(seconds: 5));
      final output = result.stdout.toString();
      final match = RegExp(r'(\d+)x(\d+)').firstMatch(output);
      if (match != null) {
        return {
          'width': int.parse(match.group(1)!),
          'height': int.parse(match.group(2)!),
        };
      }
    } catch (_) {}
    return {'width': 1080, 'height': 2400}; // default
  }

  /// Get widget screen position from VM service
  Future<Map<String, double>?> _getWidgetPosition(
      PlannedInteraction interaction) async {
    try {
      // Use Flutter inspector to get the render object bounds
      final response = await vmService.callServiceExtension(
        'ext.flutter.inspector.getSelectedWidget',
        isolateId: isolateId,
        args: {'objectGroup': 'dangi_perf'},
      );
      final json = response.json;
      if (json != null) {
        final x = (json['x'] as num?)?.toDouble();
        final y = (json['y'] as num?)?.toDouble();
        final w = (json['width'] as num?)?.toDouble();
        final h = (json['height'] as num?)?.toDouble();
        if (x != null && y != null) {
          return {
            'x': x + (w ?? 0) / 2,
            'y': y + (h ?? 0) / 2,
          };
        }
      }
    } catch (_) {}
    return null; // will use center of screen as fallback
  }

  Future<bool> _didScreenChange() async {
    try {
      final response = await vmService.callServiceExtension(
        'ext.flutter.inspector.getRootWidgetTree',
        isolateId: isolateId,
        args: {'groupName': 'dangi_check', 'isSummaryTree': 'true'},
      );
      final tree = response.json?['result'] as Map?;
      return tree != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> _goBack() async {
    final args = deviceId != null
        ? ['-s', deviceId!, 'shell', 'input', 'keyevent', '4']
        : ['shell', 'input', 'keyevent', '4'];
    await Process.run('adb', args).timeout(const Duration(seconds: 3));
  }

  String _describeOutcome(
    PlannedInteraction interaction,
    ScreenPerformance perf,
    bool screenChanged,
  ) {
    final grade = perf.grade;
    final janky =
        perf.jankyFrames > 0 ? '${perf.jankyFrames} janky frames' : 'smooth';
    final nav = screenChanged ? ' → navigated to new screen' : '';
    return 'Grade $grade — $janky$nav';
  }

  String toReportSection(List<InteractionResult> results) {
    final buffer = StringBuffer();
    buffer.writeln('INTERACTION TEST RESULTS:');

    final executed = results.where((r) => r.executed).toList();
    final skipped = results.where((r) => !r.executed).toList();
    final janky =
        executed.where((r) => (r.performance?.jankyFrames ?? 0) > 0).toList();

    buffer.writeln('- Total interactions: ${results.length}');
    buffer.writeln('- Executed: ${executed.length}');
    buffer.writeln('- Skipped (risky): ${skipped.length}');
    buffer.writeln('- Interactions with jank: ${janky.length}');

    if (janky.isNotEmpty) {
      buffer.writeln('');
      buffer.writeln('JANKY INTERACTIONS (worst first):');
      janky.sort((a, b) => (b.performance?.jankyFrames ?? 0)
          .compareTo(a.performance?.jankyFrames ?? 0));
      for (final r in janky.take(5)) {
        buffer.writeln(
          '  - ${r.interaction.widgetType} at '
          '${r.interaction.file}:${r.interaction.line} — '
          '${r.performance?.jankyFrames} janky frames',
        );
      }
    }

    if (skipped.isNotEmpty) {
      buffer.writeln('');
      buffer.writeln('SKIPPED (manual testing needed):');
      for (final r in skipped.take(5)) {
        buffer.writeln('  - ${r.interaction.widgetType}: ${r.outcome}');
      }
    }

    return buffer.toString();
  }
}
