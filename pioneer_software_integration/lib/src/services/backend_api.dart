import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'local_fleet_mirror_service.dart';
import 'network_status_service.dart';
import 'offline_sync_service.dart';

class BackendApiException implements Exception {
  final String message;
  final int? statusCode;
  final Duration? retryAfter;
  final String? category;

  const BackendApiException(this.message, {
    this.statusCode,
    this.retryAfter,
    this.category,
  });

  @override
  String toString() => message;
}

class PaginatedBackendList {
  const PaginatedBackendList({
    required this.items,
    required this.total,
    required this.currentPage,
    required this.lastPage,
    required this.perPage,
    this.nextPage,
    this.previousPage,
  });

  final List<Map<String, dynamic>> items;
  final int total;
  final int currentPage;
  final int lastPage;
  final int perPage;
  final int? nextPage;
  final int? previousPage;

  bool get hasNextPage => nextPage != null && currentPage < lastPage;
}

class BackendApiService {
  BackendApiService._();

  static const String _configuredBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: '',
  );

  static const Duration _requestTimeout = Duration(seconds: 12);
  static const Duration _defaultCacheTtl = Duration(seconds: 30);
  static const Duration _liveLocationCacheTtl = Duration(seconds: 2);
  static const Duration _trailCacheTtl = Duration(seconds: 20);

  static final Map<String, _CachedBackendResponse> _cache = {};
  static final Map<String, Future<Map<String, dynamic>>> _inflightGets = {};
  static final Map<String, _HttpCacheValidator> _validators = {};
  static final Map<String, DateTime> _pausedUntil = {};
  static Future<void>? _bootstrapFuture;
  static Future<void>? _queueReplayFuture;
  static String? _accessToken;
  static Future<bool> Function()? _refreshAuthHandler;
  static VoidCallback? _sessionExpiredHandler;
  static bool _sessionTerminating = false;

  static void setCurrentActorRole(String? role) {
    // Role headers are intentionally no longer sent. This no-op remains so
    // legacy UI code can update local role state without influencing API auth.
  }

  static void setAccessToken(String? token) {
    final trimmed = token?.trim();
    _accessToken = trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static void setSessionTerminating(bool terminating) {
    _sessionTerminating = terminating;
    if (terminating) {
      _inflightGets.clear();
    }
  }

  static String? get accessTokenForRealtime => _accessToken;

  static void configureAuthCallbacks({
    Future<bool> Function()? refreshAuth,
    VoidCallback? onSessionExpired,
  }) {
    _refreshAuthHandler = refreshAuth;
    _sessionExpiredHandler = onSessionExpired;
  }

  static String get baseUrl {
    if (_configuredBaseUrl.isNotEmpty) {
      var trimmed = _configuredBaseUrl.trim();
      while (trimmed.endsWith('/')) {
        trimmed = trimmed.substring(0, trimmed.length - 1);
      }
      return trimmed.endsWith('/api') ? trimmed : '$trimmed/api';
    }

    if (kIsWeb) {
      return 'http://127.0.0.1:8000/api';
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'http://10.0.2.2:8000/api';
      default:
        return 'http://127.0.0.1:8000/api';
    }
  }

  static Future<void> bootstrapOfflineSupport() {
    if (_bootstrapFuture != null) {
      return _bootstrapFuture!;
    }

    final future = LocalFleetMirrorService.initialize()
        .then((_) => _hydratePersistedCaches())
        .whenComplete(() {
          _bootstrapFuture = null;
          _replayQueuedMutationsSilently();
        });

    _bootstrapFuture = future;
    return future;
  }

  static Future<void> replayQueuedMutations() async {
    if (_queueReplayFuture != null) {
      return _queueReplayFuture!;
    }

    final future = _replayQueuedMutationsInternal().whenComplete(() {
      _queueReplayFuture = null;
    });

    _queueReplayFuture = future;
    return future;
  }

  static Future<List<Map<String, dynamic>>> getVehicles({
    bool forceRefresh = false,
  }) async {
    return _getList(
      '/vehicles',
      cacheTtl: const Duration(seconds: 20),
      forceRefresh: forceRefresh,
    );
  }

  static Future<PaginatedBackendList> getVehiclesPage({
    int page = 1,
    int perPage = 25,
    bool forceRefresh = false,
  }) {
    return _getListPage(
      '/vehicles',
      page: page,
      perPage: perPage,
      cacheTtl: const Duration(seconds: 20),
      forceRefresh: forceRefresh,
    );
  }

  static Future<List<Map<String, dynamic>>> getManualVehicles({
    bool forceRefresh = false,
    String status = 'all',
  }) async {
    final path = status.trim().isNotEmpty && status.toLowerCase() != 'all'
        ? '/fleet/vehicles/manual?${Uri(queryParameters: {'status': status.trim()}).query}'
        : '/fleet/vehicles/manual';

    return _getList(
      path,
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<PaginatedBackendList> getManualVehiclesPage({
    int page = 1,
    int perPage = 25,
    bool forceRefresh = false,
  }) {
    return _getListPage(
      '/fleet/vehicles/manual',
      page: page,
      perPage: perPage,
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> createManualVehicle(
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest(
      'POST',
      '/fleet/vehicles/manual',
      payload,
    );
    clearCache('/vehicles');
    clearCache('/fleet/vehicles/manual');
    clearCache('/fleet/summary');
    clearCache('/fleet/dashboard/summary');
    clearCache('/fleet/geotab/writeback/jobs');
    return response;
  }

  static Future<List<Map<String, dynamic>>> getFleetClients({
    bool forceRefresh = false,
    String search = '',
    String status = 'all',
  }) async {
    final params = <String, String>{
      if (search.trim().isNotEmpty) 'search': search.trim(),
      if (status.trim().isNotEmpty && status.toLowerCase() != 'all')
        'status': status.trim(),
    };
    final path = params.isEmpty
        ? '/fleet/clients'
        : '/fleet/clients?${Uri(queryParameters: params).query}';

    return _getList(
      path,
      cacheTtl: const Duration(minutes: 2),
      forceRefresh: forceRefresh,
    );
  }

  static Future<PaginatedBackendList> getFleetClientsPage({
    int page = 1,
    int perPage = 25,
    bool forceRefresh = false,
    String search = '',
    String status = 'all',
  }) {
    final params = <String, String>{
      if (search.trim().isNotEmpty) 'search': search.trim(),
      if (status.trim().isNotEmpty && status.toLowerCase() != 'all')
        'status': status.trim(),
    };
    final path = params.isEmpty
        ? '/fleet/clients'
        : '/fleet/clients?${Uri(queryParameters: params).query}';

    return _getListPage(
      path,
      page: page,
      perPage: perPage,
      cacheTtl: const Duration(minutes: 2),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> createFleetClient(
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest('POST', '/fleet/clients', payload);
    _clearClientRelatedCaches();
    return response;
  }

  static Future<Map<String, dynamic>> updateFleetClient(
    String clientId,
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest(
      'PATCH',
      '/fleet/clients/$clientId',
      payload,
    );
    _clearClientRelatedCaches();
    return response;
  }

  static Future<Map<String, dynamic>> deactivateFleetClient(
    String clientId, {
    String reason = 'Deactivated from PioneerPath clients page.',
  }) async {
    final response = await _sendJsonRequest(
      'DELETE',
      '/fleet/clients/$clientId',
      {'reason': reason},
    );
    _clearClientRelatedCaches();
    return response;
  }

  static Future<Map<String, dynamic>> updateManualVehicle(
    String vehicleId,
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest(
      'PATCH',
      '/fleet/vehicles/manual/$vehicleId',
      payload,
    );
    clearCache('/vehicles');
    clearCache('/fleet/vehicles/manual');
    clearCache('/fleet/summary');
    clearCache('/fleet/dashboard/summary');
    clearCache('/fleet/geotab/writeback/jobs');
    return response;
  }

  static Future<Map<String, dynamic>> pushManualVehicleToGeotab(
    String vehicleId, {
    bool previewOnly = false,
  }) async {
    final response = await _sendJsonRequest(
      'POST',
      '/fleet/vehicles/manual/$vehicleId/push-geotab',
      {'previewOnly': previewOnly},
    );
    clearCache('/vehicles');
    clearCache('/fleet/vehicles/manual');
    clearCache('/fleet/geotab/writeback/jobs');
    return response;
  }

  static Future<Map<String, dynamic>> deactivateManualVehicle(
    String vehicleId, {
    String reason = 'Deactivated from PioneerPath vehicles page.',
  }) async {
    final response = await _sendJsonRequest(
      'PATCH',
      '/fleet/vehicles/manual/$vehicleId',
      {
        'status': 'Inactive',
        'meta': {'deactivationReason': reason},
      },
    );
    clearCache('/vehicles');
    clearCache('/fleet/vehicles/manual');
    clearCache('/fleet/summary');
    clearCache('/fleet/dashboard/summary');
    clearCache('/fleet/geotab/writeback/jobs');
    return response;
  }

  static Future<Map<String, dynamic>> deleteManualVehicle(
    String vehicleId,
  ) async {
    final response = await _sendJsonRequest(
      'DELETE',
      '/fleet/vehicles/manual/$vehicleId/permanent',
      const <String, dynamic>{},
    );
    clearCache('/vehicles');
    clearCache('/fleet/vehicles/manual');
    clearCache('/fleet/summary');
    clearCache('/fleet/dashboard/summary');
    clearCache('/fleet/geotab/writeback/jobs');
    return response;
  }

  static Future<List<Map<String, dynamic>>> getVehicleLocations({
    bool forceRefresh = false,
  }) async {
    return _getList(
      '/vehicles/locations',
      cacheTtl: _liveLocationCacheTtl,
      forceRefresh: forceRefresh,
    );
  }

  static Future<List<Map<String, dynamic>>> getVehicleTrail(
    String geotabId, {
    bool forceRefresh = false,
  }) async {
    return _getList(
      '/vehicles/$geotabId/trail',
      cacheTtl: _trailCacheTtl,
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getFleetSummary({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/summary',
      cacheTtl: _defaultCacheTtl,
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getFleetSummaryLive({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/summary/live',
      cacheTtl: _liveLocationCacheTtl,
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getFleetSummaryAnalytics({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/summary/analytics',
      cacheTtl: const Duration(minutes: 10),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getFleetSummaryMaintenance({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/summary/maintenance',
      cacheTtl: const Duration(minutes: 5),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getMaintenancePredictions({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/maintenance/predictions',
      cacheTtl: const Duration(hours: 1),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getDriverPerformanceAnalytics({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/analytics/driver-performance',
      cacheTtl: const Duration(minutes: 10),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getVehicleHealthAnalytics({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/analytics/vehicle-health',
      cacheTtl: const Duration(minutes: 10),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getRouteEfficiencyAnalytics({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/analytics/route-efficiency',
      cacheTtl: const Duration(minutes: 10),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getTripForecastAnalytics({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/analytics/trip-forecast',
      cacheTtl: const Duration(hours: 1),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getFuelTrendAnalytics({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/analytics/fuel-trend',
      cacheTtl: const Duration(minutes: 10),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getApiHealth({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/health',
      cacheTtl: const Duration(seconds: 10),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getGeotabHealth({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/geotab/health',
      cacheTtl: const Duration(seconds: 10),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getFleetLive({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/live',
      cacheTtl: _liveLocationCacheTtl,
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getFleetDashboard({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/dashboard',
      cacheTtl: _defaultCacheTtl,
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getFleetDashboardSummary({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/dashboard/summary',
      cacheTtl: const Duration(seconds: 120),
      forceRefresh: forceRefresh,
    );
  }

  static Future<List<Map<String, dynamic>>> getFleetRoutes({
    bool forceRefresh = false,
  }) async {
    return _getList(
      '/fleet/routes',
      cacheTtl: _defaultCacheTtl,
      forceRefresh: forceRefresh,
    );
  }

  static Future<PaginatedBackendList> getFleetRoutesPage({
    int page = 1,
    int perPage = 25,
    bool forceRefresh = false,
  }) {
    return _getListPage(
      '/fleet/routes',
      page: page,
      perPage: perPage,
      cacheTtl: _defaultCacheTtl,
      forceRefresh: forceRefresh,
    );
  }

  static Future<List<Map<String, dynamic>>> getFleetTrips({
    bool forceRefresh = false,
  }) async {
    return _getList(
      '/fleet/trips',
      cacheTtl: const Duration(seconds: 20),
      forceRefresh: forceRefresh,
    );
  }

  static Future<List<Map<String, dynamic>>> getFleetZones({
    bool forceRefresh = false,
  }) async {
    return _getList(
      '/fleet/zones',
      cacheTtl: _defaultCacheTtl,
      forceRefresh: forceRefresh,
    );
  }

  static Future<PaginatedBackendList> getFleetZonesPage({
    int page = 1,
    int perPage = 25,
    bool forceRefresh = false,
  }) {
    return _getListPage(
      '/fleet/zones',
      page: page,
      perPage: perPage,
      cacheTtl: _defaultCacheTtl,
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> createFleetZone(
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest('POST', '/fleet/zones', payload);
    clearCache('/fleet/zones');
    clearCache('/fleet/geotab/writeback/jobs');
    clearCache('/fleet/live');
    return response;
  }

  static Future<Map<String, dynamic>> updateFleetZone(
    String zoneId,
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest(
      'PATCH',
      '/fleet/zones/$zoneId',
      payload,
    );
    clearCache('/fleet/zones');
    clearCache('/fleet/geotab/writeback/jobs');
    clearCache('/fleet/live');
    return response;
  }

  static Future<Map<String, dynamic>> deleteFleetZone(
    String zoneId, {
    bool previewOnly = false,
    bool confirmedPreview = false,
  }) async {
    final response = await _sendJsonRequest('DELETE', '/fleet/zones/$zoneId', {
      'previewOnly': previewOnly,
      'confirmedPreview': confirmedPreview,
    });
    if (!previewOnly) {
      clearCache('/fleet/zones');
      clearCache('/fleet/geotab/writeback/jobs');
      clearCache('/fleet/live');
    }
    return response;
  }

  static Future<Map<String, dynamic>> pushFleetZoneToGeotab(
    String zoneId, {
    bool previewOnly = false,
  }) async {
    final response = await _sendJsonRequest(
      'POST',
      '/fleet/zones/$zoneId/push-geotab',
      {'previewOnly': previewOnly},
    );
    clearCache('/fleet/zones');
    clearCache('/fleet/geotab/writeback/jobs');
    clearCache('/fleet/live');
    return response;
  }

  static Future<List<Map<String, dynamic>>> getGeotabWriteBackJobs({
    bool forceRefresh = false,
  }) async {
    return _getList(
      '/fleet/geotab/writeback/jobs',
      cacheTtl: const Duration(seconds: 15),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> approveGeotabWriteBackJob(
    String jobId, {
    String? temporaryPassword,
    bool processNow = true,
  }) async {
    final response = await _sendJsonRequest(
      'POST',
      '/fleet/geotab/writeback/jobs/$jobId/approve',
      {
        if ((temporaryPassword ?? '').trim().isNotEmpty)
          'temporaryPassword': temporaryPassword!.trim(),
        'processNow': processNow,
      },
    );
    clearCache('/fleet/geotab/writeback/jobs');
    clearCache('/fleet/drivers/manual');
    return response;
  }

  static Future<Map<String, dynamic>> retryGeotabWriteBackJob(
    String jobId,
  ) async {
    final response = await _sendJsonRequest(
      'POST',
      '/fleet/geotab/writeback/jobs/$jobId/retry',
      const {},
    );
    clearCache('/fleet/geotab/writeback/jobs');
    clearCache('/fleet/drivers/manual');
    return response;
  }

  static Future<Map<String, dynamic>> cancelGeotabWriteBackJob(
    String jobId, {
    String reason = 'Cancelled from PioneerPath settings.',
  }) async {
    final response = await _sendJsonRequest(
      'POST',
      '/fleet/geotab/writeback/jobs/$jobId/cancel',
      {'reason': reason},
    );
    clearCache('/fleet/geotab/writeback/jobs');
    clearCache('/fleet/drivers/manual');
    return response;
  }

  static Future<void> deleteGeotabWriteBackJob(String jobId) async {
    await _delete('/fleet/geotab/writeback/jobs/$jobId');
    clearCache('/fleet/geotab/writeback/jobs');
    clearCache('/fleet/drivers/manual');
    clearCache('/fleet/vehicles/manual');
    clearCache('/fleet/routes');
    clearCache('/fleet/zones');
    clearCache('/fleet/maintenance/history');
  }

  static Future<Map<String, dynamic>> createFleetRoute(
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest('POST', '/fleet/routes', payload);
    clearCache('/fleet/routes');
    clearCache('/fleet/geotab/writeback/jobs');
    return response;
  }

  static Future<Map<String, dynamic>> updateFleetRoute(
    String routeId,
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest(
      'PATCH',
      '/fleet/routes/$routeId',
      payload,
    );
    clearCache('/fleet/routes');
    clearCache('/fleet/geotab/writeback/jobs');
    return response;
  }

  static Future<void> deleteFleetRoute(String routeId) async {
    await _delete('/fleet/routes/$routeId');
    clearCache('/fleet/routes');
    clearCache('/fleet/geotab/writeback/jobs');
  }

  static Future<Map<String, dynamic>> pushFleetRouteToGeotab(
    String routeId, {
    bool previewOnly = false,
  }) async {
    final response = await _sendJsonRequest(
      'POST',
      '/fleet/routes/$routeId/push-geotab',
      {'previewOnly': previewOnly},
    );
    clearCache('/fleet/routes');
    clearCache('/fleet/geotab/writeback/jobs');
    return response;
  }

  static Future<Map<String, dynamic>> getFleetFuel({
    bool forceRefresh = false,
    String vehicle = '',
  }) async {
    final path = vehicle.trim().isEmpty
        ? '/fleet/fuel'
        : '/fleet/fuel?${Uri(queryParameters: {'vehicle': vehicle.trim()}).query}';
    return _getDataMap(
      path,
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getFuelPriceSettings({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/settings/fuel-prices',
      cacheTtl: const Duration(minutes: 5),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getSystemSettings({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/settings/system',
      cacheTtl: const Duration(minutes: 5),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> saveFuelPriceSettings(
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest(
      'PUT',
      '/fleet/settings/fuel-prices',
      payload,
    );
    clearCache('/fleet/settings/fuel-prices');
    clearCache('/fleet/settings/system');
    clearCache('/fleet/fuel');
    clearCache('/fleet/summary');
    clearCache('/fleet/dashboard/summary');
    clearCache('/billing/invoices');
    return response;
  }

  static Future<Map<String, dynamic>> saveSystemSettings(
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest(
      'PUT',
      '/fleet/settings/system',
      payload,
    );
    clearCache('/fleet/settings/fuel-prices');
    clearCache('/fleet/settings/system');
    clearCache('/fleet/fuel');
    clearCache('/fleet/summary');
    clearCache('/fleet/dashboard/summary');
    clearCache('/billing/invoices');
    return response;
  }

  static Future<List<Map<String, dynamic>>> getFleetFuelTransactions({
    bool forceRefresh = false,
    String vehicle = '',
  }) async {
    final path = vehicle.trim().isEmpty
        ? '/fleet/fuel/transactions'
        : '/fleet/fuel/transactions?${Uri(queryParameters: {'vehicle': vehicle.trim()}).query}';
    return _getList(
      path,
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<PaginatedBackendList> getFleetFuelTransactionsPage({
    int page = 1,
    int perPage = 25,
    bool forceRefresh = false,
  }) {
    return _getListPage(
      '/fleet/fuel/transactions',
      page: page,
      perPage: perPage,
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<List<Map<String, dynamic>>> getFleetEnergyCharges({
    bool forceRefresh = false,
  }) async {
    return _getList(
      '/fleet/energy/charges',
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getFleetMaintenance({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/maintenance',
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<List<Map<String, dynamic>>> getFleetMaintenanceFaults({
    bool forceRefresh = false,
  }) async {
    return _getList(
      '/fleet/maintenance/faults',
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<List<Map<String, dynamic>>> getFleetMaintenanceDvir({
    bool forceRefresh = false,
  }) async {
    return _getList(
      '/fleet/maintenance/dvir',
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<List<Map<String, dynamic>>> getFleetMaintenanceWorkOrders({
    bool forceRefresh = false,
  }) async {
    return _getList(
      '/fleet/maintenance/work-orders',
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getFleetTelemetry({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/telemetry',
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<List<Map<String, dynamic>>> getFleetTelemetryAssets({
    bool forceRefresh = false,
  }) async {
    return _getList(
      '/fleet/telemetry/assets',
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getFleetTelemetryAsset(
    String geotabId, {
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/telemetry/assets/$geotabId',
      cacheTtl: const Duration(seconds: 20),
      forceRefresh: forceRefresh,
    );
  }

  static Future<void> persistFleetTelemetryAsset(
    String geotabId,
    Map<String, dynamic> asset,
  ) async {
    final trimmedId = geotabId.trim();
    if (trimmedId.isEmpty || asset.isEmpty) {
      return;
    }

    final path = '/fleet/telemetry/assets/$trimmedId';
    final decoded = <String, dynamic>{'success': true, 'data': asset};
    _cache[path] = _CachedBackendResponse(
      payload: decoded,
      expiresAt: DateTime.now().add(_ttlForPath(path)),
      storedAt: DateTime.now(),
    );
    await _persistDecodedResponse(path, decoded);
  }

  static Future<Map<String, dynamic>> getFleetTemperature({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/temperature',
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<List<Map<String, dynamic>>> getFleetNotifications({
    bool forceRefresh = false,
  }) async {
    return _getList(
      '/fleet/notifications',
      cacheTtl: const Duration(seconds: 10),
      forceRefresh: forceRefresh,
    );
  }

  static Future<PaginatedBackendList> getFleetNotificationsPage({
    int page = 1,
    int perPage = 25,
    bool forceRefresh = false,
  }) {
    return _getListPage(
      '/fleet/notifications',
      page: page,
      perPage: perPage,
      cacheTtl: const Duration(seconds: 10),
      forceRefresh: forceRefresh,
    );
  }

  static Future<List<Map<String, dynamic>>> getManualDrivers({
    bool forceRefresh = false,
    String status = 'all',
  }) async {
    final path = status.trim().isNotEmpty && status.toLowerCase() != 'all'
        ? '/fleet/drivers/manual?${Uri(queryParameters: {'status': status.trim()}).query}'
        : '/fleet/drivers/manual';

    return _getList(
      path,
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<PaginatedBackendList> getManualDriversPage({
    int page = 1,
    int perPage = 25,
    bool forceRefresh = false,
  }) {
    return _getListPage(
      '/fleet/drivers/manual',
      page: page,
      perPage: perPage,
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<List<Map<String, dynamic>>> getManagedUsers({
    bool forceRefresh = false,
    String role = 'all',
    String status = 'all',
  }) async {
    final params = <String, String>{
      if (role.trim().isNotEmpty && role.toLowerCase() != 'all')
        'role': role.trim(),
      if (status.trim().isNotEmpty && status.toLowerCase() != 'all')
        'status': status.trim(),
    };
    final path = params.isEmpty
        ? '/fleet/users'
        : '/fleet/users?${Uri(queryParameters: params).query}';
    return _getList(
      path,
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<PaginatedBackendList> getManagedUsersPage({
    int page = 1,
    int perPage = 25,
    bool forceRefresh = false,
    String role = 'all',
    String status = 'all',
  }) {
    final params = <String, String>{
      if (role.trim().isNotEmpty && role.toLowerCase() != 'all')
        'role': role.trim(),
      if (status.trim().isNotEmpty && status.toLowerCase() != 'all')
        'status': status.trim(),
    };
    final path = params.isEmpty
        ? '/fleet/users'
        : '/fleet/users?${Uri(queryParameters: params).query}';
    return _getListPage(
      path,
      page: page,
      perPage: perPage,
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<PaginatedBackendList> getAuditLogsPage({
    int page = 1,
    int perPage = 25,
    bool forceRefresh = false,
    String from = '',
    String to = '',
    String actor = '',
    String entityType = '',
    String actionType = '',
  }) {
    final params = <String, String>{
      if (from.trim().isNotEmpty) 'from': from.trim(),
      if (to.trim().isNotEmpty) 'to': to.trim(),
      if (actor.trim().isNotEmpty && actor.toLowerCase() != 'all')
        'actor': actor.trim(),
      if (entityType.trim().isNotEmpty && entityType.toLowerCase() != 'all')
        'entityType': entityType.trim(),
      if (actionType.trim().isNotEmpty && actionType.toLowerCase() != 'all')
        'actionType': actionType.trim(),
    };
    final path = params.isEmpty
        ? '/fleet/audit-logs'
        : '/fleet/audit-logs?${Uri(queryParameters: params).query}';

    return _getListPage(
      path,
      page: page,
      perPage: perPage,
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> createManagedUser(
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest('POST', '/fleet/users', payload);
    _clearManagedUserCaches();
    return response;
  }

  static Future<Map<String, dynamic>> updateManagedUser(
    String userId,
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest(
      'PATCH',
      '/fleet/users/$userId',
      payload,
    );
    _clearManagedUserCaches();
    return response;
  }

  static Future<Map<String, dynamic>> resetManagedUserPassword(
    String userId,
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest(
      'POST',
      '/fleet/users/$userId/reset-password',
      payload,
    );
    _clearManagedUserCaches();
    return response;
  }

  static Future<Map<String, dynamic>> deactivateManagedUser(
    String userId,
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest(
      'DELETE',
      '/fleet/users/$userId',
      payload,
    );
    _clearManagedUserCaches();
    return response;
  }

  static Future<Map<String, dynamic>> deleteManagedUserPermanently(
    String userId,
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest(
      'DELETE',
      '/fleet/users/$userId/permanent',
      payload,
    );
    _clearManagedUserCaches();
    return response;
  }

  static Future<Map<String, dynamic>> loginManagedUser(
    String username,
    String password,
  ) async {
    return _sendJsonRequest('POST', '/fleet/users/login-check', {
      'username': username,
      'password': password,
      'platform': kIsWeb ? 'web' : 'mobile',
    }, allowAuthRetry: false);
  }

  static Future<Map<String, dynamic>> refreshAuthToken(
    String refreshToken,
  ) async {
    return _sendJsonRequest('POST', '/fleet/auth/refresh', {
      'refreshToken': refreshToken,
      'platform': kIsWeb ? 'web' : 'mobile',
    }, allowAuthRetry: false);
  }

  static Future<Map<String, dynamic>> requestPasswordReset(String email) async {
    return _sendJsonRequest('POST', '/fleet/auth/forgot-password', {
      'email': email.trim(),
    }, allowAuthRetry: false);
  }

  static Future<Map<String, dynamic>> resetPasswordWithToken({
    required String email,
    required String token,
    required String password,
  }) async {
    return _sendJsonRequest('POST', '/fleet/auth/reset-password', {
      'email': email.trim(),
      'token': token.trim(),
      'password': password,
      'platform': kIsWeb ? 'web' : 'mobile',
    }, allowAuthRetry: false);
  }

  static Future<void> logoutManagedUser(String? refreshToken) async {
    await _sendJsonRequest('POST', '/fleet/auth/logout', {
      if (refreshToken != null && refreshToken.trim().isNotEmpty)
        'refreshToken': refreshToken.trim(),
    });
  }

  static Future<void> reportClientError(Map<String, dynamic> payload) async {
    try {
      await _sendJsonRequest(
        'POST',
        '/client-errors',
        payload,
        allowAuthRetry: false,
      );
    } catch (_) {
      // Error reporting must never break the user-facing workflow.
    }
  }

  static Future<Map<String, dynamic>> changeManagedUserPassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    return _sendJsonRequest('POST', '/fleet/auth/change-password', {
      'currentPassword': currentPassword,
      'newPassword': newPassword,
      'platform': kIsWeb ? 'web' : 'mobile',
    });
  }

  static Future<Map<String, dynamic>> createManualDriver(
    Map<String, dynamic> payload,
  ) async {
    try {
      final response = await _sendJsonRequest(
        'POST',
        '/fleet/drivers/manual',
        payload,
      );
      clearCache('/fleet/drivers/manual');
      clearCache('/fleet/summary');
      clearCache('/fleet/summary/analytics');
      clearCache('/fleet/summary/live');
      return response;
    } on BackendApiException {
      rethrow;
    } catch (error) {
      NetworkStatusService.reportOffline(error.toString());
      await _queueMutation(
        'driver.create',
        'POST',
        '/fleet/drivers/manual',
        payload,
      );
      return {'queued': true, 'syncState': 'queued', ...payload};
    }
  }

  static Future<Map<String, dynamic>> updateManualDriver(
    String driverId,
    Map<String, dynamic> payload,
  ) async {
    try {
      final response = await _sendJsonRequest(
        'PATCH',
        '/fleet/drivers/manual/$driverId',
        payload,
      );
      clearCache('/fleet/drivers/manual');
      clearCache('/fleet/summary');
      clearCache('/fleet/summary/analytics');
      return response;
    } on BackendApiException {
      rethrow;
    } catch (error) {
      NetworkStatusService.reportOffline(error.toString());
      await _queueMutation(
        'driver.update',
        'PATCH',
        '/fleet/drivers/manual/$driverId',
        payload,
      );
      return {
        'id': driverId,
        'queued': true,
        'syncState': 'queued',
        ...payload,
      };
    }
  }

  static Future<Map<String, dynamic>> deactivateManualDriver(
    String driverId, {
    required String reason,
  }) async {
    try {
      final response = await _sendJsonRequest(
        'DELETE',
        '/fleet/drivers/manual/$driverId',
        {'reason': reason},
      );
      clearCache('/fleet/drivers/manual');
      clearCache('/fleet/summary');
      clearCache('/fleet/summary/analytics');
      return response;
    } on BackendApiException {
      rethrow;
    } catch (error) {
      NetworkStatusService.reportOffline(error.toString());
      await _queueMutation(
        'driver.deactivate',
        'DELETE',
        '/fleet/drivers/manual/$driverId',
        {'reason': reason},
      );
      rethrow;
    }
  }

  static Future<Map<String, dynamic>> deleteManualDriver(
    String driverId,
  ) async {
    final response = await _sendJsonRequest(
      'DELETE',
      '/fleet/drivers/manual/$driverId/permanent',
      const <String, dynamic>{},
    );
    clearCache('/fleet/drivers/manual');
    clearCache('/fleet/summary');
    clearCache('/fleet/summary/analytics');
    return response;
  }

  static Future<Map<String, dynamic>> pushManualDriverToGeotab(
    String driverId, {
    bool previewOnly = false,
  }) async {
    final response = await _sendJsonRequest(
      'POST',
      '/fleet/drivers/manual/$driverId/push-geotab',
      {'previewOnly': previewOnly},
    );
    clearCache('/fleet/drivers/manual');
    clearCache('/fleet/summary');
    clearCache('/fleet/summary/analytics');
    clearCache('/fleet/geotab/writeback/jobs');
    return response;
  }

  static Future<Map<String, dynamic>> anonymizeManualDriver(
    String driverId, {
    required String reason,
  }) async {
    final response = await _sendJsonRequest(
      'POST',
      '/fleet/drivers/manual/$driverId/anonymize',
      {'reason': reason},
    );
    clearCache('/fleet/drivers/manual');
    clearCache('/fleet/summary');
    clearCache('/fleet/summary/analytics');
    return response;
  }

  static Future<List<Map<String, dynamic>>> getMaintenanceHistory({
    bool forceRefresh = false,
    String vehicle = '',
    String type = '',
    String dateFrom = '',
    String dateTo = '',
  }) async {
    final params = <String, String>{
      if (vehicle.trim().isNotEmpty) 'vehicle': vehicle.trim(),
      if (type.trim().isNotEmpty && type.toLowerCase() != 'all')
        'type': type.trim(),
      if (dateFrom.trim().isNotEmpty) 'dateFrom': dateFrom.trim(),
      if (dateTo.trim().isNotEmpty) 'dateTo': dateTo.trim(),
    };
    final path = params.isEmpty
        ? '/fleet/maintenance/history'
        : '/fleet/maintenance/history?${Uri(queryParameters: params).query}';

    return _getList(
      path,
      cacheTtl: const Duration(minutes: 2),
      forceRefresh: forceRefresh,
    );
  }

  static Future<PaginatedBackendList> getMaintenanceHistoryPage({
    int page = 1,
    int perPage = 25,
    bool forceRefresh = false,
    String vehicle = '',
    String type = '',
    String dateFrom = '',
    String dateTo = '',
  }) {
    final params = <String, String>{
      if (vehicle.trim().isNotEmpty) 'vehicle': vehicle.trim(),
      if (type.trim().isNotEmpty && type.toLowerCase() != 'all')
        'type': type.trim(),
      if (dateFrom.trim().isNotEmpty) 'dateFrom': dateFrom.trim(),
      if (dateTo.trim().isNotEmpty) 'dateTo': dateTo.trim(),
    };
    final path = params.isEmpty
        ? '/fleet/maintenance/history'
        : '/fleet/maintenance/history?${Uri(queryParameters: params).query}';

    return _getListPage(
      path,
      page: page,
      perPage: perPage,
      cacheTtl: const Duration(minutes: 2),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> createMaintenanceHistory(
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest(
      'POST',
      '/fleet/maintenance/history',
      payload,
    );
    clearCache('/fleet/maintenance/history');
    clearCache('/fleet/summary/maintenance');
    clearCache('/fleet/summary');
    return response;
  }

  static Future<Map<String, dynamic>> voidMaintenanceHistory(
    String historyId,
    String reason,
  ) async {
    final response = await _sendJsonRequest(
      'PATCH',
      '/fleet/maintenance/history/$historyId',
      {'voidReason': reason},
    );
    clearCache('/fleet/maintenance/history');
    clearCache('/fleet/summary/maintenance');
    clearCache('/fleet/summary');
    return response;
  }

  static Future<Map<String, dynamic>> updateMaintenanceHistory(
    String historyId,
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest(
      'PATCH',
      '/fleet/maintenance/history/$historyId',
      payload,
    );
    clearCache('/fleet/maintenance/history');
    clearCache('/fleet/summary/maintenance');
    clearCache('/fleet/summary');
    return response;
  }

  static Future<Map<String, dynamic>> pushMaintenanceHistoryToGeotab(
    String historyId, {
    bool previewOnly = false,
  }) async {
    final response = await _sendJsonRequest(
      'POST',
      '/fleet/maintenance/history/$historyId/push-geotab',
      {'previewOnly': previewOnly},
    );
    clearCache('/fleet/maintenance/history');
    clearCache('/fleet/summary/maintenance');
    clearCache('/fleet/summary');
    clearCache('/fleet/geotab/writeback/jobs');
    return response;
  }

  static Future<Map<String, dynamic>> getNotificationPreferences({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/notification-preferences',
      cacheTtl: const Duration(minutes: 5),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> saveNotificationPreferences(
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest(
      'PUT',
      '/fleet/notification-preferences',
      payload,
    );
    clearCache('/fleet/notification-preferences');
    return response;
  }

  static Future<List<Map<String, dynamic>>> getClientAssignments({
    bool forceRefresh = false,
  }) async {
    return _getList(
      '/fleet/client-assignments',
      cacheTtl: const Duration(minutes: 5),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> createClientAssignment(
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest(
      'POST',
      '/fleet/client-assignments',
      payload,
    );
    clearCache('/fleet/client-assignments');
    clearCache('/fleet/summary');
    return response;
  }

  static Future<Map<String, dynamic>> updateClientAssignment(
    String assignmentId,
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest(
      'PATCH',
      '/fleet/client-assignments/$assignmentId',
      payload,
    );
    clearCache('/fleet/client-assignments');
    clearCache('/fleet/summary');
    return response;
  }

  static Future<void> markNotificationRead(String id) async {
    await _postNoBody('/fleet/notifications/$id/read');
    clearCache('/fleet/notifications');
    clearCache('/fleet/summary');
  }

  static Future<void> markAllNotificationsRead() async {
    await _postNoBody('/fleet/notifications/read-all');
    clearCache('/fleet/notifications');
    clearCache('/fleet/summary');
  }

  static Future<void> deleteNotification(String id) async {
    await _delete('/fleet/notifications/$id');
    clearCache('/fleet/notifications');
    clearCache('/fleet/summary');
  }

  static Future<void> clearNotifications() async {
    await _delete('/fleet/notifications');
    clearCache('/fleet/notifications');
    clearCache('/fleet/summary');
  }

  static Future<List<Map<String, dynamic>>> getUnmatchedRoutesReport({
    bool forceRefresh = false,
  }) async {
    return _getList(
      '/fleet/reports/unmatched-routes',
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<List<Map<String, dynamic>>> getDriverCongregationReport({
    bool forceRefresh = false,
  }) async {
    return _getList(
      '/fleet/reports/driver-congregation',
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getVehicleSubscriptionCoverageReport({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/reports/vehicle-subscription-coverage',
      cacheTtl: const Duration(minutes: 5),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getBillingInvoices({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      _pathWithPagination('/billing/invoices', page: 1, perPage: 100),
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getBillingInvoicesPage({
    int page = 1,
    int perPage = 25,
    bool forceRefresh = false,
  }) {
    return _getDataMap(
      _pathWithPagination('/billing/invoices', page: page, perPage: perPage),
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> saveBillingInvoiceReferences(
    String tripId,
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest(
      'PUT',
      '/billing/invoices/$tripId/references',
      payload,
    );
    clearCache('/billing/invoices');
    clearCache('/billing/soa');
    return response;
  }

  static Future<Map<String, dynamic>> createBillingInvoice(
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest(
      'POST',
      '/billing/invoices',
      payload,
    );
    clearCache('/billing/invoices');
    clearCache('/billing/soa');
    clearCache('/fleet/dashboard/summary');
    return response;
  }

  static Future<Map<String, dynamic>> updateBillingInvoice(
    String tripId,
    Map<String, dynamic> payload,
  ) async {
    final response = await _sendJsonRequest(
      'PATCH',
      '/billing/invoices/$tripId',
      payload,
    );
    clearCache('/billing/invoices');
    clearCache('/billing/soa');
    clearCache('/fleet/dashboard/summary');
    return response;
  }

  static Future<Map<String, dynamic>> voidBillingInvoice(
    String tripId,
    String reason,
  ) async {
    final response = await _sendJsonRequest(
      'POST',
      '/billing/invoices/$tripId/void',
      {'reason': reason},
    );
    clearCache('/billing/invoices');
    clearCache('/billing/soa');
    clearCache('/fleet/dashboard/summary');
    return response;
  }

  static Future<Map<String, dynamic>> recalculateInvoice(String tripId) async {
    final response = await _sendJsonRequest(
      'POST',
      '/billing/invoices/$tripId/recalculate',
      const <String, dynamic>{},
    );
    clearCache('/billing/invoices');
    clearCache('/billing/soa');
    clearCache('/fleet/dashboard/summary');
    return response;
  }

  static Future<Map<String, dynamic>> getStatementOfAccounts({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/billing/soa',
      cacheTtl: const Duration(seconds: 30),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getClientTracking(
    String tripId, {
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/client-tracking/$tripId',
      cacheTtl: const Duration(seconds: 15),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getPushConfig({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/push/config',
      cacheTtl: const Duration(minutes: 10),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> getMapsConfig({
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/maps/config',
      cacheTtl: const Duration(minutes: 10),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> suggestDispatchOrder(
    List<Map<String, dynamic>> trips,
  ) async {
    return _sendJsonRequest('POST', '/fleet/dispatch/optimize-order', {
      'trips': trips,
    });
  }

  static Future<Map<String, dynamic>> registerPushSubscription(
    Map<String, dynamic> payload,
  ) async {
    return _sendJsonRequest('POST', '/fleet/push/subscriptions', payload);
  }

  static Future<void> deletePushSubscription(String endpointHash) async {
    await _delete('/fleet/push/subscriptions/$endpointHash');
  }

  static Future<Map<String, dynamic>> getTripMap(
    String tripId, {
    bool forceRefresh = false,
  }) async {
    return _getDataMap(
      '/fleet/trips/$tripId/map',
      cacheTtl: const Duration(seconds: 20),
      forceRefresh: forceRefresh,
    );
  }

  static Future<Map<String, dynamic>> createTrip(
    Map<String, dynamic> payload,
  ) async {
    try {
      final response = await _sendJsonRequest('POST', '/fleet/trips', payload);
      clearCache('/fleet/summary');
      clearCache('/fleet/summary/live');
      clearCache('/fleet/summary/analytics');
      clearCache('/fleet/summary/maintenance');
      clearCache('/fleet/live');
      _replayQueuedMutationsSilently();
      return response;
    } on BackendApiException {
      rethrow;
    } catch (error) {
      NetworkStatusService.reportOffline(error.toString());
      await _queueMutation('trip.create', 'POST', '/fleet/trips', payload);
      return {'queued': true, 'syncState': 'queued', ...payload};
    }
  }

  static Future<Map<String, dynamic>> updateTrip(
    String tripId,
    Map<String, dynamic> payload,
  ) async {
    try {
      final response = await _sendJsonRequest(
        'PATCH',
        '/fleet/trips/$tripId',
        payload,
      );
      clearCache('/fleet/summary');
      clearCache('/fleet/summary/live');
      clearCache('/fleet/summary/analytics');
      clearCache('/fleet/summary/maintenance');
      clearCache('/fleet/live');
      _replayQueuedMutationsSilently();
      return response;
    } on BackendApiException {
      rethrow;
    } catch (error) {
      NetworkStatusService.reportOffline(error.toString());
      await _queueMutation(
        'trip.update',
        'PATCH',
        '/fleet/trips/$tripId',
        payload,
      );
      return {
        'tripId': tripId,
        'queued': true,
        'syncState': 'queued',
        ...payload,
      };
    }
  }

  static Future<Map<String, dynamic>> submitProofOfDelivery(
    String tripId, {
    String? recipientName,
    String? notes,
    String? signatureDataUrl,
    String? status,
    DateTime? deliveredAt,
  }) async {
    final payload = {
      if (recipientName != null && recipientName.trim().isNotEmpty)
        'recipientName': recipientName.trim(),
      if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
      if (signatureDataUrl != null && signatureDataUrl.trim().isNotEmpty)
        'signatureDataUrl': signatureDataUrl.trim(),
      if (status != null && status.trim().isNotEmpty) 'status': status,
      if (deliveredAt != null) 'deliveredAt': deliveredAt.toIso8601String(),
    };

    try {
      final response = await _sendJsonRequest(
        'POST',
        '/fleet/pod/$tripId',
        payload,
      );
      clearCache('/fleet/summary');
      clearCache('/fleet/summary/live');
      clearCache('/fleet/summary/analytics');
      clearCache('/fleet/summary/maintenance');
      clearCache('/fleet/live');
      _replayQueuedMutationsSilently();
      return response;
    } catch (error) {
      NetworkStatusService.reportOffline(error.toString());
      await _queueMutation('pod.submit', 'POST', '/fleet/pod/$tripId', payload);
      return {
        'tripId': tripId,
        'queued': true,
        'syncState': 'queued',
        ...payload,
      };
    }
  }

  static Future<T> loadWithWarmRetry<T>({
    required Future<T> Function(bool forceRefresh) request,
    int attempts = 3,
    Duration retryDelay = const Duration(milliseconds: 550),
  }) async {
    Object? lastError;

    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        return await request(attempt > 0);
      } catch (error) {
        lastError = error;
        if (attempt < attempts - 1) {
          await Future<void>.delayed(
            Duration(milliseconds: retryDelay.inMilliseconds * (attempt + 1)),
          );
        }
      }
    }

    if (lastError is BackendApiException) {
      throw lastError;
    }

    throw BackendApiException(
      lastError?.toString() ?? 'Backend request could not be loaded right now.',
    );
  }

  static Map<String, dynamic>? peekCachedDataMap(String path) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final cached = _cache[normalizedPath];
    final payload = cached?.payload;
    if (payload == null || payload.isEmpty) {
      return null;
    }

    final rawData = payload['data'];
    if (rawData is! Map) {
      return null;
    }

    return rawData.map((key, value) => MapEntry(key.toString(), value));
  }

  static List<Map<String, dynamic>>? peekCachedDataList(String path) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final cached = _cache[normalizedPath];
    final payload = cached?.payload;
    if (payload == null || payload.isEmpty) {
      return null;
    }

    final rawData = payload['data'];
    if (rawData is! List) {
      return null;
    }

    return rawData
        .whereType<Map>()
        .map(
          (item) => item.map((key, value) => MapEntry(key.toString(), value)),
        )
        .cast<Map<String, dynamic>>()
        .toList();
  }

  static Future<void> _postNoBody(String path) async {
    if (_sessionTerminating && !_isAuthPath(path)) {
      throw const BackendApiException(
        'Session is signing out. Please sign in again before making changes.',
      );
    }

    final response = await _sendWithAuthRetry(
      () => http
          .post(Uri.parse('$baseUrl$path'), headers: _headersForJson())
          .timeout(_requestTimeout),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 429) {
        _pausePathFromResponse(path, response);
        throw _rateLimitException(response);
      }

      throw BackendApiException(
        _responseErrorMessage(response),
        statusCode: response.statusCode,
      );
    }
  }

  static Future<Map<String, dynamic>> _sendJsonRequest(
    String method,
    String path,
    Map<String, dynamic> payload, {
    bool allowAuthRetry = true,
  }) async {
    if (_sessionTerminating && !_isAuthPath(path)) {
      throw const BackendApiException(
        'Session is signing out. Please sign in again before making changes.',
      );
    }

    final uri = Uri.parse('$baseUrl$path');
    Future<http.Response> send() {
      return switch (method.toUpperCase()) {
        'PUT' =>
          http
              .put(uri, headers: _headersForJson(), body: jsonEncode(payload))
              .timeout(_requestTimeout),
        'PATCH' =>
          http
              .patch(uri, headers: _headersForJson(), body: jsonEncode(payload))
              .timeout(_requestTimeout),
        'DELETE' =>
          http
              .delete(
                uri,
                headers: _headersForJson(),
                body: jsonEncode(payload),
              )
              .timeout(_requestTimeout),
        _ =>
          http
              .post(uri, headers: _headersForJson(), body: jsonEncode(payload))
              .timeout(_requestTimeout),
      };
    }

    final response = allowAuthRetry
        ? await _sendWithAuthRetry(send)
        : await send();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 429) {
        _pausePathFromResponse(path, response);
        throw _rateLimitException(response);
      }

      throw BackendApiException(
        _responseErrorMessage(response),
        statusCode: response.statusCode,
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const BackendApiException('Unexpected backend response format.');
    }

    if (decoded['success'] != true) {
      throw BackendApiException(
        decoded['message']?.toString() ?? 'Backend request was not successful.',
      );
    }

    final rawData = decoded['data'];
    if (rawData is! Map) {
      throw const BackendApiException('Backend did not return a data object.');
    }

    NetworkStatusService.reportOnline();
    final data = rawData.map((key, value) => MapEntry(key.toString(), value));
    return data;
  }

  static Future<void> _delete(String path) async {
    if (_sessionTerminating && !_isAuthPath(path)) {
      throw const BackendApiException(
        'Session is signing out. Please sign in again before making changes.',
      );
    }

    final response = await _sendWithAuthRetry(
      () => http
          .delete(Uri.parse('$baseUrl$path'), headers: _headersForJson())
          .timeout(_requestTimeout),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 429) {
        _pausePathFromResponse(path, response);
        throw _rateLimitException(response);
      }

      throw BackendApiException(
        _responseErrorMessage(response),
        statusCode: response.statusCode,
      );
    }
  }

  static void clearCache([String? path]) {
    if (path == null || path.isEmpty) {
      _cache.clear();
      return;
    }

    final normalized = path.startsWith('/') ? path : '/$path';
    _cache.removeWhere(
      (key, _) => key == normalized || key.startsWith('$normalized?'),
    );
    _validators.removeWhere(
      (key, _) => key == normalized || key.startsWith('$normalized?'),
    );
  }

  static void _reportOfflineForTransportError(Object error) {
    if (error is! BackendApiException) {
      NetworkStatusService.reportOffline(error.toString());
    }
  }

  static void _clearClientRelatedCaches() {
    _cache.removeWhere((key, _) => key.startsWith('/fleet/clients'));
    _validators.removeWhere((key, _) => key.startsWith('/fleet/clients'));
    clearCache('/fleet/clients');
    clearCache('/fleet/summary');
    clearCache('/fleet/dashboard/summary');
    clearCache('/fleet/trips');
    clearCache('/billing/invoices');
    clearCache('/billing/soa');
  }

  static void _clearManagedUserCaches() {
    _cache.removeWhere((key, _) => key.startsWith('/fleet/users'));
    _validators.removeWhere((key, _) => key.startsWith('/fleet/users'));
  }

  static Future<List<Map<String, dynamic>>> _getList(
    String path, {
    Duration? cacheTtl,
    bool forceRefresh = false,
  }) async {
    final page = await _getListPage(
      path,
      page: 1,
      perPage: 100,
      cacheTtl: cacheTtl,
      forceRefresh: forceRefresh,
    );

    return page.items;
  }

  static Future<PaginatedBackendList> _getListPage(
    String path, {
    required int page,
    required int perPage,
    Duration? cacheTtl,
    bool forceRefresh = false,
  }) async {
    final pagedPath = _pathWithPagination(path, page: page, perPage: perPage);
    final decoded = await _getDecodedResponse(
      pagedPath,
      cacheTtl: cacheTtl,
      forceRefresh: forceRefresh,
    );
    final rawData = decoded['data'];
    if (rawData is! List) {
      throw const BackendApiException('Backend did not return a data list.');
    }

    final items = rawData
        .whereType<Map>()
        .map(
          (item) => item.map((key, value) => MapEntry(key.toString(), value)),
        )
        .cast<Map<String, dynamic>>()
        .toList();
    final pagination = decoded['meta'] is Map
        ? (decoded['meta'] as Map)['pagination']
        : null;

    return PaginatedBackendList(
      items: items,
      total: _paginationInt(pagination, 'total', items.length),
      currentPage: _paginationInt(pagination, 'currentPage', page),
      lastPage: _paginationInt(pagination, 'lastPage', page),
      perPage: _paginationInt(pagination, 'perPage', perPage),
      nextPage: _paginationNullableInt(pagination, 'nextPage'),
      previousPage: _paginationNullableInt(pagination, 'previousPage'),
    );
  }

  static Future<Map<String, dynamic>> _getDataMap(
    String path, {
    Duration? cacheTtl,
    bool forceRefresh = false,
  }) async {
    final decoded = await _getDecodedResponse(
      path,
      cacheTtl: cacheTtl,
      forceRefresh: forceRefresh,
    );
    final rawData = decoded['data'];
    if (rawData is! Map) {
      throw const BackendApiException('Backend did not return a data object.');
    }

    return rawData.map((key, value) => MapEntry(key.toString(), value));
  }

  static Future<Map<String, dynamic>> _getDecodedResponse(
    String path, {
    Duration? cacheTtl,
    bool forceRefresh = false,
  }) async {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final ttl = cacheTtl ?? _defaultCacheTtl;
    final cached = _cache[normalizedPath];
    final now = DateTime.now();
    final pausedUntil = _pauseUntilForPath(normalizedPath);

    if (!forceRefresh && cached != null && cached.payload.isNotEmpty) {
      if (!cached.expiresAt.isAfter(now) && pausedUntil == null) {
        _refreshDecodedResponseInBackground(normalizedPath, ttl);
      }
      return cached.payload;
    }

    if (pausedUntil != null) {
      final persisted = await _loadPersistedResponse(normalizedPath);
      if (!forceRefresh && persisted != null && persisted.payload.isNotEmpty) {
        final decorated = _decorateRecoveredPayload(
          persisted.payload,
          normalizedPath,
          'Backend asked this endpoint to retry after ${pausedUntil.difference(now).inSeconds}s.',
          persistedAt: persisted.persistedAt,
          expiredByTtl: persisted.isExpired,
        );
        _cache[normalizedPath] = _CachedBackendResponse(
          payload: decorated,
          expiresAt: pausedUntil,
          storedAt: persisted.persistedAt ?? DateTime.now(),
        );
        return decorated;
      }

      throw BackendApiException(
        'This endpoint is cooling down after too many requests.',
        statusCode: 429,
        retryAfter: pausedUntil.difference(now),
      );
    }

    final existing = _inflightGets[normalizedPath];
    if (existing != null) {
      return existing;
    }

    if (!forceRefresh) {
      final persisted = await _loadPersistedResponse(normalizedPath);
      if (persisted != null && persisted.payload.isNotEmpty) {
        final decorated = _decorateRecoveredPayload(
          persisted.payload,
          normalizedPath,
          'Refreshing cached data in the background.',
          persistedAt: persisted.persistedAt,
          expiredByTtl: true,
        );
        _cache[normalizedPath] = _CachedBackendResponse(
          payload: decorated,
          expiresAt: DateTime.fromMillisecondsSinceEpoch(0),
          storedAt: persisted.persistedAt ?? DateTime.now(),
        );
        _refreshDecodedResponseInBackground(normalizedPath, ttl);
        return decorated;
      }
    }

    final future = _fetchDecodedResponse(normalizedPath, ttl);
    _inflightGets[normalizedPath] = future;

    try {
      return await future;
    } catch (error) {
      _reportOfflineForTransportError(error);
      final persisted = await _loadPersistedResponse(normalizedPath);
      if (!forceRefresh && persisted != null) {
        final decorated = _decorateRecoveredPayload(
          persisted.payload,
          normalizedPath,
          error.toString(),
          persistedAt: persisted.persistedAt,
          expiredByTtl: persisted.isExpired,
        );
        _cache[normalizedPath] = _CachedBackendResponse(
          payload: decorated,
          expiresAt: DateTime.now().add(ttl),
          storedAt: persisted.persistedAt ?? DateTime.now(),
        );
        return decorated;
      }

      if (cached != null && cached.payload.isNotEmpty) {
        _reportOfflineForTransportError(error);
        return cached.payload;
      }

      if (error is BackendApiException) {
        rethrow;
      }

      throw BackendApiException(
        'Backend request failed before a safe response could be loaded.',
      );
    } finally {
      _inflightGets.remove(normalizedPath);
    }
  }

  static Future<Map<String, dynamic>> _fetchDecodedResponse(
    String path,
    Duration cacheTtl,
  ) async {
    if (_sessionTerminating) {
      throw const BackendApiException(
        'Session is signing out. Please sign in again.',
      );
    }

    Object? lastError;
    final maxAttempts = _maxAttemptsForPath(path);

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final response = await _sendWithAuthRetry(
          () => http
              .get(Uri.parse('$baseUrl$path'), headers: _headersForGet(path))
              .timeout(_timeoutForPath(path)),
        );

        if (response.statusCode < 200 || response.statusCode >= 300) {
          if (response.statusCode == 304) {
            final cached = _cache[path];
            if (cached != null && cached.payload.isNotEmpty) {
              _cache[path] = cached.copyWith(
                expiresAt: DateTime.now().add(cacheTtl),
                storedAt: DateTime.now(),
              );
              NetworkStatusService.reportOnline();

              return cached.payload;
            }

            final persisted = await _loadPersistedResponse(path);
            if (persisted != null && persisted.payload.isNotEmpty) {
              _cache[path] = _CachedBackendResponse(
                payload: persisted.payload,
                expiresAt: DateTime.now().add(cacheTtl),
                storedAt: DateTime.now(),
              );
              NetworkStatusService.reportOnline();

              return persisted.payload;
            }
          }

          if (response.statusCode == 429) {
            _pausePathFromResponse(path, response);
            throw _rateLimitException(response);
          }

          throw BackendApiException(
            _responseErrorMessage(response),
            statusCode: response.statusCode,
          );
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) {
          throw const BackendApiException(
            'Unexpected backend response format.',
          );
        }

        if (decoded['success'] != true) {
          throw BackendApiException(
            decoded['message']?.toString() ??
                'Backend request was not successful.',
          );
        }

        final protectedPayload = await _recoverUsefulPayloadForDegradedResponse(
          path,
          decoded,
        );
        if (protectedPayload != null) {
          NetworkStatusService.reportOffline(
            'Backend returned a degraded empty snapshot.',
          );
          return protectedPayload;
        }

        _cache[path] = _CachedBackendResponse(
          payload: decoded,
          expiresAt: DateTime.now().add(cacheTtl),
          storedAt: DateTime.now(),
        );
        _storeValidator(path, response);
        NetworkStatusService.reportOnline();
        unawaited(_persistDecodedResponse(path, decoded));
        unawaited(
          LocalFleetMirrorService.mirrorResponse(path, decoded).catchError((
            error,
          ) {
            if (!kReleaseMode) {
              debugPrint('[pioneerpath][mirror] write failed: $error');
            }
          }),
        );
        _replayQueuedMutationsSilently();

        return decoded;
      } catch (error) {
        lastError = error;
        if (error is BackendApiException && error.statusCode == 429) {
          break;
        }
        if (attempt < maxAttempts - 1) {
          await Future<void>.delayed(_retryDelayForPath(path, attempt));
        }
      }
    }

    if (lastError is BackendApiException) {
      throw lastError;
    }

    throw const BackendApiException(
      'Backend request could not be loaded right now.',
    );
  }

  static void _refreshDecodedResponseInBackground(String path, Duration ttl) {
    if (_inflightGets.containsKey(path)) {
      return;
    }

    final future = _fetchDecodedResponse(path, ttl);
    _inflightGets[path] = future;
    future
        .catchError((_) {
          return <String, dynamic>{};
        })
        .whenComplete(() {
          _inflightGets.remove(path);
        });
  }
}

int _maxAttemptsForPath(String path) {
  if (path.startsWith('/fleet/telemetry/assets/')) {
    return 3;
  }

  if (_isFastLanePath(path)) {
    return 3;
  }

  return 2;
}

Duration _timeoutForPath(String path) {
  if (_isFastLanePath(path)) {
    return const Duration(seconds: 4);
  }

  if (path == '/vehicles' || path == '/fleet/summary') {
    return const Duration(seconds: 7);
  }

  if (path.startsWith('/fleet/telemetry/assets/')) {
    return const Duration(seconds: 12);
  }

  return BackendApiService._requestTimeout;
}

Duration _retryDelayForPath(String path, int attempt) {
  if (_isFastLanePath(path)) {
    return Duration(milliseconds: 180 * (attempt + 1));
  }

  return const Duration(milliseconds: 350);
}

bool _isFastLanePath(String path) {
  return path == '/fleet/live' ||
      path == '/fleet/summary/live' ||
      path == '/vehicles/locations';
}

bool _isAuthPath(String path) {
  final normalized = path.startsWith('/') ? path : '/$path';
  return normalized.startsWith('/fleet/auth/') ||
      normalized == '/fleet/users/login-check';
}

String _pathWithPagination(
  String path, {
  required int page,
  required int perPage,
}) {
  final normalized = path.startsWith('/') ? path : '/$path';
  final uri = Uri.parse(normalized);
  final query = Map<String, String>.from(uri.queryParameters);
  query.putIfAbsent('page', () => page.clamp(1, 1 << 31).toString());
  query.putIfAbsent('perPage', () => perPage.clamp(1, 100).toString());
  return uri.replace(queryParameters: query).toString();
}

int _paginationInt(dynamic pagination, String key, int fallback) {
  if (pagination is! Map) {
    return fallback;
  }

  final camel = pagination[key];
  final snake = pagination[_camelToSnake(key)];
  return int.tryParse((camel ?? snake ?? '').toString()) ?? fallback;
}

int? _paginationNullableInt(dynamic pagination, String key) {
  if (pagination is! Map) {
    return null;
  }

  final camel = pagination[key];
  final snake = pagination[_camelToSnake(key)];
  return int.tryParse((camel ?? snake ?? '').toString());
}

String _camelToSnake(String value) {
  return value
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (match) => '${match.group(1)}_${match.group(2)}',
      )
      .toLowerCase();
}

Map<String, String> _headersForGet(String path) {
  final validator = BackendApiService._validators[path];
  return {
    ..._headersForJson(),
    if (validator?.etag?.trim().isNotEmpty == true)
      'If-None-Match': validator!.etag!.trim(),
    if (validator?.lastModified?.trim().isNotEmpty == true)
      'If-Modified-Since': validator!.lastModified!.trim(),
  };
}

Map<String, String> _headersForJson() {
  final token = BackendApiService._accessToken;
  return {
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    if (token != null && token.trim().isNotEmpty)
      'Authorization': 'Bearer ${token.trim()}',
  };
}

Future<http.Response> _sendWithAuthRetry(
  Future<http.Response> Function() send,
) async {
  var response = await send();
  if (response.statusCode != 401) {
    return response;
  }

  final refresh = BackendApiService._refreshAuthHandler;
  final refreshed = refresh == null ? false : await refresh();
  if (refreshed) {
    response = await send();
  }

  if (response.statusCode == 401) {
    BackendApiService._sessionExpiredHandler?.call();
  }

  return response;
}

String _responseErrorMessage(http.Response response) {
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map && decoded['message'] != null) {
      return '${response.statusCode}: ${decoded['message']}';
    }
  } catch (_) {}

  return 'Request failed with status ${response.statusCode}.';
}

BackendApiException _rateLimitException(http.Response response) {
  final retryAfter = _retryAfterForResponse(response);
  var category = '';
  var message = _responseErrorMessage(response);

  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map) {
      category = decoded['category']?.toString() ?? '';
      message = decoded['message']?.toString() ?? message;
    }
  } catch (_) {}

  return BackendApiException(
    message,
    statusCode: 429,
    retryAfter: retryAfter,
    category: category.isEmpty ? null : category,
  );
}

Duration _retryAfterForResponse(http.Response response) {
  final header = response.headers['retry-after'];
  final seconds = int.tryParse((header ?? '').trim());
  if (seconds != null && seconds > 0) {
    return Duration(seconds: seconds.clamp(1, 300));
  }

  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map) {
      final bodySeconds = int.tryParse((decoded['retryAfter'] ?? '').toString());
      if (bodySeconds != null && bodySeconds > 0) {
        return Duration(seconds: bodySeconds.clamp(1, 300));
      }
    }
  } catch (_) {}

  return const Duration(seconds: 10);
}

DateTime? _pauseUntilForPath(String path) {
  final pauseUntil = BackendApiService._pausedUntil[path];
  if (pauseUntil == null) {
    return null;
  }

  if (!pauseUntil.isAfter(DateTime.now())) {
    BackendApiService._pausedUntil.remove(path);
    return null;
  }

  return pauseUntil;
}

void _pausePathFromResponse(String path, http.Response response) {
  final normalized = path.startsWith('/') ? path : '/$path';
  BackendApiService._pausedUntil[normalized] = DateTime.now().add(
    _retryAfterForResponse(response),
  );
}

void _storeValidator(String path, http.Response response) {
  final etag = response.headers['etag']?.trim();
  final lastModified = response.headers['last-modified']?.trim();
  final validator = _HttpCacheValidator(
    etag: etag == null || etag.isEmpty ? null : etag,
    lastModified: lastModified == null || lastModified.isEmpty
        ? null
        : lastModified,
  );

  if (validator.isEmpty) {
    BackendApiService._validators.remove(path);
    return;
  }

  BackendApiService._validators[path] = validator;
}

class _CachedBackendResponse {
  const _CachedBackendResponse({
    required this.payload,
    required this.expiresAt,
    required this.storedAt,
  });

  final Map<String, dynamic> payload;
  final DateTime expiresAt;
  final DateTime storedAt;

  _CachedBackendResponse copyWith({
    Map<String, dynamic>? payload,
    DateTime? expiresAt,
    DateTime? storedAt,
  }) {
    return _CachedBackendResponse(
      payload: payload ?? this.payload,
      expiresAt: expiresAt ?? this.expiresAt,
      storedAt: storedAt ?? this.storedAt,
    );
  }
}

class _HttpCacheValidator {
  const _HttpCacheValidator({this.etag, this.lastModified});

  final String? etag;
  final String? lastModified;

  bool get isEmpty =>
      (etag == null || etag!.trim().isEmpty) &&
      (lastModified == null || lastModified!.trim().isEmpty);

  Map<String, dynamic> toJson() {
    return {
      if (etag != null && etag!.trim().isNotEmpty) 'etag': etag,
      if (lastModified != null && lastModified!.trim().isNotEmpty)
        'lastModified': lastModified,
    };
  }

  static _HttpCacheValidator? fromJson(dynamic value) {
    if (value is! Map) {
      return null;
    }

    final validator = _HttpCacheValidator(
      etag: value['etag']?.toString(),
      lastModified: value['lastModified']?.toString(),
    );

    return validator.isEmpty ? null : validator;
  }
}

const Set<String> _persistedPaths = {
  '/fleet/summary',
  '/fleet/dashboard',
  '/fleet/dashboard/summary',
  '/fleet/routes',
  '/fleet/zones',
  '/fleet/summary/analytics',
  '/fleet/summary/maintenance',
  '/fleet/maintenance/predictions',
  '/fleet/analytics/driver-performance',
  '/fleet/analytics/vehicle-health',
  '/fleet/analytics/route-efficiency',
  '/fleet/analytics/trip-forecast',
  '/fleet/analytics/fuel-trend',
  '/fleet/telemetry',
  '/fleet/telemetry/assets/',
  '/fleet/temperature',
  '/fleet/fuel',
  '/fleet/fuel/transactions',
  '/fleet/energy/charges',
  '/fleet/settings/fuel-prices',
  '/fleet/maintenance',
  '/fleet/maintenance/history',
  '/fleet/notifications',
  '/fleet/clients',
  '/fleet/drivers/manual',
  '/fleet/client-assignments',
  '/fleet/trips/',
  '/fleet/client-tracking/',
  '/fleet/geotab/writeback/jobs',
  '/billing/invoices',
  '/billing/soa',
};

Future<void> _hydratePersistedCaches() async {
  final paths = _persistedPaths.where((path) => !path.endsWith('/')).toList();
  final rawResponses = await OfflineSyncService.loadResponses(paths);
  for (final entry in rawResponses.entries) {
    final persisted = _persistedResponseFromRaw(entry.key, entry.value);
    if (persisted.payload.isEmpty) {
      continue;
    }

    BackendApiService._cache[entry.key] = _CachedBackendResponse(
      payload: persisted.payload,
      expiresAt: DateTime.now().add(_ttlForPath(entry.key)),
      storedAt: persisted.persistedAt ?? DateTime.now(),
    );
  }
}

Future<void> _persistDecodedResponse(
  String path,
  Map<String, dynamic> decoded,
) async {
  if (!_shouldPersistPath(path) || decoded.isEmpty) {
    return;
  }

  await OfflineSyncService.storeResponse(path, <String, dynamic>{
    '__persistedEnvelopeV2': true,
    'persistedAt': DateTime.now().toIso8601String(),
    if (BackendApiService._validators[path] != null)
      'validator': BackendApiService._validators[path]!.toJson(),
    'payload': decoded,
  });

  final basePath = path.split('?').first;
  if (basePath != path && _shouldPersistPath(basePath)) {
    await OfflineSyncService.storeResponse(basePath, <String, dynamic>{
      '__persistedEnvelopeV2': true,
      'persistedAt': DateTime.now().toIso8601String(),
      if (BackendApiService._validators[path] != null)
        'validator': BackendApiService._validators[path]!.toJson(),
      'payload': decoded,
    });
  }
}

Future<_PersistedResponseResult?> _loadPersistedResponse(String path) async {
  if (!_shouldPersistPath(path)) {
    return null;
  }

  final raw =
      await OfflineSyncService.loadResponse(path) ??
      (path.contains('?')
          ? await OfflineSyncService.loadResponse(path.split('?').first)
          : null);
  if (raw == null || raw.isEmpty) {
    return null;
  }

  return _persistedResponseFromRaw(path, raw);
}

Future<Map<String, dynamic>?> _recoverUsefulPayloadForDegradedResponse(
  String path,
  Map<String, dynamic> decoded,
) async {
  if (!_isDegradedEmptyFleetPayload(path, decoded)) {
    return null;
  }

  final cached = BackendApiService._cache[path];
  if (cached != null && _hasUsefulFleetPayload(path, cached.payload)) {
    return cached.payload;
  }

  final persisted = await _loadPersistedResponse(path);
  if (persisted != null && _hasUsefulFleetPayload(path, persisted.payload)) {
    return _decorateRecoveredPayload(
      persisted.payload,
      path,
      'Backend returned a degraded empty snapshot.',
      persistedAt: persisted.persistedAt,
      expiredByTtl: true,
    );
  }

  return null;
}

bool _isDegradedEmptyFleetPayload(String path, Map<String, dynamic> decoded) {
  if (!_shouldPersistPath(path)) {
    return false;
  }

  final data = decoded['data'];
  final normalizedData = data is Map
      ? data.map((key, value) => MapEntry(key.toString(), value))
      : const <String, dynamic>{};
  final meta = decoded['meta'] is Map
      ? (decoded['meta'] as Map).map(
          (key, value) => MapEntry(key.toString(), value),
        )
      : const <String, dynamic>{};
  final degraded =
      normalizedData['stale'] == true ||
      normalizedData['refreshing'] == true ||
      normalizedData['syncState'] == 'stale' ||
      normalizedData['syncState'] == 'offline_cached' ||
      normalizedData['geotabAvailable'] == false ||
      normalizedData['geotab_available'] == false ||
      normalizedData['geotabReason'] == 'snapshot_unavailable' ||
      normalizedData['geotab_reason'] == 'snapshot_unavailable' ||
      normalizedData['lastError'] != null ||
      meta['servedFrom'] == 'stale_snapshot' ||
      meta['servedFrom'] == 'offline_cached' ||
      meta['geotab_available'] == false ||
      meta['geotabAvailable'] == false ||
      meta['reason'] == 'snapshot_unavailable' ||
      meta['geotabReason'] == 'snapshot_unavailable';

  if (!degraded) {
    return false;
  }

  if (path.split('?').first == '/fleet/dashboard/summary') {
    return data is Map && !_dashboardSummaryHasOperationalData(normalizedData);
  }

  return _fleetPayloadDataIsEmpty(data);
}

bool _hasUsefulFleetPayload(String path, Map<String, dynamic> decoded) {
  final data = decoded['data'];
  if (path.split('?').first == '/fleet/dashboard/summary') {
    if (data is! Map) {
      return false;
    }

    return _dashboardSummaryHasOperationalData(
      data.map((key, value) => MapEntry(key.toString(), value)),
    );
  }

  return !_fleetPayloadDataIsEmpty(data);
}

bool _fleetPayloadDataIsEmpty(Object? data) {
  if (data == null) {
    return true;
  }

  if (data is List) {
    return data.isEmpty;
  }

  if (data is Map) {
    final normalized = data.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    final businessEntries = normalized.entries.where(
      (entry) => !_metadataOnlyPayloadKeys.contains(entry.key),
    );
    if (businessEntries.isEmpty) {
      return true;
    }

    return businessEntries.every((entry) {
      final value = entry.value;
      if (value == null) {
        return true;
      }
      if (value is List || value is Map) {
        return _fleetPayloadDataIsEmpty(value);
      }
      if (value is num) {
        return value == 0;
      }
      if (value is String) {
        return value.trim().isEmpty;
      }
      if (value is bool) {
        return false;
      }
      return false;
    });
  }

  return false;
}

const Set<String> _metadataOnlyPayloadKeys = {
  'generatedAt',
  'cacheTtlSeconds',
  'stale',
  'refreshing',
  'syncState',
  'lastError',
  'lastSyncedAt',
  'lastUpdated',
  'persistedAt',
  'persistedAgeMs',
  'persistedStale',
  'servedFrom',
  'geotabAvailable',
  'geotab_available',
  'geotabReason',
  'geotab_reason',
  'reason',
};

bool _dashboardSummaryHasOperationalData(Map<String, dynamic> data) {
  if (_mapNumber(data['fleetUtilization'], 'totalVehicles') > 0 ||
      _mapNumber(data['fleetUtilization'], 'activeVehiclesToday') > 0) {
    return true;
  }

  if (_mapNumber(data['monthAtGlance'], 'completed') > 0 ||
      _mapNumber(data['monthAtGlance'], 'distanceKm') > 0 ||
      _mapNumber(data['monthAtGlance'], 'invoiced') > 0 ||
      _mapNumber(data['recentRevenueSummary'], 'thisWeek') > 0 ||
      _mapNumber(data['recentRevenueSummary'], 'lastWeek') > 0 ||
      _mapNumber(data['humidityAlertCount'], 'count') > 0) {
    return true;
  }

  if (_listHasItems(data['topActiveVehicles']) ||
      _listHasItems(data['recentTrips']) ||
      _listHasItems(data['predictiveMaintenance'])) {
    return true;
  }

  final tripsThisWeek = data['tripsThisWeek'];
  if (tripsThisWeek is List) {
    return tripsThisWeek.any(
      (bucket) =>
          bucket is Map &&
          (_numberValue(bucket['count']) > 0 ||
              _numberValue(bucket['trips']) > 0),
    );
  }

  return false;
}

bool _listHasItems(Object? value) => value is List && value.isNotEmpty;

double _mapNumber(Object? value, String key) {
  if (value is! Map) {
    return 0;
  }

  return _numberValue(value[key]);
}

double _numberValue(Object? value) {
  if (value is num) {
    return value.toDouble();
  }

  if (value is String) {
    return double.tryParse(value.replaceAll(',', '').trim()) ?? 0;
  }

  return 0;
}

_PersistedResponseResult _persistedResponseFromRaw(
  String path,
  Map<String, dynamic> raw,
) {
  DateTime? persistedAt;
  Map<String, dynamic> payload;

  if (raw['__persistedEnvelopeV2'] == true && raw['payload'] is Map) {
    persistedAt = DateTime.tryParse(raw['persistedAt']?.toString() ?? '');
    payload = (raw['payload'] as Map).map(
      (key, value) => MapEntry(key.toString(), value),
    );
    final validator = _HttpCacheValidator.fromJson(raw['validator']);
    if (validator != null) {
      BackendApiService._validators[path] = validator;
    }
  } else {
    payload = raw;
  }

  final isExpired = _isPersistedResponseExpired(path, persistedAt);
  return _PersistedResponseResult(
    payload: payload,
    persistedAt: persistedAt,
    isExpired: isExpired,
  );
}

bool _shouldPersistPath(String path) {
  final basePath = path.split('?').first;
  if (_persistedPaths.contains(path) || _persistedPaths.contains(basePath)) {
    return true;
  }

  return _persistedPaths.any(
    (candidate) =>
        candidate.endsWith('/') &&
        (path.startsWith(candidate) || basePath.startsWith(candidate)),
  );
}

Map<String, dynamic> _decorateRecoveredPayload(
  Map<String, dynamic> decoded,
  String path,
  String lastError, {
  DateTime? persistedAt,
  bool expiredByTtl = false,
}) {
  if (decoded['data'] is! Map) {
    return decoded;
  }

  final data = Map<String, dynamic>.from(decoded['data'] as Map);
  data['stale'] = true;
  data['syncState'] = expiredByTtl ? 'stale' : 'offline_cached';
  data['lastError'] = lastError;
  if (persistedAt != null) {
    data['persistedAt'] = persistedAt.toIso8601String();
    data['persistedAgeMs'] = DateTime.now()
        .difference(persistedAt)
        .inMilliseconds;
  }
  data['persistedStale'] = expiredByTtl;
  if (!data.containsKey('lastSyncedAt')) {
    data['lastSyncedAt'] = DateTime.now().toIso8601String();
  }

  return {...decoded, 'data': data, 'path': path};
}

bool _isPersistedResponseExpired(String path, DateTime? persistedAt) {
  if (!path.startsWith('/fleet/telemetry/assets/')) {
    return false;
  }

  if (persistedAt == null) {
    return true;
  }

  return DateTime.now().difference(persistedAt) > const Duration(minutes: 5);
}

class _PersistedResponseResult {
  const _PersistedResponseResult({
    required this.payload,
    required this.persistedAt,
    required this.isExpired,
  });

  final Map<String, dynamic> payload;
  final DateTime? persistedAt;
  final bool isExpired;
}

Future<void> _queueMutation(
  String type,
  String method,
  String path,
  Map<String, dynamic> payload,
) async {
  await OfflineSyncService.queueMutation({
    'id': '${DateTime.now().microsecondsSinceEpoch}::$type::$path',
    'type': type,
    'method': method,
    'path': path,
    'payload': payload,
    'queuedAt': DateTime.now().toIso8601String(),
  });
}

Future<void> _replayQueuedMutationsInternal() async {
  final queue = await OfflineSyncService.loadMutationQueue();
  if (queue.isEmpty) {
    return;
  }

  final remaining = <Map<String, dynamic>>[];
  for (final mutation in queue) {
    final method = mutation['method']?.toString() ?? 'POST';
    final path = mutation['path']?.toString() ?? '';
    final payload = mutation['payload'];
    if (path.isEmpty || payload is! Map) {
      continue;
    }

    final body = payload.map((key, value) => MapEntry(key.toString(), value));
    try {
      await BackendApiService._sendJsonRequest(method, path, body);
      BackendApiService.clearCache('/fleet/summary');
      BackendApiService.clearCache('/fleet/summary/live');
      BackendApiService.clearCache('/fleet/summary/analytics');
      BackendApiService.clearCache('/fleet/summary/maintenance');
      BackendApiService.clearCache('/fleet/live');
      BackendApiService.clearCache('/fleet/drivers/manual');
    } catch (_) {
      remaining.add(mutation);
    }
  }

  await OfflineSyncService.replaceMutationQueue(remaining);
}

void _replayQueuedMutationsSilently() {
  unawaited(BackendApiService.replayQueuedMutations().catchError((_) {}));
}

Duration _ttlForPath(String path) {
  switch (path.split('?').first) {
    case '/fleet/live':
    case '/fleet/summary/live':
      return BackendApiService._liveLocationCacheTtl;
    case '/fleet/summary/analytics':
    case '/fleet/analytics/driver-performance':
    case '/fleet/analytics/vehicle-health':
    case '/fleet/analytics/route-efficiency':
    case '/fleet/analytics/fuel-trend':
      return const Duration(minutes: 10);
    case '/fleet/maintenance/predictions':
    case '/fleet/analytics/trip-forecast':
      return const Duration(hours: 1);
    case '/fleet/summary/maintenance':
      return const Duration(minutes: 5);
    case '/fleet/dashboard/summary':
      return const Duration(seconds: 120);
    default:
      return BackendApiService._defaultCacheTtl;
  }
}
