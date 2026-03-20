import 'dart:io';

/// Runs adb commands reliably regardless of PATH issues.
/// Uses /bin/sh to inherit the full shell PATH.
class AdbRunner {
  static const _adbPaths = [
    '/opt/homebrew/bin/adb', // Mac homebrew (M1/M2)
    '/usr/local/bin/adb', // Mac Intel homebrew
    '/usr/bin/adb', // Linux
    'adb', // fallback — in PATH
  ];

  static String? _adbPath;

  /// Find the adb binary once and cache it
  static Future<String> _findAdb() async {
    if (_adbPath != null) return _adbPath!;

    // Try known paths first — faster and more reliable than 'which'
    for (final path in _adbPaths) {
      if (path == 'adb') {
        _adbPath = path;
        return _adbPath!;
      }
      if (File(path).existsSync()) {
        _adbPath = path;
        return _adbPath!;
      }
    }

    _adbPath = 'adb';
    return _adbPath!;
  }

  /// Run an adb command without a device ID (e.g. forward --remove-all, devices)
  static Future<ProcessResult> runGlobal(
    List<String> args, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final adb = await _findAdb();
    final cmd = '$adb ${args.join(' ')}';
    return Process.run('/bin/sh', ['-c', cmd]).timeout(timeout);
  }

  /// Run an adb command with the device ID
  static Future<ProcessResult> run(
    String deviceId,
    List<String> args, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final adb = await _findAdb();
    final cmd = '$adb -s $deviceId ${args.join(' ')}';
    return Process.run('/bin/sh', ['-c', cmd]).timeout(timeout);
  }

  /// Run adb forward and return true on success
  static Future<bool> forward(String deviceId, int port) async {
    return forwardRemap(deviceId, port, port);
  }

  /// Forward localPort on the Mac to devicePort on the Android device.
  /// Use this when Flutter reports a port but the VM is actually on a different port.
  static Future<bool> forwardRemap(
      String deviceId, int localPort, int devicePort) async {
    final adb = await _findAdb();

    // Kill and restart adb server to clear all stale forwards
    await Process.run('/bin/sh', ['-c', '$adb kill-server'])
        .timeout(const Duration(seconds: 3))
        .catchError((_) => ProcessResult(0, 0, '', ''));
    await Process.run('/bin/sh', ['-c', '$adb start-server'])
        .timeout(const Duration(seconds: 5))
        .catchError((_) => ProcessResult(0, 0, '', ''));
    await Future.delayed(const Duration(milliseconds: 500));

    // Forward Mac localPort → device devicePort
    final result = await Process.run('/bin/sh', [
      '-c',
      '$adb -s $deviceId forward tcp:$localPort tcp:$devicePort'
    ]).timeout(const Duration(seconds: 5));
    return result.exitCode == 0;
  }

  /// Run adb input tap at x,y
  static Future<bool> tap(String deviceId, int x, int y) async {
    final result = await run(
      deviceId,
      ['shell', 'input', 'tap', x.toString(), y.toString()],
    );
    return result.exitCode == 0;
  }

  /// Run adb input swipe
  static Future<bool> swipe(
    String deviceId,
    int x1,
    int y1,
    int x2,
    int y2,
    int durationMs,
  ) async {
    final result = await run(
      deviceId,
      [
        'shell',
        'input',
        'swipe',
        x1.toString(),
        y1.toString(),
        x2.toString(),
        y2.toString(),
        durationMs.toString()
      ],
    );
    return result.exitCode == 0;
  }

  /// Run adb input keyevent
  static Future<bool> keyEvent(String deviceId, int keyCode) async {
    final result = await run(
      deviceId,
      ['shell', 'input', 'keyevent', keyCode.toString()],
    );
    return result.exitCode == 0;
  }

  /// Run adb input text
  static Future<bool> inputText(String deviceId, String text) async {
    final safe = text
        .replaceAll(' ', '%s')
        .replaceAll('&', '\\&')
        .replaceAll('@', '\\@');
    final result = await run(deviceId, ['shell', 'input', 'text', safe]);
    return result.exitCode == 0;
  }

  /// Get screen size via adb wm size
  static Future<Map<String, int>> screenSize(String deviceId) async {
    final result = await run(deviceId, ['shell', 'wm', 'size']);
    final match = RegExp(r'(\d+)x(\d+)').firstMatch(result.stdout.toString());
    if (match != null) {
      return {
        'width': int.parse(match.group(1)!),
        'height': int.parse(match.group(2)!),
      };
    }
    return {'width': 1080, 'height': 2400};
  }
}
