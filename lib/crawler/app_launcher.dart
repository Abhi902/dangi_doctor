import 'dart:async';
import 'dart:convert';
import 'dart:io';

class AppLauncher {
  final String projectPath;
  Process? _flutterProcess;

  AppLauncher({required this.projectPath});

  Future<String> pickDeviceAndLaunch() async {
    await killAllFlutterProcesses();
    final devices = await _getDevices();

    if (devices.isEmpty) {
      throw Exception(
        'No connected devices found.\n'
        'Connect a physical device via USB or start an emulator.',
      );
    }

    final device = await _askUserToPickDevice(devices);
    return await _launchOnDevice(device);
  }

  static Future<void> killAllFlutterProcesses() async {
    print('🧹 Cleaning up stale Flutter processes...');
    await Process.run('pkill', ['-9', '-f', 'flutter_tools.snapshot']);
    await Process.run('pkill', ['-9', '-f', 'flutter run']);
    await Process.run('pkill', ['-9', '-f', 'flutter_tester']);
    await Process.run('pkill', ['-9', '-f', 'observatory-port']);
    await Process.run('pkill', ['-9', '-f', 'disable-service-auth-codes']);
    for (final port in [8181, 8182, 8183, 8184, 8185]) {
      await _killPort(port);
    }
    await Process.run('adb', ['forward', '--remove-all']);
    await Future.delayed(const Duration(seconds: 2));
    print('  ✅ All Flutter processes cleared\n');
  }

  static Future<void> _killPort(int port) async {
    try {
      final result = await Process.run('bash', ['-c', 'lsof -ti tcp:$port']);
      final pids = result.stdout
          .toString()
          .trim()
          .split('\n')
          .where((p) => p.isNotEmpty)
          .toList();
      for (final pid in pids) {
        await Process.run('kill', ['-9', pid]);
      }
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> _getDevices() async {
    print('🔍 Scanning for available devices...\n');
    try {
      final result = await Process.run(
        'flutter',
        ['devices', '--machine'],
        workingDirectory: projectPath,
      ).timeout(const Duration(seconds: 15));

      final raw = result.stdout.toString().trim();
      if (raw.isEmpty) return [];
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
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
      'flutter',
      [
        'run',
        '-d',
        deviceId,
        '--observatory-port=$port',
        '--disable-service-auth-codes',
      ],
      workingDirectory: projectPath,
    );

    final wsCompleter = Completer<String>();
    bool appBuilt = false;
    bool appSynced = false;

    // Progress spinner
    final spinner = _ProgressSpinner();
    spinner.start('Building app');

    void handleOutput(String text) {
      // Only show clean status updates — suppress raw Android logs
      if (text.contains('Running Gradle')) {
        spinner.update('Running Gradle build');
      } else if (text.contains('Built build/')) {
        appBuilt = true;
        spinner.update('Build complete — installing on device');
      } else if (text.contains('Syncing files')) {
        spinner.update('Syncing files to device');
      } else if (text.contains('Flutter run key commands')) {
        appSynced = true;
        spinner.update('App running — waiting for VM service');
      }

      if (wsCompleter.isCompleted) return;

      // Extract VM service URL — this is all we actually need
      final patterns = [
        RegExp(r'Connecting to VM Service at (ws://\S+)', caseSensitive: false),
        RegExp(r'VM Service listening on (ws://\S+)', caseSensitive: false),
        RegExp(r'A Dart VM Service on \S+ is available at: (http://\S+)',
            caseSensitive: false),
        RegExp(r'(ws://127\.0\.0\.1:\d+/\S*)'),
      ];

      for (final pattern in patterns) {
        final match = pattern.firstMatch(text);
        if (match != null) {
          var url = match.group(1)!.trim();
          url = url.replaceFirst('http://', 'ws://');
          if (!url.contains('/ws')) {
            url = '${url.replaceAll(RegExp(r'/?$'), '')}/ws';
          }
          spinner.stop('✅ App launched successfully');
          wsCompleter.complete(url);
          return;
        }
      }
    }

    _flutterProcess!.stdout.transform(const Utf8Decoder()).listen(handleOutput);
    _flutterProcess!.stderr.transform(const Utf8Decoder()).listen(handleOutput);

    final wsUrl = await wsCompleter.future.timeout(
      const Duration(minutes: 3),
      onTimeout: () {
        spinner.stop('❌ Launch timed out');
        throw Exception('App launch timed out after 3 minutes.');
      },
    );

    if (!isEmulator) {
      await _forwardPort(deviceId, port);
    }

    return wsUrl;
  }

  Future<void> _forwardPort(String deviceId, int port) async {
    stdout.write('📡 Forwarding port $port... ');
    // Try up to 3 times — sometimes needs a moment after app launches
    for (var i = 0; i < 3; i++) {
      final result = await Process.run(
        'adb',
        ['-s', deviceId, 'forward', 'tcp:$port', 'tcp:$port'],
      ).timeout(const Duration(seconds: 5));

      if (result.exitCode == 0) {
        print('✅');
        return;
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    print('⚠️  Run manually: adb -s $deviceId forward tcp:$port tcp:$port');
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
