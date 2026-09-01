import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_manager/services/nl_query/local_llm/cloud_llm_client.dart';
import 'package:money_manager/services/nl_query/local_llm/llm_engine.dart';

/// Same fake-HttpServer approach as llama_server_client_test.dart -
/// CloudLlmClient talks plain HTTP/JSON and has no idea whether the other
/// end is a real cloud provider or not, so a fake local server standing in
/// for one lets every bit of this class's own logic (request shape, auth
/// header, response parsing) be verified without any real API key/network
/// access. Whether a genuine provider actually behaves the way these fakes
/// assume (an OpenAI-compatible `/v1/chat/completions` shape) still needs
/// real hands-on verification against a real endpoint.
void main() {
  HttpServer? fakeServer;

  tearDown(() async {
    await fakeServer?.close(force: true);
  });

  Future<String> startFakeServer(
      Future<void> Function(HttpRequest) handler) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fakeServer = server;
    server.listen((request) async {
      await handler(request);
    });
    return 'http://127.0.0.1:${server.port}/v1';
  }

  test('CloudLlmClient implements LlmEngine', () {
    final client = CloudLlmClient(baseUrl: 'x', apiKey: '', model: 'm');
    expect(client, isA<LlmEngine>());
    client.close();
  });

  group('ask', () {
    test('sends a JSON-mode chat request with the auth header and returns '
        'the message content', () async {
      Map<String, dynamic>? capturedBody;
      String? capturedAuth;
      final baseUrl = await startFakeServer((request) async {
        capturedAuth = request.headers.value('Authorization');
        final body = await utf8.decoder.bind(request).join();
        capturedBody = jsonDecode(body) as Map<String, dynamic>;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {'content': '{"kind":"balance"}'}
            }
          ]
        }));
        await request.response.close();
      });
      final client =
          CloudLlmClient(baseUrl: baseUrl, apiKey: 'secret-key', model: 'gpt-test');
      final result = await client.ask('quel est mon solde ?');
      expect(result.text, '{"kind":"balance"}');
      expect(capturedAuth, 'Bearer secret-key');
      expect(capturedBody!['model'], 'gpt-test');
      expect(capturedBody!['response_format'], {'type': 'json_object'});
      final messages = capturedBody!['messages'] as List;
      expect(messages[0]['role'], 'system');
      expect(messages[1]['role'], 'user');
      expect(messages[1]['content'], 'quel est mon solde ?');
      client.close();
    });

    test('no Authorization header at all when apiKey is empty', () async {
      String? capturedAuth;
      final baseUrl = await startFakeServer((request) async {
        capturedAuth = request.headers.value('Authorization');
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {'content': 'ok'}
            }
          ]
        }));
        await request.response.close();
      });
      final client = CloudLlmClient(baseUrl: baseUrl, apiKey: '', model: 'm');
      await client.ask('...');
      expect(capturedAuth, isNull);
      client.close();
    });

    test('always requests reasoning exclusion, for reasoning-capable models '
        'on providers that support it (e.g. OpenRouter)', () async {
      Map<String, dynamic>? capturedBody;
      final baseUrl = await startFakeServer((request) async {
        final body = await utf8.decoder.bind(request).join();
        capturedBody = jsonDecode(body) as Map<String, dynamic>;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {'content': 'ok'}
            }
          ]
        }));
        await request.response.close();
      });
      final client = CloudLlmClient(baseUrl: baseUrl, apiKey: 'x', model: 'm');
      await client.ask('...');
      expect(capturedBody!['reasoning'], {'exclude': true});
      client.close();
    });

    test(
        'strips a well-formed <think>...</think> block before it reaches the '
        'caller - regression test for the 2026-09-01 user report of a free '
        "reasoning model's raw internal narration (in English, revealing "
        'the app\'s own system prompt) showing up as the actual chat answer',
        () async {
      final baseUrl = await startFakeServer((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {
                'content':
                    '<think>Okay, the user is asking about their balance...</think>'
                    'Ton solde est de 1 234,56 €.'
              }
            }
          ]
        }));
        await request.response.close();
      });
      final client = CloudLlmClient(baseUrl: baseUrl, apiKey: 'x', model: 'm');
      final result = await client.ask('...');
      expect(result.text, 'Ton solde est de 1 234,56 €.');
      client.close();
    });

    test(
        'an unterminated <think> block (cut off mid-reasoning by max_tokens) '
        'is left as-is rather than guessed at', () async {
      final baseUrl = await startFakeServer((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {'content': '<think>Okay, the user is asking...'}
            }
          ]
        }));
        await request.response.close();
      });
      final client = CloudLlmClient(baseUrl: baseUrl, apiKey: 'x', model: 'm');
      final result = await client.ask('...');
      expect(result.text, '<think>Okay, the user is asking...');
      client.close();
    });

    test('throws on a non-200 response', () async {
      final baseUrl = await startFakeServer((request) async {
        request.response.statusCode = 401;
        await request.response.close();
      });
      final client = CloudLlmClient(baseUrl: baseUrl, apiKey: 'x', model: 'm');
      await expectLater(client.ask('...'), throwsStateError);
      client.close();
    });

    test('missing/empty choices returns an empty string, not a crash', () async {
      final baseUrl = await startFakeServer((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'choices': []}));
        await request.response.close();
      });
      final client = CloudLlmClient(baseUrl: baseUrl, apiKey: 'x', model: 'm');
      expect((await client.ask('...')).text, '');
      client.close();
    });

    test('computes tokensPerSecond from usage.completion_tokens and elapsed time',
        () async {
      final baseUrl = await startFakeServer((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {'content': 'ok'}
            }
          ],
          'usage': {'completion_tokens': 10},
        }));
        await request.response.close();
      });
      final client = CloudLlmClient(baseUrl: baseUrl, apiKey: 'x', model: 'm');
      final result = await client.ask('...');
      expect(result.tokensPerSecond, isNotNull);
      expect(result.tokensPerSecond!, greaterThan(0));
      client.close();
    });

    test('tokensPerSecond is null when usage is absent - never estimated', () async {
      final baseUrl = await startFakeServer((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {'content': 'ok'}
            }
          ]
        }));
        await request.response.close();
      });
      final client = CloudLlmClient(baseUrl: baseUrl, apiKey: 'x', model: 'm');
      final result = await client.ask('...');
      expect(result.tokensPerSecond, isNull);
      client.close();
    });
  });

  group('askFreeform', () {
    test('no response_format field, plain conversational system prompt', () async {
      Map<String, dynamic>? capturedBody;
      final baseUrl = await startFakeServer((request) async {
        final body = await utf8.decoder.bind(request).join();
        capturedBody = jsonDecode(body) as Map<String, dynamic>;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {'content': 'Je suis un assistant.'}
            }
          ]
        }));
        await request.response.close();
      });
      final client = CloudLlmClient(baseUrl: baseUrl, apiKey: 'x', model: 'm');
      final result = await client.askFreeform('qui es-tu ?');
      expect(result.text, 'Je suis un assistant.');
      expect(capturedBody!.containsKey('response_format'), isFalse);
      final messages = capturedBody!['messages'] as List;
      expect(messages[1]['content'], 'qui es-tu ?');
      client.close();
    });
  });

  group('askWithSystemPrompt / askFreeformWithSystemPrompt', () {
    test('askWithSystemPrompt uses the caller-supplied system prompt, JSON mode on', () async {
      Map<String, dynamic>? capturedBody;
      final baseUrl = await startFakeServer((request) async {
        final body = await utf8.decoder.bind(request).join();
        capturedBody = jsonDecode(body) as Map<String, dynamic>;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {'content': '{"sql":"SELECT 1"}'}
            }
          ]
        }));
        await request.response.close();
      });
      final client = CloudLlmClient(baseUrl: baseUrl, apiKey: 'x', model: 'm');
      final result =
          await client.askWithSystemPrompt('Un prompt sur mesure.', 'combien ?');
      expect(result.text, '{"sql":"SELECT 1"}');
      expect(capturedBody!['response_format'], {'type': 'json_object'});
      final messages = capturedBody!['messages'] as List;
      expect(messages[0]['content'], 'Un prompt sur mesure.');
      expect(messages[1]['content'], 'combien ?');
      client.close();
    });

    test('askFreeformWithSystemPrompt uses the caller-supplied system prompt, no JSON mode', () async {
      Map<String, dynamic>? capturedBody;
      final baseUrl = await startFakeServer((request) async {
        final body = await utf8.decoder.bind(request).join();
        capturedBody = jsonDecode(body) as Map<String, dynamic>;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {'content': 'Tu as dépensé 42 €.'}
            }
          ]
        }));
        await request.response.close();
      });
      final client = CloudLlmClient(baseUrl: baseUrl, apiKey: 'x', model: 'm');
      final result = await client.askFreeformWithSystemPrompt(
          'Formule la réponse.', 'résultat: 42');
      expect(result.text, 'Tu as dépensé 42 €.');
      expect(capturedBody!.containsKey('response_format'), isFalse);
      client.close();
    });
  });

  group('healthCheck', () {
    test('true on a 200 response', () async {
      final baseUrl = await startFakeServer((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {'content': 'pong'}
            }
          ]
        }));
        await request.response.close();
      });
      final client = CloudLlmClient(baseUrl: baseUrl, apiKey: 'x', model: 'm');
      expect(await client.healthCheck(), isTrue);
      client.close();
    });

    test('false on a non-200 response, never throws', () async {
      final baseUrl = await startFakeServer((request) async {
        request.response.statusCode = 403;
        await request.response.close();
      });
      final client = CloudLlmClient(baseUrl: baseUrl, apiKey: 'wrong', model: 'm');
      expect(await client.healthCheck(), isFalse);
      client.close();
    });

    test('false when nothing is listening, never throws', () async {
      final client = CloudLlmClient(
          baseUrl: 'http://127.0.0.1:59999/v1', apiKey: 'x', model: 'm');
      expect(await client.healthCheck(), isFalse);
      client.close();
    });
  });

  group('fetchAvailableModels', () {
    test('GETs /models with the auth header and returns sorted ids', () async {
      String? capturedPath;
      String? capturedAuth;
      final baseUrl = await startFakeServer((request) async {
        capturedPath = request.uri.path;
        capturedAuth = request.headers.value('Authorization');
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'data': [
            {'id': 'openai/gpt-4o-mini'},
            {'id': 'anthropic/claude-3-haiku'},
            {'id': 'mistralai/mistral-large'},
          ]
        }));
        await request.response.close();
      });
      final client =
          CloudLlmClient(baseUrl: baseUrl, apiKey: 'secret-key', model: '');
      final models = await client.fetchAvailableModels();
      expect(capturedPath, '/v1/models');
      expect(capturedAuth, 'Bearer secret-key');
      expect(models.map((m) => m.id), [
        'anthropic/claude-3-haiku',
        'mistralai/mistral-large',
        'openai/gpt-4o-mini',
      ]);
      expect(models.every((m) => !m.isFree), isTrue);
      client.close();
    });

    test('entries with no "id" field are skipped rather than crashing', () async {
      final baseUrl = await startFakeServer((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'data': [
            {'id': 'real-model'},
            {'object': 'model'},
          ]
        }));
        await request.response.close();
      });
      final client = CloudLlmClient(baseUrl: baseUrl, apiKey: 'x', model: '');
      final models = await client.fetchAvailableModels();
      expect(models.map((m) => m.id), ['real-model']);
      client.close();
    });

    test('a model whose pricing.prompt/completion are both "0" is marked free', () async {
      final baseUrl = await startFakeServer((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'data': [
            {
              'id': 'meta-llama/llama-3.1-8b-instruct:free',
              'pricing': {'prompt': '0', 'completion': '0'},
            },
            {
              'id': 'openai/gpt-4o',
              'pricing': {'prompt': '0.0000025', 'completion': '0.00001'},
            },
            {'id': 'no-pricing-info'},
          ]
        }));
        await request.response.close();
      });
      final client = CloudLlmClient(baseUrl: baseUrl, apiKey: 'x', model: '');
      final models = await client.fetchAvailableModels();
      final byId = {for (final m in models) m.id: m};
      expect(byId['meta-llama/llama-3.1-8b-instruct:free']!.isFree, isTrue);
      expect(byId['meta-llama/llama-3.1-8b-instruct:free']!.displayLabel,
          'meta-llama/llama-3.1-8b-instruct:free (gratuit)');
      expect(byId['openai/gpt-4o']!.isFree, isFalse);
      expect(byId['openai/gpt-4o']!.displayLabel, 'openai/gpt-4o');
      // No pricing data at all - never guessed as free.
      expect(byId['no-pricing-info']!.isFree, isFalse);
      client.close();
    });

    test('free models sort before paid ones, alphabetically within each group',
        () async {
      final baseUrl = await startFakeServer((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'data': [
            {
              'id': 'zzz/paid-model',
              'pricing': {'prompt': '0.001', 'completion': '0.002'},
            },
            {
              'id': 'bbb/free-model',
              'pricing': {'prompt': '0', 'completion': '0'},
            },
            {
              'id': 'aaa/paid-model',
              'pricing': {'prompt': '0.001', 'completion': '0.002'},
            },
            {
              'id': 'ccc/free-model',
              'pricing': {'prompt': '0', 'completion': '0'},
            },
          ]
        }));
        await request.response.close();
      });
      final client = CloudLlmClient(baseUrl: baseUrl, apiKey: 'x', model: '');
      final models = await client.fetchAvailableModels();
      expect(models.map((m) => m.id), [
        'bbb/free-model',
        'ccc/free-model',
        'aaa/paid-model',
        'zzz/paid-model',
      ]);
      client.close();
    });

    test('a missing "data" field returns an empty list, not a crash', () async {
      final baseUrl = await startFakeServer((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'object': 'list'}));
        await request.response.close();
      });
      final client = CloudLlmClient(baseUrl: baseUrl, apiKey: 'x', model: '');
      expect(await client.fetchAvailableModels(), isEmpty);
      client.close();
    });

    test('throws on a non-200 response', () async {
      final baseUrl = await startFakeServer((request) async {
        request.response.statusCode = 401;
        await request.response.close();
      });
      final client = CloudLlmClient(baseUrl: baseUrl, apiKey: 'wrong', model: '');
      await expectLater(client.fetchAvailableModels(), throwsStateError);
      client.close();
    });
  });
}
