// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

const String _cacheKey = 'pioneer_google_maps_browser_key_v1';

String runtimeGoogleMapsApiKey() {
  return Uri.base.queryParameters['googleMapsKey']?.trim() ?? '';
}

String cachedGoogleMapsApiKey() {
  try {
    return html.window.localStorage[_cacheKey]?.trim() ?? '';
  } catch (_) {
    return '';
  }
}

void cacheGoogleMapsApiKey(String key) {
  try {
    final normalized = key.trim();
    if (normalized.isEmpty) {
      html.window.localStorage.remove(_cacheKey);
      return;
    }
    html.window.localStorage[_cacheKey] = normalized;
  } catch (_) {}
}

void clearCachedGoogleMapsApiKey() {
  try {
    html.window.localStorage.remove(_cacheKey);
  } catch (_) {}
}
