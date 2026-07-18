import 'package:test/test.dart';

import 'package:dangi_doctor/ai/knowledge/ai_providers.dart';

void main() {
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
}
