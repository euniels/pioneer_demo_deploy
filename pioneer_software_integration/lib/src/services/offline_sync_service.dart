import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'local_fleet_mirror_service.dart';

class OfflineSyncService {
  OfflineSyncService._();

  static const String _responsePrefix = 'offline_response_v1:';
  static const String _mutationQueueKey = 'offline_mutation_queue_v1';
  static Future<SharedPreferences>? _prefsFuture;

  static Future<SharedPreferences> _prefs() {
    return _prefsFuture ??= SharedPreferences.getInstance();
  }

  static Future<void> storeResponse(
    String path,
    Map<String, dynamic> payload,
  ) async {
    final prefs = await _prefs();
    await prefs.setString('$_responsePrefix$path', jsonEncode(payload));
  }

  static Future<Map<String, dynamic>?> loadResponse(String path) async {
    final prefs = await _prefs();
    final raw = prefs.getString('$_responsePrefix$path');
    if (raw == null || raw.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      return null;
    }

    return null;
  }

  static Future<Map<String, Map<String, dynamic>>> loadResponses(
    Iterable<String> paths,
  ) async {
    final prefs = await _prefs();
    final responses = <String, Map<String, dynamic>>{};
    for (final path in paths) {
      final raw = prefs.getString('$_responsePrefix$path');
      if (raw == null || raw.isEmpty) {
        continue;
      }

      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          responses[path] = decoded;
        }
      } catch (_) {}
    }
    return responses;
  }

  static Future<void> queueMutation(Map<String, dynamic> mutation) async {
    final queue = await loadMutationQueue();
    queue.add(mutation);
    await replaceMutationQueue(queue);
  }

  static Future<List<Map<String, dynamic>>> loadMutationQueue() async {
    try {
      final sqliteQueue = await LocalFleetMirrorService.loadMutationQueue();
      if (sqliteQueue.isNotEmpty) {
        return sqliteQueue;
      }
    } catch (_) {}

    final prefs = await _prefs();
    final raw = prefs.getString(_mutationQueueKey);
    if (raw == null || raw.isEmpty) {
      return [];
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return [];
      }

      return decoded.whereType<Map>().map((item) {
        return item.map((key, value) => MapEntry(key.toString(), value));
      }).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> replaceMutationQueue(
    List<Map<String, dynamic>> queue,
  ) async {
    try {
      await LocalFleetMirrorService.replaceMutationQueue(queue);
    } catch (_) {}

    final prefs = await _prefs();
    await prefs.setString(_mutationQueueKey, jsonEncode(queue));
  }
}
