import 'dart:async';
import 'dart:io';
import 'package:vm_service/vm_service.dart';
import '../analysis/tree_analyser.dart';
import '../analysis/performance.dart';

/// A single discovered screen
class DiscoveredScreen {
  final String name;
  final Map<String, dynamic> widgetTree;
  final ScreenPerformance? performance;
  final List<WidgetIssue> issues;
  final int totalWidgets;
  final int maxDepth;
  final String?
      navigatedVia; // which widget triggered navigation to this screen

  DiscoveredScreen({
    required this.name,
    required this.widgetTree,
    required this.issues,
    required this.totalWidgets,
    required this.maxDepth,
    this.performance,
    this.navigatedVia,
  });
}

/// Walks every reachable route in the Flutter app automatically
class ScreenNavigator {
  final VmService vmService;
  final String isolateId;
  final String? deviceId;
  final int maxScreens;

  final List<DiscoveredScreen> discoveredScreens = [];
  final Set<String> _visitedScreenNames = {};
  final TreeAnalyser _analyser = TreeAnalyser();

  ScreenNavigator({
    required this.vmService,
    required this.isolateId,
    this.deviceId,
    this.maxScreens = 10,
  });

  /// Walk all reachable screens from the current starting point
  Future<List<DiscoveredScreen>> walkAllScreens() async {
    print('\n🗺️  Starting full app navigation crawl...');
    print('   Will discover up to $maxScreens screens\n');

    // Step 1: capture and analyse the starting screen
    final startTree = await _captureTree();
    final startName = _detectScreenName(startTree);
    print('📍 Starting screen: $startName');

    await _analyseAndRecord(startTree, startName, navigatedVia: 'start');

    // Step 2: find all nav triggers on starting screen and explore
    await _exploreScreen(startTree, startName, depth: 0);

    print(
        '\n✅ Navigation crawl complete — ${discoveredScreens.length} screens discovered\n');
    return discoveredScreens;
  }

  Future<void> _exploreScreen(Map<String, dynamic> tree, String screenName,
      {required int depth}) async {
    if (depth > 3) return; // max depth to avoid infinite loops
    if (discoveredScreens.length >= maxScreens) return;

    // Find navigation triggers on this screen
    final navTriggers = _findNavTriggers(tree);
    print(
        '  🔍 Found ${navTriggers.length} navigation triggers on $screenName');

    for (final trigger in navTriggers) {
      if (discoveredScreens.length >= maxScreens) break;

      final triggerType = trigger['widgetRuntimeType']?.toString() ?? 'Widget';
      final file =
          trigger['creationLocation']?['file']?.toString().split('/').last ??
              '';
      final line = trigger['creationLocation']?['line']?.toString() ?? '?';

      print('  👆 Tapping $triggerType ($file:$line)...');

      // Tap the trigger
      final tapped = await _tap(trigger);
      if (!tapped) continue;

      // Wait longer for production apps with Firebase/animations
      await Future.delayed(const Duration(milliseconds: 2500));

      // Check if we navigated to a new screen
      final newTree = await _captureTree();
      final newName = _detectScreenName(newTree);
      final newCount = _countWidgets(newTree);
      final oldCount = _countWidgets(tree);

      // Screen changed = name changed OR widget count changed significantly
      final didNavigate =
          newName != screenName || (newCount - oldCount).abs() > 15;

      if (didNavigate && !_visitedScreenNames.contains(newName)) {
        print('  ✅ New screen discovered: $newName');
        _visitedScreenNames.add(newName);

        // Analyse and record the new screen
        await _analyseAndRecord(
          newTree,
          newName,
          navigatedVia: '$triggerType at $file:$line',
        );

        // Recursively explore this new screen
        await _exploreScreen(newTree, newName, depth: depth + 1);

        // Go back to previous screen
        await _goBack();
        await Future.delayed(const Duration(milliseconds: 800));

        // Verify we're back
        final backTree = await _captureTree();
        final backName = _detectScreenName(backTree);
        if (backName != screenName) {
          // Navigation state changed — stop exploring this branch
          print('  ⚠️  Could not return to $screenName — stopping branch');
          break;
        }
      } else if (_visitedScreenNames.contains(newName)) {
        // Already visited — go back
        await _goBack();
        await Future.delayed(const Duration(milliseconds: 600));
      }
    }
  }

  Future<void> _analyseAndRecord(
    Map<String, dynamic> tree,
    String screenName, {
    String? navigatedVia,
  }) async {
    _analyser.analyse(tree);

    // Capture performance
    final perfCapture = PerformanceCapture(
      vmService: vmService,
      isolateId: isolateId,
    );

    ScreenPerformance? perf;
    try {
      perf = await perfCapture.captureWindow(
        screenName: screenName,
        durationMs: 1500,
      );
    } catch (_) {}

    discoveredScreens.add(DiscoveredScreen(
      name: screenName,
      widgetTree: tree,
      issues: List.from(_analyser.issues),
      totalWidgets: _analyser.totalWidgets,
      maxDepth: _analyser.maxDepthFound,
      performance: perf,
      navigatedVia: navigatedVia,
    ));

    final issueCount = _analyser.issues.length;
    final grade = perf?.grade ?? 'N/A';
    print('  📊 $screenName — $issueCount issues — Perf grade: $grade');
  }

  int _countWidgets(Map<String, dynamic> tree) {
    int count = 1;
    for (final child in (tree['children'] as List? ?? [])) {
      count += _countWidgets(child as Map<String, dynamic>);
    }
    return count;
  }

