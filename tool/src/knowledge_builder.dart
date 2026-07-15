// Pure logic for tool/update_knowledge.dart — no I/O so it's unit-testable
// (see test/knowledge_builder_test.dart).

/// Ordered registry of layer-1 sections: key → heading rendered in the
/// generated prompt. Keys match the source map in update_knowledge.dart.
const Map<String, String> kLayer1Sections = {
  'changelog': 'FLUTTER VERSION HISTORY',
  'testing': 'FLUTTER TESTING OFFICIAL DOCS',
  'performance': 'FLUTTER PERFORMANCE OFFICIAL DOCS',
  'constraints': 'FLUTTER LAYOUT CONSTRAINTS',
  'devtools_perf': 'DEVTOOLS — PERFORMANCE PROFILING',
  'devtools_memory': 'DEVTOOLS — MEMORY & LEAK DETECTION',
  'android_deploy': 'ANDROID DEPLOYMENT',
  'fetch_data': 'NETWORKING & ASYNC COOKBOOK',
};

const String kUnavailable = '(unavailable)';

/// Assemble the layer-1 prompt: static Flutter fundamentals followed by one
/// `━━━ HEADING ━━━` block per registered section. Sections absent from
/// [sections] (or empty) render as `(unavailable)`.
String buildLayer1(Map<String, String> sections) {
  final buffer = StringBuffer(_staticPreamble);
  for (final entry in kLayer1Sections.entries) {
    final body = (sections[entry.key] ?? '').trim();
    buffer
      ..writeln('━━━ ${entry.value} ━━━')
      ..writeln()
      ..writeln(body.isEmpty ? kUnavailable : body)
      ..writeln();
  }
  return buffer.toString();
}

/// Pull one section's body back out of a previously generated layer-1 file
/// (the output of [generateDartConst] over [buildLayer1]). Returns null if
/// the section heading isn't present.
String? extractSection(String generatedFile, String sectionKey) {
  final heading = kLayer1Sections[sectionKey];
  if (heading == null) return null;
  final content = _unescape(generatedFile);
  final marker = '━━━ $heading ━━━';
  final start = content.indexOf(marker);
  if (start < 0) return null;
  final bodyStart = start + marker.length;
  final nextMarker = content.indexOf('\n━━━ ', bodyStart);
  final end = nextMarker >= 0 ? nextMarker : content.indexOf("'''", bodyStart);
  final body =
      content.substring(bodyStart, end >= 0 ? end : content.length).trim();
  return body;
}

/// Merge freshly fetched sections with the previous generated file:
/// a fetch failure (empty string) falls back to the previous run's content
/// so a transient 404 can never erase good knowledge. `(unavailable)`
/// placeholders in the previous file are never resurrected.
Map<String, String> mergeWithPrevious({
  required Map<String, String> fresh,
  required String? previousFile,
}) {
  final merged = <String, String>{};
  for (final entry in fresh.entries) {
    if (entry.value.trim().isNotEmpty && entry.value.trim() != kUnavailable) {
      merged[entry.key] = entry.value;
      continue;
    }
    final previous =
        previousFile == null ? null : extractSection(previousFile, entry.key);
    final usable = previous != null &&
        previous.trim().isNotEmpty &&
        previous.trim() != kUnavailable;
    merged[entry.key] = usable ? previous : '';
  }
  return merged;
}

/// Sections that ended up with no real content — drives the tool's exit code
/// so CI goes red instead of committing a degraded file.
List<String> missingSections(Map<String, String> sections) => [
      for (final entry in sections.entries)
        if (entry.value.trim().isEmpty || entry.value.trim() == kUnavailable)
          entry.key,
    ];

/// Render a Dart file declaring `const String varName = '''...''';`.
/// Deterministic: no timestamps, so regenerating with identical content
/// produces an identical file and the workflow's diff check stays honest.
String generateDartConst({
  required String varName,
  required String comment,
  required String content,
}) {
  final escaped = _escape(content);
  return '''$comment

const String $varName = \'\'\'
$escaped\'\'\';
''';
}

