import 'dart:io';
import 'package:dangi_doctor/ai/knowledge/ai_providers.dart';
import 'package:dangi_doctor/analysis/performance.dart';
import 'package:dangi_doctor/ai/knowledge/project_fingerprint.dart';
import 'package:dangi_doctor/crawler/screen_navigator.dart';
import 'package:dangi_doctor/generator/app_analyser.dart';
import 'package:dangi_doctor/crawler/app_launcher.dart';
import 'package:dangi_doctor/crawler/adb_runner.dart';
import 'package:dangi_doctor/crawler/screen_crawler.dart';
import 'package:dangi_doctor/crawler/vm_locator.dart';
import 'package:dangi_doctor/generator/test_generator.dart';
import 'package:dangi_doctor/report/html_report.dart';
import 'package:dangi_doctor/src/cli_config.dart';

void main(List<String> argv) async {
  final CliConfig config;
  try {
    config = parseCliArgs(argv);
  } on FormatException catch (e) {
    stderr.writeln('❌ ${e.message}\n');
    stderr.writeln(usage());
    exitCode = 64; // EX_USAGE
    return;
  }
  if (config.showHelp) {
    print(usage());
    return;
  }
  if (config.showVersion) {
    print('dangi_doctor $kDangiVersion');
    return;
  }

  print('');
  print('██████╗  █████╗ ███╗   ██╗ ██████╗ ██╗');
  print('██╔══██╗██╔══██╗████╗  ██║██╔════╝ ██║');
  print('██║  ██║███████║██╔██╗ ██║██║  ███╗██║');
  print('██║  ██║██╔══██║██║╚██╗██║██║   ██║██║');
  print('██████╔╝██║  ██║██║ ╚████║╚██████╔╝██║');
  print('╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝ ╚═════╝ ╚═╝');
  print('██████╗  ██████╗  ██████╗████████╗ ██████╗ ██████╗ ');
  print('██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗');
  print('██║  ██║██║   ██║██║        ██║   ██║   ██║██████╔╝');
  print('██║  ██║██║   ██║██║        ██║   ██║   ██║██╔══██╗');
  print('██████╔╝╚██████╔╝╚██████╗   ██║   ╚██████╔╝██║  ██║');
  print('╚═════╝  ╚═════╝  ╚═════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝');
  print('');
  print("Your Flutter app's personal physician 🩺");
  print('');

  final projectPath = _resolveProjectPath(config);
  print('📁 Project: $projectPath\n');

  if (config.rescan) {
    final fingerprint = File('$projectPath/.dangi_doctor/project.json');
    if (fingerprint.existsSync()) {
      fingerprint.deleteSync();
      print('🔄 --rescan: cached project fingerprint deleted — rescanning.\n');
    }
  }

  // Step 1 — pick AI provider (unless --no-ai)
  final provider = config.noAi ? null : await AiProviderDetector.detect();
  if (provider == null) print('⚡ Crawler-only mode — no AI diagnosis.\n');

  // Step 2 — get VM service URL: --vm-url wins, then the cached/scanned
  // discovery, then the interactive menu (terminal only — never hang CI).
  String? wsUrl =
      config.vmUrl ?? await VmServiceLocator.discover(projectPath: projectPath);
  AppLauncher? launcher;
  String? deviceId = config.device;

  if (wsUrl == null) {
    if (!stdin.hasTerminal) {
      stderr.writeln('❌ No VM service URL and no terminal to ask on. '
          'Pass --vm-url <ws://...> (from a running `flutter run --debug`).');
      exitCode = 64;
      return;
    }
    print('');
    print('┌─────────────────────────────────────────────┐');
    print('│  How do you want to connect?                │');
    print('│                                             │');
    print('│  1. Launch app now (Dangi Doctor runs it)   │');
    print('│  2. App already running — paste VM URL      │');
    print('└─────────────────────────────────────────────┘');
    stdout.write('\nYour choice (1-2): ');
    final choice = stdin.readLineSync()?.trim() ?? '1';

    if (choice == '1') {
      launcher = AppLauncher(projectPath: projectPath);
      wsUrl = await launcher.pickDeviceAndLaunch();
      deviceId ??= launcher.pickedDeviceId;
      await VmServiceLocator.saveUrl(projectPath, wsUrl);
    } else {
      wsUrl = await VmServiceLocator.askUser();
      if (wsUrl.isNotEmpty) {
        await VmServiceLocator.saveUrl(projectPath, wsUrl);
      }
    }
  }

  // Detect device ID for ADB taps (Phase 2) — covers all connection paths:
  // launched via option 1, pasted URL via option 2, or auto-connected from cache.
  deviceId ??= await _detectAdbDevice();

  // Cross-check the picked device actually runs the app under test. The VM
  // service and the ADB device are discovered independently, so with several
  // devices attached we could tap a *different* phone than the one hosting the
  // app. If nothing (or only the launcher) is in the foreground, warn — Phase
  // 2 taps would be landing on the wrong device.
  if (deviceId != null) {
    try {
      final activities = await AdbRunner.run(
          deviceId, ['shell', 'dumpsys', 'activity', 'activities']);
      final fg = parseForegroundPackage(activities.stdout.toString());
      if (fg == null || isLauncherPackage(fg)) {
        print(
            '  ⚠️  Device $deviceId shows ${fg ?? 'no'} app in the foreground '
            '— if your Flutter app is on a different device, pass --device <id>.');
      }
    } catch (_) {}
  }

  // Jank budget follows the device's real refresh rate — judging a 120Hz
  // phone against 60Hz's 16ms grades a visibly janky app as "A".
  if (deviceId != null) {
    final display =
        await AdbRunner.run(deviceId, ['shell', 'dumpsys', 'display']);
    final hz = parseDisplayRefreshRate(display.stdout.toString());
    if (hz != null) {
      PerformanceCapture.frameBudgetMs = budgetMsForRefreshRate(hz);
      print('  🖥️  Display: ${hz.toStringAsFixed(0)}Hz — frame budget '
          '${PerformanceCapture.frameBudgetMs.toStringAsFixed(1)}ms');
    }
  }

  if (wsUrl.isEmpty) {
    stderr.writeln('❌ No VM service URL. Exiting.');
    exitCode = 64; // EX_USAGE — consistent with the non-terminal path above
    return;
  }

  final crawler = ScreenCrawler(projectPath: projectPath, wsUrl: wsUrl);

  try {
    await crawler.connect();

    // Wait for splash screen to dismiss
    await crawler.waitForAppReady();
    print('');

    // Layer 3 — always generate project fingerprint, regardless of AI provider
    await ProjectFingerprint(projectPath: projectPath).loadOrScan();

    // Static analysis — detect routes, router type, known risks
    print('\n🔬 Running static analysis...');
    final appAnalysis = await AppAnalyser(projectPath: projectPath).analyse();
    print('  ✅ Router: ${appAnalysis.routerType}'
        '${appAnalysis.routerVariable != null ? ' (var: ${appAnalysis.routerVariable})' : ''}'
        ' — ${appAnalysis.routes.length} routes');

    // Full app navigation crawl
    final navigator = ScreenNavigator(
      vmService: crawler.vmService,
      isolateId: crawler.isolateId,
      deviceId: deviceId ?? '',
      maxScreens: 20,
      analysis: appAnalysis,
      projectPath: projectPath,
    );

    final screens = await navigator.walkAllScreens();
    navigator.printSummary();

    // AI diagnosis per screen
    if (provider != null) {
      final aiClient = AiClient(provider: provider, projectPath: projectPath);
      print('\n🤖 Running AI diagnosis on ${screens.length} screens...\n');

      var aiFailures = 0;
      for (final screen in screens) {
        print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
        print('🤖 ${screen.name}');
        print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

        // One failed diagnosis must not abort the remaining screens —
        // nor the test generation and HTML report, which don't need AI.
        try {
          final aiReport = await aiClient.diagnose(
            issues: screen.issues
                .map((i) => {
                      'severity': i.severity,
                      'type': i.type,
                      'file': i.file,
                      'line': i.line,
                      'message': i.message,
                    })
                .toList(),
            totalWidgets: screen.totalWidgets,
            maxDepth: screen.maxDepth,
            widgetCounts: {},
            screenName: screen.name,
            perfGrade: screen.performance?.grade ?? 'N/A',
            avgBuildMs: screen.performance?.avgBuildMs ?? 0,
            jankRate: screen.performance?.jankRate ?? 0,
            jankyFrames: screen.performance?.jankyFrames ?? 0,
            totalFrames: screen.performance?.totalFrames ?? 0,
          );

          print(aiReport);
          print('');
        } catch (e) {
          aiFailures++;
          print('⚠️  AI diagnosis failed for ${screen.name}: $e');
          print('   Continuing with the remaining screens.\n');
        }
      }
      if (aiFailures > 0) {
        print('⚠️  AI diagnosis failed for $aiFailures of '
            '${screens.length} screens.');
      }
    }

    // Generate test scripts per screen — plumb each screen's REAL Phase-1/2
    // performance capture into the perf-test emitter (#16).
    final generator = TestGenerator(projectPath: projectPath);
    for (final screen in screens) {
      await generator.generateAndSave(
        screenName: screen.name,
        widgetTree: screen.widgetTree,
        interactionResults: [],
        issues: screen.issues,
        performance: screen.performance,
      );
    }

    // Generate HTML health report
    await HtmlReportGenerator.generate(
      screens: screens,
      knownRisks: generator.cachedAnalysis?.knownRisks ?? [],
      projectPath: projectPath,
      projectName: projectPath.split('/').last,
    );
  } catch (e, st) {
    stderr.writeln('❌ Error: $e');
    stderr.writeln(st);
    exitCode = 1; // a crashed run must not look like success to CI
  } finally {
    await crawler.disconnect();
    await launcher?.dispose();
  }
}

