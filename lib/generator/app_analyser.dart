import 'dart:io';

/// A risky code pattern detected by static analysis.
class KnownRisk {
  final String type; // e.g. 'late_field_double_init'
  final String file; // relative path from lib/
  final int line; // approx line of the problematic assignment
  final String fieldName; // the late field involved
  final String callerMethod; // method that does the bad assignment
  final String description; // human-readable explanation
  final String suggestedFix; // code snippet fix

  KnownRisk({
    required this.type,
    required this.file,
    required this.line,
    required this.fieldName,
    required this.callerMethod,
    required this.description,
    required this.suggestedFix,
  });
}

/// Analyses the Flutter project codebase to extract everything the
/// test generator needs — no manual configuration required.
class AppAnalyser {
  final String projectPath;

  AppAnalyser({required this.projectPath});

  late AppAnalysis analysis;

  Future<AppAnalysis> analyse() async {
    print('  🔬 Analysing project codebase...');

    final packageName = _detectPackageName();
    final appStateInfo = _analyseAppState();
    final mainInfo = _analyseMain();
    final firebaseOptions = _detectFirebaseOptions();
    final detectedRoutes = _detectRoutes();
    final routerType = _detectRouterType();
    final routerVariable = _detectRouterVariable();
    final stateManagement = _detectStateManagement();
    final knownRisks = _detectKnownRisks();

    analysis = AppAnalysis(
      packageName: packageName,
      appClass: mainInfo['appClass'] ?? 'MyApp',
      appArgs: mainInfo['appArgs'] ?? '',
      appStateClass: appStateInfo['class'] ?? 'AppState',
      appStateInitMethod: appStateInfo['initMethod'],
      appStateTokenField: appStateInfo['tokenField'],
      appStateJwtField: appStateInfo['jwtField'],
      appStateUserIdField: appStateInfo['userIdField'],
      appStateUserNameField: appStateInfo['userNameField'],
      appStateEmailField: appStateInfo['emailField'],
      hasFirebase: firebaseOptions != null,
      firebaseOptionsImport: firebaseOptions,
      routes: detectedRoutes,
      routerType: routerType,
      routerVariable: routerVariable,
      stateManagement: stateManagement,
      knownRisks: knownRisks,
    );

    print('  ✅ Package: $packageName');
    print('  ✅ App class: ${analysis.appClass}(${analysis.appArgs})');
    print(
        '  ✅ AppState: ${analysis.appStateClass}.${analysis.appStateInitMethod ?? 'none'}()');
    print('  ✅ Token field: ${analysis.appStateTokenField ?? 'not found'}');
    print('  ✅ Firebase: ${analysis.hasFirebase}');
    print('  ✅ Routes found: ${analysis.routes.length}');
    if (knownRisks.isNotEmpty) {
      print('  ⚠️  Known risks detected: ${knownRisks.length}');
      for (final r in knownRisks) {
        print('     • [${r.type}] ${r.file}:${r.line} — ${r.fieldName}');
      }
    }

    return analysis;
  }

  String _detectPackageName() {
    final pubspec = File('$projectPath/pubspec.yaml');
    if (!pubspec.existsSync()) return 'app';
    final match = RegExp(r'^name:\s*(\w+)', multiLine: true)
        .firstMatch(pubspec.readAsStringSync());
    return match?.group(1) ?? 'app';
  }

  Map<String, String?> _analyseAppState() {
    // Find app_state.dart
    final candidates = [
      '$projectPath/lib/app_state.dart',
      '$projectPath/lib/flutter_flow/app_state.dart',
    ];

    String? content;
    for (final path in candidates) {
      final f = File(path);
      if (f.existsSync()) {
        content = f.readAsStringSync();
        break;
      }
    }

    // Also search lib/ recursively
    if (content == null) {
      final libDir = Directory('$projectPath/lib');
      if (libDir.existsSync()) {
        final files = libDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('app_state.dart'));
        if (files.isNotEmpty) content = files.first.readAsStringSync();
      }
    }

    if (content == null) return {};

    // Find class name
    final classMatch =
        RegExp(r'class\s+(\w*AppState\w*)\s').firstMatch(content);
    final className = classMatch?.group(1) ?? 'AppState';

