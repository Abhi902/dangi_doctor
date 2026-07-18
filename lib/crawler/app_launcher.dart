import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'adb_runner.dart';

/// Patterns that carry the VM service URL in `flutter run` output.
/// NOTE: device names contain spaces ("sdk gphone64 x86 64"), hence `.+`
/// in the third pattern — `\S+` never matched real output.
final List<RegExp> _vmUrlPatterns = [
  RegExp(r'Connecting to VM Service at (ws://\S+)', caseSensitive: false),
  RegExp(r'VM Service listening on (ws://\S+)', caseSensitive: false),
  RegExp(r'A Dart VM Service on .+ is available at: (http://\S+)',
      caseSensitive: false),
  RegExp(r'(ws://127\.0\.0\.1:\d+/\S*)'),
];

/// Extract and normalize the VM service WebSocket URL from a single line of
/// `flutter run` output. Rewrites the host to 127.0.0.1 (traffic goes over
/// the adb forward), keeps any auth-token path segment, and guarantees a
/// trailing `/ws`. Returns null when the line carries no VM service URL.
({String url, int port})? parseVmServiceLine(String line,
    {int fallbackPort = 8181}) {
  for (final pattern in _vmUrlPatterns) {
    final match = pattern.firstMatch(line);
    if (match == null) continue;

    var url = match.group(1)!.trim();
    url = url.replaceFirst('http://', 'ws://');

    // Extract the actual port Flutter chose.
    final portMatch = RegExp(r':(\d+)').firstMatch(url);
    final actualPort = portMatch != null
        ? int.tryParse(portMatch.group(1)!) ?? fallbackPort
        : fallbackPort;

    // Rewrite host but keep token path.
    url = url.replaceFirstMapped(
      RegExp(r'ws://[^/]+'),
      (_) => 'ws://127.0.0.1:$actualPort',
    );

    if (!url.endsWith('/ws')) {
      url = '${url.replaceAll(RegExp(r'/?$'), '')}/ws';
    }
    return (url: url, port: actualPort);
  }
  return null;
}

class AppLauncher {
  final String projectPath;

  /// Executable used for all `flutter` invocations — overridable in tests.
  final String flutterCommand;

  /// How long `flutter devices --machine` may take before its process is killed.
  final Duration deviceScanTimeout;

  Process? _flutterProcess;

  /// The device ID that was picked during [pickDeviceAndLaunch].
  String? pickedDeviceId;

  AppLauncher({
    required this.projectPath,
    this.flutterCommand = 'flutter',
    this.deviceScanTimeout = const Duration(seconds: 15),
  });

  /// Returns the VM service WebSocket URL.
  /// Sets [pickedDeviceId] as a side-effect.
  Future<String> pickDeviceAndLaunch() async {
    await killAllFlutterProcesses();
    final devices = await getDevices();

    if (devices.isEmpty) {
      throw Exception(
        'No connected devices found.\n'
        'Connect a physical device via USB or start an emulator.',
      );
    }

    final device = await _askUserToPickDevice(devices);
    pickedDeviceId = device['id'] as String?;
    return await _launchOnDevice(device);
  }

  /// Clear only state a previous Dangi Doctor run may have left behind.
  ///
  /// This used to pkill -9 every `flutter run` on the machine (including the
  /// user's own IDE debug sessions), kill whatever process was bound to
  /// ports 8181-8185, and remove ALL adb forwards. A doctor must not kill
  /// unrelated patients — we only drop our own default forward; if the
  /// launch port turns out to be busy, the launch fails with a clear error
  /// instead of us killing the owner.
  static Future<void> killAllFlutterProcesses() async {
    await AdbRunner.runGlobal(['forward', '--remove', 'tcp:8181']);
  }

  /// Enumerate devices via `flutter devices --machine`. Public for testing.
  /// Kills the child process if it exceeds [deviceScanTimeout] — a plain
  /// `.timeout()` on `Process.run` abandons the future but leaves the
  /// process running forever.
  Future<List<Map<String, dynamic>>> getDevices() async {
    print('🔍 Scanning for available devices...\n');
    Process? process;
    try {
      process = await Process.start(
        flutterCommand,
        ['devices', '--machine'],
        workingDirectory: projectPath,
      );
      final stdoutFuture = process.stdout.transform(const Utf8Decoder()).join();
      unawaited(process.stderr.drain<void>());
      await process.exitCode.timeout(deviceScanTimeout);

      final raw = (await stdoutFuture).trim();
      if (raw.isEmpty) return [];
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      process?.kill(ProcessSignal.sigkill);
      return [];
    }
  }

  Future<Map<String, dynamic>> _askUserToPickDevice(
    List<Map<String, dynamic>> devices,
  ) async {
    print('┌─────────────────────────────────────────────────────────────┐');
    print('│  Available devices — where do you want to test?            │');
    print('├─────────────────────────────────────────────────────────────┤');
    for (var i = 0; i < devices.length; i++) {
      final d = devices[i];
      final name = d['name'] as String? ?? 'Unknown';
      final platform = d['targetPlatform'] as String? ?? '';
      final isEmulator = d['emulator'] as bool? ?? false;
      final type = isEmulator ? '📱 Emulator' : '📲 Physical';
      print('│  ${i + 1}. $type — $name ($platform)');
    }
    print('└─────────────────────────────────────────────────────────────┘');
    stdout.write('\nYour choice (1-${devices.length}): ');

    final input = stdin.readLineSync()?.trim() ?? '1';
    final index = (int.tryParse(input) ?? 1) - 1;
    final picked = devices[index.clamp(0, devices.length - 1)];
    print('\n✅ Selected: ${picked['name']}\n');
    return picked;
  }

