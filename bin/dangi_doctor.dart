import 'dart:io';
import 'package:dangi_doctor/ai/knowledge/ai_providers.dart';
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

  final projectPath = Platform.environment['DANGI_PROJECT'] ??
      '/Users/abhishek/Desktop/reflex-flutter';
  final deviceId = Platform.environment['DANGI_DEVICE'] ?? 'Z5BISOCMHEP7FAXG';
  print('📁 Project: $projectPath\n');

  // Step 1 — pick AI provider
  final provider = await AiProviderDetector.detect();
  if (provider == null) print('⚡ Crawler-only mode — no AI diagnosis.\n');

  // Step 2 — get VM service URL
  String? wsUrl = await VmServiceLocator.discover(projectPath: projectPath);
  AppLauncher? launcher;

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

    // Full app navigation crawl
    final navigator = ScreenNavigator(
      vmService: crawler.vmService,
      isolateId: crawler.isolateId,
      deviceId: deviceId,
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
