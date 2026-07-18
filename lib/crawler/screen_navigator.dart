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
/// A screen-name candidate found while walking the widget tree, ranked by
/// [tier] (how screen-like the name is) then by [depth] (shallowest wins).
class _ScreenCandidate {
  final String name;
  final int depth;
  final int tier;
  _ScreenCandidate(this.name, this.depth, this.tier);
}

const int kScreenTierPageScreen = 0; // contains "page"/"screen" — a real screen
const int kScreenTierWidget = 1; // ends in "Widget" only — likely a component
const int kScreenTierSplash = 2; // splash/init — last resort
const int kScreenTierSkip = 99; // not a screen name at all

/// Rank a widget type name by how screen-like it is (lower = more screen-like).
/// FlutterFlow names screens `HomePageWidget` (ends in Widget but contains
/// "page"); component leaves (AvatarWidget, IconWidget) contain neither.
int screenNameTier(String type) {
  final tl = type.toLowerCase();
  if (tl.contains('splash') || tl.contains('init')) return kScreenTierSplash;
  if (tl.contains('page') || tl.contains('screen')) {
    return kScreenTierPageScreen;
  }
  if (type.endsWith('Widget')) return kScreenTierWidget;
  return kScreenTierSkip;
}

const _kLeaveKeywords = {
  'leave',
  'exit',
  'quit',
  'yes',
  'ok',
  'confirm',
  'discard',
  'go back',
};
const _kStayKeywords = {
  'stay',
  'no',
  'cancel',
  'resume',
  'keep',
  'continue',
};

/// True when [desc] is a dialog "leave/confirm" button. Uses WHOLE-WORD
/// matching — substring matching taps "B**ook**ing" for "ok" and
/// "E**yes** Only" for "yes".
bool isLeaveDialogLabel(String desc) {
  final words = desc
      .toLowerCase()
      .split(RegExp(r'[^a-z]+'))
      .where((w) => w.isNotEmpty)
      .toSet();
  if (words.any(_kStayKeywords.contains)) return false;
  if (desc.toLowerCase().contains('go back')) return true; // two-word phrase
  return words.any(_kLeaveKeywords.contains);
}

/// A clickable element from a uiautomator dump: exact pixel centre + label.
typedef Tappable = ({int cx, int cy, String desc});

/// Decode the XML character entities `uiautomator dump` puts in attribute
/// values, so labels feed the dangerous-label / back-button / dialog matchers
/// as the user actually sees them ("Save & Continue", not
/// "Save &amp; Continue"). `&amp;` is decoded LAST so double-encoded input
/// like `&amp;lt;` yields the literal text `&lt;`, not `<`.
String decodeXmlEntities(String s) => s
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&#10;', '\n')
    .replaceAll('&amp;', '&');

