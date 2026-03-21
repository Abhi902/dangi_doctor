import 'dart:convert';
import 'dart:io';

class ProjectFingerprint {
  final String projectPath;

  ProjectFingerprint({required this.projectPath});

  /// Runs on first diagnosis — scans the project and saves .dangi_doctor/project.json
  Future<Map<String, dynamic>> scan() async {
    print('\n🔬 Scanning project for first-time fingerprint...');

    final fingerprint = <String, dynamic>{};

    fingerprint['scanned_at'] = DateTime.now().toIso8601String();
    fingerprint['project_path'] = projectPath;

    // 1. Read pubspec.yaml
    fingerprint['pubspec'] = await _scanPubspec();

    // 2. Detect state management
    fingerprint['state_management'] = await _detectStateManagement();

    // 3. Scan folder structure
    fingerprint['structure'] = await _scanStructure();

    // 4. Detect naming conventions
    fingerprint['conventions'] = await _detectConventions();

    // 5. Count file sizes — find large files
    fingerprint['large_files'] = await _findLargeFiles();

    // 6. Detect custom base widgets
    fingerprint['custom_widgets'] = await _detectCustomWidgets();

    // Save to .dangi_doctor/project.json
    await _save(fingerprint);

    print('✅ Project fingerprint saved to .dangi_doctor/project.json');
    return fingerprint;
  }

  /// Load existing fingerprint or scan if not found
  Future<Map<String, dynamic>> loadOrScan() async {
    final file = File('$projectPath/.dangi_doctor/project.json');
    if (file.existsSync()) {
      print('📂 Loading existing project fingerprint...');
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }
    return await scan();
  }

  Future<Map<String, dynamic>> _scanPubspec() async {
    final pubspec = File('$projectPath/pubspec.yaml');
    if (!pubspec.existsSync()) return {};

    final content = pubspec.readAsStringSync();
    final deps = <String>[];

    // Extract dependency names simply
    final lines = content.split('\n');
    bool inDeps = false;
    for (final line in lines) {
      if (line.trim() == 'dependencies:') {
        inDeps = true;
        continue;
      }
      if (inDeps &&
          line.isNotEmpty &&
          !line.startsWith(' ') &&
          !line.startsWith('\t')) {
        inDeps = false;
      }
      if (inDeps && line.startsWith('  ') && !line.startsWith('   ')) {
        final name = line.trim().split(':').first.trim();
        if (name.isNotEmpty && !name.startsWith('#')) {
          deps.add(name);
        }
      }
    }

    return {'dependencies': deps};
  }

  Future<String> _detectStateManagement() async {
    final libDir = Directory('$projectPath/lib');
    if (!libDir.existsSync()) return 'unknown';

    final dartFiles = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

    int providerCount = 0;
    int blocCount = 0;
    int riverpodCount = 0;
    int getxCount = 0;

    for (final file in dartFiles.take(50)) {
      try {
        final content = file.readAsStringSync();
        if (content.contains('ChangeNotifier') ||
            content.contains('Provider(')) {
          providerCount++;
        }
        if (content.contains('Bloc') || content.contains('BlocBuilder')) {
          blocCount++;
        }
        if (content.contains('Riverpod') || content.contains('WidgetRef')) {
          riverpodCount++;
        }
        if (content.contains('GetX') || content.contains('GetBuilder')) {
          getxCount++;
        }
      } catch (_) {}
    }

    if (blocCount > providerCount && blocCount > riverpodCount) return 'bloc';
    if (riverpodCount > providerCount) return 'riverpod';
    if (getxCount > providerCount) return 'getx';
    if (providerCount > 0) return 'provider';
    return 'setState';
  }

  Future<Map<String, dynamic>> _scanStructure() async {
    final libDir = Directory('$projectPath/lib');
    if (!libDir.existsSync()) return {};

    final topDirs = libDir
        .listSync()
        .whereType<Directory>()
        .map((d) => d.path.split('/').last)
        .toList();

    final dartFiles = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .length;

    return {
      'top_level_folders': topDirs,
      'total_dart_files': dartFiles,
    };
  }

