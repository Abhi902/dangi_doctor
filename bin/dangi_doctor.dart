import 'dart:io';
import 'package:dangi_doctor/ai/knowledge/ai_providers.dart';

import '../lib/generator/test_generator.dart';
import '../lib/crawler/app_launcher.dart';
import '../lib/crawler/screen_crawler.dart';
import '../lib/crawler/vm_locator.dart';
import '../lib/crawler/interaction_engine.dart';
import '../lib/analysis/tree_analyser.dart';
import '../lib/analysis/performance.dart';
import '../lib/ai/claude_client.dart';

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
  print('📁 Project: $projectPath\n');

  final provider = await AiProviderDetector.detect();
  if (provider == null) print('⚡ Crawler-only mode — no AI diagnosis.\n');

  // VM connection
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

  if (wsUrl == null || wsUrl.isEmpty) {
    print('❌ No VM service URL. Exiting.');
    exit(1);
  }

  final crawler = ScreenCrawler(projectPath: projectPath, wsUrl: wsUrl);
  final analyser = TreeAnalyser();

  try {
    await crawler.connect();

    // ── Wait for splash screen to dismiss ──
    await crawler.waitForAppReady();
    print('');

    // ── Capture widget tree ──
    final tree = await crawler.captureWidgetTree();
    print('✅ Widget tree captured\n');
    analyser.analyse(tree);

    // ── Baseline performance (2s idle) ──
    print('⏱️  Capturing baseline performance...');
    final perfCapture = PerformanceCapture(
      vmService: crawler.vmService,
      isolateId: crawler.isolateId,
    );
    final baselinePerf =
        await perfCapture.captureWindow(screenName: 'Screen_baseline');

    // ── AI-directed interaction testing ──
    print('\n🎮 Planning AI-directed interactions...');
    final engine = InteractionEngine(
      vmService: crawler.vmService,
      isolateId: crawler.isolateId,
      deviceId: Platform.environment['DANGI_DEVICE'] ?? 'Z5BISOCMHEP7FAXG',
    );

    final planned = engine.planInteractions(tree);

    if (planned.isEmpty) {
      print('  ℹ️  No interactive widgets found on current screen.');
      print('  Current screen may still be loading — try option 2 next time');
      print('  and paste the URL after your app has fully loaded.\n');
    } else {
      print('  ${planned.length} interactions planned:');
      for (final p in planned) {
        final icon = p.type == InteractionType.skip
            ? '⏭️ '
            : p.type == InteractionType.scroll
                ? '📜'
                : p.type == InteractionType.typeText
                    ? '⌨️ '
                    : p.type == InteractionType.animate
                        ? '🎬'
                        : '👆';
        final loc = p.file != null ? ' (${p.file}:${p.line})' : '';
        print('  $icon ${p.widgetType}$loc');
      }
    }

    final currentScreenName = _detectScreenName(tree);
    final List<InteractionResult> interactionResults = planned.isNotEmpty
        ? await engine.execute(planned, currentScreenName)
        : <InteractionResult>[];

    // ── Print reports ──
    baselinePerf.printReport();
    analyser.printSummary();

    // ── AI diagnosis ──
    if (provider != null) {
      final aiClient = AiClient(
        provider: provider,
        projectPath: projectPath,
      );

      final interactionReport =
          planned.isNotEmpty ? engine.toReportSection(interactionResults) : '';

      final aiReport = await aiClient.diagnose(
        issues: analyser.issues
            .map((i) => {
                  'severity': i.severity,
                  'type': i.type,
                  'file': i.file,
                  'line': i.line,
                  'message': i.message,
                })
            .toList(),
        totalWidgets: analyser.totalWidgets,
        maxDepth: analyser.maxDepthFound,
        widgetCounts: analyser.widgetCounts,
        screenName: currentScreenName,
        perfGrade: baselinePerf.grade,
        avgBuildMs: baselinePerf.avgBuildMs,
        jankRate: baselinePerf.jankRate,
        jankyFrames: baselinePerf.jankyFrames,
        totalFrames: baselinePerf.totalFrames,
        interactionReport: interactionReport,
      );

      print('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      print('🤖 AI DIAGNOSIS — DANGI DOCTOR');
      print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
      print(aiReport);
      print('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    }

    // ── Generate test scripts ──
    final generator = TestGenerator(projectPath: projectPath);
    await generator.generateAndSave(
      screenName: currentScreenName,
      widgetTree: tree,
      interactionResults: interactionResults,
      issues: analyser.issues,
    );
  } catch (e) {
    print('❌ Error: $e');
  } finally {
    await crawler.disconnect();
    await launcher?.dispose();
  }
}

/// Extract the current screen name from the widget tree
String _detectScreenName(Map<String, dynamic> tree) {
  String screen = 'UnknownScreen';
  _walkForScreenName(tree, (name) {
    screen = name;
  });
  return screen;
}

void _walkForScreenName(dynamic node, void Function(String) onScreen) {
  if (node == null) return;
  final type = node['widgetRuntimeType']?.toString() ?? '';
  if ((type.contains('Page') ||
          type.contains('Screen') ||
          type.contains('Widget')) &&
      !type.startsWith('_') &&
      type != 'Scaffold') {
    onScreen(type);
  }
  for (final child in (node['children'] as List? ?? [])) {
    _walkForScreenName(child, onScreen);
  }
}
