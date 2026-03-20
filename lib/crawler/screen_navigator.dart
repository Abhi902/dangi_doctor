import 'dart:async';
import 'package:vm_service/vm_service.dart';
import '../analysis/tree_analyser.dart';
import '../analysis/performance.dart';
import '../generator/app_analyser.dart';
import 'adb_runner.dart';
import 'vm_evaluator.dart';

/// A single discovered screen.
class DiscoveredScreen {
  final String name;
  final Map<String, dynamic> widgetTree;
  final ScreenPerformance? performance;
  final List<WidgetIssue> issues;
  final int totalWidgets;
  final int maxDepth;
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
/// **Phase 2 — Widget heuristic taps**
///   For BottomNavigationBar, NavigationBar, TabBar, and NavigationRail widgets
///   that are visible on each recorded screen, calculates physical tap
///   coordinates from screen dimensions + item count rather than asking the
///   VM inspector (which does not reliably return position data on all
///   Flutter versions).
class ScreenNavigator {
  final VmService vmService;
  final String isolateId;
  final String? deviceId;
  final int maxScreens;

  /// Optional static analysis result — provides detected routes and router type.
  final AppAnalysis? analysis;

  final List<DiscoveredScreen> discoveredScreens = [];
  final Set<String> _visitedScreenNames = {};
  final TreeAnalyser _analyser = TreeAnalyser();

  late final VmEvaluator _evaluator;

  /// Physical screen size in pixels (width, height).
  (int, int)? _screenSize;

  ScreenNavigator({
    required this.vmService,
    required this.isolateId,
    this.deviceId,
    this.maxScreens = 10,
    this.analysis,
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
      print('  📐 Screen size: ${w}x$h px');
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
        print('🔀 Phase 1 — skipped (no Dart compilation service; rerun with a fresh flutter launch)\n');
      } else {
        print(
            '🔀 Phase 1 — navigating ${analysis!.routes.length} detected routes '
            '(${analysis!.routerType})\n');
        await _phase1RouteNavigation(startName);
      }
    } else {
      print('  ℹ️  No routes detected by static analysis — skipping Phase 1');
    }

    // ── Phase 2: widget heuristic taps ────────────────────────────────────
    print('\n👆 Phase 2 — widget heuristic taps\n');
    await _phase2HeuristicTaps(startName);

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
            navigatedVia: 'route:$route');

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
  // Phase 2 — heuristic taps on nav widgets
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _phase2HeuristicTaps(String homeScreenName) async {
    // Gather nav widget hints from every screen discovered so far
    // (we'll also try from the current live tree)
    final liveTree = await _captureTree();
    await _exploreHeuristicTaps(liveTree, homeScreenName);
  }

