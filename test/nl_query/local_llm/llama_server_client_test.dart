import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_manager/services/nl_query/local_llm/llama_server_client.dart';

/// LlamaServerClient talks plain HTTP and has no idea whether the other
/// end is a real llama-server.exe or not - so a fake local HttpServer
/// standing in for it lets every bit of *this* class's logic (health
/// polling, request/response shape) be verified for real, without needing
/// the actual binary (unavailable in this environment - see ROADMAP.md).
/// Whether a genuine llama-server.exe actually behaves the way these fakes
/// assume still needs real hands-on verification.
void main() {
  late HttpServer fakeServer;

  tearDown(() async {
    await fakeServer.close(force: true);
  });

  Future<int> startFakeServer(Future<void> Function(HttpRequest) handler) async {
    fakeServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fakeServer.listen((request) async {
      await handler(request);
    });
    return fakeServer.port;
  }

  group('waitUntilHealthy', () {
    test('returns as soon as /health answers 200', () async {
      final port = await startFakeServer((request) async {
        request.response.statusCode = 200;
        await request.response.close();
      });
      final client = LlamaServerClient(port);
      await client.waitUntilHealthy(timeout: const Duration(seconds: 5));
      client.close();
    });

    test('keeps polling until health flips from unavailable to ok', () async {
      var callCount = 0;
      final port = await startFakeServer((request) async {
        callCount++;
        request.response.statusCode = callCount < 3 ? 503 : 200;
        await request.response.close();
      });
      final client = LlamaServerClient(port);
      await client.waitUntilHealthy(timeout: const Duration(seconds: 5));
      expect(callCount, greaterThanOrEqualTo(3));
      client.close();
    });

    test('throws once the timeout elapses without a healthy response', () async {
      final port = await startFakeServer((request) async {
        request.response.statusCode = 503;
        await request.response.close();
      });
      final client = LlamaServerClient(port);
      await expectLater(
        client.waitUntilHealthy(timeout: const Duration(milliseconds: 1200)),
        throwsStateError,
      );
      client.close();
    });

    test('throws immediately once hasExited reports the process died, '
        'without waiting out the timeout', () async {
      final client = LlamaServerClient(59999); // nothing listening there
      final stopwatch = Stopwatch()..start();
      await expectLater(
        client.waitUntilHealthy(timeout: const Duration(seconds: 30), hasExited: () => true),
        throwsStateError,
      );
      stopwatch.stop();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      client.close();
    });
  });

  group('ask', () {
    test('sends the grammar-constrained completion request and returns the content field',
        () async {
      Map<String, dynamic>? capturedBody;
      final port = await startFakeServer((request) async {
        if (request.uri.path == '/completion') {
          final body = await utf8.decoder.bind(request).join();
          capturedBody = jsonDecode(body) as Map<String, dynamic>;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'content': '{"kind":"balance"}'}));
        }
        await request.response.close();
      });
      final client = LlamaServerClient(port);
      final result = await client.ask('quel est mon solde ?');
      expect(result, '{"kind":"balance"}');
      expect(capturedBody!['grammar'], isNotEmpty);
      expect(capturedBody!['prompt'], contains('quel est mon solde ?'));
      expect(capturedBody!['prompt'], contains('<|im_start|>system'));
      expect(capturedBody!['stop'], contains('<|im_end|>'));
      client.close();
    });

    test('throws on a non-200 response', () async {
      final port = await startFakeServer((request) async {
        request.response.statusCode = 500;
        await request.response.close();
      });
      final client = LlamaServerClient(port);
      await expectLater(client.ask('...'), throwsStateError);
      client.close();
    });

    test('an empty/missing content field returns an empty string, not a crash', () async {
      final port = await startFakeServer((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'stop': true}));
        await request.response.close();
      });
      final client = LlamaServerClient(port);
      expect(await client.ask('...'), '');
      client.close();
    });

    test('honors an explicit host instead of only the 127.0.0.1 default', () async {
      final port = await startFakeServer((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'content': 'ok'}));
        await request.response.close();
      });
      final client = LlamaServerClient(port, host: '127.0.0.1');
      expect(await client.ask('...'), 'ok');
      client.close();
    });
  });

  group('askFreeform', () {
    test('sends an ungrammared completion request and returns the content field', () async {
      Map<String, dynamic>? capturedBody;
      final port = await startFakeServer((request) async {
        if (request.uri.path == '/completion') {
          final body = await utf8.decoder.bind(request).join();
          capturedBody = jsonDecode(body) as Map<String, dynamic>;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'content': 'Je suis un assistant.'}));
        }
        await request.response.close();
      });
      final client = LlamaServerClient(port);
      final result = await client.askFreeform('qui es-tu ?');
      expect(result, 'Je suis un assistant.');
      expect(capturedBody!.containsKey('grammar'), isFalse);
      expect(capturedBody!['prompt'], contains('qui es-tu ?'));
      expect(capturedBody!['prompt'], contains('<|im_start|>system'));
      expect(capturedBody!['stop'], contains('<|im_end|>'));
      client.close();
    });

    test('throws on a non-200 response', () async {
      final port = await startFakeServer((request) async {
        request.response.statusCode = 500;
        await request.response.close();
      });
      final client = LlamaServerClient(port);
      await expectLater(client.askFreeform('...'), throwsStateError);
      client.close();
    });

    test('an empty/missing content field returns an empty string, not a crash', () async {
      final port = await startFakeServer((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'stop': true}));
        await request.response.close();
      });
      final client = LlamaServerClient(port);
      expect(await client.askFreeform('...'), '');
      client.close();
    });
  });

  group('askWithSystemPrompt', () {
    test('uses the caller-supplied system prompt instead of the fixed one, with grammar', () async {
      Map<String, dynamic>? capturedBody;
      final port = await startFakeServer((request) async {
        final body = await utf8.decoder.bind(request).join();
        capturedBody = jsonDecode(body) as Map<String, dynamic>;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'content': '{"sql":"SELECT 1"}'}));
        await request.response.close();
      });
      final client = LlamaServerClient(port);
      final result = await client.askWithSystemPrompt('Un prompt sur mesure.', 'combien ?');
      expect(result, '{"sql":"SELECT 1"}');
      expect(capturedBody!['grammar'], isNotEmpty);
      expect(capturedBody!['prompt'], contains('Un prompt sur mesure.'));
      expect(capturedBody!['prompt'], contains('combien ?'));
      expect(capturedBody!['n_predict'], 1024);
      client.close();
    });

    test('throws on a non-200 response', () async {
      final port = await startFakeServer((request) async {
        request.response.statusCode = 500;
        await request.response.close();
      });
      final client = LlamaServerClient(port);
      await expectLater(client.askWithSystemPrompt('x', 'y'), throwsStateError);
      client.close();
    });
  });

  group('askFreeformWithSystemPrompt', () {
    test('uses the caller-supplied system prompt, with no grammar', () async {
      Map<String, dynamic>? capturedBody;
      final port = await startFakeServer((request) async {
        final body = await utf8.decoder.bind(request).join();
        capturedBody = jsonDecode(body) as Map<String, dynamic>;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'content': 'Tu as dépensé 42 €.'}));
        await request.response.close();
      });
      final client = LlamaServerClient(port);
      final result = await client.askFreeformWithSystemPrompt('Formule la réponse.', 'résultat: 42');
      expect(result, 'Tu as dépensé 42 €.');
      expect(capturedBody!.containsKey('grammar'), isFalse);
      expect(capturedBody!['prompt'], contains('Formule la réponse.'));
      expect(capturedBody!['prompt'], contains('résultat: 42'));
      expect(capturedBody!['n_predict'], 4096);
      client.close();
    });
  });

  test('chatMlPromptWithSystem wraps the question in ChatML turns with the given system prompt', () {
    final prompt = chatMlPromptWithSystem('Mon prompt.', 'bonjour');
    expect(prompt, startsWith('<|im_start|>system\nMon prompt.<|im_end|>\n'));
    expect(prompt, contains('<|im_start|>user\nbonjour<|im_end|>'));
    expect(prompt, endsWith('<|im_start|>assistant\n'));
  });

  test('chatMlPrompt wraps the question in ChatML turns', () {
    final prompt = chatMlPrompt('bonjour');
    expect(prompt, startsWith('<|im_start|>system\n'));
    expect(prompt, contains('<|im_start|>user\nbonjour<|im_end|>'));
    expect(prompt, endsWith('<|im_start|>assistant\n'));
  });

  test('chatMlPrompt teaches the new adHoc schema, not the retired fixed kinds', () {
    final prompt = chatMlPrompt('bonjour');
    expect(prompt, contains('adHoc'));
    expect(prompt, contains('"metric"'));
    expect(prompt, contains('"groupBy"'));
    expect(prompt, contains('"transactionType"'));
    expect(prompt, contains('"recurringOnly"'));
    // Retired from the model's own vocabulary - decodeIntentJson no longer
    // accepts these as a "kind" value even if the model still produced one.
    expect(prompt, isNot(contains('expenseTotal')));
    expect(prompt, isNot(contains('topExpenses')));
    expect(prompt, isNot(contains('payeeSpend')));
    expect(prompt, isNot(contains('expenseByMonth')));
  });

  test('freeformChatMlPrompt wraps the question in ChatML turns with a plain '
      'conversational system prompt', () {
    final prompt = freeformChatMlPrompt('bonjour');
    expect(prompt, startsWith('<|im_start|>system\n'));
    expect(prompt, contains('<|im_start|>user\nbonjour<|im_end|>'));
    expect(prompt, endsWith('<|im_start|>assistant\n'));
    // Distinct from the intent-extraction prompt: no JSON-shape instructions.
    expect(prompt, isNot(contains('"kind"')));
  });
}
