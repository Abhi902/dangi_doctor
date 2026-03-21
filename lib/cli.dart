/// Dangi Doctor — Flutter app health CLI.
///
/// Automatically crawls a live Flutter app on a real Android device,
/// analyses widget trees, measures performance, detects known bugs,
/// and generates integration test scripts — no manual configuration required.
///
/// **Typical usage:** run as a command-line tool from your Flutter project root.
/// ```
/// dart pub global activate dangi_doctor
/// cd your_flutter_project
/// dangi_doctor
/// ```
library;

export 'crawler/screen_navigator.dart' show DiscoveredScreen, ScreenNavigator;
export 'generator/app_analyser.dart' show AppAnalysis, AppAnalyser;
