import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'realtime_stream_core.dart';

class RealtimeStreamService {
  RealtimeStreamService._();

  static http.Client? _client;
  static StreamSubscription<String>? _subscription;
  static final RealtimeStreamCore _core = RealtimeStreamCore(
    connect: _connect,
    close: _close,
  );

  static bool get isConnected => _core.isConnected;

  static void start() => _core.start();

  static void stop() => _core.stop();

  static Future<void> _connect(Uri uri) async {
    _close();
    final client = http.Client();
    _client = client;
    final request = http.Request('GET', uri)
      ..headers['Accept'] = 'text/event-stream'
      ..headers['Cache-Control'] = 'no-cache';
    final response = await client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('SSE stream failed with status ${response.statusCode}');
    }

    _core.handleConnected();
    final parser = _SseParser(_core.handleSseMessage);
    _subscription = response.stream
        .transform(utf8.decoder)
        .listen(
          parser.add,
          onError: (_) => _core.handleDisconnected(),
          onDone: () => _core.handleDisconnected(),
          cancelOnError: true,
        );
  }

  static void _close() {
    _subscription?.cancel();
    _subscription = null;
    _client?.close();
    _client = null;
  }
}

class _SseParser {
  _SseParser(this.onEvent);

  final void Function(String event, String data) onEvent;
  final StringBuffer _buffer = StringBuffer();

  void add(String chunk) {
    _buffer.write(chunk);
    var raw = _buffer.toString();
    int separatorIndex;
    while ((separatorIndex = raw.indexOf('\n\n')) != -1) {
      final block = raw.substring(0, separatorIndex);
      raw = raw.substring(separatorIndex + 2);
      _parseBlock(block);
    }

    _buffer
      ..clear()
      ..write(raw);
  }

  void _parseBlock(String block) {
    var event = 'message';
    final dataLines = <String>[];
    for (final line in block.split('\n')) {
      if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trimLeft());
      }
    }

    if (dataLines.isNotEmpty) {
      onEvent(event, dataLines.join('\n'));
    }
  }
}
