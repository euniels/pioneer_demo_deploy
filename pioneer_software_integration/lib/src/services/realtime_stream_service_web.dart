// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

import 'realtime_stream_core.dart';

class RealtimeStreamService {
  RealtimeStreamService._();

  static html.EventSource? _source;
  static final RealtimeStreamCore _core = RealtimeStreamCore(
    connect: _connect,
    close: _close,
  );

  static bool get isConnected => _core.isConnected;

  static void start() => _core.start();

  static void stop() => _core.stop();

  static Future<void> _connect(Uri uri) async {
    _source?.close();
    final source = html.EventSource(uri.toString());
    _source = source;

    source.onOpen.first.then((_) => _core.handleConnected());
    source.addEventListener('live', (event) {
      if (event is html.MessageEvent) {
        _core.handleSseMessage('live', event.data?.toString() ?? '');
      }
    });
    source.addEventListener('notification', (event) {
      if (event is html.MessageEvent) {
        _core.handleSseMessage('notification', event.data?.toString() ?? '');
      }
    });
    source.addEventListener('writeback', (event) {
      if (event is html.MessageEvent) {
        _core.handleSseMessage('writeback', event.data?.toString() ?? '');
      }
    });
    source.addEventListener('heartbeat', (event) {
      if (event is html.MessageEvent) {
        _core.handleSseMessage('heartbeat', event.data?.toString() ?? '');
      }
    });
    source.onError.first.then((_) {
      source.close();
      if (identical(_source, source)) {
        _source = null;
      }
      _core.handleDisconnected();
    });
  }

  static void _close() {
    _source?.close();
    _source = null;
  }
}
