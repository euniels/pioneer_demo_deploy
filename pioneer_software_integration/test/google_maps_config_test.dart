import 'package:flutter_test/flutter_test.dart';
import 'package:pioneerpath/src/services/google_maps_config.dart';

void main() {
  test(
    'google maps browser key resolves from backend config fallback',
    () async {
      final key = await resolveGoogleMapsBrowserApiKey(
        backendLoader: () async => {
          'configured': true,
          'browserKey': 'backend-browser-key',
        },
      );

      expect(key, 'backend-browser-key');
    },
  );

  test(
    'google maps browser key stays empty when backend config is missing',
    () async {
      final key = await resolveGoogleMapsBrowserApiKey(
        backendLoader: () async => {'configured': false, 'browserKey': ''},
      );

      expect(key, '');
    },
  );
}
