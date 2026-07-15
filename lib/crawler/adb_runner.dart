import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Parse `adb shell wm size` output. Prefers `Override size:` when present —
/// input coordinates operate in the override resolution, not the physical one.
Map<String, int> parseWmSize(String stdout) {
  final match = RegExp(r'Override size:\s*(\d+)x(\d+)').firstMatch(stdout) ??
      RegExp(r'Physical size:\s*(\d+)x(\d+)').firstMatch(stdout) ??
      RegExp(r'(\d+)x(\d+)').firstMatch(stdout);
  if (match != null) {
    return {
      'width': int.parse(match.group(1)!),
      'height': int.parse(match.group(2)!),
    };
  }
  return {'width': 1080, 'height': 2400};
}

/// Escape text for `adb shell input text`. The argument passes through the
/// DEVICE-side shell, so every metacharacter must be backslash-escaped and
/// spaces encoded as %s (the `input` tool's convention).
String escapeAdbShellText(String text) {
  var out = text.replaceAll('\\', '\\\\');
  for (final ch in ["'", '"', '&', r'$', '`', ';', '|', '<', '>', '(', ')']) {
    out = out.replaceAll(ch, '\\$ch');
  }
  return out.replaceAll(' ', '%s');
}

/// Runs adb commands reliably regardless of PATH issues.
class AdbRunner {
  static final _adbPaths = [
    if (Platform.environment['ANDROID_HOME'] != null)
      '${Platform.environment['ANDROID_HOME']}/platform-tools/adb',
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
      if (path == 'adb' || File(path).existsSync()) {
        _adbPath = path;
        return _adbPath!;
      }
    }

    _adbPath = 'adb';
    return _adbPath!;
  }

  /// Run adb directly (no shell wrapper — args with spaces/quotes/$ must
  /// never be re-interpreted by a local shell). On timeout the process is
  /// KILLED and a failure ProcessResult is returned instead of throwing, so
  /// one hung adb can't abort a whole crawl or leave zombies behind.
  static Future<ProcessResult> _exec(
      List<String> args, Duration timeout) async {
    final adb = await _findAdb();
    final Process process;
    try {
      process = await Process.start(adb, args);
    } on ProcessException catch (e) {
      return ProcessResult(0, 127, '', 'failed to start adb: $e');
    }
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    try {
      final code = await process.exitCode.timeout(timeout);
      return ProcessResult(
          process.pid, code, await stdoutFuture, await stderrFuture);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      return ProcessResult(process.pid, -1, '',
          'adb timed out after ${timeout.inSeconds}s: adb ${args.join(' ')}');
    }
  }

  /// Run an adb command without a device ID (e.g. devices)
  static Future<ProcessResult> runGlobal(
    List<String> args, {
    Duration timeout = const Duration(seconds: 5),
  }) =>
      _exec(args, timeout);

  /// Run an adb command with the device ID
  static Future<ProcessResult> run(
    String deviceId,
    List<String> args, {
    Duration timeout = const Duration(seconds: 5),
  }) =>
      _exec(['-s', deviceId, ...args], timeout);

  /// Run adb forward and return true on success
  static Future<bool> forward(String deviceId, int port) async {
    return forwardRemap(deviceId, port, port);
  }

  /// Forward localPort on the host to devicePort on the Android device.
  /// Use this when Flutter reports a port but the VM is actually on a
  /// different port.
  static Future<bool> forwardRemap(
      String deviceId, int localPort, int devicePort) async {
    // Remove only OUR forward if it exists. Never `adb kill-server` here —
    // that tears down every forward and session on the machine, including
    // the one `flutter run` itself relies on, and disconnects wireless
    // debugging for unrelated tools.
    await run(deviceId, ['forward', '--remove', 'tcp:$localPort']);
    final result =
        await run(deviceId, ['forward', 'tcp:$localPort', 'tcp:$devicePort']);
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
    final result = await run(
        deviceId, ['shell', 'input', 'text', escapeAdbShellText(text)]);
    return result.exitCode == 0;
  }

  /// Get screen size via adb wm size
  static Future<Map<String, int>> screenSize(String deviceId) async {
    final result = await run(deviceId, ['shell', 'wm', 'size']);
    return parseWmSize(result.stdout.toString());
  }
}
