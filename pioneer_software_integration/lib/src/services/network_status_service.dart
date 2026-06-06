import 'package:flutter/foundation.dart';

class NetworkStatusService {
  NetworkStatusService._();

  static final ValueNotifier<bool> isOffline = ValueNotifier<bool>(false);
  static final ValueNotifier<String?> offlineReason = ValueNotifier<String?>(
    null,
  );
  static final ValueNotifier<DateTime?> lastOnlineAt = ValueNotifier<DateTime?>(
    null,
  );

  static void reportOnline() {
    if (isOffline.value) {
      isOffline.value = false;
    }
    if (offlineReason.value != null) {
      offlineReason.value = null;
    }
    lastOnlineAt.value = DateTime.now();
  }

  static void reportOffline([String? reason]) {
    if (!isOffline.value) {
      isOffline.value = true;
    }
    final normalized = reason?.trim();
    offlineReason.value = normalized == null || normalized.isEmpty
        ? 'Network unavailable.'
        : normalized;
  }
}