    // Find init method — could be static or instance, various names
    String? initMethod;
    for (final pattern in [
      RegExp(r'static\s+Future\S*\s+(initialize)\s*\('),
      RegExp(r'static\s+Future\S*\s+(initializePersistedState)\s*\('),
      RegExp(r'static\s+Future\S*\s+(init)\s*\('),
      RegExp(r'static\s+Future\S*\s+(setup)\s*\('),
      // Instance methods (no static keyword)
      RegExp(r'^\s*Future\s+\w*\s+(initializePersistedState)\s*\(',
          multiLine: true),
      RegExp(r'^\s*Future\s+\w*\s+(initialize)\s*\(', multiLine: true),
      RegExp(r'^\s*Future\s+\w*\s+(init)\s*\(', multiLine: true),
    ]) {
      final m = pattern.firstMatch(content);
      if (m != null) {
        initMethod = m.group(1);
        break;
      }
    }

    // Final fallback — find any method that assigns prefs
    if (initMethod == null && content.contains('SharedPreferences')) {
      final prefInitMatch = RegExp(
        r'(?:Future|void)\s+(\w+)\s*\([^)]*\)\s*async[^{]*\{[^}]*prefs\s*=',
        dotAll: true,
      ).firstMatch(content);
      initMethod = prefInitMatch?.group(1);
    }

    // Find token/auth fields
    String? tokenField = _findStateField(content, [
      'token',
      'authToken',
      'accessToken',
      'jwtToken',
      'idToken',
      'bearerToken',
      'apiToken'
    ]);
    String? jwtField =
        _findStateField(content, ['jwtToken', 'jwt', 'bearerToken']);
    String? userIdField =
        _findStateField(content, ['userIdInt', 'userId', 'uid']);
    String? userNameField =
        _findStateField(content, ['userName', 'name', 'displayName']);
    String? emailField =
        _findStateField(content, ['emailId', 'email', 'userEmail']);

