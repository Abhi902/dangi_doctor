import 'dart:async';
import 'dart:io';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Pick the isolate running the Flutter framework.
///
/// [extensionsByIsolateId] maps isolate id → that isolate's `extensionRPCs`.
/// Returns the first id (map iteration order) exposing any `ext.flutter.*`
/// service extension, or null when none qualifies. `.first` is NOT safe:
/// background/helper isolates can list before the UI isolate.
String? pickFlutterIsolateId(Map<String, List<String>> extensionsByIsolateId) {
  for (final entry in extensionsByIsolateId.entries) {
    if (entry.value.any((rpc) => rpc.startsWith('ext.flutter.'))) {
      return entry.key;
    }
  }
  return null;
}

class ScreenCrawler {
  VmService? _vmService;
  String? _isolateId;
  final String? projectPath;
  final String wsUrl;

  ScreenCrawler({this.projectPath, required this.wsUrl});

  VmService get vmService => _vmService!;
  String get isolateId => _isolateId!;

  Future<void> connect() async {
    print('🔌 Connecting to VM service...');
    print('  📡 $wsUrl');

    // Retry up to 5 times — VM service may not be ready immediately
    for (var attempt = 1; attempt <= 5; attempt++) {
      try {
        _vmService = await vmServiceConnectUri(wsUrl, log: null);
        _isolateId = await _findFlutterIsolateId(_vmService!);

        print('✅ Connected to VM service');
        print('📱 Isolate ID: $_isolateId');

        final isolate = await _vmService!.getIsolate(_isolateId!);
        print('🩺 App name   : ${isolate.name}');
        print('🩺 App running: ${isolate.runnable}');
        return;
      } catch (e) {
        if (attempt == 5) {
          print('❌ Failed to connect after $attempt attempts: $e');
          rethrow;
        }
        print('  ⏳ Connection attempt $attempt failed — retrying in 2s...');
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  /// Find the isolate that exposes `ext.flutter.*` service extensions.
  ///
  /// Flutter registers its extensions lazily (around the first frame), so
  /// poll for up to ~5s before giving up with a clear error.
  Future<String> _findFlutterIsolateId(VmService service) async {
    for (var poll = 0; poll < 10; poll++) {
      final vm = await service.getVM();
      final extensionsById = <String, List<String>>{};
      for (final ref in vm.isolates ?? const <IsolateRef>[]) {
        final id = ref.id;
        if (id == null) continue;
        try {
          final isolate = await service.getIsolate(id);
          extensionsById[id] = isolate.extensionRPCs ?? const [];
        } catch (_) {
          // Isolate exited between getVM and getIsolate — skip it.
        }
      }
      final picked = pickFlutterIsolateId(extensionsById);
      if (picked != null) return picked;
      await Future.delayed(const Duration(milliseconds: 500));
    }
    throw StateError(
        'No isolate exposes ext.flutter.* service extensions after 5s. '
        'Is the target a Flutter app (not a plain Dart process), and has it '
        'rendered its first frame?');
  }

  /// Wait until a specific screen is visible in the widget tree.
  /// Polls every 500ms until the screen appears or times out.
  Future<bool> waitForScreen(String screenWidgetName,
      {int timeoutSeconds = 30}) async {
    print('\n⏳ Waiting for $screenWidgetName to appear...');
    final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds));

    while (DateTime.now().isBefore(deadline)) {
      final tree = await captureWidgetTree(silent: true);
      final currentScreen = _findCurrentScreen(tree);

      if (currentScreen.contains(screenWidgetName) ||
          _treeContains(tree, screenWidgetName)) {
        print('  ✅ $screenWidgetName detected');
        return true;
      }

      stdout.write('  ⏳ Current screen: $currentScreen — waiting...\r');
      await Future.delayed(const Duration(milliseconds: 500));
    }

    print('\n  ⚠️  Timed out waiting for $screenWidgetName');
    return false;
  }

  /// Wait until the splash screen is gone and the real app is loaded.
  Future<void> waitForAppReady() async {
    print('\n⏳ Waiting for app to finish loading...');
    const splashWidgets = [
      'SplashScreen',
      'splashScreenPage',
      'LinearProgressIndicator',
      'AnimatedContainer',
    ];
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    bool wasSplash = false;
    int failCount = 0;

    while (DateTime.now().isBefore(deadline)) {
      try {
        final tree = await captureWidgetTree(silent: true);
        failCount = 0; // reset on success

        final isSplash = splashWidgets.any((s) => _treeContains(tree, s));

        if (isSplash) {
          wasSplash = true;
          stdout.write('  ⏳ Splash screen loading...\r');
        } else if (wasSplash) {
          print('  ✅ App loaded — splash screen dismissed');
          await Future.delayed(const Duration(milliseconds: 800));
          return;
        } else {
          // Never saw splash — app already loaded
          print('  ✅ App ready');
          return;
        }
      } catch (_) {
        failCount++;
        stdout.write('  ⏳ Connecting... (attempt $failCount)\r');
        if (failCount > 10) {
          // Connection repeatedly failing — likely port not forwarded
          print('\n  ⚠️  Cannot read widget tree.');
          if (!stdin.hasTerminal) {
            // Never block on a prompt in CI — fail with the fix instead.
            throw Exception(
                'Cannot read widget tree after $failCount attempts. '
                'Check the adb port forward: adb -s <device_id> forward tcp:8181 tcp:8181');
          }
          print('  Run this in another terminal:');
          print('  adb -s <device_id> forward tcp:8181 tcp:8181');
          print('  Then press Enter to retry...');
          stdin.readLineSync();
          failCount = 0;
        }
      }

      await Future.delayed(const Duration(milliseconds: 500));
    }

    print('  ⚠️  Timed out — proceeding anyway');
  }

  String _findCurrentScreen(Map<String, dynamic> tree) {
    // Walk to find the deepest named page widget
    String screen = 'Unknown';
    _walkForScreen(tree, (name) {
      screen = name;
    });
    return screen;
  }

  void _walkForScreen(dynamic node, void Function(String) onScreen) {
    if (node == null) return;
    final type = node['widgetRuntimeType']?.toString() ?? '';
    if (type.contains('Page') ||
        type.contains('Screen') ||
        type.contains('View')) {
      onScreen(type);
    }
    for (final child in (node['children'] as List? ?? [])) {
      _walkForScreen(child, onScreen);
    }
  }

  bool _treeContains(Map<String, dynamic> tree, String widgetName) {
    final type = tree['widgetRuntimeType']?.toString() ?? '';
    if (type.contains(widgetName)) return true;
    for (final child in (tree['children'] as List? ?? [])) {
      if (_treeContains(child as Map<String, dynamic>, widgetName)) return true;
    }
    return false;
  }

  Future<Map<String, dynamic>> captureWidgetTree({bool silent = false}) async {
    if (!silent) print('\n📸 Capturing widget tree...');

    final response = await _vmService!.callServiceExtension(
      'ext.flutter.inspector.getRootWidgetTree',
      isolateId: _isolateId,
      args: {'groupName': 'dangi_doctor', 'isSummaryTree': 'true'},
    ).timeout(const Duration(seconds: 6));

    final json = response.json ?? {};
    if (json.containsKey('result')) {
      return json['result'] as Map<String, dynamic>;
    }
    if (json.containsKey('value')) return json['value'] as Map<String, dynamic>;
    return json;
  }

  Future<void> disconnect() async {
    await _vmService?.dispose();
    print('\n👋 Disconnected from VM service');
  }
}
