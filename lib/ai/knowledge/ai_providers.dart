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
  // llama-3.1-8b-instant: 30 000 TPM on free tier (vs 12 000 for 70B).
  String get name => 'Llama 3.1 8B Instant (Groq — fast & free)';

  @override
  Future<String> complete(String systemPrompt, String userMessage) async {
    final response = await http.post(
      Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': 'llama-3.1-8b-instant',
        'max_tokens': 1024,
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

    final screenContext = _buildScreenContext(
      screenName: screenName,
      totalWidgets: totalWidgets,
      maxDepth: maxDepth,
      widgetCounts: widgetCounts,
      perfGrade: perfGrade,
      avgBuildMs: avgBuildMs,
      jankRate: jankRate,
      jankyFrames: jankyFrames,
      totalFrames: totalFrames,
      interactionReport: interactionReport,
    );

    final issueText = _formatIssues(issues);
    final userMessage = '''
Diagnose this Flutter screen and provide your full medical report.

$screenContext

DETECTED ISSUES:
$issueText

Give me your full diagnosis with health score and prioritised prescriptions.
''';

    try {
      return await _completeWithRetry(systemPrompt, userMessage);
    } catch (e) {
      if (_isTokenLimitError(e)) {
        return await _diagnoseChunked(
          issues: issues,
          screenContext: screenContext,
        );
      }
      rethrow;
    }
  }

  /// Splits issues into chunks of 40, runs each batch with a compact system
  /// prompt asking for a tight bullet list, then does one final summarization
  /// call — also with the compact prompt so the total fits in tight TPM limits.
  Future<String> _diagnoseChunked({
    required List<Map<String, dynamic>> issues,
    required String screenContext,
  }) async {
    const chunkSize = 40;
    final chunks = <List<Map<String, dynamic>>>[];
    for (var i = 0; i < issues.length; i += chunkSize) {
      final end = (i + chunkSize).clamp(0, issues.length);
      chunks.add(issues.sublist(i, end));
    }

    print(
        '  ⚠️  Request too large — pooling ${chunks.length} batches of ≤$chunkSize issues...');

    // Use compact system prompt for all calls in the chunked path.
    final assembler = PromptAssembler(projectPath: projectPath);
    final compactSystem = await assembler.assemble(compact: true);

    final batchFindings = <String>[];
    for (var i = 0; i < chunks.length; i++) {
      print('  📦 Batch ${i + 1}/${chunks.length} (${chunks[i].length} issues)...');
      // Ask for a tiny bullet list — max 3 items, one line each.
      final batchMessage =
          'Batch ${i + 1}/${chunks.length}. List up to 3 CRITICAL issues only.\n'
          'Format each as: `[TYPE] file:line — reason (≤8 words)`\n\n'
          '${_formatIssues(chunks[i])}';
      try {
        final result = await _completeWithRetry(compactSystem, batchMessage);
        batchFindings.add(result.trim());
      } catch (e) {
        batchFindings.add('⚠️ Batch ${i + 1} skipped: $e');
      }
    }

    // Final summarization — compact system prompt + compact batch findings.
    print('  🔄 Summarising ${chunks.length} batch results into unified report...');
    final summaryMessage =
        'Produce the full medical report from these batch findings.\n\n'
        '$screenContext\n\n'
        'CRITICAL FINDINGS ACROSS ${chunks.length} BATCHES '
        '(${issues.length} total issues):\n'
        '${batchFindings.join('\n')}\n\n'
        'Give health score and prioritised prescriptions.';

    return await _completeWithRetry(compactSystem, summaryMessage);
  }

  String _buildScreenContext({
    required String screenName,
    required int totalWidgets,
    required int maxDepth,
    required Map<String, int> widgetCounts,
    required String perfGrade,
    required double avgBuildMs,
    required double jankRate,
    required int jankyFrames,
    required int totalFrames,
    required String interactionReport,
  }) {
    final topWidgets = widgetCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final widgetSummary =
        topWidgets.take(10).map((e) => '${e.key}: ${e.value}x').join(', ');

    return '''
SCREEN: $screenName
TOTAL WIDGETS: $totalWidgets
MAX NESTING DEPTH: $maxDepth
TOP WIDGETS: $widgetSummary

PERFORMANCE DATA:
- Performance grade : $perfGrade
- Avg build time    : ${avgBuildMs.toStringAsFixed(2)}ms (budget: 16ms)
- Jank rate         : ${jankRate.toStringAsFixed(1)}%
- Janky frames      : $jankyFrames / $totalFrames total frames

${interactionReport.isNotEmpty ? interactionReport : ''}''';
  }

  String _formatIssues(List<Map<String, dynamic>> issues) {
    return issues.map((i) {
      return '[${(i['severity'] as String).toUpperCase()}] '
          '${i['type']} in ${i['file'] ?? 'unknown'}:${i['line'] ?? '?'} — '
          '${i['message']}';
    }).join('\n');
  }

  /// Calls [provider.complete] and retries once on 429 rate-limit responses,
  /// waiting the number of seconds the API tells us to wait.
  Future<String> _completeWithRetry(
      String systemPrompt, String userMessage) async {
    try {
      return await provider.complete(systemPrompt, userMessage);
    } catch (e) {
      final wait = _parseRetryAfter(e);
      if (wait != null) {
        final secs = wait + 2; // small buffer
        print('  ⏳ Rate limited — waiting ${secs}s before retry...');
        await Future.delayed(Duration(seconds: secs));
        return await provider.complete(systemPrompt, userMessage);
      }
      rethrow;
    }
  }

  /// Parses "Please try again in Xs" from a Groq / OpenAI 429 message.
  /// Returns seconds to wait, or null if not a rate-limit error.
  int? _parseRetryAfter(Object e) {
    final msg = e.toString();
    if (!msg.contains('429') && !msg.contains('rate_limit_exceeded')) {
      return null;
    }
    // "Please try again in 19.91s" or "try again in 2m30s"
    final secMatch = RegExp(r'try again in (\d+(?:\.\d+)?)s').firstMatch(msg);
    if (secMatch != null) {
      return (double.parse(secMatch.group(1)!)).ceil();
    }
    final minMatch =
        RegExp(r'try again in (\d+)m(\d+)s').firstMatch(msg);
    if (minMatch != null) {
      return int.parse(minMatch.group(1)!) * 60 +
          int.parse(minMatch.group(2)!);
    }
    return 30; // fallback: wait 30s if we can't parse
  }

  bool _isTokenLimitError(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('413') ||
        msg.contains('request too large') ||
        msg.contains('context_length_exceeded') ||
        msg.contains('max_tokens');
  }
}
