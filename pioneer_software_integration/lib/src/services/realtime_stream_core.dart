import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'app_logger.dart';
import 'backend_api.dart';
import 'fleet_sync_service.dart';
import 'geotab_sync_status_service.dart';
import 'notification_service.dart';
import 'vehicles_store.dart';

typedef RealtimeConnect = Future<void> Function(Uri uri);
typedef RealtimeClose = void Function();

class RealtimeStreamCore {
  RealtimeStreamCore({
    required RealtimeConnect connect,
    required RealtimeClose close,
  }) : _connect = connect,
       _close = close;

  static const String _sseMode = String.fromEnvironment(
    'PIONEER_SSE_MODE',
    defaultValue: 'auto',
  );

  final RealtimeConnect _connect;
  final RealtimeClose _close;
  final ValueNotifier<bool> connected = ValueNotifier<bool>(false);
  Timer? _reconnectTimer;
  Timer? _fallbackLiveTimer;
  Timer? _fallbackNotificationTimer;
  bool _started = false;
  int _reconnectAttempts = 0;

  bool get isConnected => connected.value;

  void start() {
    if (_started) {
      return;
    }
    _started = true;
    if (!_shouldOpenSse) {
      if (kDebugMode) {
        AppLogger.info('Realtime SSE disabled; using polling fallback', {
          'mode': _sseMode,
        });
      }
      connected.value = false;
      _startFallbackPolling();
      return;
    }
    _open();
  }

  void stop() {
    _started = false;
    connected.value = false;
    _reconnectTimer?.cancel();
    _fallbackLiveTimer?.cancel();
    _fallbackNotificationTimer?.cancel();
    _close();
  }

  void handleConnected() {
    _reconnectAttempts = 0;
    connected.value = true;
    _fallbackLiveTimer?.cancel();
    _fallbackNotificationTimer?.cancel();
  }

  void handleDisconnected() {
    if (!_started) {
      return;
    }

    connected.value = false;
    _startFallbackPolling();
    _scheduleReconnect();
  }

  void handleSseMessage(String event, String data) {
    if (data.trim().isEmpty) {
      return;
    }

    try {
      final decoded = jsonDecode(data);
      if (decoded is! Map) {
        return;
      }
      final payload = decoded.map(
        (key, value) => MapEntry(key.toString(), value),
      );

      switch (event) {
        case 'live':
          applyFleetLivePayload(payload);
          break;
        case 'notification':
          final notification = payload['notification'];
          if (notification is Map) {
            NotificationService.instance.upsertFromJson(
              notification.map((key, value) => MapEntry(key.toString(), value)),
            );
          }
          break;
        case 'writeback':
          applyGeotabWriteBackEvent(payload);
          break;
        case 'heartbeat':
          break;
      }
    } catch (error) {
      if (kDebugMode) {
        AppLogger.warning('Realtime ignored malformed SSE event', {
          'event': event,
          'error': error.toString(),
        });
      }
    }
  }

  Future<void> _open() async {
    if (!_started) {
      return;
    }

    try {
      await _connect(_streamUri());
    } catch (error) {
      if (kDebugMode) {
        AppLogger.warning('Realtime SSE connection failed', {
          'error': error.toString(),
        });
      }
      handleDisconnected();
    }
  }

  Uri _streamUri() {
    final uri = Uri.parse('${BackendApiService.baseUrl}/fleet/stream');
    return uri.replace(
      queryParameters: {
        'channels': 'live,notification,writeback',
        if ((BackendApiService.accessTokenForRealtime ?? '').isNotEmpty)
          'token': BackendApiService.accessTokenForRealtime!,
      },
    );
  }

  bool get _shouldOpenSse {
    final mode = _sseMode.trim().toLowerCase();
    if (mode == 'enabled' || mode == 'on' || mode == 'true') {
      return true;
    }
    if (mode == 'disabled' || mode == 'off' || mode == 'false') {
      return false;
    }

    return kReleaseMode;
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    final delaySeconds = (2 * (1 << _reconnectAttempts)).clamp(2, 30);
    _reconnectAttempts = (_reconnectAttempts + 1).clamp(0, 4);
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), _open);
  }

  void _startFallbackPolling() {
    _fallbackLiveTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      refreshVehicleLocationsFromBackend().catchError((_) {
        return vehiclesNotifier.value;
      });
    });
    _fallbackNotificationTimer ??= Timer.periodic(const Duration(seconds: 60), (
      _,
    ) {
      refreshNotificationsFromBackend(forceRefresh: true).catchError((_) {
        return NotificationService.instance.notifications.value;
      });
    });
  }
}