/// Parse `uiautomator dump` XML into the clickable elements on screen:
/// centre coordinates and best label (content-desc, else text, else a
/// `tap(cx,cy)` placeholder), entities decoded, sorted top-to-bottom then
/// left-to-right, elements smaller than 20x20px and duplicate centres
/// dropped, repeated data-driven list rows reduced to their first item via
/// [deduplicateListItems].
///
/// Pure function (no adb) — extracted from `ScreenNavigator._getAllTappables`
/// so recorded dump fixtures can exercise it directly.
List<Tappable> parseUiautomatorTappables(String xml) {
  final trimmed = xml.trim();
  if (trimmed.isEmpty || !trimmed.startsWith('<')) return [];

  final boundsRe = RegExp(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"');
  final descRe = RegExp(r'content-desc="([^"]*)"');
  final textRe = RegExp(r'\btext="([^"]*)"');
  final tagRe = RegExp(r'<node\b[^>]+>');

  final seen = <String>{};
  final result = <Tappable>[];
  for (final m in tagRe.allMatches(trimmed)) {
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
    final rawDesc =
        decodeXmlEntities(descRe.firstMatch(tag)?.group(1) ?? '').trim();
    final rawText =
        decodeXmlEntities(textRe.firstMatch(tag)?.group(1) ?? '').trim();
    final desc = rawDesc.isNotEmpty
        ? rawDesc
        : rawText.isNotEmpty
            ? rawText
            : 'tap($cx,$cy)';
    result.add((cx: cx, cy: cy, desc: desc));
  }
  result.sort(
      (a, b) => a.cy != b.cy ? a.cy.compareTo(b.cy) : a.cx.compareTo(b.cx));
  return deduplicateListItems(result);
}

/// Detects data-driven list items (e.g. ListView.builder rows) and removes
/// all but the first from each group, so we explore one representative item
/// rather than wasting taps on every row of the same list.
///
/// Detection: elements whose label contains a structural newline (`&#10;`
/// already decoded to `\n` by [decodeXmlEntities]) with enough text to be
/// multi-line data. Those sharing the same X-bucket form a group; all but
/// the first are skipped. The first item is still tapped and explored fully.
List<Tappable> deduplicateListItems(List<Tappable> items) {
  if (items.length < 3) return items;

  final candidates =
      items.where((e) => e.desc.contains('\n') && e.desc.length > 15).toList();
  if (candidates.length < 2) return items;

  // Group by X-bucket (same column → same list).
  const xBucketSize = 120;
  final groups = <int, List<Tappable>>{};
  for (final item in candidates) {
    final bucket = (item.cx ~/ xBucketSize) * xBucketSize;
    (groups[bucket] ??= []).add(item);
  }

  final skipCoords = <String>{};
  for (final group in groups.values) {
    if (group.length < 2) continue;
    group.sort((a, b) => a.cy.compareTo(b.cy));
    for (var i = 1; i < group.length; i++) {
      skipCoords.add('${group[i].cx},${group[i].cy}');
    }
    final firstName = group.first.desc.split('\n').first.trim();
    print(
        '  📋 ListView group (${group.length} items) — exploring only first: "$firstName"');
  }

  if (skipCoords.isEmpty) return items;
  return items.where((e) => !skipCoords.contains('${e.cx},${e.cy}')).toList();
}

/// Widget types that end in Page/Screen/Widget but are structural, not
/// content screens.
const kScreenSkipTypes = {
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

/// Detect the visible screen name from a Flutter inspector widget tree.
/// Picks the most screen-like name (a `*Page`/`*Screen`, or a FlutterFlow
/// `*PageWidget`) and, among equally screen-like names, the DEEPEST — which
/// is the top of a pushed navigation stack. Returns 'UnknownScreen' when the
/// tree has no usable names (e.g. an obfuscated release build).
String detectScreenNameFromTree(Map<String, dynamic> tree) {
  _ScreenCandidate? best;
  void walk(dynamic node, int depth) {
    if (node == null) return;
    final type = node['widgetRuntimeType']?.toString() ?? '';
    final tl = type.toLowerCase();
    if ((type.endsWith('Page') ||
            type.endsWith('Screen') ||
            type.endsWith('Widget')) &&
        !type.startsWith('_') &&
        type != 'Scaffold' &&
        type != 'ScreenUtilInit' &&
        !kScreenSkipTypes.contains(type) &&
        !tl.contains('navbar') &&
        !tl.contains('bottomnav') &&
        !tl.contains('bottombar') &&
        !tl.contains('navwidget')) {
      final tier = screenNameTier(type);
      // Better = lower tier, then deeper, then later in DFS (>= on equal
      // depth) — pushed routes are same-depth siblings within the Navigator's
      // overlay, with the active route appearing last.
      if (tier != kScreenTierSkip &&
          (best == null ||
              tier < best!.tier ||
              (tier == best!.tier && depth >= best!.depth))) {
        best = _ScreenCandidate(type, depth, tier);
      }
    }
    for (final child in (node['children'] as List? ?? [])) {
      walk(child, depth + 1);
    }
  }

  walk(tree, 0);
  return best?.name ?? 'UnknownScreen';
}

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

      // Phase 2 vets tappable labels before tapping; route injection needs
      // the same gate — never navigate a real app to /logout, /deleteAccount
      // or a checkout flow just because the route table lists it.
      if (_isDangerousLabel(route)) {
        print('  ⏭️  Skipping dangerous route: $route');
        continue;
      }

      print('  🔀 Navigating to route: $route');

      // Start recording before navigation so transition frames are captured.
      PerformanceCapture? routeCapture;
      try {
        routeCapture =
            PerformanceCapture(vmService: vmService, isolateId: isolateId);
        await routeCapture.startRecording();
      } catch (_) {
        // startRecording may fail partway — make sure nothing stays on.
        await routeCapture?.abandon();
        routeCapture = null;
      }

      final navigated = await _evaluator.navigateTo(route);
      if (!navigated) {
        print('     ↳ No router strategy accepted this route — skipping');
        await routeCapture?.abandon();
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
      } else {
        print('     ↳ No new screen (still $effectiveName)');
        await routeCapture?.abandon();
      }

      // Return home before the next route. We navigate with push() now, so a
      // single BACK returns here; but if the app only accepted go() (which
      // REPLACES the stack), BACK from the root would exit the app and kill
      // the VM service. So verify we landed back on home, and if not, recover
      // by re-navigating to the home route instead of pressing BACK again.
      await _goBack();
      await Future.delayed(const Duration(milliseconds: 1000));
      if (_detectScreenName(await _captureTree()) != homeScreenName) {
        await _returnHome(homeScreenName);
      }
    }
  }

  /// Best-effort return to the home screen without risking an app exit:
  /// re-inject the home route (works even when go() replaced the stack), then
  /// fall back to a couple of bounded BACK presses.
  Future<void> _returnHome(String homeScreenName) async {
    for (final homeRoute in const ['/', 'home', '/home']) {
      if (await _evaluator.navigateTo(homeRoute)) {
        await Future.delayed(const Duration(milliseconds: 800));
        if (_detectScreenName(await _captureTree()) == homeScreenName) return;
      }
    }
    for (var i = 0; i < 2; i++) {
      if (_detectScreenName(await _captureTree()) == homeScreenName) return;
      await _goBack();
      await Future.delayed(const Duration(milliseconds: 600));
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
      // Default to resuming when there is no terminal to ask on (CI).
      String answer = 'y';
      if (stdin.hasTerminal) {
        stdout.write(
            '  Continue from where we left off? [Y = continue / N = restart]: ');
        answer = stdin.readLineSync()?.trim().toLowerCase() ?? 'y';
      } else {
        print('  ▶️  No terminal — resuming previous exploration by default.');
      }
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

    if (_isWebViewScreen(screenName)) {
      print('  🌐 WebView screen "$screenName" — skipping tappable exploration'
          ' (web content, not Flutter routes).');
      return;
    }

    final tappables = await _waitForStableTappables();
    if (tappables.isEmpty) {
      print('  ⚠️  No tappable elements found on $screenName');
      return;
    }
    print(
        '  🔍 ${tappables.length} tappable elements on $screenName (depth $depth)');

    // After we navigate into a child screen and return, the layout may have
    // scrolled or reordered — the coordinates captured above can be stale, so
    // the label at (cx,cy) may no longer be the element we vetted. When this
    // is set we re-resolve the pending element by label against a fresh dump
    // before tapping (and skip it if it's gone).
    var coordsMayBeStale = false;

    for (final el in tappables) {
      if (discoveredScreens.length >= maxScreens) break;

      var cx = el.cx;
      var cy = el.cy;
      final desc = el.desc;

      if (coordsMayBeStale) {
        final fresh = await _getAllTappables();
        final match = fresh
            .where((e) => e.desc == desc && e.desc != 'tap(${e.cx},${e.cy})')
            .toList();
        if (match.isEmpty) {
          // Element no longer present after the layout changed — skip it
          // rather than tap whatever drifted into its old coordinates.
          continue;
        }
        cx = match.first.cx;
        cy = match.first.cy;
        coordsMayBeStale = false;
      }

      final tapKey = '$screenName@$cx,$cy';

      // Skip if already explored in this session or a previous run.
      if (_exploredTappables[screenName]?.contains('$cx,$cy') == true) {
        continue;
      }
      if (_visitedScreenNames.contains(tapKey)) continue;
      _visitedScreenNames.add(tapKey);

      if (_isDangerousLabel(desc)) {
        print('  ⚠️  Skipping "$desc" — potentially destructive');
        continue;
      }

      // Never tap Back/Close/Cancel — these navigate backward and would
      // break our position tracking. We handle returning ourselves.
      if (_isBackwardNavButton(desc, cx: cx, cy: cy)) {
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
        // startRecording may fail partway — make sure nothing stays on.
        await tapCapture?.abandon();
        tapCapture = null;
      }

      print('  👆 Tapping "$desc" at ($cx, $cy)...');
      final tapped = await AdbRunner.tap(deviceId!, cx, cy);
      if (!tapped) {
        print('  ⚠️  adb tap failed for "$desc" — will retry on a later visit');
        // Un-claim the session key so a later visit to this screen retries
        // the element instead of permanently blacklisting it.
        _visitedScreenNames.remove(tapKey);
        await tapCapture?.abandon();
        continue;
      }
      // Only a tap that actually landed counts as explored — recording any
      // earlier would let one adb hiccup permanently blacklist an element
      // that was never exercised.
      (_exploredTappables[screenName] ??= {}).add('$cx,$cy');
      await _waitForNavigation(nameBefore);

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
          print('  ✅ New screen: $effectiveName  ← "$desc"');
          _visitedScreenNames.add(effectiveName);
          await _analyseAndRecord(newTree, effectiveName,
              navigatedVia: desc, startedCapture: tapCapture);
          // Explore this new screen as a complete sub-path.
          await _exploreTappables(newTree, effectiveName,
              depth: depth + 1,
              navDepth: navDepth + 1,
              homeScreenName: homeScreenName);
        } else {
          // Navigated to a screen we already analysed — end the capture
          // without producing a result.
          await tapCapture?.abandon();
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
        // We navigated away and came back — the remaining coordinates in
        // `tappables` may now be stale; re-resolve the next one by label.
        coordsMayBeStale = true;
      } else {
        // No navigation → nothing to analyse; end the capture, then continue
        // to the next element without pressing back.
        await tapCapture?.abandon();
      }
    }
  }

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
      return parseUiautomatorTappables(catResult.stdout.toString());
    } catch (_) {
      return [];
    }
  }

  /// Polls [_getAllTappables] until the count stabilises (two consecutive polls
  /// return the same count) or [maxAttempts] is reached. This handles screens
  /// that load content asynchronously (e.g. API-driven lists) where an early
  /// call would return far fewer tappables than the fully-loaded state.
  Future<List<({int cx, int cy, String desc})>> _waitForStableTappables({
    int maxAttempts = 5,
    int intervalMs = 600,
  }) async {
    var prev = await _getAllTappables();
    for (var i = 0; i < maxAttempts - 1; i++) {
      await Future.delayed(Duration(milliseconds: intervalMs));
      final current = await _getAllTappables();
      if (current.length == prev.length) return current;
      prev = current;
    }
    return prev;
  }

  /// Waits up to [maxWaitMs] for the screen to change after a tap. Polls the
  /// widget tree every [intervalMs] ms and returns as soon as the root screen
  /// name differs from [screenNameBefore]. Falls back gracefully if the screen
  /// never changes (button had no navigation effect).
  Future<void> _waitForNavigation(
    String screenNameBefore, {
    int maxWaitMs = 2400,
    int intervalMs = 400,
  }) async {
    final steps = maxWaitMs ~/ intervalMs;
    for (var i = 0; i < steps; i++) {
      await Future.delayed(Duration(milliseconds: intervalMs));
      final tree = await _captureTree();
      if (_detectScreenName(tree) != screenNameBefore) return;
    }
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
    'checkout',
    'unsubscribe',
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
    // Only dismiss a confirmation dialog ONCE per return attempt.
    // Repeated dismissals risk cascading into destructive actions
    // (e.g. tapping a "Leave" button on a submit confirmation after
    // already having exited the first dialog).
    var dialogDismissed = false;

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
      final screenBeforeBack = current;
      // Capture what was on screen BEFORE back, so dialog detection can
      // consider only genuinely-new buttons (the dialog's own), not the
      // page's existing controls.
      final tappablesBeforeBack = await _getAllTappables();
      await _goBack();
      await Future.delayed(const Duration(milliseconds: 800));
      // Only check for a dialog if Back didn't change the screen AND
      // we haven't already dismissed one dialog this call.
      final treeAfterBack = await _captureTree();
      final screenAfterBack = _detectScreenName(treeAfterBack);
      if (screenAfterBack == screenBeforeBack && !dialogDismissed) {
        final dismissed =
            await _dismissConfirmationDialogIfPresent(tappablesBeforeBack);
        if (dismissed) dialogDismissed = true;
        await Future.delayed(const Duration(milliseconds: 600));
      }
    }

    // Fail-safe: rapid back burst — 3 quick presses in case we landed on an
    // unexpected intermediate screen (e.g. a post-dialog results page).
    // Each press checks immediately whether we've reached the target.
    print('  ↩️  Back-burst fail-safe for "$targetScreenName"...');
    for (var i = 0; i < 3; i++) {
      await _goBack();
      await Future.delayed(const Duration(milliseconds: 400));
      final t = await _captureTree();
      final s = _detectScreenName(t);
      if (s == targetScreenName) return true;
      if (homeScreenName != null &&
          s == homeScreenName &&
          targetScreenName != homeScreenName) {
        break;
      }
    }

    final finalTree = await _captureTree();
    return _detectScreenName(finalTree) == targetScreenName;
  }

  /// After pressing Back, some screens show a "Are you sure you want to leave?"
  /// dialog or bottom sheet. This detects common leave/exit/confirm buttons and
  /// taps them so the navigation actually completes.
  ///
  /// Returns `true` if a button was found and tapped, `false` if no dialog was
  /// detected. Callers should cap calls to this at one per navigation attempt.
  ///
  /// Keywords deliberately exclude "submit", "finish", and "end" — these are
  /// too destructive (e.g. they would submit a real in-progress test).
  Future<bool> _dismissConfirmationDialogIfPresent(
      List<({int cx, int cy, String desc})> tappablesBeforeBack) async {
    if (deviceId == null || deviceId!.isEmpty) return false;
    final tappables = await _getAllTappables();

    // Only genuinely-NEW buttons can belong to a dialog that appeared after
    // BACK. This is what stops us tapping a page's own "Booking"/"Save"
    // button when no dialog is actually present.
    final beforeCoords =
        tappablesBeforeBack.map((e) => '${e.cx},${e.cy}').toSet();
    final candidates =
        tappables.where((e) => !beforeCoords.contains('${e.cx},${e.cy}'));

    for (final el in candidates) {
      if (isLeaveDialogLabel(el.desc)) {
        print('  🚪 Confirmation dialog — tapping "${el.desc}" to leave');
        await AdbRunner.tap(deviceId!, el.cx, el.cy);
        await Future.delayed(const Duration(milliseconds: 600));
        return true;
      }
    }
    return false;
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
  // WebView screen detection
  // ─────────────────────────────────────────────────────────────────────────

  /// Returns true when the screen is a web view. WebView screens contain
  /// browser-rendered content (calendars, dashboards, etc.) whose tappable
  /// elements are web DOM nodes, not Flutter routes — exploring them produces
  /// hundreds of useless taps and no new screens.
  bool _isWebViewScreen(String screenName) {
    return screenName.toLowerCase().contains('webview');
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
  String _detectScreenName(Map<String, dynamic> tree) =>
      detectScreenNameFromTree(tree);

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
    ).timeout(const Duration(seconds: 6));
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