/// Auto-detect the connected Android device via `adb devices`.
/// Returns the device ID, or null if none found / multiple require user choice.
Future<String?> _detectAdbDevice() async {
  try {
    final result = await AdbRunner.runGlobal(['devices']);
    final lines = result.stdout
        .toString()
        .split('\n')
        .where((l) => l.trim().isNotEmpty && !l.startsWith('List'))
        .where((l) => l.contains('\tdevice'))
        .toList();
    if (lines.isEmpty) {
      print(
          '  ⚠️  No ADB devices found — Phase 2 (widget taps) will be skipped');
      return null;
    }
    if (lines.length == 1) {
      final id = lines.first.split('\t').first.trim();
      print('  📱 Auto-detected device: $id');
      return id;
    }
    if (!stdin.hasTerminal) {
      final id = lines.first.split('\t').first.trim();
      print('  📱 Multiple ADB devices, no terminal to ask — using first: $id'
          ' (override with --device)');
      return id;
    }
    print('  Multiple ADB devices connected:');
    for (var i = 0; i < lines.length; i++) {
      print('    ${i + 1}. ${lines[i].split('\t').first.trim()}');
    }
    stdout.write('  Pick device (1-${lines.length}): ');
    final pick = int.tryParse(stdin.readLineSync()?.trim() ?? '1') ?? 1;
    if (pick >= 1 && pick <= lines.length) {
      return lines[pick - 1].split('\t').first.trim();
    }
  } catch (e) {
    print('  ⚠️  Could not run adb ($e) — is Android platform-tools '
        'installed and on PATH? Phase 2 (widget taps) will be skipped.');
  }
  return null;
}