  Future<String> _launchOnDevice(Map<String, dynamic> device) async {
    final deviceId = device['id'] as String;
    final isEmulator = device['emulator'] as bool? ?? false;
    const port = 8181;

    print('📱 Launching app on ${device['name']}...');

    _flutterProcess = await Process.start(
      flutterCommand,
      [
        'run',
        '-d',
        deviceId,
        '--vm-service-port=$port',
        '--disable-service-auth-codes',
      ],
      workingDirectory: projectPath,
    );

    final wsCompleter = Completer<String>();

    // Progress spinner
    final spinner = _ProgressSpinner();
    spinner.start('Building app');

    var vmUrlClaimed = false;

    Future<void> handleLine(String line) async {
      // Only show clean status updates — suppress raw Android logs
      if (line.contains('Running Gradle')) {
        spinner.update('Running Gradle build');
      } else if (line.contains('Built build/')) {
        spinner.update('Build complete — installing on device');
      } else if (line.contains('Syncing files')) {
        spinner.update('Syncing files to device');
      } else if (line.contains('Flutter run key commands')) {
        spinner.update('App running — waiting for VM service');
      }

      if (vmUrlClaimed) return;
      final parsed = parseVmServiceLine(line, fallbackPort: port);
      if (parsed == null) return;
      // Claim synchronously — BEFORE the first await — so a second matching
      // line cannot also pass the guard while we forward the port.
      vmUrlClaimed = true;

      spinner.stop('✅ App launched successfully');
      print('  📡 VM service on port ${parsed.port}');

      // Forward port, remapping to the real device port if Flutter lied
      if (!isEmulator) {
        await _forwardWithActualDevicePort(deviceId, parsed.port);
      }
      wsCompleter.complete(parsed.url);
    }

    _flutterProcess!.stdout
        .transform(const Utf8Decoder())
        .transform(const LineSplitter())
        .listen(handleLine);
    _flutterProcess!.stderr
        .transform(const Utf8Decoder())
        .transform(const LineSplitter())
        .listen(handleLine);

    final wsUrl = await wsCompleter.future.timeout(
      const Duration(minutes: 3),
      onTimeout: () {
        spinner.stop('❌ Launch timed out');
        throw Exception('App launch timed out after 3 minutes.');
      },
    );

    // Wait for VM service to be fully ready
    stdout.write('  ⏳ Waiting for VM service to be ready...');
    await Future.delayed(const Duration(seconds: 2));
    print(' ready!');

    return wsUrl;
  }

  /// Forward the reported port, remapping to the real device port if Flutter lied.
  Future<void> _forwardWithActualDevicePort(
      String deviceId, int reportedPort) async {
    final devicePort =
        await _findActualVmPort(deviceId, hintPort: reportedPort);
    if (devicePort != null && devicePort != reportedPort) {
      print(
          '  ⚠️  Flutter reported port $reportedPort but VM is on device port $devicePort');
      final ok =
          await AdbRunner.forwardRemap(deviceId, reportedPort, devicePort);
      if (ok) {
        print('📡 Port remapped: Mac:$reportedPort → Device:$devicePort ✅');
      } else {
        print(
            '📡 Run manually: adb -s $deviceId forward tcp:$reportedPort tcp:$devicePort');
      }
    } else {
      final ok = await AdbRunner.forward(deviceId, reportedPort);
      if (ok) {
        print('📡 Port $reportedPort forwarded ✅');
      } else {
        print(
            '📡 Run manually: adb -s $deviceId forward tcp:$reportedPort tcp:$reportedPort');
      }
    }
  }

  /// Scan /proc/net/tcp on the device to find the actual port the Dart VM
  /// is listening on. Flutter sometimes reports the wrong port.
  ///
  /// Looks for LISTEN (state 0A) entries on loopback (127.0.0.1 = 0100007F).
  /// Returns the port closest to [hintPort] when multiple candidates exist.
  Future<int?> _findActualVmPort(String deviceId, {int? hintPort}) async {
    try {
      final result = await AdbRunner.run(
        deviceId,
        ['shell', 'cat', '/proc/net/tcp'],
        timeout: const Duration(seconds: 5),
      );
      final ports = <int>[];
      for (final line in result.stdout.toString().split('\n')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 4) continue;
        final localAddr = parts[1]; // "0100007F:A28D"
        final state = parts[3]; // "0A" = LISTEN
        if (state != '0A') continue;
        final addrParts = localAddr.split(':');
        if (addrParts.length != 2) continue;
        if (addrParts[0] != '0100007F') continue; // must be 127.0.0.1
        final port = int.tryParse(addrParts[1], radix: 16);
        if (port == null || port <= 1024) continue;
        ports.add(port);
      }
      if (ports.isEmpty) return null;
      if (ports.length == 1) return ports.first;
      if (hintPort != null) {
        ports.sort(
            (a, b) => (a - hintPort).abs().compareTo((b - hintPort).abs()));
      }
      return ports.first;
    } catch (_) {
      return null;
    }
  }

  Future<void> dispose() async {
    _flutterProcess?.kill();
    _flutterProcess = null;
  }
}

/// Clean animated spinner for terminal progress
class _ProgressSpinner {
  static const _frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
  int _frameIndex = 0;
  String _message = '';
  Timer? _timer;
  bool _active = false;

  void start(String message) {
    _message = message;
    _active = true;
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!_active) return;
      _frameIndex = (_frameIndex + 1) % _frames.length;
      stdout.write('\r  ${_frames[_frameIndex]}  $_message   ');
    });
  }

  void update(String message) {
    _message = message;
  }

  void stop(String finalMessage) {
    _active = false;
    _timer?.cancel();
    stdout.write('\r');
    print('  $finalMessage');
  }
}
