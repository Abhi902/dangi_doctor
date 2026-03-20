import 'dart:convert';
import 'dart:io';
import 'package:dangi_doctor/ai/knowledge/prompt_assembler.dart';
import 'package:http/http.dart' as http;

// ─── Base interface ────────────────────────────────────────────────────────────

abstract class AiProvider {
  String get name;
  Future<String> complete(String systemPrompt, String userMessage);
}

// ─── Claude ───────────────────────────────────────────────────────────────────

class ClaudeProvider implements AiProvider {
  final String apiKey;

  ClaudeProvider(this.apiKey);

  @override
  String get name => 'Claude Opus (Anthropic)';

  @override
  Future<String> complete(String systemPrompt, String userMessage) async {
    final response = await http.post(
      Uri.parse('https://api.anthropic.com/v1/messages'),
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: jsonEncode({
        'model': 'claude-opus-4-6',
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
    }
    throw Exception('Claude error: ${response.statusCode} ${response.body}');
  }
}

// ─── OpenAI ───────────────────────────────────────────────────────────────────

class OpenAiProvider implements AiProvider {
  final String apiKey;

  OpenAiProvider(this.apiKey);

  @override
  String get name => 'GPT-4o (OpenAI)';

  @override
  Future<String> complete(String systemPrompt, String userMessage) async {
    final response = await http.post(
      Uri.parse('https://api.openai.com/v1/chat/completions'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': 'gpt-4o',
        'max_tokens': 2048,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userMessage},
        ],
      }),
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['choices'][0]['message']['content'] as String;
    }
    throw Exception('OpenAI error: ${response.statusCode} ${response.body}');
  }
}

// ─── Gemini ───────────────────────────────────────────────────────────────────

class GeminiProvider implements AiProvider {
  final String apiKey;

  GeminiProvider(this.apiKey);

  @override
  String get name => 'Gemini 1.5 Pro (Google)';

  @override
  Future<String> complete(String systemPrompt, String userMessage) async {
    final response = await http.post(
      Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-pro:generateContent?key=$apiKey'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'system_instruction': {
          'parts': [
            {'text': systemPrompt}
          ]
        },
        'contents': [
          {
            'parts': [
              {'text': userMessage}
            ]
          }
        ],
        'generationConfig': {'maxOutputTokens': 2048},
      }),
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['candidates'][0]['content']['parts'][0]['text'] as String;
    }
    throw Exception('Gemini error: ${response.statusCode} ${response.body}');
  }
}

// ─── Groq ─────────────────────────────────────────────────────────────────────

class GroqProvider implements AiProvider {
  final String apiKey;

  GroqProvider(this.apiKey);

  @override
  String get name => 'Llama 3.3 70B (Groq — fast & cheap)';

  @override
  Future<String> complete(String systemPrompt, String userMessage) async {
    final response = await http.post(
      Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': 'llama-3.3-70b-versatile',
        'max_tokens': 2048,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userMessage},
        ],
      }),
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['choices'][0]['message']['content'] as String;
    }
    throw Exception('Groq error: ${response.statusCode} ${response.body}');
  }
}

// ─── Ollama (free, local, no API key needed) ──────────────────────────────────

class OllamaProvider implements AiProvider {
  OllamaProvider();

  @override
  String get name => 'Llama 3 (Ollama — free, local)';