  List<Map<String, dynamic>> _findNavTriggers(Map<String, dynamic> tree) {
    final triggers = <Map<String, dynamic>>[];
    _walkForTriggers(tree, triggers);

    // Deduplicate by file:line
    final seen = <String>{};
    return triggers.where((t) {
      final key =
          '${t['creationLocation']?['file']}:${t['creationLocation']?['line']}';
      return seen.add(key);
    }).toList();
  }

  void _walkForTriggers(dynamic node, List<Map<String, dynamic>> triggers) {
    if (node == null) return;
    final type = node['widgetRuntimeType']?.toString() ?? '';

    // Navigation triggers — these are likely to push new routes
    const navTypes = [
      'BottomNavigationBar',
      'BottomNavigationBarItem',
      'NavigationBar',
      'NavigationRail',
      'DrawerHeader',
      'ListTile',
      'TabBar',
      'Tab',
    ];

    // Also include tappable widgets that are likely navigation
    const tappableTypes = [
      'GestureDetector',
      'InkWell',
      'ElevatedButton',
      'TextButton',
      'IconButton',
    ];

    if (navTypes.contains(type)) {
      triggers.add(Map<String, dynamic>.from(node));
    } else if (tappableTypes.contains(type)) {
      // Only include if it looks like navigation (not inside a form)
      if (!_isFormWidget(node)) {
        triggers.add(Map<String, dynamic>.from(node));
      }
    }

    for (final child in (node['children'] as List? ?? [])) {
      _walkForTriggers(child, triggers);
    }
  }

  bool _isFormWidget(Map<String, dynamic> node) {
    // Heuristic: if the widget is near a TextField, it's probably a form submit
    // We'll keep this simple for now — skip widgets with 'submit', 'login', 'sign' in key
    final key = node['key']?.toString().toLowerCase() ?? '';
    return key.contains('submit') ||
        key.contains('login') ||
        key.contains('register') ||
        key.contains('signup') ||
        key.contains('password');
  }

  Future<bool> _tap(Map<String, dynamic> widget) async {
    try {
      // Get approximate screen position from VM service
      final response = await vmService.callServiceExtension(
        'ext.flutter.inspector.getLayoutExplorerNode',
        isolateId: isolateId,
        args: {
          'id': widget['valueId']?.toString() ?? '',
          'groupName': 'dangi_nav',
          'subtreeDepth': '1',
        },
      );

      final json = response.json;
      double? x, y;

      if (json != null && json['result'] != null) {
        final result = json['result'] as Map?;
        final renderObject = result?['renderObject'] as Map?;
        final rect = renderObject?['localToGlobal'] as Map?;
        if (rect != null) {
          x = (rect['x'] as num?)?.toDouble();
          y = (rect['y'] as num?)?.toDouble();
          final w = (rect['width'] as num?)?.toDouble() ?? 0;
          final h = (rect['height'] as num?)?.toDouble() ?? 0;
          x = x != null ? x + w / 2 : null;
          y = y != null ? y + h / 2 : null;
        }
      }

      // Fallback to center of screen
      x ??= 540;
      y ??= 960;

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
          : [
              'shell',
              'input',
              'tap',
              x.toInt().toString(),
              y.toInt().toString()
            ];

      final result =
          await Process.run('adb', args).timeout(const Duration(seconds: 5));
      return result.exitCode == 0;
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

  Future<Map<String, dynamic>> _captureTree() async {
    final response = await vmService.callServiceExtension(
      'ext.flutter.inspector.getRootWidgetTree',
      isolateId: isolateId,
      args: {'groupName': 'dangi_nav', 'isSummaryTree': 'true'},
    );
    final json = response.json ?? {};
    if (json.containsKey('result'))
      return json['result'] as Map<String, dynamic>;
    if (json.containsKey('value')) return json['value'] as Map<String, dynamic>;
    return json;
  }

  String _detectScreenName(Map<String, dynamic> tree) {
    String screen = 'UnknownScreen';
    _walkForScreenName(tree, (name) {
      screen = name;
    });
    return screen;
  }

  void _walkForScreenName(dynamic node, void Function(String) onScreen) {
    if (node == null) return;
    final type = node['widgetRuntimeType']?.toString() ?? '';
    if ((type.contains('Page') ||
            type.contains('Screen') ||
            type.contains('Widget')) &&
        !type.startsWith('_') &&
        type != 'Scaffold' &&
        type != 'ScreenUtilInit') {
      onScreen(type);
    }
    for (final child in (node['children'] as List? ?? [])) {
      _walkForScreenName(child, onScreen);
    }
  }

  /// Print a summary of all discovered screens
  void printSummary() {
    print('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    print('🗺️  APP MAP — ${discoveredScreens.length} SCREENS DISCOVERED');
    print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

    for (final screen in discoveredScreens) {
      final grade = screen.performance?.gradeEmoji ?? '⚪';
      final issues = screen.issues.length;
      final via =
          screen.navigatedVia != null ? '  ← ${screen.navigatedVia}' : '';
      print('$grade ${screen.name}$via');
      print('   Widgets: ${screen.totalWidgets}  |  '
          'Max depth: ${screen.maxDepth}  |  '
          'Issues: $issues  |  '
          'Perf: ${screen.performance?.grade ?? 'N/A'}');
      print('');
    }
    print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  }
}
