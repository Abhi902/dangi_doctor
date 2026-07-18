import 'package:test/test.dart';

import 'package:dangi_doctor/ai/knowledge/ai_providers.dart';

void main() {
  group('ModelConfig defaults', () {
    // These assert the FALLBACK values — the test environment must not set
    // DANGI_OPENAI_MODEL / DANGI_GROQ_MODEL / DANGI_OLLAMA_MODEL.
    test('OpenAI default is a current model (gpt-4o retired as default)', () {
      expect(ModelConfig.openai, 'gpt-5.5');
    });

    test('Groq default follows the llama-3.1-8b-instant deprecation', () {
      // Groq deprecated llama-3.1-8b-instant on 2026-06-17 and recommends
      // openai/gpt-oss-20b as the migration target.
      expect(ModelConfig.groq, 'openai/gpt-oss-20b');
    });

    test('Ollama default is a current local model', () {
      expect(ModelConfig.ollama, 'gpt-oss:20b');
    });
  });

  group('AiHttpException classification', () {
    test('429 is a rate limit and retryable', () {
      final e = AiHttpException(
          provider: 'groq', statusCode: 429, body: 'rate_limit_exceeded');
      expect(e.isRateLimit, isTrue);
      expect(e.isRetryable, isTrue);
      expect(e.isTokenLimit, isFalse);
    });

    test('500/529 are retryable server errors, not rate limits', () {
      for (final code in [500, 503, 529]) {
        final e = AiHttpException(
            provider: 'claude', statusCode: code, body: 'overloaded_error');
        expect(e.isRetryable, isTrue, reason: '$code should be retryable');
        expect(e.isRateLimit, isFalse);
      }
    });

    test('413 and context-overflow messages are token limits', () {
      expect(
          AiHttpException(provider: 'groq', statusCode: 413, body: '')
              .isTokenLimit,
          isTrue);
      expect(
          AiHttpException(
                  provider: 'claude',
                  statusCode: 400,
                  body: '{"error": {"message": "prompt is too long"}}')
              .isTokenLimit,
          isTrue);
      expect(
          AiHttpException(
                  provider: 'openai',
                  statusCode: 400,
                  body: 'context_length_exceeded')
              .isTokenLimit,
          isTrue);
    });

    test('a 400 validation error mentioning max_tokens is NOT a token limit',
        () {
      final e = AiHttpException(
          provider: 'openai',
          statusCode: 400,
          body: '{"error": {"message": "max_tokens: field required"}}');
      expect(e.isTokenLimit, isFalse);
    });
  });

  group('parseRetryAfterSeconds', () {
    test('prefers the Retry-After header when present', () {
      expect(parseRetryAfterSeconds(header: '30', body: ''), 30);
    });

    test('parses Groq-style "try again in Xs" prose', () {
      expect(
          parseRetryAfterSeconds(
              header: null, body: 'Please try again in 19.91s'),
          20);
      expect(parseRetryAfterSeconds(header: null, body: 'try again in 2m30s'),
          150);
    });

    test('returns null when nothing parseable', () {
      expect(parseRetryAfterSeconds(header: null, body: 'nope'), isNull);
    });
  });

  group('computeRetryDelaySeconds', () {
    test('honours the server Retry-After up to the 60s cap (+2s cushion)', () {
      expect(
          computeRetryDelaySeconds(
              attempt: 1, retryAfterSeconds: 30, jitter: 0),
          32);
      expect(
          computeRetryDelaySeconds(
              attempt: 1, retryAfterSeconds: 60, jitter: 0),
          62);
    });

    test('returns null beyond the cap so the caller fails the screen', () {
      expect(
          computeRetryDelaySeconds(
              attempt: 1, retryAfterSeconds: 61, jitter: 0),
          isNull);
      expect(
          computeRetryDelaySeconds(
              attempt: 2, retryAfterSeconds: 3600, jitter: 2),
          isNull);
    });

    test('falls back to exponential backoff with jitter when no Retry-After',
        () {
      // attempt 1: 2^1*2 + jitter + 2 = 6;  attempt 2: 2^2*2 + jitter + 2 = 11
      expect(
          computeRetryDelaySeconds(
              attempt: 1, retryAfterSeconds: null, jitter: 0),
          6);
      expect(
          computeRetryDelaySeconds(
              attempt: 2, retryAfterSeconds: null, jitter: 1),
          11);
    });
  });

  group('extractClaudeText', () {
    test('returns the first text block', () {
      final text = extractClaudeText({
        'content': [
          {'type': 'text', 'text': 'diagnosis here'}
        ],
        'stop_reason': 'end_turn',
      });
      expect(text, 'diagnosis here');
    });

    test('skips non-text leading blocks (e.g. thinking)', () {
      final text = extractClaudeText({
        'content': [
          {'type': 'thinking', 'thinking': ''},
          {'type': 'text', 'text': 'after thinking'},
        ],
        'stop_reason': 'end_turn',
      });
      expect(text, 'after thinking');
    });

    test('joins ALL text blocks, not just the first', () {
      final text = extractClaudeText({
        'content': [
          {'type': 'text', 'text': 'part one'},
          {'type': 'tool_use', 'id': 'tu_1', 'name': 'x', 'input': {}},
          {'type': 'text', 'text': 'part two'},
        ],
        'stop_reason': 'end_turn',
      });
      expect(text, 'part one\npart two');
    });

    test('flags truncation when stop_reason is max_tokens', () {
      final text = extractClaudeText({
        'content': [
          {'type': 'text', 'text': 'partial'}
        ],
        'stop_reason': 'max_tokens',
      });
      expect(text, contains('partial'));
      expect(text.toLowerCase(), contains('truncated'));
    });

    test('throws a clear error on refusal / empty content', () {
      expect(
          () => extractClaudeText({'content': [], 'stop_reason': 'refusal'}),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('refus'))));
    });
  });

  group('extractOpenAiText', () {
    test('returns message content and flags length truncation', () {
      final text = extractOpenAiText({
        'choices': [
          {
            'message': {'content': 'report'},
            'finish_reason': 'length',
          }
        ]
      });
      expect(text, contains('report'));
      expect(text.toLowerCase(), contains('truncated'));
    });

    test('throws a clear error on null content or empty choices', () {
      expect(() => extractOpenAiText({'choices': []}),
          throwsA(isA<FormatException>()));
      expect(
          () => extractOpenAiText({
                'choices': [
                  {
                    'message': {'content': null},
                    'finish_reason': 'content_filter'
                  }
                ]
              }),
          throwsA(isA<FormatException>()));
    });
  });

  group('buildOpenAiChatBody', () {
    test('sends max_completion_tokens, never the legacy max_tokens', () {
      final body = buildOpenAiChatBody(
        model: 'gpt-5.5',
        maxTokens: 4096,
        systemPrompt: 'sys prompt',
        userMessage: 'user msg',
      );
      expect(body['max_completion_tokens'], 4096);
      expect(body.containsKey('max_tokens'), isFalse,
          reason: 'current OpenAI models reject max_tokens');
      expect(body['model'], 'gpt-5.5');
      expect(body['messages'], [
        {'role': 'system', 'content': 'sys prompt'},
        {'role': 'user', 'content': 'user msg'},
      ]);
    });
  });

  group('extractGeminiText', () {
    test('returns candidate text', () {
      final text = extractGeminiText({
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': 'gemini report'}
              ]
            },
            'finishReason': 'STOP',
          }
        ]
      });
      expect(text, 'gemini report');
    });

    test('concatenates ALL text parts and skips thought parts', () {
      final text = extractGeminiText({
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': 'internal reasoning...', 'thought': true},
                {'text': 'first half '},
                {'text': 'second half'},
              ]
            },
            'finishReason': 'STOP',
          }
        ]
      });
      expect(text, 'first half second half');
    });

    test('surfaces partial text with a truncation note on MAX_TOKENS', () {
      final text = extractGeminiText({
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': 'thinking that ate the budget', 'thought': true},
                {'text': 'partial answer'},
              ]
            },
            'finishReason': 'MAX_TOKENS',
          }
        ]
      });
      expect(text, contains('partial answer'));
      expect(text, isNot(contains('thinking that ate')));
      expect(text.toLowerCase(), contains('truncated'));
    });

    test('throws a clear error when candidates are empty (safety block)', () {
      expect(
          () => extractGeminiText({
                'candidates': [],
                'promptFeedback': {'blockReason': 'SAFETY'}
              }),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('SAFETY'))));
    });
  });

  group('buildGeminiGenerationConfig', () {
    test('budgets output tokens ON TOP of an explicit thinking budget', () {
      final config = buildGeminiGenerationConfig(maxTokens: 4096);
      final thinking = config['thinkingConfig'] as Map;
      final budget = thinking['thinkingBudget'] as int;
      expect(budget, greaterThanOrEqualTo(128),
          reason: 'gemini-2.5-pro rejects budgets below 128');
      expect(config['maxOutputTokens'], 4096 + budget,
          reason: 'reasoning tokens must never consume the answer budget');
    });
  });
}
