import 'project_fingerprint.dart';
import 'knowledge_updater.dart';

class PromptAssembler {
  final String projectPath;

  PromptAssembler({required this.projectPath});

  /// Assembles the full system prompt from all three knowledge layers.
  ///
  /// [compact] — when true, uses a truncated Layer 1 (first 3000 chars only)
  /// instead of the full flutter docs. Use this for free-tier providers that
  /// have strict token-per-minute limits (e.g. Groq free tier).
  Future<String> assemble({bool compact = false}) async {
    final buffer = StringBuffer();

    // Layer 1 — Flutter official knowledge (bundled, updated weekly)
    final layer1 = KnowledgeUpdater.layer1;
    if (compact) {
      // Role definition + core rules only — cut at the last section
      // boundary before ~3000 chars, never mid-word. The compact prompt is
      // used by the chunked batch path (tight free-tier TPM limits), which
      // asks for tiny bullet lists — so it deliberately omits layer 2 and
      // the full-report output format that would contradict that ask.
      buffer.writeln(_truncateAtSectionBoundary(layer1, 3000));
    } else {
      buffer.writeln(layer1);

      // Layer 2 — Community anti-patterns (bundled, updated weekly)
      buffer.writeln(KnowledgeUpdater.layer2);
    }

    // Layer 3 — Project specific (auto-detected on first run)
    final fingerprint = ProjectFingerprint(projectPath: projectPath);
    final projectData = await fingerprint.loadOrScan();
    buffer.writeln(fingerprint.toPromptSection(projectData));

    if (!compact) {
      // Output format instructions
      buffer.writeln(_outputFormat());
    }

    return buffer.toString();
  }

  /// Cut [text] at the last `━━━` section boundary before [maxChars]
  /// (falls back to the last newline) so a truncated prompt never ends
  /// mid-word or mid-sentence.
  String _truncateAtSectionBoundary(String text, int maxChars) {
    if (text.length <= maxChars) return text;
    final window = text.substring(0, maxChars);
    final sectionCut = window.lastIndexOf('\n━━━');
    if (sectionCut > 0) return window.substring(0, sectionCut);
    final lineCut = window.lastIndexOf('\n');
    return lineCut > 0 ? window.substring(0, lineCut) : window;
  }

  String _outputFormat() {
    return '''
=== OUTPUT FORMAT ===
Structure your diagnosis exactly like this:

HEALTH SCORE: X/100

SUMMARY:
One paragraph. Plain English. What is the overall state of this screen?
Be direct — developers appreciate honesty over politeness.

CRITICAL ISSUES (must fix before shipping):
For each issue: file name, line number, what is wrong, why it matters, exact fix.
Show before/after code for the top 2 most impactful issues.

WARNINGS (fix soon):
Grouped by file. Short and actionable.

PRESCRIPTIONS (priority order):
Numbered list. Most impactful fix first.
Each prescription = one specific action the developer can take today.
''';
  }
}