  Future<void> _exploreHeuristicTaps(
    Map<String, dynamic> tree,
    String screenName, {
    int depth = 0,
  }) async {
    if (depth > 2) return;
    if (discoveredScreens.length >= maxScreens) return;
    if (deviceId == null || deviceId!.isEmpty) return;

    final hints = _extractNavHints(tree);
    print(
        '  🔍 Found ${hints.length} nav hints on $screenName (depth $depth)');

    final baseFiles = _sourceFiles(tree);

    for (final hint in hints) {
      if (discoveredScreens.length >= maxScreens) break;

      final coords = _heuristicCoords(hint);
      if (coords == null) {
        print('     ↳ Cannot compute coords for ${hint.description} — skip');
        continue;
      }
      final (tapX, tapY) = coords;
      print('  👆 Tapping ${hint.description} at ($tapX, $tapY)...');

      await AdbRunner.tap(deviceId!, tapX, tapY);
      await Future.delayed(const Duration(milliseconds: 2000));

      final newTree = await _captureTree();
      final newFiles = _sourceFiles(newTree);

      // Bottom nav / tab bar: each tab IS a distinct screen, but they share
      // the same root widget (IndexedStack). Use the hint index as the
      // unique key — don't rely on name/file changes (all tabs are loaded).
      final isTab = hint.type == _HintType.bottomNav ||
          hint.type == _HintType.tabBar;
      final tabKey = '${screenName}#${hint.index}';

      if (isTab) {
        final newName = _detectScreenName(newTree);
        final isPushNav = newName != screenName;

        if (isPushNav) {
          // Screen name changed → push navigation, not an IndexedStack switch.
          if (!_visitedScreenNames.contains(newName)) {
            print('  ✅ New screen (push via tab): $newName  ← ${hint.description}');
            _visitedScreenNames.add(newName);
            await _analyseAndRecord(newTree, newName,
                navigatedVia: hint.description);
            await _exploreHeuristicTaps(newTree, newName, depth: depth + 1);
          }
          await _goBack();
          await Future.delayed(const Duration(milliseconds: 1000));
        } else {
          // Screen name unchanged → IndexedStack tab switch.
          if (_visitedScreenNames.contains(tabKey)) continue;
          _visitedScreenNames.add(tabKey);

          final contentName = _detectTabContentName(newTree, hint.index) ??
              '$screenName.Tab${hint.index + 1}';
          if (!_visitedScreenNames.contains(contentName)) {
            print('  ✅ Tab screen: $contentName  ← ${hint.description}');
            _visitedScreenNames.add(contentName);
            await _analyseAndRecord(newTree, contentName,
                navigatedVia: hint.description);
            await _exploreHeuristicTaps(newTree, contentName,
                depth: depth + 1);
          }
        }
      } else {
        // Push-style navigation (NavigationRail, etc.)
        final newName = _detectScreenName(newTree);
        final nameChanged = newName != screenName;
        final filesChanged = newFiles.difference(baseFiles).length >= 3 ||
            baseFiles.difference(newFiles).length >= 3;
        final effectiveName = (!nameChanged && filesChanged)
            ? (_inferNameFromFiles(newFiles, baseFiles) ?? newName)
            : newName;

        if ((nameChanged || filesChanged) &&
            !_visitedScreenNames.contains(effectiveName)) {
          print('  ✅ New screen: $effectiveName  ← ${hint.description}');
          _visitedScreenNames.add(effectiveName);
          await _analyseAndRecord(newTree, effectiveName,
              navigatedVia: hint.description);

          await _exploreHeuristicTaps(newTree, effectiveName,
              depth: depth + 1);

          await _goBack();
          await Future.delayed(const Duration(milliseconds: 1000));

          final backTree = await _captureTree();
          if (_detectScreenName(backTree) != screenName) {
            print('  ⚠️  Could not return to $screenName — stopping branch');
            break;
          }
        } else if (_visitedScreenNames.contains(effectiveName)) {
          await _goBack();
          await Future.delayed(const Duration(milliseconds: 600));
        }
      }
    }
  }

  /// Returns the name of the primary content page widget shown in a tab.
  ///
  /// [tabIndex] is used to read the Nth child of an IndexedStack (FlutterFlow
  /// loads all tab pages simultaneously, so we must use the index rather than
  /// looking for the "first" visible page — every search would find the same
  /// page regardless of which tab is active).
  String? _detectTabContentName(Map<String, dynamic> tree, int tabIndex) {
    // Primary: find IndexedStack and return its Nth child's type.
    final fromStack = _indexedStackChildName(tree, tabIndex);
    if (fromStack != null && fromStack.isNotEmpty) return fromStack;

    // Fallback: collect all page/screen candidates and return the Nth one.
    final candidates = <String>[];
    _collectTabContentNames(tree, candidates);
    if (tabIndex < candidates.length) return candidates[tabIndex];
    return candidates.firstOrNull;
  }

  /// Depth-first search for an IndexedStack; returns the widget type of its
  /// child at [index], or null if not found.
  String? _indexedStackChildName(dynamic node, int index) {
    if (node == null) return null;
    final type = node['widgetRuntimeType']?.toString() ?? '';
    if (type == 'IndexedStack') {
      final children = node['children'] as List? ?? [];
      if (index < children.length) {
        return _firstMeaningfulType(children[index]);
      }
      return null;
    }
    for (final child in (node['children'] as List? ?? [])) {
      final result = _indexedStackChildName(child, index);
      if (result != null) return result;
    }
    return null;
  }

  /// Returns the most specific page/screen widget type name in a subtree.
  ///
  /// Two-pass strategy:
  ///   1. Prefer anything ending in `Page` or `Screen` (DFS, first match).
  ///   2. Fall back to the first non-trivial widget name if nothing page-like found.
  ///
  /// This ensures FlutterFlow wrapper widgets (RootWidget, FadeWidget, etc.)
  /// don't shadow the actual page class inside them.
  String? _firstMeaningfulType(dynamic node) {
    // Pass 1 — find a Page/Screen widget anywhere in this subtree.
    final pageType = _findPageType(node);
    if (pageType != null) return pageType;
    // Pass 2 — any non-trivial widget name.
    return _findAnyMeaningfulType(node);
  }

  String? _findPageType(dynamic node) {
    if (node == null) return null;
    final type = node['widgetRuntimeType']?.toString() ?? '';
    if ((type.endsWith('Page') || type.endsWith('Screen')) &&
        !type.startsWith('_') &&
        type.length > 6) {
      return type;
    }
    for (final child in (node['children'] as List? ?? [])) {
      final result = _findPageType(child);
      if (result != null) return result;
    }
    return null;
  }