  Future<Map<String, dynamic>> _detectConventions() async {
    final libDir = Directory('$projectPath/lib');
    if (!libDir.existsSync()) return {};

    final files = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => f.path.split('/').last)
        .toList();

    // Detect naming pattern
    final hasWidget = files.any((f) => f.contains('_widget.dart'));
    final hasPage = files.any((f) => f.contains('_page.dart'));
    final hasScreen = files.any((f) => f.contains('_screen.dart'));
    final hasView = files.any((f) => f.contains('_view.dart'));

    String screenNaming = 'unknown';
    if (hasWidget) screenNaming = '_widget.dart';
    if (hasPage) screenNaming = '_page.dart';
    if (hasScreen) screenNaming = '_screen.dart';
    if (hasView) screenNaming = '_view.dart';

    return {
      'screen_file_naming': screenNaming,
      'total_files_scanned': files.length,
    };
  }

  Future<List<Map<String, dynamic>>> _findLargeFiles() async {
    final libDir = Directory('$projectPath/lib');
    if (!libDir.existsSync()) return [];

    final largeFiles = <Map<String, dynamic>>[];

    final dartFiles = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

    for (final file in dartFiles) {
      try {
        final lines = file.readAsLinesSync().length;
        if (lines > 300) {
          largeFiles.add({
            'file': file.path.replaceAll('$projectPath/', ''),
            'lines': lines,
          });
        }
      } catch (_) {}
    }

    // Sort by size descending
    largeFiles.sort((a, b) => (b['lines'] as int).compareTo(a['lines'] as int));
    return largeFiles.take(10).toList();
  }

  Future<List<String>> _detectCustomWidgets() async {
    final libDir = Directory('$projectPath/lib');
    if (!libDir.existsSync()) return [];

    final customWidgets = <String>[];
    final dartFiles = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

    for (final file in dartFiles) {
      try {
        final content = file.readAsStringSync();
        // Find classes that extend StatelessWidget or StatefulWidget
        final matches = RegExp(r'class (\w+) extends Stateless|StatefulWidget')
            .allMatches(content);
        for (final match in matches) {
          final className = match.group(1);
          if (className != null) customWidgets.add(className);
        }
      } catch (_) {}
    }

    return customWidgets.take(20).toList();
  }

  Future<void> _save(Map<String, dynamic> fingerprint) async {
    final dir = Directory('$projectPath/.dangi_doctor');
    if (!dir.existsSync()) dir.createSync();

    final file = File('$projectPath/.dangi_doctor/project.json');
    const encoder = JsonEncoder.withIndent('  ');
    file.writeAsStringSync(encoder.convert(fingerprint));
  }

  /// Convert fingerprint to prompt section for Claude
  String toPromptSection(Map<String, dynamic> fingerprint) {
    final pubspec = fingerprint['pubspec'] as Map? ?? {};
    final deps = (pubspec['dependencies'] as List? ?? []).join(', ');
    final stateManagement = fingerprint['state_management'] ?? 'unknown';
    final structure = fingerprint['structure'] as Map? ?? {};
    final folders = (structure['top_level_folders'] as List? ?? []).join(', ');
    final totalFiles = structure['total_dart_files'] ?? 0;
    final conventions = fingerprint['conventions'] as Map? ?? {};
    final naming = conventions['screen_file_naming'] ?? 'unknown';
    final largeFiles = fingerprint['large_files'] as List? ?? [];
    final largeFilesText = largeFiles
        .map((f) => '  ${f['file']} (${f['lines']} lines)')
        .join('\n');

    return '''
PROJECT SPECIFIC KNOWLEDGE (auto-detected on first run):
- State management: $stateManagement
- Dependencies: $deps
- Folder structure: $folders
- Total Dart files: $totalFiles
- Screen naming convention: $naming
- Files over 300 lines (refactor candidates):
$largeFilesText

When diagnosing this project:
- Use $stateManagement patterns and terminology
- Flag any usage that goes against $stateManagement best practices
- Files over 300 lines are already known — mention them as a priority refactor
''';
  }
}
