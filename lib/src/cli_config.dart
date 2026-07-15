import 'dart:io';

import 'package:args/args.dart';

/// Bumped on release alongside pubspec.yaml.
const String kDangiVersion = '0.3.0';

/// Parsed command-line configuration for the dangi_doctor CLI.
class CliConfig {
  final bool showHelp;
  final bool showVersion;
  final bool noAi;
  final String? project;
  final String? vmUrl;
  final String? device;

  const CliConfig({
    this.showHelp = false,
    this.showVersion = false,
    this.noAi = false,
    this.project,
    this.vmUrl,
    this.device,
  });
}

ArgParser _buildParser() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.')
  ..addFlag('version', negatable: false, help: 'Show version.')
  ..addFlag('no-ai',
      negatable: false,
      help: 'Skip AI diagnosis (crawler + static analysis only).')
  ..addOption('project',
      help: 'Path to the Flutter project (defaults to DANGI_PROJECT or cwd).')
  ..addOption('vm-url',
      help: 'VM service WebSocket URL of an already-running app.')
  ..addOption('device', help: 'ADB device id for widget taps.');

String usage() => 'Usage: dangi_doctor [options]\n\n${_buildParser().usage}';

/// Throws [FormatException] on unknown flags/options.
CliConfig parseCliArgs(List<String> argv) {
  final results = _buildParser().parse(argv);
  return CliConfig(
    showHelp: results['help'] as bool,
    showVersion: results['version'] as bool,
    noAi: results['no-ai'] as bool,
    project: results['project'] as String?,
    vmUrl: results['vm-url'] as String?,
    device: results['device'] as String?,
  );
}

/// Returns an error message if [path] is not a usable Flutter project
/// directory, or null if it is. Keeps DANGI_PROJECT / --project typos from
/// turning into confusing downstream failures.
String? validateProjectDir(String path) {
  if (!Directory(path).existsSync()) {
    return 'Project directory not found: $path';
  }
  final pubspec = File('$path/pubspec.yaml');
  if (!pubspec.existsSync()) {
    return 'No pubspec.yaml in $path — not a Dart/Flutter project.';
  }
  return null;
}
