import 'google_maps_runtime_stub.dart'
    if (dart.library.html) 'google_maps_runtime_web.dart';

import 'app_logger.dart';
import 'backend_api.dart';

const String _dartDefinedGoogleMapsApiKey = String.fromEnvironment(
  'GOOGLE_MAPS_API_KEY',
);

String get googleMapsApiKey {
  final runtimeKey = runtimeGoogleMapsApiKey().trim();
  if (runtimeKey.isNotEmpty) {
    return runtimeKey;
  }

  return _dartDefinedGoogleMapsApiKey.trim();
}

bool get isGoogleMapsConfigured => googleMapsApiKey.isNotEmpty;

Future<String> resolveGoogleMapsBrowserApiKey({
  Future<Map<String, dynamic>> Function()? backendLoader,
}) async {
  final localKey = googleMapsApiKey;
  if (localKey.isNotEmpty) {
    AppLogger.info('Google Maps using local dart-defined API key.');
    return localKey;
  }

  final cachedKey = backendLoader == null ? cachedGoogleMapsApiKey() : '';
  if (cachedKey.isNotEmpty) {
    AppLogger.info('Google Maps using cached browser key.');
    return cachedKey;
  }

  try {
    // Fetch maps config from the backend (Laravel). This may fail if the
    // backend is not running, has CORS restrictions, or the route is unreachable.
    final config =
        await (backendLoader ??
            () => BackendApiService.getMapsConfig(forceRefresh: false))();
    AppLogger.info('Google Maps backend config resolved', {
      'configured': config['configured'] == true,
      'provider': config['provider']?.toString(),
    });

    final configured = config['configured'] == true;
    final backendKey = config['browserKey']?.toString().trim() ?? '';
    if (configured && backendKey.isNotEmpty) {
      cacheGoogleMapsApiKey(backendKey);
      AppLogger.info('Google Maps using browser key from backend.');
      return backendKey;
    }
    clearCachedGoogleMapsApiKey();
    AppLogger.warning(
      'Google Maps backend reports maps disabled or empty key.',
    );
  } catch (_) {
    // Keep maps safely disabled if the backend config cannot be reached.
    AppLogger.warning(
      'Google Maps failed to reach backend to resolve API key.',
    );
  }

  return '';
}
