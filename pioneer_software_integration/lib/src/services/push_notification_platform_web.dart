import 'dart:js_interop';

@JS('PioneerPathPush.register')
external JSPromise<JSAny?> _registerPioneerPathPush();

Future<void> registerWebPushAfterLogin() async {
  try {
    await _registerPioneerPathPush().toDart;
  } catch (_) {
    // Web push is opportunistic; missing browser support or placeholder VAPID
    // config should never block login.
  }
}