/// Resolve the Flutter project path.
///
/// Priority:
/// 1. --project flag
/// 2. DANGI_PROJECT env var (CI / power users)
/// 3. Current working directory if it contains a pubspec.yaml with a flutter dependency
/// 4. Ask the user interactively (terminal only)
///
/// Explicit paths (1-2) are validated instead of trusted blindly — a typo
/// used to surface as confusing downstream failures ("Package: app", 0 routes).
String _resolveProjectPath(CliConfig config) {
  for (final (label, explicit) in [
    ('--project', config.project),
    ('DANGI_PROJECT', Platform.environment['DANGI_PROJECT']),
  ]) {
    if (explicit == null || explicit.isEmpty) continue;
    final error = validateProjectDir(explicit);
    if (error != null) {
      stderr.writeln('❌ $label: $error');
      exit(64);
    }
    return explicit;
  }

  // Auto-detect: current working directory is a Flutter project
  final cwd = Directory.current.path;
  final pubspec = File('$cwd/pubspec.yaml');
  if (pubspec.existsSync()) {
    final content = pubspec.readAsStringSync();
    if (content.contains('flutter:')) {
      print('✅ Detected Flutter project in current directory.');
      return cwd;
    }
  }

  if (!stdin.hasTerminal) {
    stderr.writeln('❌ Not a Flutter project directory and no terminal to '
        'ask on. Pass --project <path> or set DANGI_PROJECT.');
    exit(64);
  }

  // Ask the user
  print('Could not auto-detect a Flutter project in the current directory.');
  print('Please provide the absolute path to your Flutter project:');
  stdout.write('Project path: ');
  final input = stdin.readLineSync()?.trim() ?? '';
  if (input.isEmpty) {
    print('❌ No project path provided. Exiting.');
    exit(1);
  }
  final error = validateProjectDir(input);
  if (error != null) {
    print('❌ $error');
    exit(1);
  }
  return input;
}