  @override
  Future<String> complete(String systemPrompt, String userMessage) async {
    final response = await http
        .post(
          Uri.parse('http://localhost:11434/api/generate'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': 'llama3',
            'prompt': '$systemPrompt\n\n$userMessage',
            'stream': false,
          }),
        )
        .timeout(const Duration(seconds: 120));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['response'] as String;
    }
    throw Exception('Ollama error: ${response.statusCode} ${response.body}');
  }

  /// Check if Ollama is running locally
  static Future<bool> isAvailable() async {
    try {
      final response = await http
          .get(Uri.parse('http://localhost:11434/api/tags'))
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

// ─── Provider detector — auto picks the best available ───────────────────────

class AiProviderDetector {
  /// Detects which provider to use based on available env vars or user input.
  /// Priority: Claude > OpenAI > Gemini > Groq > Ollama (free) > none
  static Future<AiProvider?> detect() async {
    // 1. Check env vars first — silent, no prompt needed
    final claudeKey = Platform.environment['CLAUDE_API_KEY'] ?? '';
    if (claudeKey.isNotEmpty) {
      print('🧠 Using Claude Opus (from CLAUDE_API_KEY)');
      return ClaudeProvider(claudeKey);
    }

    final openaiKey = Platform.environment['OPENAI_API_KEY'] ?? '';
    if (openaiKey.isNotEmpty) {
      print('🧠 Using GPT-4o (from OPENAI_API_KEY)');
      return OpenAiProvider(openaiKey);
    }

    final geminiKey = Platform.environment['GEMINI_API_KEY'] ?? '';
    if (geminiKey.isNotEmpty) {
      print('🧠 Using Gemini 1.5 Pro (from GEMINI_API_KEY)');
      return GeminiProvider(geminiKey);
    }

    final groqKey = Platform.environment['GROQ_API_KEY'] ?? '';
    if (groqKey.isNotEmpty) {
      print('🧠 Using Llama 3.3 on Groq (from GROQ_API_KEY)');
      return GroqProvider(groqKey);
    }

    // 2. No env var — ask user interactively
    print('');
    print('┌─────────────────────────────────────────────┐');
    print('│  No AI key found. Choose an option:         │');
    print('│                                             │');
    print('│  1. Claude  (CLAUDE_API_KEY)                │');
    print('│  2. OpenAI  (OPENAI_API_KEY)                │');
    print('│  3. Gemini  (GEMINI_API_KEY)                │');
    print('│  4. Groq    (GROQ_API_KEY) — fast & cheap   │');
    print('│  5. Ollama  — free, runs locally            │');
    print('│  6. Skip    — crawler only, no AI           │');
    print('└─────────────────────────────────────────────┘');
    stdout.write('\nYour choice (1-6): ');

    final choice = stdin.readLineSync()?.trim() ?? '6';

    switch (choice) {
      case '1':
        stdout.write('Enter Claude API key: ');
        final key = stdin.readLineSync()?.trim() ?? '';
        if (key.isNotEmpty) return ClaudeProvider(key);
        break;

      case '2':
        stdout.write('Enter OpenAI API key: ');
        final key = stdin.readLineSync()?.trim() ?? '';
        if (key.isNotEmpty) return OpenAiProvider(key);
        break;

      case '3':
        stdout.write('Enter Gemini API key: ');
        final key = stdin.readLineSync()?.trim() ?? '';
        if (key.isNotEmpty) return GeminiProvider(key);
        break;

      case '4':
        stdout.write('Enter Groq API key: ');
        final key = stdin.readLineSync()?.trim() ?? '';
        if (key.isNotEmpty) return GroqProvider(key);
        break;

      case '5':
        print('🔍 Checking if Ollama is running...');
        final available = await OllamaProvider.isAvailable();
        if (available) {
          print('✅ Ollama found — using Llama 3 (free, local)');
          return OllamaProvider();
        } else {
          print('❌ Ollama not running.');
          print('   Install: https://ollama.com');
          print('   Then run: ollama pull llama3');
          print('   Then run: ollama serve');
          print('   Running crawler-only mode instead.\n');
        }
        break;

      case '6':
      default:
        break;
    }

    return null; // crawler-only mode
  }
}

// ─── Main AI client — uses whatever provider was detected ─────────────────────

class AiClient {
  final AiProvider provider;
  final String projectPath;

  AiClient({required this.provider, required this.projectPath});

  Future<String> diagnose({
    required List<Map<String, dynamic>> issues,
    required int totalWidgets,
    required int maxDepth,
    required Map<String, int> widgetCounts,
    required String screenName,
    String perfGrade = 'N/A',
    double avgBuildMs = 0,
    double jankRate = 0,
    int jankyFrames = 0,
    int totalFrames = 0,
    String interactionReport = '',
  }) async {
    print('\n🤖 Diagnosing with ${provider.name}...');

    final assembler = PromptAssembler(projectPath: projectPath);
    final systemPrompt = await assembler.assemble();

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
TOP WIDGETS: $widgetSummary

PERFORMANCE DATA:
- Performance grade : $perfGrade
- Avg build time    : ${avgBuildMs.toStringAsFixed(2)}ms (budget: 16ms)
- Jank rate         : ${jankRate.toStringAsFixed(1)}%
- Janky frames      : $jankyFrames / $totalFrames total frames

${interactionReport.isNotEmpty ? interactionReport : ''}

DETECTED ISSUES:
$issueText

Give me your full diagnosis with health score and prioritised prescriptions.
''';

    return await provider.complete(systemPrompt, userMessage);
  }
}