String _escape(String content) => content
    .replaceAll(r'\', r'\\')
    .replaceAll(r'$', r'\$')
    .replaceAll("'''", r"\'\'\'");

String _unescape(String content) => content
    .replaceAll(r"\'\'\'", "'''")
    .replaceAll(r'\$', r'$')
    .replaceAll(r'\\', r'\');

/// Extract the most recent major Flutter version sections from CHANGELOG.md,
/// each capped so the total stays prompt-sized.
/// Handles header formats: "## Flutter 3.41 Changes", "## 3.x.y", "## v3.x.y"
String parseChangelog(
  String raw, {
  int versionsToKeep = 5,
  int charsPerVersion = 1500,
}) {
  if (raw.isEmpty) return '(changelog unavailable)';

  final lines = raw.split('\n');
  final versions = <String, StringBuffer>{};
  final versionOrder = <String>[];
  String? currentVersion;

  for (final line in lines) {
    if (RegExp(r'^##\s+(Flutter\s+)?(v)?\d+\.\d+').hasMatch(line)) {
      final match =
          RegExp(r'(Flutter\s+)?(v)?(\d+\.\d+[\.\d]*)').firstMatch(line);
      final label = match != null ? 'Flutter ${match.group(3)}' : line.trim();

      if (versionOrder.length >= versionsToKeep) break;

      currentVersion = label;
      if (!versions.containsKey(label)) {
        versions[label] = StringBuffer();
        versionOrder.add(label);
      }
    }
    if (currentVersion != null) {
      versions[currentVersion]!.writeln(line);
    }
  }

  if (versionOrder.isEmpty) return '(no version sections found in changelog)';

  final buffer = StringBuffer();
  for (final version in versionOrder) {
    final content = versions[version]!.toString();
    final capped = content.length > charsPerVersion
        ? '${content.substring(0, charsPerVersion)}\n  ...(more fixes not shown)'
        : content;

    buffer.writeln('─── $version ───────────────────────────');
    buffer.writeln(capped.trim());
    buffer.writeln();
  }

  return buffer.toString();
}

/// Strip markdown/HTML/Jekyll syntax and cap length for prompt use.
String trimMarkdown(String raw, int maxChars) {
  if (raw.isEmpty) return kUnavailable;
  var text = raw
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll(RegExp(r'```[^`]*```', dotAll: true), '')
      .replaceAll(RegExp(r'\{%[^%]*%\}'), '')
      .replaceAll(RegExp(r'\[\[.*?\]\]'), '')
      .trim();
  return text.length > maxChars
      ? '${text.substring(0, maxChars)}\n...(truncated)'
      : text;
}

const String _staticPreamble = '''
=== LAYER 1: FLUTTER OFFICIAL KNOWLEDGE ===
You are Dangi Doctor — an expert Flutter app physician diagnosing real production apps.

━━━ FLUTTER FUNDAMENTALS ━━━

WIDGET LIFECYCLE:
- StatelessWidget: build() called once on creation and when parent rebuilds
- StatefulWidget lifecycle: createState → initState → didChangeDependencies →
  build → didUpdateWidget → deactivate → dispose
- didChangeDependencies() is called MULTIPLE TIMES — never assign late fields here
  without a boolean guard or you get LateInitializationError
- dispose() MUST cancel: StreamSubscription, AnimationController,
  TextEditingController, FocusNode, ScrollController
- Never call setState() after dispose() — check `if (mounted)` in async callbacks

THREE TREES:
- Widget tree: immutable config, cheap to create
- Element tree: mutable lifecycle state, persists across rebuilds
- RenderObject tree: actual painting, expensive to create
- Keys help Flutter match elements across rebuilds — use ValueKey for lists,
  GlobalKey sparingly (expensive — causes full subtree rebuilds)

CONST & REBUILD OPTIMIZATION:
- const constructors skip build() entirely on rebuild — use aggressively
- RepaintBoundary wraps independently animating widgets to isolate rasterization
- Consumer/Selector from provider limit rebuild scope to the exact widget that needs it

━━━ STATE MANAGEMENT — ERRORS BY FRAMEWORK ━━━

PROVIDER (most common in FlutterFlow/generated apps):
- "Could not find the correct Provider" → context does not have access to the
  provider. Provider must be above the widget in the tree.
- Calling context.watch() inside initState, didChangeDependencies, or a
  callback → runtime error. Only call watch() inside build().
- context.read() in build() → misses updates. Use context.watch() in build.
- Creating ChangeNotifier inside build() → new instance on every rebuild,
  all listeners dropped. Create in initState or above the tree.
- Calling notifyListeners() inside build() or inside another notifyListeners() →
  "setState called during build" error.
- Not calling super.dispose() in ChangeNotifier subclass → listeners never freed.

BLOC/FLUTTER_BLOC:
- Emitting state after the bloc is closed → "Cannot emit new states after calling close"
  Add `if (!isClosed)` guard before any async emit.
- BlocBuilder without buildWhen → rebuilds on every state change including
  unrelated sub-states. Always specify buildWhen for performance.
- Using context.read<MyBloc>() inside build() to get bloc events → anti-pattern.
  Use BlocListener for side effects, BlocBuilder for UI.
- Creating a Bloc inline in BlocProvider without lazy:false → bloc created before
  it's needed, causing stale state bugs on navigation.
- Forgetting to close Bloc in dispose() if created manually → memory leak.

RIVERPOD:
- Reading a provider outside of widget build or ref.watch → "No ProviderScope found"
  or stale data. Always use ref.watch (rebuild) or ref.read (one-time) appropriately.
- Using ref.watch inside a callback (onPressed, onTap) → runtime error.
  Use ref.read inside callbacks.
- StateNotifier: calling state = newValue inside build() → rebuild loop.
- AsyncNotifier: forgetting to handle error state → unhandled exception in UI.
- Not using ref.listen for side effects (navigation, dialogs) → they trigger on
  every rebuild, not just state changes.

GETX:
- Calling Get.find<MyController>() before it's registered → "MyController not found"
  Register with Get.put() or Get.lazyPut() before use.
- Using Obx() without a .obs variable inside → widget never rebuilds.
  Every variable accessed inside Obx must be .obs.
- GetX controller lifecycle: onInit → onReady (after first frame) → onClose.
  Heavy work should be in onInit, not in the constructor.
- Not calling Get.delete<MyController>() when done → controller lives forever.

━━━ COMMON FLUTTER ERRORS BY CATEGORY ━━━

RENDERING:
- "RenderFlex overflowed by X pixels" → Column/Row child too large for available
  space. Use Expanded, Flexible, or wrap in SingleChildScrollView.
- "A RenderFlex overflowed" during keyboard open → Scaffold body not wrapped in
  SingleChildScrollView or resizeToAvoidBottomInset not set.
- "Incorrect use of ParentDataWidget" → Expanded/Flexible used outside Column/Row/Flex.
- "RenderBox was not laid out" → widget tree has a cycle or unbounded constraint.
  Use LayoutBuilder to inspect constraints.

NAVIGATION:
- "Navigator operation requested with a context that does not include a Navigator"
  → context is above MaterialApp. Use a GlobalKey<NavigatorState> or
  Navigator.of(context, rootNavigator: true).
- GoRouter "No GoRouter found in context" → GoRouter not provided above the widget.
  Add router: goRouter to MaterialApp.router().
- WillPopScope is deprecated in Flutter 3.12+ → use PopScope with canPop/onPopInvoked.
- pushReplacement vs pushAndRemoveUntil: use pushAndRemoveUntil for logout flows
  to prevent back-navigation to authenticated screens.

ASYNC & FUTURES:
- "setState() called after dispose()" → async gap completed after widget removed.
  Guard every setState with `if (mounted)`.
- "Bad state: Stream has already been listened to" → StreamSubscription not
  cancelled in dispose(), stream re-listened on rebuild.
- FutureBuilder with a future created inline in build() → new Future on every
  rebuild, infinite loading spinner. Cache the Future in initState.
- await in build() → silently ignored, returns stale data. Use FutureBuilder.

FIREBASE:
- "Failed to initialize Firebase" → Firebase.initializeApp() not called before
  runApp(), or DefaultFirebaseOptions not generated (run flutterfire configure).
- Firestore listener not cancelled → StreamSubscription from snapshots() must
  be cancelled in dispose() or it leaks across hot restarts.
- Firebase Auth persistence: on web, default is LOCAL. On mobile, always LOCAL.
  If user keeps getting logged out, check FirebaseAuth.instance.setPersistence().
- "permission-denied" on Firestore → security rules not configured for the
  authenticated user's document path.

PERFORMANCE RULES (from flutter.dev/perf):
- 16ms frame budget for 60fps, 8ms for 120fps devices
- Jank = frame takes > 16ms to build OR raster
- Never: async calls, setState, heavy computation, or network requests in build()
- ListView.builder mandatory for lists > 20 items (ListView renders all children)
- Image.network: always set width/height/cacheWidth to avoid layout thrashing
- Avoid Opacity widget for animations — use AnimatedOpacity or FadeTransition
- Use const constructors everywhere possible — Flutter skips rebuild entirely
- RepaintBoundary around animations, maps, or any expensive independently-animated widget

''';
