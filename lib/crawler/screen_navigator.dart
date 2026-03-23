import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:vm_service/vm_service.dart';
import '../analysis/tree_analyser.dart';
import '../analysis/performance.dart';
import '../generator/app_analyser.dart';
import 'adb_runner.dart';
import 'vm_evaluator.dart';

/// A single discovered screen with its full analysis results.
class DiscoveredScreen {
  /// Widget type name of the root widget (e.g. `HomePageWidget`).
  final String name;

  /// Raw widget tree captured from the Flutter VM service.
  final Map<String, dynamic> widgetTree;

  /// Frame-timing performance data, or null if unavailable.
  final ScreenPerformance? performance;

  /// All widget-tree issues detected by [TreeAnalyser].
  final List<WidgetIssue> issues;

  /// Total number of widgets in the tree.
  final int totalWidgets;

  /// Maximum widget nesting depth.
  final int maxDepth;

  /// Human-readable label describing how this screen was reached
  /// (e.g. a button label, route path, or `"start"`).
  final String? navigatedVia;

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

/// Walks every reachable screen in the Flutter app using a two-phase strategy:
///
/// **Phase 1 — Route injection**
///   Uses [VmEvaluator] to call the app's router API directly
///   (GetX / GoRouter / Navigator 1.0 / AutoRoute / Beamer).
///   Iterates over every route path found by static analysis.
///
/// **Phase 2 — Universal tappable exploration**
///   Dumps the Android accessibility tree via `uiautomator dump` to get the
///   exact pixel bounds of every clickable element on screen. Taps each one;
///   if the root widget type or loaded source files change, a new screen was
///   discovered. Presses BACK to return and repeats for the next element.
///   No screen-size guessing, no nav-bar detection — works on any Flutter app.
class ScreenNavigator {
  /// Connected VM service used to read the widget tree and evaluate expressions.
  final VmService vmService;

  /// Dart isolate ID of the running Flutter app.
  final String isolateId;

  /// ADB device ID (e.g. `Z5BISOCMHEP7FAXG`). Required for Phase 2 taps.
  /// Pass an empty string or null to skip Phase 2.
  final String? deviceId;

  /// Maximum number of screens to discover before stopping. Defaults to 20.
  final int maxScreens;

  /// Optional static analysis result — provides detected routes and router type.
  final AppAnalysis? analysis;

  /// Absolute path to the Flutter project root — used to persist explored paths
  /// in `.dangi_doctor/explored_paths.json` across runs.
  final String? projectPath;

  /// All screens discovered so far, in discovery order.
  final List<DiscoveredScreen> discoveredScreens = [];
  final Set<String> _visitedScreenNames = {};
  final TreeAnalyser _analyser = TreeAnalyser();

  late final VmEvaluator _evaluator;

  /// Physical screen size in pixels (width, height).
  (int, int)? _screenSize;

  /// Explored tappable coordinates per screen, keyed by "$screenName@$cx,$cy".
  /// Loaded from the persistence file at phase-2 start and merged with new
  /// discoveries at phase-2 end.
  final Map<String, Set<String>> _exploredTappables = {};

