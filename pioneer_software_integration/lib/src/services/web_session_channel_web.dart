// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;

const String _sessionEventKey = 'pioneer_session_event';
bool _initialized = false;

Future<void> initWebSessionChannel({
  required Future<void> Function() onLogout,
}) async {
  if (_initialized) return;
  _initialized = true;
  html.window.onStorage.listen((event) {
    if (event.key != _sessionEventKey) return;
    final value = event.newValue ?? '';
    if (!value.startsWith('logout:')) return;
    unawaited(onLogout());
  });
}

void notifyWebLogout() {
  html.window.localStorage[_sessionEventKey] =
      'logout:${DateTime.now().millisecondsSinceEpoch}';
}
