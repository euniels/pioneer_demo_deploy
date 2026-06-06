import 'dart:async';

import 'package:flutter/foundation.dart';

import 'backend_api.dart';

class AppLogger {
  AppLogger._();

  static const _sensitiveParts = <String>[
    'password',
    'token',
    'authorization',
    'api_key',
    'apikey',
    'secret',
    'vapid',
    'geotab',
    'firebase',
    'credential',
    'private_key',
  ];

  static void info(String message, [Map<String, Object?> context = const {}]) {
    if (!kReleaseMode) {
      debugPrint(_line('info', message, context));
    }
  }

  static void warning(
    String message, [
    Map<String, Object?> context = const {},
  ]) {
    if (!kReleaseMode) {
      debugPrint(_line('warning', message, context));
    }
  }

  static void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> context = const {},
    bool report = true,
  }) {
    final payload = <String, dynamic>{
      'level': 'error',
      'message': message,
      if (error != null) 'error': error.toString(),
      if (stackTrace != null) 'stackTrace': stackTrace.toString(),
      'context': _sanitize(context),
      'platform': defaultTargetPlatform.name,
      'releaseMode': kReleaseMode,
      'reportedAt': DateTime.now().toIso8601String(),
    };

    if (!kReleaseMode) {
      debugPrint(_line('error', message, payload));
    }

    if (report) {
      unawaited(BackendApiService.reportClientError(payload));
    }
  }

  static void reportFlutterError(FlutterErrorDetails details) {
    error(
      'Unhandled Flutter framework error',
      error: details.exception,
      stackTrace: details.stack,
      context: {
        'library': details.library,
        'context': details.context?.toDescription(),
      },
    );
  }

  static bool reportPlatformError(Object error, StackTrace stackTrace) {
    AppLogger.error(
      'Unhandled platform error',
      error: error,
      stackTrace: stackTrace,
    );
    return true;
  }

  static String _line(
    String level,
    String message,
    Map<String, Object?> context,
  ) {
    return '[pioneerpath][$level] $message ${_sanitize(context)}';
  }

  static Object? _sanitize(Object? value) {
    if (value is Map) {
      return value.map((key, item) {
        final keyString = key.toString().toLowerCase();
        final sensitive = _sensitiveParts.any(keyString.contains);
        return MapEntry(
          key.toString(),
          sensitive ? '[redacted]' : _sanitize(item),
        );
      });
    }
    if (value is Iterable) {
      return value.map(_sanitize).toList(growable: false);
    }
    if (value is String && value.length > 2000) {
      return value.substring(0, 2000);
    }
    return value;
  }
}