    return {
      'class': className,
      'initMethod': initMethod,
      'tokenField': tokenField,
      'jwtField': jwtField,
      'userIdField': userIdField,
      'userNameField': userNameField,
      'emailField': emailField,
    };
  }

  String? _findStateField(String content, List<String> candidates) {
    for (final name in candidates) {
      // Look for setter or field declaration
      if (RegExp(r'\b' + name + r'\b').hasMatch(content)) return name;
    }
    return null;
  }

  Map<String, String?> _analyseMain() {
    final mainFile = File('$projectPath/lib/main.dart');
    if (!mainFile.existsSync()) return {};
    final content = mainFile.readAsStringSync();

    // Find child: WidgetName(...) inside runApp
    final childMatch =
        RegExp(r'child:\s*(\w+)\s*\(([^)]*)\)').firstMatch(content);
    final directMatch = RegExp(r'runApp\(\s*(?:const\s+)?(\w+)\s*\(([^)]*)\)')
        .firstMatch(content);

    String appClass;
    String appArgs;

    if (childMatch != null) {
      appClass = childMatch.group(1)!;
      appArgs = childMatch.group(2)!.trim();
    } else if (directMatch != null) {
      appClass = directMatch.group(1)!;
      appArgs = directMatch.group(2)!.trim();
    } else {
      return {'appClass': 'MyApp', 'appArgs': ''};
    }

    // Keep only literal args
    appArgs = appArgs.replaceAll(RegExp(r'\s+'), ' ').trim();
    final safeArgs = appArgs
        .split(',')
        .map((a) => a.trim())
        .where((a) => a.isNotEmpty && a.contains(':'))
        .where((a) {
      final val = a.split(':').last.trim();
      return val == 'true' ||
          val == 'false' ||
          val.startsWith("'") ||
          val.startsWith('"') ||
          RegExp(r'^\d+$').hasMatch(val);
    }).join(', ');

    return {
      'appClass': appClass,
      'appArgs': safeArgs,
    };
  }

  String? _detectFirebaseOptions() {
    final candidates = [
      '$projectPath/lib/firebase_options.dart',
      '$projectPath/lib/firebase/firebase_options.dart',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) {
        // Return the import path relative to package
        final packageName = _detectPackageName();
        final relativePath = path
            .replaceFirst('$projectPath/lib/', '')
            .replaceFirst('.dart', '');
        return "import 'package:$packageName/$relativePath.dart';";
      }
    }
    return null;
  }

  /// Detect the navigation router type from pubspec.yaml dependencies.
  String _detectRouterType() {
    final pubspec = File('$projectPath/pubspec.yaml');
    if (!pubspec.existsSync()) return 'unknown';
    final content = pubspec.readAsStringSync();
    if (content.contains('go_router')) return 'gorouter';
    if (RegExp(r'\bget:\s').hasMatch(content) || content.contains('get_x')) {
      return 'getx';
    }
    if (content.contains('auto_route')) return 'autoroute';
    if (content.contains('beamer')) return 'beamer';
    return 'navigator1';
  }

  /// Detect the top-level GoRouter/navigatorKey variable name from source.
  String? _detectRouterVariable() {
    final libDir = Directory('$projectPath/lib');
    if (!libDir.existsSync()) return null;

    final patterns = [
      RegExp(r'(?:final|late|var)\s+(\w+)\s*=\s*GoRouter\s*\('),
      RegExp(r'(?:final|late|var)\s+(\w+)\s*=\s*RouterConfig'),
      RegExp(r'GlobalKey<NavigatorState>\(\)\s*;\s*\n.*?(\w+)\s*='),
    ];

    for (final file in libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      try {
        final content = file.readAsStringSync();
        for (final p in patterns) {
          final m = p.firstMatch(content);
          if (m != null) return m.group(1);
        }
      } catch (_) {}
    }
    return null;
  }

  /// Scan the entire lib/ directory for route paths across all major router types.
  List<String> _detectRoutes() {
    final routes = <String>{};
    final libDir = Directory('$projectPath/lib');
    if (!libDir.existsSync()) return [];

    // Patterns that capture a route identifier from various router declarations.
    // GoRouter may use relative paths (e.g. 'loginPage') or absolute ('/login').
    // We capture the value and normalise to an absolute path where needed.
    final pathPatterns = [
      // GoRouter: name: 'PracticePage'  — preferred for goNamed() navigation
      RegExp(r"name:\s*'([A-Z][a-zA-Z0-9_]+)'"),
      RegExp(r'name:\s*"([A-Z][a-zA-Z0-9_]+)"'),
      // GoRouter / any: path: '/home' or path: 'home'
      RegExp(r"path:\s*'([a-zA-Z0-9_/][^']*)'"),
      RegExp(r'path:\s*"([a-zA-Z0-9_/][^"]*)"'),
      // GetX: GetPage(name: '/home')
      RegExp(r"GetPage\s*\([^)]*name:\s*'(/[^']+)'"),
      RegExp(r'GetPage\s*\([^)]*name:\s*"(/[^"]+)"'),
      // Navigator 1.0: pushNamed('/home')
      RegExp(r"pushNamed\s*\(\s*'(/[^']+)'"),
      RegExp(r'pushNamed\s*\(\s*"(/[^"]+)"'),
      // AutoRoute: @AutoRoute(path: '/home')
      RegExp(r"@\w*[Rr]oute\s*\([^)]*path:\s*'([^']+)'"),
      RegExp(r'@\w*[Rr]oute\s*\([^)]*path:\s*"([^"]+)"'),
      // Beamer: pathPatterns: ['/home']
      RegExp(r"pathPatterns:\s*\[[^\]]*'(/[^']+)'"),
      RegExp(r'pathPatterns:\s*\[[^\]]*"(/[^"]+)"'),
    ];

    for (final file in libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      try {
        final content = file.readAsStringSync();
        for (final pattern in pathPatterns) {
          for (final m in pattern.allMatches(content)) {
            final route = m.group(1)!;
            // Skip empty, single-char, template params, and obvious non-routes
            if (route.length > 1 &&
                !route.contains(r'$') &&
                route != '_initialize' &&
                route != 'initial') {
              routes.add(route);
            }
          }
        }
      } catch (_) {}
    }

    return routes.toList();
  }

  // ─── Known-risk static analysis ──────────────────────────────────────────

  List<KnownRisk> _detectKnownRisks() {
    final risks = <KnownRisk>[];
    final libDir = Directory('$projectPath/lib');
    if (!libDir.existsSync()) return risks;

    for (final file in libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      try {
        final content = file.readAsStringSync();
        final shortPath = file.path.split('/lib/').last;
        _detectLateFieldDoubleInit(shortPath, content, risks);
        _detectSetStateAfterDispose(shortPath, content, risks);
        _detectStreamSubscriptionLeak(shortPath, content, risks);
        _detectBuildSideEffects(shortPath, content, risks);
      } catch (_) {}
    }
    return risks;
  }

  /// Detects: late field assigned inside a method called from
  /// didChangeDependencies() without an initialization guard.
  /// Produces LateInitializationError on widget rebuild.
  void _detectLateFieldDoubleInit(
      String shortPath, String content, List<KnownRisk> risks) {
    if (!content.contains('didChangeDependencies')) return;

    final lines = content.split('\n');

    // Collect all `late Type _fieldName` declarations
    final lateFields = <String, int>{}; // fieldName → line number
    for (var i = 0; i < lines.length; i++) {
      final m = RegExp(r'late\s+\w[\w<>, ?]*\s+(_\w+)').firstMatch(lines[i]);
      if (m != null) lateFields[m.group(1)!] = i + 1;
    }
    if (lateFields.isEmpty) return;

    // Extract didChangeDependencies body
    final didChange = _extractMethodBody(lines, 'didChangeDependencies');
    if (didChange == null) return;

    // Find non-system method calls made from didChangeDependencies.
    // Use negative lookbehind to skip chained calls like Something.of(context).
    final calledMethods = RegExp(r'(?<!\.)\b([a-z]\w+)\s*\(')
        .allMatches(didChange['body'] as String)
        .map((m) => m.group(1)!)
        .where((m) => !const {
              'super',
              'if',
              'while',
              'for',
              'switch',
              'setState',
              'print',
              'log',
              'assert',
              'mounted',
              'context',
              'of',
            }.contains(m))
        .toSet();

    for (final methodName in calledMethods) {
      final method = _extractMethodBody(lines, methodName);
      if (method == null) continue;
      // Skip static methods — they can't be called as instance methods from
      // didChangeDependencies, so any match is a false positive.
      if (method['isStatic'] == true) continue;
      final methodBody = method['body'] as String;

      for (final field in lateFields.keys) {
        // Does the method assign this late field?
        if (!RegExp(r'\b' + RegExp.escape(field) + r'\s*=\s*\w')
            .hasMatch(methodBody)) {
          continue;
        }

        // Is there an initialization guard?
        final didChangeBody = didChange['body'] as String;
        if (_hasInitGuard(didChangeBody) || _hasInitGuard(methodBody)) continue;

        // Find the line of the assignment
        int assignLine = lateFields[field]!;
        for (var i = (method['startLine'] as int); i < lines.length; i++) {
          if (RegExp(r'\b' + RegExp.escape(field) + r'\s*=\s*\w')
              .hasMatch(lines[i])) {
            assignLine = i + 1;
            break;
          }
        }

        risks.add(KnownRisk(
          type: 'late_field_double_init',
          file: shortPath,
          line: assignLine,
          fieldName: field,
          callerMethod: methodName,
          description: 'Late field `$field` is assigned in `$methodName()` '
              'which is called from `didChangeDependencies()` without an '
              'initialization guard. Flutter calls `didChangeDependencies()` '
              'multiple times during mounting, causing LateInitializationError '
              'on the second call.',
          suggestedFix: 'Add a boolean guard:\n'
              '\n'
              '  bool _${methodName}Called = false;\n'
              '\n'
              '  @override\n'
              '  void didChangeDependencies() {\n'
              '    super.didChangeDependencies();\n'
              '    if (!_${methodName}Called) {\n'
              '      _${methodName}Called = true;\n'
              '      $methodName();\n'
              '    }\n'
              '  }',
        ));
      }
    }
  }

  /// Detects: setState() called without a mounted guard.
  /// Common cause of "setState called after dispose" FlutterError.
  void _detectSetStateAfterDispose(
      String shortPath, String content, List<KnownRisk> risks) {
    if (!content.contains('setState')) return;
    if (!content.contains('async')) return; // only async contexts are risky

    final lines = content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      // Match setState( but NOT inside a mounted guard on the same or previous line
      if (!RegExp(r'\bsetState\s*\(').hasMatch(line)) continue;

      // Check a window of 3 lines above for `if (mounted)`
      final window =
          lines.sublist((i - 3).clamp(0, lines.length), i).join('\n');
      if (window.contains('mounted')) continue;

      // Must be inside an async method (look back for async keyword)
      final before = lines.sublist(0, i).join('\n');
      final asyncMethodMatch =
          RegExp(r'(Future|void)\s+\w+\s*\([^)]*\)\s*async').hasMatch(before);
      if (!asyncMethodMatch) continue;

      risks.add(KnownRisk(
        type: 'setState_after_dispose',
        file: shortPath,
        line: i + 1,
        fieldName: 'setState',
        callerMethod: 'async callback',
        description:
            '`setState()` is called inside an async method without checking '
            '`mounted` first. If the widget is disposed before the async '
            'operation completes, this throws a FlutterError at runtime.',
        suggestedFix: 'Wrap setState with a mounted guard:\n'
            '\n'
            '  if (mounted) setState(() { ... });',
      ));
    }
  }

  /// Detects: StreamSubscription field with no cancel() call in dispose().
  /// Causes memory leaks and "Bad state: Stream has already been listened to".
  void _detectStreamSubscriptionLeak(
      String shortPath, String content, List<KnownRisk> risks) {
    if (!content.contains('StreamSubscription')) return;

    final lines = content.split('\n');

    // Find all StreamSubscription field declarations
    final subFields = <String, int>{};
    for (var i = 0; i < lines.length; i++) {
      final m =
          RegExp(r'StreamSubscription\S*\??\s+(_\w+)').firstMatch(lines[i]);
      if (m != null) subFields[m.group(1)!] = i + 1;
    }
    if (subFields.isEmpty) return;

    // Extract dispose() body
    final dispose = _extractMethodBody(lines, 'dispose');
    final disposeBody = dispose?['body'] as String? ?? '';

    for (final entry in subFields.entries) {
      final field = entry.key;
      final declLine = entry.value;
      // Is there a cancel() call on this field in dispose?
      if (RegExp(r'\b' + RegExp.escape(field) + r'\s*\??\s*\.cancel\s*\(')
          .hasMatch(disposeBody)) {
        continue;
      }
      risks.add(KnownRisk(
        type: 'stream_subscription_leak',
        file: shortPath,
        line: declLine,
        fieldName: field,
        callerMethod: 'dispose',
        description:
            '`$field` is a StreamSubscription but `$field.cancel()` is not '
            'called in `dispose()`. This leaks the subscription and can cause '
            '"Bad state: Stream has already been listened to" on hot-restart.',
        suggestedFix: 'Cancel in dispose():\n'
            '\n'
            '  @override\n'
            '  void dispose() {\n'
            '    $field?.cancel();\n'
            '    super.dispose();\n'
            '  }',
      ));
    }
  }

  /// Detects: async calls or setState() directly inside build().
  /// Causes infinite rebuild loops and unpredictable UI state.
  void _detectBuildSideEffects(
      String shortPath, String content, List<KnownRisk> risks) {
    if (!content.contains('Widget build(')) return;

    final lines = content.split('\n');
    final build = _extractMethodBody(lines, 'build');
    if (build == null) return;
    if (build['isStatic'] == true) return;

    final buildBody = build['body'] as String;
    final startLine = build['startLine'] as int;

    // setState inside build
    if (RegExp(r'\bsetState\s*\(').hasMatch(buildBody)) {
      final setStateLine = lines.indexWhere(
          (l) => RegExp(r'\bsetState\s*\(').hasMatch(l), startLine);
      risks.add(KnownRisk(
        type: 'build_side_effects',
        file: shortPath,
        line: setStateLine > 0 ? setStateLine + 1 : startLine + 1,
        fieldName: 'setState',
        callerMethod: 'build',
        description:
            '`setState()` is called directly inside `build()`. This triggers '
            'an infinite rebuild loop and will crash the app with '
            '"setState called during build".',
        suggestedFix:
            'Move state mutations to event handlers (onTap, onPressed, '
            'initState, didChangeDependencies) — never inside build().',
      ));
    }

    // Unguarded async call inside build (Future/await but not as a FutureBuilder value)
    if (buildBody.contains('await ') &&
        !buildBody.contains('FutureBuilder') &&
        !buildBody.contains('StreamBuilder')) {
      final awaitLine =
          lines.indexWhere((l) => l.contains('await '), startLine);
      risks.add(KnownRisk(
        type: 'build_side_effects',
        file: shortPath,
        line: awaitLine > 0 ? awaitLine + 1 : startLine + 1,
        fieldName: 'await',
        callerMethod: 'build',
        description: '`await` is used directly inside `build()` without a '
            'FutureBuilder/StreamBuilder. Build methods must be synchronous; '
            'async calls here are silently ignored and cause stale UI.',
        suggestedFix: 'Wrap async data with FutureBuilder:\n'
            '\n'
            '  FutureBuilder<T>(\n'
            '    future: myAsyncCall(),\n'
            '    builder: (context, snapshot) {\n'
            '      if (!snapshot.hasData) return CircularProgressIndicator();\n'
            '      return MyWidget(data: snapshot.data!);\n'
            '    },\n'
            '  )',
      ));
    }
  }

  /// Returns true if [body] contains a recognizable initialization guard.
  bool _hasInitGuard(String body) {
    return body.contains('_initialized') ||
        body.contains('_isInit') ||
        body.contains('Called') ||
        RegExp(r'if\s*\(\s*!_\w+\s*\)').hasMatch(body) ||
        body.contains('!= null') ||
        body.contains('?? ');
  }

  /// Extracts the body of the first method named [methodName] by tracking
  /// brace depth. Returns {'body': String, 'startLine': int, 'isStatic': bool}
  /// or null if not found.
  Map<String, dynamic>? _extractMethodBody(
      List<String> lines, String methodName) {
    int start = -1;
    for (var i = 0; i < lines.length; i++) {
      if (RegExp(r'\b' + RegExp.escape(methodName) + r'\s*\(')
          .hasMatch(lines[i])) {
        start = i;
        break;
      }
    }
    if (start == -1) return null;

    // Check the declaration line (and one line above) for `static` keyword.
    final declarationContext = [
      if (start > 0) lines[start - 1],
      lines[start],
    ].join(' ');
    final isStatic = declarationContext.contains(RegExp(r'\bstatic\b'));

    var depth = 0;
    var started = false;
    final buffer = StringBuffer();

    for (var i = start; i < lines.length; i++) {
      for (final ch in lines[i].split('')) {
        if (ch == '{') {
          depth++;
          started = true;
        } else if (ch == '}') {
          depth--;
          if (started && depth == 0) {
            return {
              'body': buffer.toString(),
              'startLine': start,
              'isStatic': isStatic,
            };
          }
        }
      }
      if (started) buffer.writeln(lines[i]);
    }
    return null;
  }

  String _detectStateManagement() {
    final pubspec = File('$projectPath/pubspec.yaml');
    if (!pubspec.existsSync()) return 'unknown';
    final content = pubspec.readAsStringSync();
    if (content.contains('flutter_bloc') || content.contains('bloc:')) {
      return 'bloc';
    }
    if (content.contains('riverpod')) return 'riverpod';
    if (content.contains('get:') || content.contains('get_x')) return 'getx';
    if (content.contains('provider:')) return 'provider';
    return 'provider'; // flutter_flow default
  }
}

