import 'dart:async';

import 'auth.dart';
import 'backend_api.dart';
import 'fleet_sync_service.dart';
import 'vehicles_store.dart';

class FleetDataCoordinator {
  FleetDataCoordinator._();

  static Future<void>? _startupFuture;
  static Future<void>? _priorityQueueFuture;
  static final Map<String, Future<Object?>> _coalescedRequests = {};

  static Future<void> initialize() {
    final existing = _startupFuture;
    if (existing != null) {
      return existing;
    }

    final future = _initialize().whenComplete(() {
      _startupFuture = null;
    });
    _startupFuture = future;
    return future;
  }

  static Future<void> _initialize() async {
    await BackendApiService.bootstrapOfflineSupport();
    if (_canWarmOperationalFleet(AuthService.currentManagedRole)) {
      await warmFleetStateFromCache();
    }
  }

  static void refreshSilently({bool forceRefresh = false}) {
    refreshFleetBootstrapSilently(forceRefresh: forceRefresh);
    refreshFleetSnapshotSilently(forceRefresh: forceRefresh);
    warmOperationalCachesSilently(forceRefresh: forceRefresh);
  }

  static Future<void> startPriorityQueue({bool forceRefresh = false}) {
    final existing = _priorityQueueFuture;
    if (!forceRefresh && existing != null) {
      return existing;
    }

    final future = _runPriorityQueue(forceRefresh: forceRefresh).whenComplete(
      () {
        _priorityQueueFuture = null;
      },
    );
    _priorityQueueFuture = future;
    return future;
  }

  static Future<void> _runPriorityQueue({bool forceRefresh = false}) async {
    final role = AuthService.currentManagedRole;
    if (!_canWarmOperationalFleet(role)) {
      return;
    }

    await _runTier(() async {
      final live = await coalesce(
        'GET /fleet/summary/live force=$forceRefresh',
        () => BackendApiService.getFleetSummaryLive(forceRefresh: forceRefresh),
      );
      applyFleetLivePayload(live);
    });

    await _tierDelay();
    await _runTier(() async {
      await coalesce(
        'GET /fleet/summary force=$forceRefresh',
        () => refreshFleetSnapshot(forceRefresh: forceRefresh),
      );
    });

    await _tierDelay();
    await _runTier(() async {
      await coalesce(
        'GET /fleet/dashboard/summary force=$forceRefresh',
        () => BackendApiService.getFleetDashboardSummary(
          forceRefresh: forceRefresh,
        ),
      );
    });

    final laterTiers = <Future<void> Function()>[
      () async {
        await coalesce(
          'GET /fleet/summary/analytics force=$forceRefresh',
          () => BackendApiService.getFleetSummaryAnalytics(
            forceRefresh: forceRefresh,
          ),
        );
      },
      () async {
        await coalesce(
          'GET /fleet/notifications force=$forceRefresh',
          () => refreshNotificationsFromBackend(forceRefresh: forceRefresh),
        );
      },
      () async {
        await coalesce(
          'GET /fleet/routes force=$forceRefresh',
          () => BackendApiService.getFleetRoutes(forceRefresh: forceRefresh),
        );
      },
    ];

    if (_canWarmFullOperations(role)) {
      laterTiers.insertAll(1, [
        () async {
          await coalesce(
            'GET /fleet/fuel force=$forceRefresh',
            () => BackendApiService.getFleetFuel(forceRefresh: forceRefresh),
          );
        },
        () async {
          await coalesce(
            'GET /fleet/maintenance force=$forceRefresh',
            () => BackendApiService.getFleetMaintenance(
              forceRefresh: forceRefresh,
            ),
          );
        },
        () async {
          await coalesce(
            'GET /billing/invoices force=$forceRefresh',
            () => BackendApiService.getBillingInvoices(
              forceRefresh: forceRefresh,
            ),
          );
        },
        () async {
          await coalesce(
            'GET /billing/soa force=$forceRefresh',
            () => BackendApiService.getStatementOfAccounts(
              forceRefresh: forceRefresh,
            ),
          );
        },
        () async {
          await coalesce(
            'GET /fleet/geotab/writeback/jobs force=$forceRefresh',
            () => BackendApiService.getGeotabWriteBackJobs(
              forceRefresh: forceRefresh,
            ),
          );
        },
      ]);
    }

    for (final tier in laterTiers) {
      await _tierDelay();
      await _runTier(tier);
    }
  }

  static Future<void> _runTier(Future<void> Function() tier) async {
    try {
      await tier();
    } catch (_) {}
  }

  static Future<void> _tierDelay() {
    return Future<void>.delayed(const Duration(milliseconds: 200));
  }

  static bool _canWarmOperationalFleet(String role) {
    return const {
      'super_administrator',
      'system_administrator',
      'fleet_manager',
      'dispatcher',
    }.contains(role);
  }

  static bool _canWarmFullOperations(String role) {
    return const {
      'super_administrator',
      'system_administrator',
      'fleet_manager',
    }.contains(role);
  }

  static Future<T> coalesce<T>(String key, Future<T> Function() loader) async {
    final existing = _coalescedRequests[key];
    if (existing != null) {
      return await existing as T;
    }

    final future = loader().then<Object?>((value) => value);
    _coalescedRequests[key] = future;
    try {
      return await future as T;
    } finally {
      _coalescedRequests.remove(key);
    }
  }
}
