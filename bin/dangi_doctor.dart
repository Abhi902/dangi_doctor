import 'dart:io';
import 'package:dangi_doctor/ai/knowledge/ai_providers.dart';
import 'package:dangi_doctor/ai/knowledge/project_fingerprint.dart';
import 'package:dangi_doctor/crawler/screen_navigator.dart';
import 'package:dangi_doctor/crawler/app_launcher.dart';
import 'package:dangi_doctor/crawler/screen_crawler.dart';
import 'package:dangi_doctor/crawler/vm_locator.dart';
import 'package:dangi_doctor/generator/test_generator.dart';
import 'package:dangi_doctor/report/html_report.dart';

void main() async {
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

  final projectPath = _resolveProjectPath();
  print('📁 Project: $projectPath\n');

  // Step 1 — pick AI provider
  final provider = await AiProviderDetector.detect();
  if (provider == null) print('⚡ Crawler-only mode — no AI diagnosis.\n');

  // Step 2 — get VM service URL
  String? wsUrl = await VmServiceLocator.discover(projectPath: projectPath);
  AppLauncher? launcher;
  String? deviceId;

  if (wsUrl == null) {
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
      deviceId = launcher.pickedDeviceId;
      await VmServiceLocator.saveUrl(projectPath, wsUrl);
    } else {
      wsUrl = await VmServiceLocator.askUser();
      if (wsUrl.isNotEmpty) {
        await VmServiceLocator.saveUrl(projectPath, wsUrl);
      }
    }
  }

  if (wsUrl.isEmpty) {
    print('❌ No VM service URL. Exiting.');
    exit(1);
  }

  final crawler = ScreenCrawler(projectPath: projectPath, wsUrl: wsUrl);

  try {
    await crawler.connect();

    // Wait for splash screen to dismiss
    await crawler.waitForAppReady();
    print('');

    // Layer 3 — always generate project fingerprint, regardless of AI provider
    await ProjectFingerprint(projectPath: projectPath).loadOrScan();

    // Full app navigation crawl
    final navigator = ScreenNavigator(
      vmService: crawler.vmService,
      isolateId: crawler.isolateId,
      deviceId: deviceId ?? '',
      maxScreens: 10,
    );

    final screens = await navigator.walkAllScreens();
    navigator.printSummary();

    // AI diagnosis per screen
    if (provider != null) {
      final aiClient = AiClient(provider: provider, projectPath: projectPath);
      print('\n🤖 Running AI diagnosis on ${screens.length} screens...\n');

      for (final screen in screens) {
        print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
        print('🤖 ${screen.name}');
        print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

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
      }
    }

    // Generate test scripts per screen
    final generator = TestGenerator(projectPath: projectPath);
    for (final screen in screens) {
      await generator.generateAndSave(
        screenName: screen.name,
        widgetTree: screen.widgetTree,
        interactionResults: [],
        issues: screen.issues,
      );
    }

    // Generate HTML health report
    await HtmlReportGenerator.generate(
      screens: screens,
      knownRisks: generator.cachedAnalysis?.knownRisks ?? [],
      projectPath: projectPath,
      projectName: projectPath.split('/').last,
    );
  } catch (e) {
    print('❌ Error: $e');
    print(StackTrace.current);
  } finally {
    await crawler.disconnect();
    await launcher?.dispose();
  }
}

/// Resolve the Flutter project path.
///
/// Priority:
/// 1. DANGI_PROJECT env var (CI / power users)
/// 2. Current working directory if it contains a pubspec.yaml with a flutter dependency
/// 3. Ask the user interactively
String _resolveProjectPath() {
  // 1. Explicit env var override
  final envPath = Platform.environment['DANGI_PROJECT'];
  if (envPath != null && envPath.isNotEmpty) return envPath;

  // 2. Auto-detect: current working directory is a Flutter project
  final cwd = Directory.current.path;
  final pubspec = File('$cwd/pubspec.yaml');
  if (pubspec.existsSync()) {
    final content = pubspec.readAsStringSync();
    if (content.contains('flutter:')) {
      print('✅ Detected Flutter project in current directory.');
      return cwd;
    }
  }

  // 3. Ask the user
  print('Could not auto-detect a Flutter project in the current directory.');
  print('Please provide the absolute path to your Flutter project:');
  stdout.write('Project path: ');
  final input = stdin.readLineSync()?.trim() ?? '';
  if (input.isEmpty) {
    print('❌ No project path provided. Exiting.');
    exit(1);
  }
  if (!Directory(input).existsSync()) {
    print('❌ Directory not found: $input');
    exit(1);
  }
  return input;
}