  static const _skipTypes = {
    'Scaffold', 'SizedBox', 'Container', 'Offstage', 'TickerMode',
    'KeepAlive', 'RootWidget', 'FadeWidget', 'FadeInEffect',
    'AnimatedSwitcher', 'AnimatedContainer', 'Opacity',
  };

  String? _findAnyMeaningfulType(dynamic node) {
    if (node == null) return null;
    final type = node['widgetRuntimeType']?.toString() ?? '';
    if (type.isNotEmpty &&
        !type.startsWith('_') &&
        !_skipTypes.contains(type) &&
        !type.toLowerCase().contains('navbar') &&
        !type.toLowerCase().contains('bottomnav')) {
      return type;
    }
    for (final child in (node['children'] as List? ?? [])) {
      final result = _findAnyMeaningfulType(child);
      if (result != null) return result;
    }
    return null;
  }

  void _collectTabContentNames(dynamic node, List<String> out) {
    if (node == null) return;
    final type = node['widgetRuntimeType']?.toString() ?? '';
    if ((type.endsWith('Page') || type.endsWith('Screen') ||
            type.endsWith('Widget')) &&
        !type.startsWith('_') &&
        type != 'Scaffold' &&
        type != 'ScreenUtilInit' &&
        !type.toLowerCase().contains('navbar') &&
        !type.toLowerCase().contains('bottomnav') &&
        !type.toLowerCase().contains('navbarwidget')) {
      out.add(type);
    }
    for (final child in (node['children'] as List? ?? [])) {
      _collectTabContentNames(child, out);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Nav hint extraction
  // ─────────────────────────────────────────────────────────────────────────

  List<_NavHint> _extractNavHints(Map<String, dynamic> tree) {
    final hints = <_NavHint>[];
    _walkForNavHints(tree, hints);
    // Deduplicate by description
    final seen = <String>{};
    return hints.where((h) => seen.add(h.description)).toList();
  }

  void _walkForNavHints(dynamic node, List<_NavHint> hints) {
    if (node == null) return;
    final type = node['widgetRuntimeType']?.toString() ?? '';

    // Also check source file — catches custom NavBar widgets regardless of class name
    final sourceFile = (node['creationLocation']?['file'] ?? '').toString().split('/').last.toLowerCase();
    final isNavFile = sourceFile.contains('nav_bar') ||
        sourceFile.contains('navbar') ||
        sourceFile.contains('bottom_bar') ||
        sourceFile.contains('bottombar');

    final isStandardBottomNav =
        type == 'BottomNavigationBar' || type == 'NavigationBar';
    final isCustomBottomNav = !isStandardBottomNav &&
        (isNavFile ||
            type.toLowerCase().contains('navbar') ||
            type.toLowerCase().contains('bottomnav') ||
            type.toLowerCase().contains('bottombar') ||
            type.toLowerCase().contains('navbarwidget'));

    if (isStandardBottomNav || isCustomBottomNav) {
      // Standard: count BottomNavigationBarItem / NavigationDestination children
      // Custom: count GestureDetector / InkWell / tappable direct children
      int count = _countDescendantsOfType(
          node, ['BottomNavigationBarItem', 'NavigationDestination']);
      if (count == 0) {
        count = _countDirectTappableChildren(node);
      }
      final n = count > 0 ? count : 3; // safe default for custom navbars
      for (var i = 0; i < n; i++) {
        hints.add(_NavHint(
          type: _HintType.bottomNav,
          description: '$type[item $i/$n]',
          index: i,
          total: n,
        ));
      }
      return;
    }

    if (type == 'TabBar' ||
        type.toLowerCase().contains('tabbar') ||
        type.toLowerCase().contains('tabwidget')) {
      int count = _countDescendantsOfType(node, ['Tab']);
      if (count == 0) count = _countDirectTappableChildren(node);
      final n = count > 0 ? count : 3;
      for (var i = 0; i < n; i++) {
        hints.add(_NavHint(
          type: _HintType.tabBar,
          description: '${isStandardBottomNav ? "TabBar" : type}[tab $i/$n]',
          index: i,
          total: n,
        ));
      }
      return;
    }

    if (type == 'NavigationRail') {
      final count =
          _countDescendantsOfType(node, ['NavigationRailDestination']);
      final n = count > 0 ? count : 3;
      for (var i = 0; i < n; i++) {
        hints.add(_NavHint(
          type: _HintType.navigationRail,
          description: 'NavigationRail[item $i/$n]',
          index: i,
          total: n,
        ));
      }
      return;
    }

    for (final child in (node['children'] as List? ?? [])) {
      _walkForNavHints(child, hints);
    }
  }

  /// BFS through subtree levels until finding tappable widgets, then count
  /// those at the first level where any are found.
  int _countDirectTappableChildren(dynamic node) {
    const tappable = {
      'GestureDetector',
      'InkWell',
      'InkResponse',
      'TextButton',
      'ElevatedButton',
      'IconButton',
      'CupertinoButton',
    };
    var currentLevel = (node['children'] as List? ?? []).cast<dynamic>();
    while (currentLevel.isNotEmpty) {
      int count = 0;
      for (final child in currentLevel) {
        final t = child['widgetRuntimeType']?.toString() ?? '';
        if (tappable.contains(t)) count++;
      }
      if (count > 0) return count;
      final nextLevel = <dynamic>[];
      for (final child in currentLevel) {
        nextLevel.addAll((child['children'] as List? ?? []).cast<dynamic>());
      }
      currentLevel = nextLevel;
    }
    return 0;
  }

  int _countDescendantsOfType(dynamic node, List<String> types) {
    if (node == null) return 0;
    int count = 0;
    final type = node['widgetRuntimeType']?.toString() ?? '';
    if (types.contains(type)) count++;
    for (final child in (node['children'] as List? ?? [])) {
      count += _countDescendantsOfType(child, types);
    }
    return count;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Heuristic coordinate calculation
  // ─────────────────────────────────────────────────────────────────────────

  /// Convert a [_NavHint] to physical screen coordinates (adb pixels).
  ///
  /// Layout assumptions (standard Material Design):
  ///   - BottomNavigationBar height ≈ 56 dp → center at screenH - 28dp
  ///   - TabBar height ≈ 48 dp, placed below AppBar (≈56dp) + StatusBar (24dp)
  ///     → center at ~104 dp from top
  ///   - NavigationRail width ≈ 72 dp, items spaced ~56dp apart from top
  ///
  /// Physical px = logical dp * DPR. We use screenH/W directly (already physical).
  (int, int)? _heuristicCoords(_NavHint hint) {
    if (_screenSize == null) return null;
    final (screenW, screenH) = _screenSize!;

    switch (hint.type) {
      case _HintType.bottomNav:
        // Items evenly spaced across full width; bar at bottom ~56dp
        // physical pixels: bar center y ≈ screenH - (56/2 * dpr)
        // We don't know dpr precisely but 56dp on a 1080p phone at 3x = 168px
        // Use screenH - 84 (half the bar height in px at ~3x dpr)
        final barCenterY = screenH - 84;
        final itemCenterX =
            ((screenW * (hint.index + 0.5)) / hint.total).toInt();
        return (itemCenterX, barCenterY.clamp(0, screenH - 1));

      case _HintType.tabBar:
        // Status bar ≈ 72px, AppBar ≈ 168px, TabBar center ≈ 72+168+72=312px
        // Empirically ~280–330px works well on most phones.
        const tabBarCenterY = 300;
        final tabCenterX =
            ((screenW * (hint.index + 0.5)) / hint.total).toInt();
        return (tabCenterX, tabBarCenterY.clamp(0, screenH - 1));

      case _HintType.navigationRail:
        // Rail on left side, items stacked vertically ~56dp apart from top
        // Top item center: status bar (72px) + app bar (168px) + 28px ≈ 268px
        const railCenterX = 36; // half of 72dp rail at 3x = ~108px / 3
        final itemCenterY = 268 + (hint.index * 168); // 56dp * 3 between items
        return (railCenterX, itemCenterY.clamp(0, screenH - 1));
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Screen recording
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _analyseAndRecord(
    Map<String, dynamic> tree,
    String screenName, {
    String? navigatedVia,
  }) async {
    _analyser.analyse(tree);

    final perfCapture =
        PerformanceCapture(vmService: vmService, isolateId: isolateId);
    ScreenPerformance? perf;
    try {
      perf = await perfCapture.captureWindow(
          screenName: screenName, durationMs: 1500);
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
    if (json.containsKey('result')) return json['result'] as Map<String, dynamic>;
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

// ─────────────────────────────────────────────────────────────────────────
// Internal types
// ─────────────────────────────────────────────────────────────────────────

enum _HintType { bottomNav, tabBar, navigationRail }

class _NavHint {
  final _HintType type;
  final String description;
  final int index;
  final int total;

  const _NavHint({
    required this.type,
    required this.description,
    required this.index,
    required this.total,
  });
}
