import 'project_fingerprint.dart';
import 'knowledge_updater.dart';

class PromptAssembler {
  final String projectPath;

  PromptAssembler({required this.projectPath});

  Future<String> assemble() async {
    final buffer = StringBuffer();

    // Layer 1 — Flutter official knowledge (bundled, updated weekly via pub upgrade)
    buffer.writeln(KnowledgeUpdater.layer1);

    // Layer 2 — Community anti-patterns (bundled, updated weekly via pub upgrade)
    buffer.writeln(KnowledgeUpdater.layer2);

    // Layer 3 — Project specific (auto-detected on first run)
    final fingerprint = ProjectFingerprint(projectPath: projectPath);
    final projectData = await fingerprint.loadOrScan();
    buffer.writeln(fingerprint.toPromptSection(projectData));

    // Output format instructions
    buffer.writeln(_outputFormat());

    return buffer.toString();
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

HEALTH TREND:
If this is not the first run, compare to previous diagnosis and note improvement or regression.
''';
  }
}
