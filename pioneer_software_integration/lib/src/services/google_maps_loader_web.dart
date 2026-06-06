// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

import 'app_logger.dart';
import 'google_maps_config.dart';
import 'google_maps_runtime_web.dart';

Future<bool>? _loadFuture;

Future<bool> ensureGoogleMapsReady() async {
  final key = await _resolveKeyWithShortRetry();
  if (key.isEmpty) {
    AppLogger.warning(
      'Google Maps API key is unavailable for web map rendering.',
    );
    return false;
  }

  final existing = html.document.getElementById('pioneer-google-maps-sdk');
  if (existing?.dataset['loaded'] == 'true') {
    return true;
  }

  final activeLoad = _loadFuture;
  if (activeLoad != null) {
    return activeLoad;
  }

  _loadFuture = _injectGoogleMapsScript(key);
  final loaded = await _loadFuture!;
  if (!loaded) {
    _loadFuture = null;
    clearCachedGoogleMapsApiKey();
  }
  return loaded;
}

void preloadGoogleMaps() {
  ensureGoogleMapsReady();
}

Future<String> _resolveKeyWithShortRetry() async {
  const delays = <Duration>[
    Duration.zero,
    Duration(milliseconds: 180),
    Duration(milliseconds: 420),
  ];

  for (final delay in delays) {
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    final key = await resolveGoogleMapsBrowserApiKey();
    if (key.isNotEmpty) {
      return key;
    }
  }

  return '';
}

Future<bool> _injectGoogleMapsScript(String key) {
  html.document.getElementById('pioneer-google-maps-sdk')?.remove();

  final script = html.ScriptElement()
    ..id = 'pioneer-google-maps-sdk'
    ..async = true
    ..defer = true
    ..src =
        'https://maps.googleapis.com/maps/api/js?key=${Uri.encodeComponent(key)}&v=weekly';

  final loaded = script.onLoad.first.then((_) {
    script.dataset['loaded'] = 'true';
    return true;
  });
  final failed = script.onError.first.then((_) {
    script.remove();
    clearCachedGoogleMapsApiKey();
    return false;
  });

  html.document.head?.append(script);
  return Future.any([loaded, failed]).timeout(
    const Duration(seconds: 8),
    onTimeout: () {
      script.remove();
      clearCachedGoogleMapsApiKey();
      return false;
    },
  );
}
