// Dangi Doctor is designed to be run as a command-line tool:
//
//   dart pub global activate dangi_doctor
//   cd your_flutter_project
//   dangi_doctor
//
// It will:
//   1. Connect to the Flutter VM service of your running app
//   2. Crawl every reachable screen via uiautomator tap simulation
//   3. Analyse widget trees and detect known anti-patterns
//   4. Generate integration test scripts per screen
//   5. Open an HTML health report in your browser
//
// The library API below is available for programmatic use:

import 'package:dangi_doctor/cli.dart';

void main() {
  // Build a DiscoveredScreen result manually (the crawler produces these):
  final screen = DiscoveredScreen(
    name: 'HomeScreen',
    widgetTree: {'type': 'Scaffold', 'children': []},
    issues: [],
    totalWidgets: 42,
    maxDepth: 8,
  );

  print('Screen: ${screen.name}');
  print('Total widgets: ${screen.totalWidgets}');
  print('Max nesting depth: ${screen.maxDepth}');
  print('Issues: ${screen.issues.length}');
}
