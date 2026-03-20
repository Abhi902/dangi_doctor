import 'dart:convert';
import 'package:dangi_doctor/ai/knowledge/prompt_assembler.dart';
import 'package:http/http.dart' as http;

class ClaudeClient {
  final String apiKey;
  final String projectPath;
  final String model = 'claude-opus-4-6';

  ClaudeClient({required this.apiKey, required this.projectPath});

  Future<String> diagnose({
    required List<Map<String, dynamic>> issues,
    required int totalWidgets,
    required int maxDepth,
    required Map<String, int> widgetCounts,
    required String screenName,
  }) async {
    print('\n🤖 Assembling knowledge layers...');

    // Assemble the prompt from all 3 layers
    final assembler = PromptAssembler(projectPath: projectPath);
    final systemPrompt = await assembler.assemble();

    print('🧠 Sending to Claude Opus (most powerful model)...');

    final issueText = issues.map((i) {
      return '[${(i['severity'] as String).toUpperCase()}] '
          '${i['type']} in ${i['file'] ?? 'unknown'}:${i['line'] ?? '?'} — '
          '${i['message']}';
    }).join('\n');

    final topWidgets = widgetCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final widgetSummary =
        topWidgets.take(10).map((e) => '${e.key}: ${e.value}x').join(', ');

    final userMessage = '''
Diagnose this Flutter screen and provide your full medical report.

SCREEN: $screenName
TOTAL WIDGETS: $totalWidgets
MAX NESTING DEPTH: $maxDepth
TOP WIDGETS ON SCREEN: $widgetSummary

DETECTED ISSUES:
$issueText

Give me your full diagnosis with health score and prioritised prescriptions.
''';

    final response = await http.post(
      Uri.parse('https://api.anthropic.com/v1/messages'),
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: jsonEncode({
        'model': model,
        'max_tokens': 2048,
        'system': systemPrompt,
        'messages': [
          {'role': 'user', 'content': userMessage}
        ],
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['content'][0]['text'] as String;
    } else {
      throw Exception(
          'Claude API error: ${response.statusCode}\n${response.body}');
    }
  }
}
