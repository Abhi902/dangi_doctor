import 'layer1_content.dart';
import 'layer2_content.dart';

/// Provides Layer 1 and Layer 2 knowledge content bundled with the package.
///
/// These files are updated automatically each week by a GitHub Actions workflow
/// in the dangi_doctor repository. Users receive fresh knowledge when they run:
///   dart pub upgrade dangi_doctor
///
/// No runtime HTTP fetching happens on the user's machine.
class KnowledgeUpdater {
  static String get layer1 => kLayer1Content;
  static String get layer2 => kLayer2Content;
}
