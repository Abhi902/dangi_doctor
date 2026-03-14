import 'dart:io';

class VmServiceLocator {
  static Future<String?> discover({String? projectPath}) async {
    print('🔍 Auto-detecting running Flutter app...');

    // Strategy 1: saved URL from last successful run
    if (projectPath != null) {
      final saved = await _fromSavedUrl(projectPath);
      if (saved != null) return saved;
    }

    // Strategy 2: scan default Flutter observatory ports
    final fromScan = await _scanFlutterPorts();
    if (fromScan != null) return fromScan;

    return null;
  }

  static Future<String?> _fromSavedUrl(String projectPath) async {
    final file = File('$projectPath/.dangi_doctor/vm_url.txt');
    if (!file.existsSync()) return null;
    final url = file.readAsStringSync().trim();
    if (url.isEmpty) return null;
    print('  📂 Testing saved VM URL...');
    if (await _isAliveWs(url)) {
      print('  ✅ Auto-connected using saved URL');
      return url;
    }
    print('  ⚠️  Saved URL stale — will relaunch app');
    file.deleteSync();
    return null;
  }

  static Future<String?> _scanFlutterPorts() async {
    print('  🔍 Scanning Flutter ports 8181-8183...');
    for (final port in [8181, 8182, 8183]) {
      final url = 'ws://127.0.0.1:$port/ws';
      if (await _isAliveWs(url)) {
        print('  ✅ Found Flutter app on port $port');
        return url;
      }
    }
    return null;
  }

  static Future<bool> _isAliveWs(String wsUrl) async {
    try {
      final httpBase = wsUrl
          .replaceFirst('ws://', 'http://')
          .replaceAll(RegExp(r'/ws$'), '');
      final req = await HttpClient()
          .getUrl(Uri.parse(httpBase))
          .timeout(const Duration(milliseconds: 800));
      final res = await req.close().timeout(const Duration(milliseconds: 800));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<void> saveUrl(String projectPath, String url) async {
    final dir = Directory('$projectPath/.dangi_doctor');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File('$projectPath/.dangi_doctor/vm_url.txt').writeAsStringSync(url);
    print('  💾 VM URL saved — next run will auto-connect');
  }

  static Future<String> askUser() async {
    print('');
    print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    print('  Could not auto-detect your Flutter app.');
    print('  Paste the VM service URL from your flutter run output:');
    print('  (look for: "Connecting to VM Service at ws://...")');
    print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    stdout.write('\nVM service URL: ');
    return stdin.readLineSync()?.trim() ?? '';
  }
}