  ScreenNavigator({
    required this.vmService,
    required this.isolateId,
    this.deviceId,
    this.maxScreens = 10,
    this.analysis,
    this.projectPath,
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Entry point
  // ─────────────────────────────────────────────────────────────────────────

  Future<List<DiscoveredScreen>> walkAllScreens() async {
    print('\n🗺️  Starting full app navigation crawl...');
    print('   Will discover up to $maxScreens screens\n');

    _evaluator = VmEvaluator(
      vmService: vmService,
      isolateId: isolateId,
      routerType: analysis?.routerType ?? 'unknown',
      routerVariable: analysis?.routerVariable,
    );
    await _evaluator.init();

    if (deviceId != null && deviceId!.isNotEmpty) {
      _screenSize = await _getScreenPhysicalSize();
      final (w, h) = _screenSize!;
      print('  📐 Screen size: ${w}x${h}px');
    }

    // Record the starting screen
    final startTree = await _captureTree();
    final startName = _detectScreenName(startTree);
    print('📍 Starting screen: $startName\n');
    _visitedScreenNames.add(startName);
    await _analyseAndRecord(startTree, startName, navigatedVia: 'start');

    // ── Phase 1: route-based navigation ───────────────────────────────────
    if (analysis != null && analysis!.routes.isNotEmpty) {
      if (!_evaluator.canEvaluate) {
        print(
            '🔀 Phase 1 — skipped (no Dart compilation service; rerun with a fresh flutter launch)\n');
      } else {
        print(
            '🔀 Phase 1 — navigating ${analysis!.routes.length} detected routes '
            '(${analysis!.routerType})\n');
        await _phase1RouteNavigation(startName);
      }
    } else {
      print('  ℹ️  No routes detected by static analysis — skipping Phase 1');
    }

    // ── Phase 2: tap every tappable element, record new screens ───────────
    print('\n👆 Phase 2 — universal tappable exploration\n');
    await _phase2ExploreAll(startName);

    print(
        '\n✅ Navigation crawl complete — ${discoveredScreens.length} screens discovered\n');
    return discoveredScreens;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Phase 1 — route injection via VM evaluate
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _phase1RouteNavigation(String homeScreenName) async {
    final baseTree = await _captureTree();
    final baseFiles = _sourceFiles(baseTree);

    for (final route in analysis!.routes) {
      if (discoveredScreens.length >= maxScreens) break;

      print('  🔀 Navigating to route: $route');

      // Start recording before navigation so transition frames are captured.
      PerformanceCapture? routeCapture;
      try {
        routeCapture =
            PerformanceCapture(vmService: vmService, isolateId: isolateId);
        await routeCapture.startRecording();
      } catch (_) {
        routeCapture = null;
      }

      final navigated = await _evaluator.navigateTo(route);
      if (!navigated) {
        print('     ↳ No router strategy accepted this route — skipping');
        continue;
      }

      // Wait for route animation to settle
      await Future.delayed(const Duration(milliseconds: 2000));

      final newTree = await _captureTree();
      final newName = _detectScreenName(newTree);
      final newFiles = _sourceFiles(newTree);

      final nameChanged = newName != homeScreenName;
      final filesChanged = newFiles.difference(baseFiles).length >= 3 ||
          baseFiles.difference(newFiles).length >= 3;
      final effectiveName = (!nameChanged && filesChanged)
          ? (_inferNameFromFiles(newFiles, baseFiles) ?? newName)
          : newName;

      if ((nameChanged || filesChanged) &&
          !_visitedScreenNames.contains(effectiveName)) {
        print('  ✅ New screen: $effectiveName  ← route $route');
        _visitedScreenNames.add(effectiveName);
        await _analyseAndRecord(newTree, effectiveName,
            navigatedVia: 'route:$route', startedCapture: routeCapture);

        // Go back and wait
        await _goBack();
        await Future.delayed(const Duration(milliseconds: 1200));
      } else {
        print('     ↳ No new screen (still $effectiveName)');
        // Go back just in case something pushed
        await _goBack();
        await Future.delayed(const Duration(milliseconds: 800));
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Phase 2 — universal tappable exploration
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _phase2ExploreAll(String homeScreenName) async {
    // ── Load previously explored paths ─────────────────────────────────────
    final resumed = await _loadExploredPaths();
    if (resumed) {
      final totalExplored =
          _exploredTappables.values.fold(0, (s, v) => s + v.length);
      print('  📂 Previous run: ${_exploredTappables.length} screens'
          ', $totalExplored taps already explored.');
      stdout.write(
          '  Continue from where we left off? [Y = continue / N = restart]: ');
      final answer = stdin.readLineSync()?.trim().toLowerCase() ?? 'y';
      if (answer == 'n' || answer == 'no') {
        _exploredTappables.clear();
        print('  🔄 Starting fresh — re-exploring everything.');
      } else {
        print('  ▶️  Continuing — skipping already-explored taps.');
      }
    }

    final liveTree = await _captureTree();
    await _exploreTappables(liveTree, homeScreenName,
        homeScreenName: homeScreenName);

    // ── Save explored paths for the next run ───────────────────────────────
    await _saveExploredPaths();
  }

  /// Explores all tappable elements on [screenName], navigating forward into
  /// any new screens discovered and returning to [screenName] after each.
  ///
  /// [navDepth] is the number of forward Navigator.push steps taken from home.
  /// It is used to limit how many times we press BACK when returning, so we
  /// never overshoot past the target screen.
  Future<void> _exploreTappables(
    Map<String, dynamic> tree,
    String screenName, {
    int depth = 0,
    int navDepth = 0,
    required String homeScreenName,
  }) async {
    if (discoveredScreens.length >= maxScreens) return;
    if (deviceId == null || deviceId!.isEmpty) return;

    if (_isLoginScreen(tree)) {
      print(
          '  🔐 Login screen detected on "$screenName" — skipping exploration.');
      print(
          '     Run the app while already logged in, or implement auth injection.');
      return;
    }

    final tappables = await _getAllTappables();
    if (tappables.isEmpty) {
      print('  ⚠️  No tappable elements found on $screenName');
      return;
    }
    print(
        '  🔍 ${tappables.length} tappable elements on $screenName (depth $depth)');

    for (final el in tappables) {
      if (discoveredScreens.length >= maxScreens) break;

      final tapKey = '$screenName@${el.cx},${el.cy}';

      // Skip if already explored in this session or a previous run.
      if (_exploredTappables[screenName]?.contains('${el.cx},${el.cy}') ==
          true) {
        continue;
      }
      if (_visitedScreenNames.contains(tapKey)) continue;
      _visitedScreenNames.add(tapKey);

      // Track for persistence.
      (_exploredTappables[screenName] ??= {}).add('${el.cx},${el.cy}');

      if (_isDangerousLabel(el.desc)) {
        print('  ⚠️  Skipping "${el.desc}" — potentially destructive');
        continue;
      }

      // Never tap Back/Close/Cancel — these navigate backward and would
      // break our position tracking. We handle returning ourselves.
      if (_isBackwardNavButton(el.desc, cx: el.cx, cy: el.cy)) {
        continue;
      }

      final treeBefore = await _captureTree();
      final nameBefore = _detectScreenName(treeBefore);
      final filesBefore = _sourceFiles(treeBefore);

      // Start recording before tap so transition frames are captured.
      PerformanceCapture? tapCapture;
      try {
        tapCapture =
            PerformanceCapture(vmService: vmService, isolateId: isolateId);
        await tapCapture.startRecording();
      } catch (_) {
        tapCapture = null;
      }

      print('  👆 Tapping "${el.desc}" at (${el.cx}, ${el.cy})...');
      await AdbRunner.tap(deviceId!, el.cx, el.cy);
      await Future.delayed(const Duration(milliseconds: 1200));

      final newTree = await _captureTree();
      final newName = _detectScreenName(newTree);
      final newFiles = _sourceFiles(newTree);

      final nameChanged = newName != nameBefore;
      final filesChanged = newFiles.difference(filesBefore).length >= 3;

      if (nameChanged || filesChanged) {
        final effectiveName = nameChanged
            ? newName
            : (_inferNameFromFiles(newFiles, filesBefore) ?? newName);

        if (!_visitedScreenNames.contains(effectiveName)) {
          print('  ✅ New screen: $effectiveName  ← "${el.desc}"');
          _visitedScreenNames.add(effectiveName);
          await _analyseAndRecord(newTree, effectiveName,
              navigatedVia: el.desc, startedCapture: tapCapture);
          // Explore this new screen as a complete sub-path.
          await _exploreTappables(newTree, effectiveName,
              depth: depth + 1,
              navDepth: navDepth + 1,
              homeScreenName: homeScreenName);
        }

        // Return to [screenName].
        // maxPresses = navDepth + 2: one press per forward step + 1 safety
        // margin for dialogs/sheets; overshoot detection stops early if we
        // accidentally land on home before reaching the target.
        final returned = await _returnToScreen(screenName,
            maxPresses: navDepth + 2, homeScreenName: homeScreenName);
        if (!returned) {
          print('  ⚠️  Could not return to $screenName — stopping branch');
          return;
        }
      }
      // No navigation → continue to next element without pressing back.
    }
  }

  static const _skipTypes = {
    'Scaffold',
    'SizedBox',
    'Container',
    'Offstage',
    'TickerMode',
    'KeepAlive',
    'RootWidget',
    'FadeWidget',
    'FadeInEffect',
    'AnimatedSwitcher',
    'AnimatedContainer',
    'Opacity',
  };

  // ─────────────────────────────────────────────────────────────────────────
  // Exact tappable element discovery via Android accessibility layer
  // ─────────────────────────────────────────────────────────────────────────

  /// Returns all clickable elements currently visible on screen with their
  /// exact pixel centres and labels, sorted top-to-bottom left-to-right.
  ///
  /// Uses `adb shell uiautomator dump` — no screen-size guessing, no widget
  /// tree parsing, works on any Flutter version and any device.
  Future<List<({int cx, int cy, String desc})>> _getAllTappables() async {
    if (deviceId == null || deviceId!.isEmpty) return [];
    try {
      await AdbRunner.run(
          deviceId!, ['shell', 'uiautomator', 'dump', '/sdcard/dangi_ui.xml']);
      final catResult = await AdbRunner.run(
          deviceId!, ['shell', 'cat', '/sdcard/dangi_ui.xml']);
      await AdbRunner.run(
          deviceId!, ['shell', 'rm', '-f', '/sdcard/dangi_ui.xml']);
      final xml = catResult.stdout.toString().trim();
      if (xml.isEmpty || !xml.startsWith('<')) return [];

      final boundsRe = RegExp(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"');
      final descRe = RegExp(r'content-desc="([^"]*)"');
      final textRe = RegExp(r'\btext="([^"]*)"');
      final tagRe = RegExp(r'<node\b[^>]+>');

      final seen = <String>{};
      final result = <({int cx, int cy, String desc})>[];
      for (final m in tagRe.allMatches(xml)) {
        final tag = m.group(0)!;
        if (!tag.contains('clickable="true"')) continue;
        final bm = boundsRe.firstMatch(tag);
        if (bm == null) continue;
        final x1 = int.parse(bm.group(1)!);
        final y1 = int.parse(bm.group(2)!);
        final x2 = int.parse(bm.group(3)!);
        final y2 = int.parse(bm.group(4)!);
        if ((x2 - x1) < 20 || (y2 - y1) < 20) continue;
        final cx = (x1 + x2) ~/ 2;
        final cy = (y1 + y2) ~/ 2;
        if (!seen.add('$cx,$cy')) continue;
        final rawDesc = descRe.firstMatch(tag)?.group(1)?.trim() ?? '';
        final rawText = textRe.firstMatch(tag)?.group(1)?.trim() ?? '';
        final desc = rawDesc.isNotEmpty
            ? rawDesc
            : rawText.isNotEmpty
                ? rawText
                : 'tap($cx,$cy)';
        result.add((cx: cx, cy: cy, desc: desc));
      }
      result.sort(
          (a, b) => a.cy != b.cy ? a.cy.compareTo(b.cy) : a.cx.compareTo(b.cx));
      return _deduplicateListItems(result);
    } catch (_) {
      return [];
    }
  }

  /// Detects data-driven list items (e.g. ListView.builder rows) and removes
  /// all but the first from each group, so we explore one representative item
  /// rather than wasting taps on every row of the same list.
  ///
  /// Detection: elements whose label contains a structural newline (`&#10;` or
  /// `\n` with enough text to be multi-line data) are candidates. Those sharing
  /// the same X-bucket (within ±60px) form a group; all but the first are
  /// skipped.  The first item is still tapped and explored fully.
  List<({int cx, int cy, String desc})> _deduplicateListItems(
      List<({int cx, int cy, String desc})> items) {
    if (items.length < 3) return items;

    // Collect list-item candidates: multi-line data-driven labels.
    final candidates = items.where((e) {
      final isMultiLine = e.desc.contains('&#10;') || e.desc.contains('\n');
      return isMultiLine && e.desc.length > 15;
    }).toList();

    if (candidates.length < 2) return items;

    // Group by X-bucket (same column → same list).
    const xBucketSize = 120;
    final groups = <int, List<({int cx, int cy, String desc})>>{};
    for (final item in candidates) {
      final bucket = (item.cx ~/ xBucketSize) * xBucketSize;
      (groups[bucket] ??= []).add(item);
    }

    final skipCoords = <String>{};
    for (final group in groups.values) {
      if (group.length < 2) continue;
      group.sort((a, b) => a.cy.compareTo(b.cy));
      // Skip everything after the first item.
      for (var i = 1; i < group.length; i++) {
        skipCoords.add('${group[i].cx},${group[i].cy}');
      }
      final firstName = group.first.desc.split('&#10;').first.trim();
      print(
          '  📋 ListView group (${group.length} items) — exploring only first: "$firstName"');
    }

    if (skipCoords.isEmpty) return items;
    return items.where((e) => !skipCoords.contains('${e.cx},${e.cy}')).toList();
  }

  static const _dangerousLabels = {
    'delete',
    'remove',
    'logout',
    'log out',
    'sign out',
    'signout',
    'purchase',
    'buy',
    'pay now',
    'uninstall',
    'clear all',
    'reset',
  };

  bool _isDangerousLabel(String desc) {
    final lower = desc.toLowerCase();
    return _dangerousLabels.any((label) => lower.contains(label));
  }

  /// Returns true if this element is a backward-navigation control.
  /// We never tap these — we return ourselves via the system back key
  /// ([_returnToScreen] → [_goBack] → KEYCODE_BACK), which is always correct.
  ///
  /// Detection uses two signals:
  /// 1. Label match against known back-button semantic labels (Flutter icon
  ///    names, standard Android/iOS accessibility labels, common symbols).
  /// 2. AppBar back-button position: top-left corner of the screen.
  bool _isBackwardNavButton(String desc, {required int cx, required int cy}) {
    final lower = desc.toLowerCase().trim();

    // Flutter Material + Cupertino icon semantic labels used as back buttons.
    const backLabels = {
      // Human-readable labels
      'back', 'close', 'cancel', 'dismiss', 'navigate up', 'go back',
      'return', 'exit', 'done',
      // Flutter icon names (Icons.xxx.name exposed as semanticLabel or tooltip)
      'arrow_back', 'arrow_back_ios', 'arrow_back_ios_new',
      'arrow_back_outlined', 'arrow_back_rounded', 'arrow_back_sharp',
      'chevron_left', 'chevron_left_outlined',
      'chevron_left_rounded', 'chevron_left_sharp',
      'keyboard_arrow_left', 'keyboard_arrow_left_outlined',
      'keyboard_backspace',
      'close_outlined', 'close_rounded', 'close_sharp',
      'clear', 'clear_outlined', 'clear_rounded', 'clear_sharp',
      'cancel_outlined', 'cancel_rounded', 'cancel_sharp',
      // Unicode arrow/close symbols sometimes used as label text
      '←', '‹', '«', '×', '✕', '✖', '⬅',
    };

    if (backLabels.contains(lower)) return true;

    // AppBar back button: always top-left, small hit area.
    // Catches empty/short labels AND our own "tap(cx,cy)" fallback label
    // generated when uiautomator returns no accessibility text.
    // An unlabeled element in the top-left corner is almost always a back icon.
    if (cx < 200 && cy < 380) {
      final isUnlabeled = lower.isEmpty ||
          lower.length <= 2 ||
          RegExp(r'^tap\(\d+,\d+\)$').hasMatch(lower);
      if (isUnlabeled) return true;
    }

    return false;
  }

  /// Presses BACK until [targetScreenName] is the current screen, or
  /// [maxPresses] attempts are exhausted.
  ///
  /// If [homeScreenName] is provided and we land there before reaching the
  /// target, we stop immediately — we've overshot (e.g. a tab-switch brought
  /// us to a sibling screen, not a child screen, so back goes home not back
  /// to the target).
  Future<bool> _returnToScreen(
    String targetScreenName, {
    int maxPresses = 3,
    String? homeScreenName,
  }) async {
    for (var i = 0; i < maxPresses; i++) {
      final tree = await _captureTree();
      final current = _detectScreenName(tree);
      if (current == targetScreenName) return true;
      // Overshot: we're at home but the target isn't home — pressing more
      // back won't help, we'd just exit the app.
      if (homeScreenName != null &&
          current == homeScreenName &&
          targetScreenName != homeScreenName) {
        return false;
      }
      await _goBack();
      await Future.delayed(const Duration(milliseconds: 800));
    }
    final finalTree = await _captureTree();
    return _detectScreenName(finalTree) == targetScreenName;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Explored paths persistence (Layer 3 — app-specific knowledge)
  // ─────────────────────────────────────────────────────────────────────────

  File? get _exploredPathsFile {
    if (projectPath == null) return null;
    return File('$projectPath/.dangi_doctor/explored_paths.json');
  }

  /// Loads previously explored tappable paths from disk.
  /// Returns true if any data was loaded.
  Future<bool> _loadExploredPaths() async {
    final file = _exploredPathsFile;
    if (file == null || !file.existsSync()) return false;
    try {
      final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final screens = raw['screens'] as Map<String, dynamic>? ?? {};
      for (final entry in screens.entries) {
        _exploredTappables[entry.key] =
            Set<String>.from(entry.value as List<dynamic>);
      }
      return _exploredTappables.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Saves the current session's explored tappable paths to disk.
  Future<void> _saveExploredPaths() async {
    final file = _exploredPathsFile;
    if (file == null) return;
    try {
      file.parent.createSync(recursive: true);
      final data = {
        'lastRun': DateTime.now().toIso8601String(),
        'screens': {
          for (final e in _exploredTappables.entries)
            e.key: e.value.toList()..sort(),
        },
      };
      file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
      print('  💾 Explored paths saved for next run.');
    } catch (_) {}
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Login-screen detection
  // ─────────────────────────────────────────────────────────────────────────

  /// Returns true when the widget tree looks like a login/sign-in screen.
  ///
  /// Heuristic: two or more TextFormFields (email + password) plus at least
  /// one tappable widget whose semantic label or value contains "login",
  /// "sign in", or "continue".
  bool _isLoginScreen(Map<String, dynamic> tree) {
    int textFields = 0;
    bool hasLoginButton = false;
    _scanForLoginWidgets(tree, (type, label) {
      if (type == 'TextFormField' || type == 'TextField') textFields++;
      final l = label.toLowerCase();
      if (l.contains('login') ||
          l.contains('sign in') ||
          l.contains('log in') ||
          l.contains('continue') ||
          l.contains('otp') ||
          l.contains('verify')) {
        hasLoginButton = true;
      }
    });
    return textFields >= 1 && hasLoginButton;
  }

  void _scanForLoginWidgets(
      dynamic node, void Function(String type, String label) onWidget) {
    if (node == null) return;
    final type = node['widgetRuntimeType']?.toString() ?? '';
    final label = (node['description'] ?? node['value'] ?? '').toString();
    onWidget(type, label);
    for (final child in (node['children'] as List? ?? [])) {
      _scanForLoginWidgets(child, onWidget);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Screen recording
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _analyseAndRecord(
    Map<String, dynamic> tree,
    String screenName, {
    String? navigatedVia,
    PerformanceCapture? startedCapture,
  }) async {
    _analyser.analyse(tree);

    ScreenPerformance? perf;
    try {
      if (startedCapture != null) {
        perf = await startedCapture.stopAndAnalyse(screenName);
      } else {
        final perfCapture =
            PerformanceCapture(vmService: vmService, isolateId: isolateId);
        perf = await perfCapture.captureWindow(
            screenName: screenName, durationMs: 1500);
      }
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

    print(
        '  📊 $screenName — ${_analyser.issues.length} issues — Perf grade: ${perf?.grade ?? 'N/A'}');
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Screen fingerprinting
  // ─────────────────────────────────────────────────────────────────────────

  Set<String> _sourceFiles(Map<String, dynamic> tree) {
    final files = <String>{};
    _collectFiles(tree, files);
    return files;
  }

  void _collectFiles(dynamic node, Set<String> files) {
    if (node == null) return;
    final file = node['creationLocation']?['file']?.toString();
    if (file != null) files.add(file.split('/').last);
    for (final child in (node['children'] as List? ?? [])) {
      _collectFiles(child, files);
    }
  }

  String? _inferNameFromFiles(Set<String> newFiles, Set<String> oldFiles) {
    final added = newFiles.difference(oldFiles);
    for (final file in added) {
      if (!file.endsWith('.dart')) continue;
      if (file.contains('page') || file.contains('screen')) {
        return _fileToClassName(file);
      }
    }
    for (final file in added) {
      if (file.endsWith('.dart')) return _fileToClassName(file);
    }
    return null;
  }

  String _fileToClassName(String file) => file
      .replaceAll('.dart', '')
      .split('_')
      .map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}')
      .join('');

  /// Detect the visible screen name from the widget tree.
  ///
  /// Preference order (highest to lowest):
  ///   1. A widget ending in 'Page' or 'Screen' that is NOT a splash/init screen.
  ///   2. Any widget ending in 'Page', 'Screen', or 'Widget' (taking the deepest match,
  ///      so the most-recently pushed route wins).
  ///
  /// "SplashScreen" and "_initialize" type names are skipped when a better
  /// match exists, because GoRouter keeps the root route in the tree even
  /// after navigation.
  String _detectScreenName(Map<String, dynamic> tree) {
    String? bestName;
    String? splashFallback;

    _walkForScreenName(tree, (name) {
      final isSplashLike = name == 'SplashScreen' ||
          name.toLowerCase().contains('splash') ||
          name.toLowerCase().contains('init');

      if (isSplashLike) {
        splashFallback ??= name;
      } else {
        bestName = name; // overwritten with deepest non-splash match
      }
    });

    return bestName ?? splashFallback ?? 'UnknownScreen';
  }

  void _walkForScreenName(dynamic node, void Function(String) onScreen) {
    if (node == null) return;
    final type = node['widgetRuntimeType']?.toString() ?? '';
    final tl = type.toLowerCase();
    // Use endsWith, not contains — custom screens end with Page/Screen/Widget.
    // Framework widgets like PageView, PagedLayoutBuilder, PageController,
    // PagedSliverList all CONTAIN "Page" but never END with it.
    // Using contains caused PageView to be detected as the home screen.
    if ((type.endsWith('Page') ||
            type.endsWith('Screen') ||
            type.endsWith('Widget')) &&
        !type.startsWith('_') &&
        type != 'Scaffold' &&
        type != 'ScreenUtilInit' &&
        !_skipTypes.contains(type) &&
        // Exclude navigation-container widgets — they wrap page content but
        // are not content screens themselves. Without this, NavBarWidget
        // appears after page content in the GoRouter Navigator DFS traversal
        // and overwrites the real screen name as _detectScreenName runs.
        !tl.contains('navbar') &&
        !tl.contains('bottomnav') &&
        !tl.contains('bottombar') &&
        !tl.contains('navwidget')) {
      onScreen(type);
    }
    for (final child in (node['children'] as List? ?? [])) {
      _walkForScreenName(child, onScreen);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Device helpers
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _goBack() async {
    if (deviceId == null || deviceId!.isEmpty) return;
    await AdbRunner.keyEvent(deviceId!, 4); // KEYCODE_BACK
  }

  /// Returns (width, height) in physical pixels via `adb shell wm size`.
  Future<(int, int)> _getScreenPhysicalSize() async {
    try {
      final result = await AdbRunner.run(deviceId!, ['shell', 'wm', 'size']);
      final output = result.stdout.toString();
      // "Physical size: 1080x2400" or "Override size: 1080x1920\nPhysical size: ..."
      final match =
          RegExp(r'Physical size:\s*(\d+)x(\d+)').firstMatch(output) ??
              RegExp(r'(\d+)x(\d+)').firstMatch(output);
      if (match != null) {
        return (int.parse(match.group(1)!), int.parse(match.group(2)!));
      }
    } catch (_) {}
    return (1080, 2400); // safe fallback
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Tree capture
  // ─────────────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _captureTree() async {
    try {
      final r = await vmService.callServiceExtension(
        'ext.flutter.inspector.getRootWidgetSummaryTreeWithPaintTransform',
        isolateId: isolateId,
        args: {'groupName': 'dangi_nav'},
      ).timeout(const Duration(seconds: 6));
      final j = r.json ?? {};
      final result = j['result'] ?? j['value'];
      if (result != null) return result as Map<String, dynamic>;
    } catch (_) {}

    final response = await vmService.callServiceExtension(
      'ext.flutter.inspector.getRootWidgetTree',
      isolateId: isolateId,
      args: {'groupName': 'dangi_nav', 'isSummaryTree': 'true'},
    );
    final json = response.json ?? {};
    if (json.containsKey('result')) {
      return json['result'] as Map<String, dynamic>;
    }
    if (json.containsKey('value')) return json['value'] as Map<String, dynamic>;
    return json;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Summary
  // ─────────────────────────────────────────────────────────────────────────

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