class AppAnalysis {
  final String packageName;
  final String appClass;
  final String appArgs;
  final String appStateClass;
  final String? appStateInitMethod;
  final String? appStateTokenField;
  final String? appStateJwtField;
  final String? appStateUserIdField;
  final String? appStateUserNameField;
  final String? appStateEmailField;
  final bool hasFirebase;
  final String? firebaseOptionsImport;
  final List<String> routes;

  /// 'gorouter' | 'getx' | 'autoroute' | 'beamer' | 'navigator1' | 'unknown'
  final String routerType;

  /// Top-level variable name holding the router instance (e.g. '_router').
  final String? routerVariable;
  final String stateManagement;
  final List<KnownRisk> knownRisks;

  AppAnalysis({
    required this.packageName,
    required this.appClass,
    required this.appArgs,
    required this.appStateClass,
    required this.appStateInitMethod,
    required this.appStateTokenField,
    required this.appStateJwtField,
    required this.appStateUserIdField,
    required this.appStateUserNameField,
    required this.appStateEmailField,
    required this.hasFirebase,
    required this.firebaseOptionsImport,
    required this.routes,
    required this.routerType,
    required this.routerVariable,
    required this.stateManagement,
    required this.knownRisks,
  });

  /// The full runApp call e.g. MyApp(allowDarkMode: true)
  String get runAppCall =>
      appArgs.isNotEmpty ? '$appClass($appArgs)' : 'const $appClass()';
}
