import 'package:flutter/foundation.dart';

import 'app_logger.dart';

class PageCacheEntry<T> {
  const PageCacheEntry({required this.data, required this.fetchedAt});

  final T data;
  final DateTime fetchedAt;

  bool isFresh(Duration ttl, DateTime now) => now.difference(fetchedAt) <= ttl;

  Duration age(DateTime now) => now.difference(fetchedAt);
}

class CachedLoadState<T> {
  const CachedLoadState({
    required this.data,
    required this.hasCache,
    required this.isStale,
    required this.isRefreshing,
    this.lastSyncedAt,
    this.error,
  });

  final T? data;
  final bool hasCache;
  final bool isStale;
  final bool isRefreshing;
  final DateTime? lastSyncedAt;
  final Object? error;
}

class PageCacheService {
  PageCacheService._();

  static final Map<String, PageCacheEntry<Object?>> _entries = {};
  static final Map<String, Future<Object?>> _inflightLoads = {};
  static final Set<String> _refreshingKeys = {};

  static const Duration vehiclesTtl = Duration(seconds: 60);
  static const Duration fuelTtl = Duration(seconds: 300);
  static const Duration analyticsTtl = Duration(seconds: 300);
  static const Duration tripsTtl = Duration(seconds: 120);
  static const Duration driversTtl = Duration(seconds: 120);
  static const Duration dispatchTtl = Duration(seconds: 60);

  static PageCacheEntry<T>? entry<T>(String key) {
    final entry = _entries[key];
    if (entry == null || entry.data is! T) {
      return null;
    }

    return PageCacheEntry<T>(data: entry.data as T, fetchedAt: entry.fetchedAt);
  }

  static T? freshData<T>(String key, Duration ttl) {
    final cached = entry<T>(key);
    if (cached == null || !cached.isFresh(ttl, DateTime.now())) {
      _debugCache('miss', key);
      return null;
    }

    _debugCache('hit', key);
    return cached.data;
  }

  static T? anyData<T>(String key) {
    final cached = entry<T>(key);
    if (cached == null) {
      _debugCache('empty', key);
      return null;
    }

    _debugCache('stale-ok', key);
    return cached.data;
  }

  static bool hasAny(String key) => _entries.containsKey(key);

  static bool isFresh(String key, Duration ttl) {
    final cached = entry<Object?>(key);
    return cached != null && cached.isFresh(ttl, DateTime.now());
  }

  static bool isStale(String key, Duration ttl) {
    final cached = entry<Object?>(key);
    return cached != null && !cached.isFresh(ttl, DateTime.now());
  }

  static bool isRefreshing(String key) => _refreshingKeys.contains(key);

  static Duration? age(String key) {
    final fetchedAt = _entries[key]?.fetchedAt;
    if (fetchedAt == null) {
      return null;
    }
    return DateTime.now().difference(fetchedAt);
  }

  static CachedLoadState<T> state<T>(String key, Duration ttl) {
    final cached = entry<T>(key);
    final now = DateTime.now();
    return CachedLoadState<T>(
      data: cached?.data,
      hasCache: cached != null,
      isStale: cached != null && !cached.isFresh(ttl, now),
      isRefreshing: isRefreshing(key),
      lastSyncedAt: cached?.fetchedAt,
    );
  }

  static void store<T>(String key, T data) {
    _entries[key] = PageCacheEntry<Object?>(
      data: data,
      fetchedAt: DateTime.now(),
    );
  }

  static Future<T> getOrLoad<T>({
    required String key,
    required Duration ttl,
    required Future<T> Function() loader,
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh) {
      final cached = entry<T>(key);
      if (cached != null) {
        if (cached.isFresh(ttl, DateTime.now())) {
          _debugCache('hit', key);
        } else {
          _debugCache('stale-hit', key);
          _refreshInBackground<T>(key: key, loader: loader);
        }
        return cached.data;
      }
    }

    final inflight = _inflightLoads[key];
    if (inflight != null) {
      _debugCache('join-inflight', key);
      return await inflight as T;
    }

    _debugCache(forceRefresh ? 'refresh' : 'load', key);
    _refreshingKeys.add(key);
    final future = loader().then<Object?>((data) {
      store<T>(key, data);
      return data;
    });
    _inflightLoads[key] = future;

    try {
      return await future as T;
    } finally {
      _refreshingKeys.remove(key);
      _inflightLoads.remove(key);
    }
  }

  static Future<T?> getCachedThenRefresh<T>({
    required String key,
    required Future<T> Function() loader,
    bool forceRefresh = false,
    void Function(T data)? onFreshData,
    void Function(Object error)? onError,
  }) async {
    final cached = forceRefresh ? null : anyData<T>(key);
    if (cached != null) {
      _refreshInBackground<T>(
        key: key,
        loader: loader,
        onFreshData: onFreshData,
        onError: onError,
      );
      return cached;
    }

    try {
      final data = await getOrLoad<T>(
        key: key,
        ttl: Duration.zero,
        forceRefresh: true,
        loader: loader,
      );
      onFreshData?.call(data);
      return data;
    } catch (error) {
      onError?.call(error);
      return null;
    }
  }

  static DateTime? fetchedAt(String key) => _entries[key]?.fetchedAt;

  static void invalidate(String key) {
    _entries.remove(key);
    _inflightLoads.remove(key);
    _refreshingKeys.remove(key);
  }

  static void _refreshInBackground<T>({
    required String key,
    required Future<T> Function() loader,
    void Function(T data)? onFreshData,
    void Function(Object error)? onError,
  }) {
    if (_inflightLoads.containsKey(key)) {
      _debugCache('refresh-join', key);
      return;
    }

    _debugCache('refresh-background', key);
    _refreshingKeys.add(key);
    final future = loader().then<Object?>((data) {
      store<T>(key, data);
      onFreshData?.call(data);
      return data;
    });
    _inflightLoads[key] = future;
    future
        .catchError((Object error) {
          onError?.call(error);
          return null;
        })
        .whenComplete(() {
          _refreshingKeys.remove(key);
          _inflightLoads.remove(key);
        });
  }

  static void _debugCache(String state, String key) {
    if (kDebugMode) {
      AppLogger.info('Page cache state changed', {'state': state, 'key': key});
    }
  }
}
