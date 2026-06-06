import 'package:flutter/foundation.dart';

import 'backend_api.dart';
import 'push_notification_platform_stub.dart'
    if (dart.library.js_interop) 'push_notification_platform_web.dart';

class PushNotificationService {
  PushNotificationService._();

  static Future<void> initialize() async {
    if (kIsWeb) {
      await BackendApiService.getPushConfig().catchError((_) {
        return <String, dynamic>{};
      });
      return;
    }

    // Mobile FCM is intentionally left as a credential-backed placeholder.
    // Add Firebase configuration files before enabling a real token registration.
  }

  static Future<void> registerAfterAuthenticatedLogin() async {
    if (!kIsWeb) {
      return;
    }

    await registerWebPushAfterLogin();
  }

  static Future<void> registerPlaceholder({
    required String platform,
    Map<String, dynamic> payload = const {},
  }) async {
    await BackendApiService.registerPushSubscription({
      'platform': platform,
      'endpoint': payload['endpoint'] ?? 'placeholder:$platform',
      'keys': payload['keys'] ?? const <String, dynamic>{},
      'meta': {'placeholder': true, ...payload},
    });
  }
}
