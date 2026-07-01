import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart';

import '../services/backend_api.dart';
import '../services/external_link_service.dart';
import '../services/fleet_sync_service.dart';
import '../services/google_map_marker_factory.dart';
import '../services/live_tracking_motion_math.dart';
import '../services/realtime_stream_service.dart';
import '../services/trips_store.dart';
import '../services/vehicles_store.dart';
import '../theme/app_theme.dart';
import '../widgets/dashboard_layout.dart';
import '../widgets/page_skeletons.dart';
import '../widgets/pioneer_google_map.dart';

class LiveTrackingPageEnhanced extends StatefulWidget {
  const LiveTrackingPageEnhanced({super.key});

  @override
  State<LiveTrackingPageEnhanced> createState() =>
      _LiveTrackingPageEnhancedState();
}

enum _MarkerZoomTier { regional, street, close }

class _LiveTrackingPageEnhancedState extends State<LiveTrackingPageEnhanced>
    with TickerProviderStateMixin {
  static const LatLng _defaultCenter = LatLng(14.5995, 120.9842);

  gmaps.GoogleMapController? _mapController;
  late final AnimationController _pulseController;
  late final Ticker _motionTicker;
  final ValueNotifier<int> _motionFrame = ValueNotifier<int>(0);
  Timer? _updateTimer;
  Timer? _boundsRefreshDebounce;
  final Map<String, _MarkerMotionState> _markerMotionStates = {};
  bool _isFollowingSelected = false;
  DateTime? _lastFollowMoveAt;
  double _currentMapZoom = 10.0;
  double _trackingSidebarWidth = 420.0;
  gmaps.LatLngBounds? _visibleBounds;
  Offset? _selectedPulseOffset;
  DateTime? _lastPulseProjectionAt;
  gmaps.BitmapDescriptor? _movingMarkerIcon;
  gmaps.BitmapDescriptor? _idleMarkerIcon;
  gmaps.BitmapDescriptor? _offlineMarkerIcon;
  gmaps.BitmapDescriptor? _staleMarkerIcon;
  gmaps.BitmapDescriptor? _selectedMovingMarkerIcon;
  gmaps.BitmapDescriptor? _selectedIdleMarkerIcon;
  gmaps.BitmapDescriptor? _selectedOfflineMarkerIcon;
  gmaps.BitmapDescriptor? _selectedStaleMarkerIcon;
  gmaps.BitmapDescriptor? _compactMovingMarkerIcon;
  gmaps.BitmapDescriptor? _compactIdleMarkerIcon;
  gmaps.BitmapDescriptor? _compactOfflineMarkerIcon;
  gmaps.BitmapDescriptor? _compactStaleMarkerIcon;
  gmaps.BitmapDescriptor? _selectedCompactMovingMarkerIcon;
  gmaps.BitmapDescriptor? _selectedCompactIdleMarkerIcon;
  gmaps.BitmapDescriptor? _selectedCompactOfflineMarkerIcon;
  gmaps.BitmapDescriptor? _selectedCompactStaleMarkerIcon;
  gmaps.BitmapDescriptor? _largeMovingMarkerIcon;
  gmaps.BitmapDescriptor? _largeIdleMarkerIcon;
  gmaps.BitmapDescriptor? _largeOfflineMarkerIcon;
  gmaps.BitmapDescriptor? _largeStaleMarkerIcon;
  gmaps.BitmapDescriptor? _selectedLargeMovingMarkerIcon;
  gmaps.BitmapDescriptor? _selectedLargeIdleMarkerIcon;
  gmaps.BitmapDescriptor? _selectedLargeOfflineMarkerIcon;
  gmaps.BitmapDescriptor? _selectedLargeStaleMarkerIcon;
  final Map<String, gmaps.BitmapDescriptor> _zoneLabelIconCache = {};

  bool _isLoading = true;
  String? _errorMessage;
  String selectedPlate = '';
  String? _pendingPlateArg;
  List<LatLng> _selectedTrail = const [];
  List<Map<String, dynamic>> _zoneOverlays = const [];
  DateTime? _lastLiveSyncAt;
  int _pollTick = 0;
  int _loadFailureCount = 0;
  bool _showTrafficLayer = true;
  bool _showWeatherContext = true;
  bool _showTrafficEta = true;
  bool _showRoutePath = true;
  bool _showVehicleTrail = true;
  bool _showZoneOverlays = true;
  bool _showPredictiveContext = true;
  bool _showMapIntelligencePanel = false;
  bool _sidebarRouteOrdersExpanded = false;
  bool _sidebarFleetStatusExpanded = false;
  bool _sidebarVehiclesExpanded = true;
  bool _sidebarCollapsed = false;
  PioneerMapMarkerStyle? _sidebarStatusFilter;
  gmaps.MapType _mapType = gmaps.MapType.normal;
  late final DateTime _launchedAt;
  static const Duration _livePollInterval = Duration(seconds: 30);
  static const Duration _pollAlignedLerpDuration = Duration(seconds: 29);
  static const Duration _accelerationDuration = Duration(milliseconds: 1200);
  static const Duration _decelerationDuration = Duration(milliseconds: 1500);
  static const Duration _dataStaleThreshold = Duration(minutes: 5);
  static const Duration _followMoveThrottle = Duration(milliseconds: 220);
  static const double _stationarySpeedThresholdKph = 2.0;
  static const double _bearingCorrectionThresholdDegrees = 5.0;
  static const Duration _markerRenderDelay = Duration(milliseconds: 900);
  static const Duration _freeDriveProjectionLimit = Duration(seconds: 18);
  static const double _roadLockToleranceMeters = 80.0;
  static const double _viewportBufferFraction = 0.20;
  static const double _compactMarkerZoomThreshold = 12.0;
  static const double _closeMarkerZoomThreshold = 16.0;
  static const double _trackingSidebarCollapsedWidth = 54.0;
  static const double _trackingSidebarMinWidth = 360.0;
  static const double _trackingSidebarMaxWidth = 560.0;

  bool get _usesCompactMapMarkers =>
      _currentMapZoom < _compactMarkerZoomThreshold;

  bool get _usesCloseMapMarkers => _currentMapZoom >= _closeMarkerZoomThreshold;

  _MarkerZoomTier get _markerZoomTier {
    if (_usesCompactMapMarkers) {
      return _MarkerZoomTier.regional;
    }
    if (_usesCloseMapMarkers) {
      return _MarkerZoomTier.close;
    }
    return _MarkerZoomTier.street;
  }

  List<Map<String, dynamic>> get _vehicleMarkers {
    return vehiclesNotifier.value.where(_hasLiveCoordinates).toList();
  }

  List<Map<String, dynamic>> get _visibleVehicleMarkers {
    final bounds = _visibleBounds;
    final vehicles = _vehicleMarkers;
    if (bounds == null) {
      return vehicles;
    }

    final sampleAt = DateTime.now();
    return vehicles.where((vehicle) {
      final plate = _plateOf(vehicle);
      if (plate.isNotEmpty && plate == selectedPlate && _isFollowingSelected) {
        return true;
      }
      return _isPointInsideBufferedBounds(
        _animatedLatLngOf(vehicle, sampleAt),
        bounds,
      );
    }).toList();
  }

  List<Map<String, dynamic>> get _sortedVehicles {
    final vehicles = List<Map<String, dynamic>>.from(_vehicleMarkers);
    vehicles.sort((left, right) {
      final speedSort = _speedOf(right).compareTo(_speedOf(left));
      if (speedSort != 0) {
        return speedSort;
      }
      return _plateOf(left).compareTo(_plateOf(right));
    });
    return vehicles;
  }

  List<Map<String, dynamic>> get _sidebarVehicles {
    final filter = _sidebarStatusFilter;
    if (filter == null) {
      return _sortedVehicles;
    }

    return _sortedVehicles
        .where((vehicle) => _visualMarkerState(vehicle) == filter)
        .toList();
  }

  List<Map<String, dynamic>> get _movingVehicles {
    return _vehicleMarkers.where(_isVehicleMoving).toList();
  }

  List<Map<String, dynamic>> get _idleVehicles {
    return _vehicleMarkers.where(_isVehicleIdle).toList();
  }

  Map<String, dynamic>? get _selectedVehicle {
    if (selectedPlate.isEmpty) {
      return null;
    }

    return _vehicleMarkers.cast<Map<String, dynamic>?>().firstWhere(
      (vehicle) => _plateOf(vehicle) == selectedPlate,
      orElse: () => null,
    );
  }

  List<Map<String, dynamic>> get _selectedRouteStops {
    final selectedVehicle = _selectedVehicle;
    if (selectedVehicle == null) {
      return const [];
    }
    return _routeStopsFor(selectedVehicle);
  }

  List<Map<String, dynamic>> _routeStopsFor(Map<String, dynamic> vehicle) {
    final routeStops = vehicle['routeStops'];
    if (routeStops is! List) {
      return const [];
    }

    return routeStops.whereType<Map>().map((stop) {
      return stop.map((key, value) => MapEntry(key.toString(), value));
    }).toList();
  }

  List<LatLng> get _selectedPlannedPath {
    final vehicle = _selectedVehicle;
    return vehicle == null ? const [] : _plannedPathForVehicle(vehicle);
  }

  List<LatLng> _plannedPathForVehicle(Map<String, dynamic> vehicle) {
    final roadAwarePath = _roadAwarePathFromVehicle(vehicle);
    if (roadAwarePath.length > 1) {
      return roadAwarePath;
    }

    final plannedPath = _pathFromAny(
      vehicle['plannedPath'] ??
          vehicle['routePath'] ??
          vehicle['optimizedPath'] ??
          vehicle['roadPath'],
    );
    if (plannedPath.length > 1) {
      return plannedPath;
    }

    final stopPath = _routeStopsFor(
      vehicle,
    ).map((stop) => _latLngFrom(stop['center'])).whereType<LatLng>().toList();
    if (stopPath.length > 1) {
      return stopPath;
    }

    final target = _navigationTargetPoint(vehicle);
    final current = LatLng(_latitudeOf(vehicle), _longitudeOf(vehicle));
    if ((_showPredictiveContext || _showRoutePath) &&
        target != null &&
        _distanceMeters(current, target) > 50) {
      return [current, target];
    }

    return const [];
  }

  List<LatLng> get _visibleSelectedTrail {
    final vehicle = _selectedVehicle;
    if (vehicle == null || !_isVehicleMoving(vehicle)) {
      return const [];
    }
    if (!_hasMeaningfulTrailMovement(_selectedTrail)) {
      return const [];
    }
    return _selectedTrail;
  }

  List<gmaps.Polygon> get _selectedGeofencePolygons {
    return _selectedRouteStops
        .map((stop) {
          final rawPoints = stop['points'];
          if (rawPoints is! List) {
            return null;
          }

          final points = rawPoints
              .whereType<Map>()
              .map((point) => _latLngFrom(point))
              .whereType<LatLng>()
              .toList();

          if (points.length < 3) {
            return null;
          }

          return gmaps.Polygon(
            polygonId: gmaps.PolygonId(
              stop['id']?.toString() ?? stop['name']?.toString() ?? 'geofence',
            ),
            points: points.map(_toGoogleLatLng).toList(),
            fillColor: AppTheme.colorFF4B7BE5.withValues(alpha: 0.08),
            strokeWidth: 2,
            strokeColor: AppTheme.colorFF4B7BE5.withValues(alpha: 0.4),
          );
        })
        .whereType<gmaps.Polygon>()
        .toList();
  }

  List<gmaps.Polygon> get _visibleZoneOverlayPolygons {
    return _zoneOverlays
        .map((zone) {
          final rawPoints = zone['points'] ?? zone['boundaryPoints'];
          if (rawPoints is! List) {
            return null;
          }

          final points = rawPoints
              .whereType<Map>()
              .map((point) => _latLngFrom(point))
              .whereType<LatLng>()
              .toList();
          if (points.length < 3) {
            return null;
          }

          final id = (zone['zoneId'] ?? zone['id'] ?? zone['name'] ?? 'zone')
              .toString();
          return gmaps.Polygon(
            polygonId: gmaps.PolygonId('fleet-zone-$id'),
            points: points.map(_toGoogleLatLng).toList(),
            fillColor: AppTheme.primaryBlue.withValues(alpha: 0.14),
            strokeColor: AppTheme.pioneerDeepBlue.withValues(alpha: 0.82),
            strokeWidth: 3,
          );
        })
        .whereType<gmaps.Polygon>()
        .toList();
  }

  Set<gmaps.Marker> get _zoneLabelMarkers {
    return _zoneOverlays
        .map((zone) {
          final rawPoints = zone['points'] ?? zone['boundaryPoints'];
          if (rawPoints is! List) {
            return null;
          }
          final points = rawPoints
              .whereType<Map>()
              .map((point) => _latLngFrom(point))
              .whereType<LatLng>()
              .toList();
          if (points.length < 3) {
            return null;
          }
          final id = (zone['zoneId'] ?? zone['id'] ?? zone['name'] ?? 'zone')
              .toString();
          final name = (zone['name'] ?? 'Zone').toString();
          final center = _polygonCenter(points);
          return gmaps.Marker(
            markerId: gmaps.MarkerId('fleet-zone-label-$id'),
            position: _toGoogleLatLng(center),
            anchor: const Offset(0.5, 0.5),
            flat: true,
            zIndexInt: 0,
            icon:
                _zoneLabelIconCache[name] ??
                gmaps.BitmapDescriptor.defaultMarkerWithHue(
                  gmaps.BitmapDescriptor.hueAzure,
                ),
            infoWindow: gmaps.InfoWindow(title: name),
          );
        })
        .whereType<gmaps.Marker>()
        .toSet();
  }

  @override
  void initState() {
    super.initState();
    _launchedAt = DateTime.now();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _motionTicker = createTicker((_) {
      final sampleAt = DateTime.now();
      if (!_hasActiveMarkerMotion()) {
        _maybeFollowSelectedVehicle();
        return;
      }
      for (final state in _markerMotionStates.values) {
        if (state.needsFrameAt(
          sampleAt,
          stationaryThresholdKph: _stationarySpeedThresholdKph,
        )) {
          // Advance off-screen trajectories too, so map panning never
          // resurrects a paused position from an older frame.
          state.pointAt(sampleAt);
        }
      }
      _maybeFollowSelectedVehicle();
      _motionFrame.value++;
    })..start();
    vehiclesNotifier.addListener(_onVehiclesChanged);
    tripsNotifier.addListener(_onRouteOrdersChanged);
    refreshFleetBootstrapSilently();
    refreshFleetSnapshotSilently();
    _loadMarkerIcons();
    _loadZoneOverlays();
    _loadVehicles(fullRefresh: false, refreshTrail: true);
    _updateTimer = Timer.periodic(_livePollInterval, (_) {
      if (mounted && _vehicleMarkers.isNotEmpty) {
        setState(() {});
      }
      if (RealtimeStreamService.isConnected) {
        return;
      }
      _pollTick++;
      _loadVehicles(
        fullRefresh: false,
        refreshTrail: selectedPlate.isNotEmpty && _pollTick % 3 == 0,
      );
    });
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _boundsRefreshDebounce?.cancel();
    _pulseController.dispose();
    _motionTicker.dispose();
    _motionFrame.dispose();
    vehiclesNotifier.removeListener(_onVehiclesChanged);
    tripsNotifier.removeListener(_onRouteOrdersChanged);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map && args['plate'] != null) {
      _pendingPlateArg = args['plate'] as String;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final plate = _pendingPlateArg;
        if (plate != null) {
          _pendingPlateArg = null;
          _selectVehicleByPlate(plate);
        }
      });
    }
  }

  void _onVehiclesChanged() {
    _syncMarkerAnimations();
    if (_vehicleMarkers.isNotEmpty) {
      final nextSelectedPlate =
          selectedPlate.isNotEmpty &&
              _vehicleMarkers.any(
                (vehicle) => _plateOf(vehicle) == selectedPlate,
              )
          ? selectedPlate
          : _plateOf(_vehicleMarkers.first);
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = null;
          _loadFailureCount = 0;
          selectedPlate = nextSelectedPlate;
          _lastLiveSyncAt ??= DateTime.now();
        });
      }
      return;
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _onRouteOrdersChanged() {
    unawaited(_loadZoneOverlays());
    if (mounted) {
      setState(() {});
    }
  }

  List<Map<String, dynamic>> get _routeOrders {
    final orders = tripsNotifier.value.where((trip) {
      final source = trip['source']?.toString().trim().toLowerCase() ?? '';
      final routeSource =
          trip['routeSource']?.toString().trim().toLowerCase() ?? '';
      final status = trip['status']?.toString().trim().toLowerCase() ?? '';
      final isRoutePlan =
          trip['isRoutePlan'] == true ||
          source == 'geotab_route_plan' ||
          routeSource == 'geotab_route_plan';
      return isRoutePlan &&
          (status == 'pending' ||
              status == 'dispatched' ||
              status == 'active' ||
              status == 'in transit' ||
              status == 'on trip');
    }).toList();

    orders.sort((left, right) {
      final statusSort = _routeOrderStatusRank(
        left,
      ).compareTo(_routeOrderStatusRank(right));
      if (statusSort != 0) {
        return statusSort;
      }
      return _routeOrderTitle(left).compareTo(_routeOrderTitle(right));
    });
    return orders;
  }

  int _routeOrderStatusRank(Map<String, dynamic> order) {
    final status = order['status']?.toString().trim().toLowerCase() ?? '';
    return switch (status) {
      'dispatched' || 'active' || 'in transit' || 'on trip' => 0,
      'pending' => 1,
      _ => 2,
    };
  }

  String _routeOrderTitle(Map<String, dynamic> order) {
    final routeName = order['routeName']?.toString().trim() ?? '';
    final customer = order['customer']?.toString().trim() ?? '';
    if (routeName.isNotEmpty) {
      return routeName;
    }
    if (customer.isNotEmpty) {
      return customer;
    }
    return order['tripId']?.toString().trim() ?? 'GeoTab Route Order';
  }

  String _routeOrderOrigin(Map<String, dynamic> order) {
    final origin = order['origin']?.toString().trim() ?? '';
    return origin.isEmpty ? 'Route start' : origin;
  }

  String _routeOrderDestination(Map<String, dynamic> order) {
    final destination = order['destination']?.toString().trim() ?? '';
    return destination.isEmpty ? 'Route destination' : destination;
  }

  String _routeOrderVehicle(Map<String, dynamic> order) {
    final vehicle = order['vehicle']?.toString().trim() ?? '';
    return vehicle == 'N/A' ? '' : vehicle;
  }

  Color _routeOrderStatusColor(String status) {
    return switch (status) {
      'dispatched' ||
      'active' ||
      'in transit' ||
      'on trip' => AppTheme.colorFF4B7BE5,
      'pending' => AppTheme.colorFFF59E0B,
      _ => AppTheme.colorFF6B7280,
    };
  }

  Future<void> _loadZoneOverlays() async {
    try {
      List<Map<String, dynamic>> zones;
      try {
        zones = await BackendApiService.getFleetZones();
      } catch (_) {
        zones = const [];
      }
      final combinedZones = <Map<String, dynamic>>[
        ...zones.where(
          (zone) => (zone['status'] ?? '').toString() != 'deleted',
        ),
        ..._derivedOperationalZones(),
      ];
      final labelIcons = <String, gmaps.BitmapDescriptor>{};
      for (final zone in combinedZones) {
        final name = (zone['name'] ?? '').toString().trim();
        if (name.isEmpty || labelIcons.containsKey(name)) {
          continue;
        }
        labelIcons[name] = await _zoneLabelIcon(name);
      }
      if (!mounted) return;
      setState(() {
        _zoneOverlays = combinedZones;
        _zoneLabelIconCache.addAll(labelIcons);
      });
    } catch (_) {
      // Zone overlays are non-blocking; live vehicle tracking remains usable.
    }
  }

  List<Map<String, dynamic>> _derivedOperationalZones() {
    final derived = <Map<String, dynamic>>[];
    final seen = <String>{};

    for (final order in _routeOrders) {
      final routeName = _routeOrderTitle(order);
      for (final point in _candidateStopPoints(order)) {
        final center = point.center;
        if (center == null) {
          continue;
        }
        final stopName = point.name.isEmpty ? routeName : point.name;
        _appendDerivedFence(
          derived,
          seen,
          id: 'route:${order['tripId'] ?? routeName}:$stopName',
          name: stopName,
          center: center,
          type: 'Route stop',
          sourceLabel: routeName,
          radiusMeters: 160,
        );
      }
    }

    for (final vehicle in _vehicleMarkers) {
      final plate = _plateOf(vehicle);
      for (final point in _candidateStopPoints(vehicle)) {
        final center = point.center;
        if (center == null) {
          continue;
        }
        final stopName = point.name.isEmpty
            ? '$plate service zone'
            : point.name;
        _appendDerivedFence(
          derived,
          seen,
          id: 'vehicle:$plate:$stopName',
          name: stopName,
          center: center,
          type: 'Vehicle route stop',
          sourceLabel: plate,
          radiusMeters: 140,
        );
      }
    }

    return derived;
  }

  void _appendDerivedFence(
    List<Map<String, dynamic>> zones,
    Set<String> seen, {
    required String id,
    required String name,
    required LatLng center,
    required String type,
    required String sourceLabel,
    required double radiusMeters,
  }) {
    final normalizedName = name.trim().isEmpty ? type : name.trim();
    final key =
        '${normalizedName.toLowerCase()}:${center.latitude.toStringAsFixed(4)}:${center.longitude.toStringAsFixed(4)}';
    if (!seen.add(key)) {
      return;
    }
    zones.add({
      'id': 'derived:$id',
      'name': normalizedName,
      'zoneType': type,
      'type': type,
      'status': 'active',
      'source': 'pioneer_operational',
      'description': 'Derived from $sourceLabel in PioneerPath.',
      'boundaryPoints': _squareFenceAround(center, radiusMeters)
          .map(
            (point) => {
              'latitude': point.latitude,
              'longitude': point.longitude,
            },
          )
          .toList(),
    });
  }

  List<_DerivedStopPoint> _candidateStopPoints(Map<String, dynamic> source) {
    final candidates = <_DerivedStopPoint>[];
    for (final key in [
      'routeStops',
      'stops',
      'routePlanItems',
      'geofences',
      'zones',
    ]) {
      final raw = source[key];
      if (raw is! List) {
        continue;
      }
      for (final item in raw) {
        final point = _derivedStopPointFrom(item);
        if (point != null) {
          candidates.add(point);
        }
      }
    }

    for (final key in ['originPoint', 'destinationPoint', 'destination']) {
      final point = _derivedStopPointFrom(source[key], fallbackName: key);
      if (point != null) {
        candidates.add(point);
      }
    }

    return candidates;
  }

  _DerivedStopPoint? _derivedStopPointFrom(
    dynamic raw, {
    String fallbackName = '',
  }) {
    final center = _pointFromAny(raw);
    if (center == null) {
      return null;
    }

    var name = fallbackName;
    if (raw is Map) {
      for (final key in ['name', 'stopName', 'zoneName', 'address', 'label']) {
        final value = raw[key]?.toString().trim() ?? '';
        if (value.isNotEmpty) {
          name = value;
          break;
        }
      }
    }

    return _DerivedStopPoint(name: name, center: center);
  }

  LatLng? _pointFromAny(dynamic raw) {
    if (raw == null) {
      return null;
    }
    final direct = _latLngFrom(raw);
    if (direct != null) {
      return direct;
    }
    if (raw is Map) {
      for (final key in [
        'center',
        'position',
        'location',
        'coordinate',
        'coordinates',
        'point',
      ]) {
        final nested = _latLngFrom(raw[key]);
        if (nested != null) {
          return nested;
        }
      }
    }
    return null;
  }

  List<LatLng> _squareFenceAround(LatLng center, double meters) {
    final latDelta = meters / 111320;
    final cosLat = math.cos(_degreesToRadians(center.latitude)).abs();
    final lngDelta = meters / (111320 * math.max(cosLat, 0.18));
    return [
      LatLng(center.latitude - latDelta, center.longitude - lngDelta),
      LatLng(center.latitude - latDelta, center.longitude + lngDelta),
      LatLng(center.latitude + latDelta, center.longitude + lngDelta),
      LatLng(center.latitude + latDelta, center.longitude - lngDelta),
    ];
  }

  Future<void> _loadVehicles({
    required bool fullRefresh,
    required bool refreshTrail,
  }) async {
    try {
      if (fullRefresh) {
        await refreshVehiclesFromBackend();
      } else {
        await refreshVehicleLocationsFromBackend();
        if (_vehicleMarkers.isEmpty) {
          await refreshVehiclesFromBackend();
        }
        if (_vehicleMarkers.isEmpty) {
          await refreshFleetBootstrap(forceRefresh: true);
        }
        if (_vehicleMarkers.isEmpty) {
          await refreshFleetSnapshot(forceRefresh: true);
          try {
            await refreshVehicleLocationsFromBackend();
          } catch (_) {}
        }
      }

      if (!mounted) {
        return;
      }

      final vehicles = _vehicleMarkers;
      if (vehicles.isEmpty) {
        setState(() {
          _isLoading = false;
          _errorMessage = null;
          _selectedTrail = const [];
        });
        return;
      }

      final nextSelectedPlate =
          selectedPlate.isNotEmpty &&
              vehicles.any((vehicle) => _plateOf(vehicle) == selectedPlate)
          ? selectedPlate
          : _plateOf(vehicles.first);

      setState(() {
        _isLoading = false;
        _errorMessage = null;
        _loadFailureCount = 0;
        selectedPlate = nextSelectedPlate;
        _lastLiveSyncAt = DateTime.now();
      });
      unawaited(_loadZoneOverlays());

      if (refreshTrail) {
        await _loadSelectedTrail();
      }
    } on BackendApiException {
      if (!mounted) {
        return;
      }

      _loadFailureCount += 1;
      final warmupWindow =
          DateTime.now().difference(_launchedAt) < const Duration(seconds: 8);
      if ((_vehicleMarkers.isEmpty && warmupWindow) || _loadFailureCount < 3) {
        setState(() {
          _isLoading = true;
          _errorMessage = null;
        });
        return;
      }

      setState(() {
        _isLoading = false;
        _errorMessage =
            'Unable to reach the Laravel backend. Start php artisan serve on port 8000 and confirm the Geotab credentials are valid.';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      _loadFailureCount += 1;
      final warmupWindow =
          DateTime.now().difference(_launchedAt) < const Duration(seconds: 8);
      if ((_vehicleMarkers.isEmpty && warmupWindow) || _loadFailureCount < 3) {
        setState(() {
          _isLoading = true;
          _errorMessage = null;
        });
        return;
      }

      setState(() {
        _isLoading = false;
        _errorMessage = 'Live tracking is temporarily unavailable.';
      });
    }
  }

  Future<void> _loadMarkerIcons() async {
    final icons = await Future.wait<gmaps.BitmapDescriptor>([
      PioneerGoogleMapMarkerFactory.marker(PioneerMapMarkerStyle.moving),
      PioneerGoogleMapMarkerFactory.marker(PioneerMapMarkerStyle.idle),
      PioneerGoogleMapMarkerFactory.marker(PioneerMapMarkerStyle.offline),
      PioneerGoogleMapMarkerFactory.marker(PioneerMapMarkerStyle.stale),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.moving,
        selected: true,
      ),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.idle,
        selected: true,
      ),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.offline,
        selected: true,
      ),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.stale,
        selected: true,
      ),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.moving,
        compact: true,
      ),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.idle,
        compact: true,
      ),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.offline,
        compact: true,
      ),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.stale,
        compact: true,
      ),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.moving,
        selected: true,
        compact: true,
      ),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.idle,
        selected: true,
        compact: true,
      ),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.offline,
        selected: true,
        compact: true,
      ),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.stale,
        selected: true,
        compact: true,
      ),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.moving,
        zoomScale: 1.16,
      ),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.idle,
        zoomScale: 1.14,
      ),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.offline,
        zoomScale: 1.12,
      ),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.stale,
        zoomScale: 1.12,
      ),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.moving,
        selected: true,
        zoomScale: 1.12,
      ),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.idle,
        selected: true,
        zoomScale: 1.10,
      ),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.offline,
        selected: true,
        zoomScale: 1.08,
      ),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.stale,
        selected: true,
        zoomScale: 1.08,
      ),
    ]);
    if (!mounted) {
      return;
    }

    setState(() {
      _movingMarkerIcon = icons[0];
      _idleMarkerIcon = icons[1];
      _offlineMarkerIcon = icons[2];
      _staleMarkerIcon = icons[3];
      _selectedMovingMarkerIcon = icons[4];
      _selectedIdleMarkerIcon = icons[5];
      _selectedOfflineMarkerIcon = icons[6];
      _selectedStaleMarkerIcon = icons[7];
      _compactMovingMarkerIcon = icons[8];
      _compactIdleMarkerIcon = icons[9];
      _compactOfflineMarkerIcon = icons[10];
      _compactStaleMarkerIcon = icons[11];
      _selectedCompactMovingMarkerIcon = icons[12];
      _selectedCompactIdleMarkerIcon = icons[13];
      _selectedCompactOfflineMarkerIcon = icons[14];
      _selectedCompactStaleMarkerIcon = icons[15];
      _largeMovingMarkerIcon = icons[16];
      _largeIdleMarkerIcon = icons[17];
      _largeOfflineMarkerIcon = icons[18];
      _largeStaleMarkerIcon = icons[19];
      _selectedLargeMovingMarkerIcon = icons[20];
      _selectedLargeIdleMarkerIcon = icons[21];
      _selectedLargeOfflineMarkerIcon = icons[22];
      _selectedLargeStaleMarkerIcon = icons[23];
    });
  }

  Future<void> _loadSelectedTrail() async {
    final vehicle = _selectedVehicle;
    final geotabId = vehicle?['geotabId']?.toString() ?? '';

    if (geotabId.isEmpty) {
      if (mounted) {
        setState(() => _selectedTrail = const []);
      }
      return;
    }

    try {
      final trail = await BackendApiService.getVehicleTrail(geotabId);
      final points = trail
          .where((point) {
            final latitude = (point['latitude'] as num?)?.toDouble() ?? 0.0;
            final longitude = (point['longitude'] as num?)?.toDouble() ?? 0.0;
            return latitude != 0.0 || longitude != 0.0;
          })
          .map(
            (point) => LatLng(
              (point['latitude'] as num).toDouble(),
              (point['longitude'] as num).toDouble(),
            ),
          )
          .toList();

      if (mounted && geotabId == _selectedVehicle?['geotabId']?.toString()) {
        setState(
          () => _selectedTrail = _hasMeaningfulTrailMovement(points)
              ? _dedupeTrailPoints(points)
              : const [],
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _selectedTrail = const []);
      }
    }
  }

  Future<void> _selectVehicle(Map<String, dynamic> vehicle) async {
    final plate = _plateOf(vehicle);
    if (plate.isEmpty) {
      return;
    }

    if (mounted) {
      setState(() {
        selectedPlate = plate;
        _isFollowingSelected = true;
        _selectedPulseOffset = null;
      });
      _moveMap(_animatedLatLngOf(vehicle), 15.0);
      _scheduleSelectedPulseProjection();
    }

    await _loadSelectedTrail();
  }

  Future<void> _selectVehicleByPlate(String plate) async {
    final vehicle = _vehicleMarkers.cast<Map<String, dynamic>?>().firstWhere(
      (item) => _plateOf(item) == plate,
      orElse: () => null,
    );
    if (vehicle != null) {
      await _selectVehicle(vehicle);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      currentRoute: '/live-tracking',
      title: 'Live Tracking',
      child: _buildPageContent(),
    );
  }

  Widget _buildPageContent() {
    if (_isLoading && _vehicleMarkers.isEmpty) {
      return const PioneerRouteSkeletonBody(routeName: '/live-tracking');
    }

    if (_vehicleMarkers.isEmpty) {
      return _buildEmptyState();
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final isLargeScreen = screenWidth >= 1024;
    final moving = _movingVehicles.length;
    final idle = _idleVehicles.length;
    final stopped = _vehicleMarkers
        .where(
          (vehicle) =>
              _visualMarkerState(vehicle) == PioneerMapMarkerStyle.offline,
        )
        .length;
    final stale = _vehicleMarkers
        .where(
          (vehicle) =>
              _visualMarkerState(vehicle) == PioneerMapMarkerStyle.stale,
        )
        .length;
    final total = _vehicleMarkers.length;

    if (isLargeScreen) {
      return Row(
        children: [
          Expanded(
            flex: 7,
            child: Stack(
              children: [
                _buildMapView(_visibleVehicleMarkers)
                    .animate()
                    .fadeIn(duration: 500.ms)
                    .slideY(begin: 0.2, end: 0, duration: 500.ms),
                Positioned(
                  top: 24,
                  left: 24,
                  right: 24,
                  child: _buildTopStats(moving, idle, stopped, stale, total)
                      .animate()
                      .fadeIn(duration: 600.ms)
                      .slideY(begin: 0.2, end: 0, duration: 500.ms),
                ),
                if (_selectedVehicle != null)
                  Positioned(
                    bottom: 14,
                    left: 18,
                    right: 18,
                    child: _buildSelectedVehicleCard(_selectedVehicle!)
                        .animate()
                        .fadeIn(duration: 700.ms)
                        .slideY(begin: 0.2, end: 0, duration: 500.ms),
                  ),
                if (_showMapIntelligencePanel)
                  Positioned(
                    top: 84,
                    right: 82,
                    child: _buildMapIntelligencePanel(
                      context,
                      width: _mapIntelligencePanelWidth(context),
                    ),
                  ),
                Positioned(
                  top: 100,
                  right: 24,
                  child: _buildMapControls(hideListButton: true)
                      .animate()
                      .fadeIn(duration: 800.ms)
                      .slideY(begin: 0.2, end: 0, duration: 500.ms),
                ),
              ],
            ),
          ),
          _buildResizableVehicleSidebar()
              .animate()
              .fadeIn(duration: 900.ms)
              .slideY(begin: 0.2, end: 0),
        ],
      );
    }

    return Stack(
      children: [
        _buildMapView(_visibleVehicleMarkers)
            .animate()
            .fadeIn(duration: 500.ms)
            .slideY(begin: 0.2, end: 0, duration: 500.ms),
        Positioned(
          top: 16,
          left: 12,
          right: 12,
          child: _buildTopStats(moving, idle, stopped, stale, total)
              .animate()
              .fadeIn(duration: 600.ms)
              .slideY(begin: 0.2, end: 0, duration: 500.ms),
        ),
        if (_selectedVehicle != null)
          Positioned(
            bottom: 10,
            left: 12,
            right: 12,
            child: _buildSelectedVehicleCard(_selectedVehicle!)
                .animate()
                .fadeIn(duration: 700.ms)
                .slideY(begin: 0.2, end: 0, duration: 500.ms),
          ),
        if (_showMapIntelligencePanel)
          Positioned(
            top: 76,
            right: 62,
            child: _buildMapIntelligencePanel(
              context,
              width: _mapIntelligencePanelWidth(context),
            ),
          ),
        Positioned(
          top: 84,
          right: 12,
          child: _buildMapControls(hideListButton: false)
              .animate()
              .fadeIn(duration: 800.ms)
              .slideY(begin: 0.2, end: 0, duration: 500.ms),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final message =
        _errorMessage ?? 'No Geotab vehicles have reported GPS data yet.';

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.location_off_rounded, size: 80, color: AppTheme.gray400),
            const SizedBox(height: 24),
            Text(
              'Live tracking unavailable',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
              ),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                ),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () =>
                  _loadVehicles(fullRefresh: true, refreshTrail: true),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopStats(
    int moving,
    int idle,
    int stopped,
    int stale,
    int total,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: isMobile ? 12 : 20,
          vertical: isMobile ? 8 : 12,
        ),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
          borderRadius: BorderRadius.circular(isMobile ? 30 : 50),
          boxShadow: [
            BoxShadow(
              color: AppTheme.black.withValues(alpha: isDark ? 0.4 : 0.08),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildStatChip(
              label: '$moving Moving',
              color: AppTheme.colorFF4B7BE5,
              isDark: isDark,
              isMobile: isMobile,
            ),
            SizedBox(width: isMobile ? 8 : 12),
            _buildStatChip(
              label: '$idle Idle',
              color: AppTheme.colorFFF39C12,
              isDark: isDark,
              isMobile: isMobile,
            ),
            SizedBox(width: isMobile ? 8 : 12),
            _buildStatChip(
              label: '$stopped Stopped',
              color: AppTheme.colorFF64748B,
              isDark: isDark,
              isMobile: isMobile,
            ),
            SizedBox(width: isMobile ? 8 : 12),
            _buildStatChip(
              label: '$stale Stale',
              color: AppTheme.colorFF94A3B8,
              isDark: isDark,
              isMobile: isMobile,
            ),
            SizedBox(width: isMobile ? 8 : 12),
            _buildStatChip(
              label: '$total Total',
              color: AppTheme.colorFF27AE60,
              isDark: isDark,
              isMobile: isMobile,
            ),
            SizedBox(width: isMobile ? 8 : 12),
            _buildStatChip(
              label: _lastLiveSyncAt == null
                  ? 'Connecting'
                  : 'Live ${_secondsAgo(_lastLiveSyncAt!)}s',
              color: AppTheme.colorFF00C2A8,
              isDark: isDark,
              isMobile: isMobile,
            ),
            SizedBox(width: isMobile ? 10 : 14),
            _buildTopLegendDivider(isDark),
            SizedBox(width: isMobile ? 10 : 14),
            _buildMapMarkerLegend(context, compact: true),
          ],
        ),
      ),
    );
  }

  Widget _buildTopLegendDivider(bool isDark) {
    return Container(
      width: 1,
      height: 26,
      color: isDark
          ? AppTheme.white.withValues(alpha: 0.14)
          : AppTheme.black.withValues(alpha: 0.10),
    );
  }

  Widget _buildStatChip({
    required String label,
    required Color color,
    required bool isDark,
    required bool isMobile,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 10 : 12,
        vertical: isMobile ? 6 : 8,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(isMobile ? 20 : 30),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: isMobile ? 5 : 6,
            height: isMobile ? 5 : 6,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.5),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          SizedBox(width: isMobile ? 6 : 8),
          Text(
            label,
            style: TextStyle(
              fontSize: isMobile ? 11 : 13,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMapControls({required bool hideListButton}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600;

    return Column(
      children: [
        if (!hideListButton) ...[
          _buildControlButton(
            icon: Icons.list_rounded,
            tooltip: 'Vehicle list',
            onTap: _showVehicleListBottomSheet,
            isDark: isDark,
            isMobile: isMobile,
          ),
          SizedBox(height: isMobile ? 8 : 12),
        ],
        _buildControlButton(
          icon: Icons.tune_rounded,
          tooltip: 'Map intelligence',
          active: _showMapIntelligencePanel,
          onTap: () => setState(
            () => _showMapIntelligencePanel = !_showMapIntelligencePanel,
          ),
          isDark: isDark,
          isMobile: isMobile,
        ),
        SizedBox(height: isMobile ? 8 : 12),
        _buildControlButton(
          icon: Icons.my_location_rounded,
          tooltip: 'Recenter fleet',
          onTap: () {
            final vehicle = _selectedVehicle;
            if (vehicle != null) {
              _moveMap(_animatedLatLngOf(vehicle), 15.0);
              return;
            }

            if (_vehicleMarkers.isNotEmpty) {
              final avgLat =
                  _vehicleMarkers.fold<double>(
                    0,
                    (sum, vehicle) => sum + _latitudeOf(vehicle),
                  ) /
                  _vehicleMarkers.length;
              final avgLng =
                  _vehicleMarkers.fold<double>(
                    0,
                    (sum, vehicle) => sum + _longitudeOf(vehicle),
                  ) /
                  _vehicleMarkers.length;
              _moveMap(LatLng(avgLat, avgLng), 12.0);
            }
          },
          isDark: isDark,
          isMobile: isMobile,
        ),
        SizedBox(height: isMobile ? 8 : 12),
        _buildControlButton(
          icon: Icons.refresh_rounded,
          tooltip: 'Refresh live data',
          onTap: () => _loadVehicles(fullRefresh: true, refreshTrail: true),
          isDark: isDark,
          isMobile: isMobile,
        ),
        SizedBox(height: isMobile ? 8 : 12),
        _buildControlButton(
          icon: Icons.add_rounded,
          tooltip: 'Zoom in',
          onTap: () => _zoomBy(1),
          isDark: isDark,
          isMobile: isMobile,
        ),
        SizedBox(height: isMobile ? 8 : 12),
        _buildControlButton(
          icon: Icons.remove_rounded,
          tooltip: 'Zoom out',
          onTap: () => _zoomBy(-1),
          isDark: isDark,
          isMobile: isMobile,
        ),
      ],
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    required bool isDark,
    required bool isMobile,
    bool active = false,
  }) {
    final activeColor = AppTheme.colorFF4B7BE5;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: isMobile ? 40 : 48,
          height: isMobile ? 40 : 48,
          decoration: BoxDecoration(
            color: active
                ? activeColor
                : (isDark ? AppTheme.colorFF1A1D23 : AppTheme.white),
            borderRadius: BorderRadius.circular(isMobile ? 10 : 12),
            border: Border.all(
              color: active
                  ? activeColor.withValues(alpha: 0.72)
                  : AppTheme.getBorderColor(context),
            ),
            boxShadow: [
              BoxShadow(
                color: active
                    ? activeColor.withValues(alpha: 0.24)
                    : AppTheme.black.withValues(alpha: isDark ? 0.4 : 0.08),
                blurRadius: active ? 18 : 12,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(
            icon,
            color: active
                ? AppTheme.white
                : (isDark ? AppTheme.white : AppTheme.colorFF2C3E50),
            size: isMobile ? 20 : 24,
          ),
        ),
      ),
    );
  }

  double _mapIntelligenceRightOffset(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    return screenWidth < 600 ? 62.0 : 78.0;
  }

  double _mapIntelligencePanelWidth(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final reservedRight = _mapIntelligenceRightOffset(context);
    final available = screenWidth - reservedRight - 28;
    final minimum = screenWidth < 420 ? 160.0 : 220.0;
    return math.min(300.0, math.max(minimum, available));
  }

  Widget _buildMapIntelligencePanel(BuildContext context, {double? width}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final panelWidth = width ?? _mapIntelligencePanelWidth(context);

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {},
      onPointerMove: (_) {},
      onPointerSignal: (_) {},
      child: MouseRegion(
        opaque: true,
        cursor: SystemMouseCursors.basic,
        child: Material(
          color: Colors.transparent,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: panelWidth,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isDark
                  ? AppTheme.colorFF111827.withValues(alpha: 0.98)
                  : AppTheme.white.withValues(alpha: 0.98),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.getBorderColor(context)),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.black.withValues(alpha: isDark ? 0.42 : 0.16),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.tune_rounded,
                        size: 16,
                        color: AppTheme.colorFF4B7BE5,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Map Intelligence',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                              color: isDark
                                  ? AppTheme.white
                                  : AppTheme.colorFF1F2937,
                            ),
                          ),
                          Text(
                            'Google APIs and GeoTab layers',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: isDark
                                  ? AppTheme.gray400
                                  : AppTheme.gray600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () =>
                          setState(() => _showMapIntelligencePanel = false),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _intelligenceToggle(
                  isDark: isDark,
                  icon: Icons.traffic_rounded,
                  label: 'Traffic layer',
                  detail: 'Maps JavaScript traffic overlay',
                  value: _showTrafficLayer,
                  color: AppTheme.colorFFE67E22,
                  onChanged: (value) =>
                      setState(() => _showTrafficLayer = value),
                ),
                _intelligenceToggle(
                  isDark: isDark,
                  icon: Icons.cloud_queue_rounded,
                  label: 'Weather',
                  detail: 'Google Weather at vehicle location',
                  value: _showWeatherContext,
                  color: AppTheme.colorFF4B7BE5,
                  onChanged: (value) =>
                      setState(() => _showWeatherContext = value),
                ),
                _intelligenceToggle(
                  isDark: isDark,
                  icon: Icons.schedule_rounded,
                  label: 'Traffic ETA',
                  detail: 'Routes API delay to next stop',
                  value: _showTrafficEta,
                  color: AppTheme.colorFF27AE60,
                  onChanged: (value) => setState(() => _showTrafficEta = value),
                ),
                _intelligenceToggle(
                  isDark: isDark,
                  icon: Icons.alt_route_rounded,
                  label: 'Route path',
                  detail: 'Planned GeoTab route line',
                  value: _showRoutePath,
                  color: AppTheme.colorFF7C3AED,
                  onChanged: (value) => setState(() => _showRoutePath = value),
                ),
                _intelligenceToggle(
                  isDark: isDark,
                  icon: Icons.timeline_rounded,
                  label: 'Vehicle trail',
                  detail: 'Recent GPS trail from GeoTab',
                  value: _showVehicleTrail,
                  color: AppTheme.colorFF0E7A43,
                  onChanged: (value) =>
                      setState(() => _showVehicleTrail = value),
                ),
                _intelligenceToggle(
                  isDark: isDark,
                  icon: Icons.hexagon_rounded,
                  label: 'Zones',
                  detail: 'Geofences and route stop areas',
                  value: _showZoneOverlays,
                  color: AppTheme.colorFF0EA5E9,
                  onChanged: (value) =>
                      setState(() => _showZoneOverlays = value),
                ),
                _intelligenceToggle(
                  isDark: isDark,
                  icon: Icons.auto_graph_rounded,
                  label: 'Predictive context',
                  detail:
                      'Shows estimated values when live sensors are missing',
                  value: _showPredictiveContext,
                  color: AppTheme.colorFFF59E0B,
                  onChanged: (value) =>
                      setState(() => _showPredictiveContext = value),
                ),
                const SizedBox(height: 8),
                Text(
                  'Map style',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    color: isDark ? AppTheme.gray300 : AppTheme.colorFF374151,
                  ),
                ),
                const SizedBox(height: 6),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                  childAspectRatio: 3.35,
                  children: [
                    _mapTypeChip('Normal', gmaps.MapType.normal, isDark),
                    _mapTypeChip('Terrain', gmaps.MapType.terrain, isDark),
                    _mapTypeChip('Satellite', gmaps.MapType.satellite, isDark),
                    _mapTypeChip('Hybrid', gmaps.MapType.hybrid, isDark),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _intelligenceToggle({
    required bool isDark,
    required IconData icon,
    required String label,
    required String detail,
    required bool value,
    required Color color,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => onChanged(!value),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: value
                ? color.withValues(alpha: isDark ? 0.16 : 0.10)
                : (isDark
                      ? AppTheme.white.withValues(alpha: 0.04)
                      : AppTheme.colorFFF8FAFC),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: value
                  ? color.withValues(alpha: 0.34)
                  : AppTheme.getBorderColor(context),
            ),
          ),
          child: Row(
            children: [
              Icon(icon, color: value ? color : AppTheme.gray500, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w900,
                        color: isDark ? AppTheme.white : AppTheme.colorFF1F2937,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 9.8,
                        fontWeight: FontWeight.w600,
                        color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                constraints: const BoxConstraints(minWidth: 30),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(
                  color: value
                      ? color.withValues(alpha: isDark ? 0.24 : 0.16)
                      : (isDark
                            ? AppTheme.white.withValues(alpha: 0.06)
                            : AppTheme.colorFFE5E7EB.withValues(alpha: 0.75)),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: value
                        ? color.withValues(alpha: 0.45)
                        : AppTheme.getBorderColor(context),
                  ),
                ),
                child: Text(
                  value ? 'ON' : 'OFF',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 8.8,
                    fontWeight: FontWeight.w900,
                    color: value
                        ? color
                        : (isDark ? AppTheme.gray400 : AppTheme.gray600),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Transform.scale(
                scale: 0.82,
                child: Switch.adaptive(
                  value: value,
                  onChanged: onChanged,
                  activeThumbColor: color,
                  activeTrackColor: color.withValues(alpha: 0.28),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mapTypeChip(String label, gmaps.MapType type, bool isDark) {
    final selected = _mapType == type;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => setState(() => _mapType = type),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        constraints: const BoxConstraints(minHeight: 34, minWidth: 58),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.colorFF4B7BE5
              : (isDark
                    ? AppTheme.white.withValues(alpha: 0.05)
                    : AppTheme.colorFFF8FAFC),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? AppTheme.colorFF4B7BE5
                : AppTheme.getBorderColor(context),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w900,
            color: selected
                ? AppTheme.white
                : (isDark ? AppTheme.gray300 : AppTheme.colorFF374151),
          ),
        ),
      ),
    );
  }

  Widget _buildResizableVehicleSidebar() {
    if (_sidebarCollapsed) {
      return SizedBox(
        width: _trackingSidebarCollapsedWidth,
        child: _buildCollapsedVehicleSidebar(),
      );
    }

    final width = _effectiveTrackingSidebarWidth(context);
    return SizedBox(
      width: width,
      child: Row(
        children: [
          _buildSidebarResizeHandle(),
          Expanded(child: _buildVehicleListSidebar()),
        ],
      ),
    );
  }

  Widget _buildCollapsedVehicleSidebar() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF111827 : AppTheme.white,
        border: Border(
          left: BorderSide(color: AppTheme.getBorderColor(context)),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Tooltip(
            message: 'Expand sidebar',
            child: IconButton(
              onPressed: () => setState(() => _sidebarCollapsed = false),
              icon: const Icon(Icons.keyboard_double_arrow_left_rounded),
              color: AppTheme.colorFF4B7BE5,
            ),
          ),
          const Divider(height: 12),
          _collapsedSidebarIcon(
            icon: Icons.assignment_rounded,
            label: '${_routeOrders.length}',
            color: AppTheme.colorFF4B7BE5,
            tooltip: 'Route orders',
          ),
          _collapsedSidebarIcon(
            icon: Icons.filter_alt_rounded,
            label: '${_sidebarVehicles.length}',
            color: AppTheme.colorFF27AE60,
            tooltip: 'Fleet status',
          ),
          _collapsedSidebarIcon(
            icon: Icons.sensors_rounded,
            label: '${_vehicleMarkers.length}',
            color: AppTheme.colorFF0EA5E9,
            tooltip: 'Tracked vehicles',
          ),
        ],
      ),
    );
  }

  Widget _collapsedSidebarIcon({
    required IconData icon,
    required String label,
    required Color color,
    required String tooltip,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w900,
                color: isDark ? AppTheme.gray300 : AppTheme.colorFF334155,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebarResizeHandle() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) {
          setState(() {
            _trackingSidebarWidth = (_trackingSidebarWidth - details.delta.dx)
                .clamp(_trackingSidebarMinWidth, _trackingSidebarMaxWidth);
          });
        },
        child: Container(
          width: 12,
          height: double.infinity,
          alignment: Alignment.center,
          color: isDark
              ? const Color(0xFF0F172A).withValues(alpha: 0.68)
              : const Color(0xFFEFF6FF).withValues(alpha: 0.72),
          child: Container(
            width: 3,
            height: 44,
            decoration: BoxDecoration(
              color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      ),
    );
  }

  double _effectiveTrackingSidebarWidth(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final maxForScreen = math.max(
      _trackingSidebarMinWidth,
      math.min(_trackingSidebarMaxWidth, screenWidth * 0.46),
    );
    return _trackingSidebarWidth
        .clamp(_trackingSidebarMinWidth, maxForScreen)
        .toDouble();
  }

  Widget _buildVehicleListSidebar() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sidebarVehicles = _sidebarVehicles;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        border: Border(
          left: BorderSide(
            color: isDark
                ? AppTheme.white.withValues(alpha: 0.05)
                : AppTheme.black.withValues(alpha: 0.05),
            width: 1,
          ),
        ),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 9),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: isDark
                      ? AppTheme.white.withValues(alpha: 0.05)
                      : AppTheme.black.withValues(alpha: 0.05),
                  width: 1,
                ),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.route_rounded,
                  color: AppTheme.colorFF4B7BE5,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  'Live Orders',
                  style: AppTheme.getHeadingStyle(context, fontSize: 15),
                ),
                const Spacer(),
                Tooltip(
                  message: 'Collapse sidebar',
                  child: IconButton(
                    onPressed: () => setState(() => _sidebarCollapsed = true),
                    icon: const Icon(Icons.keyboard_double_arrow_right_rounded),
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                  ),
                ),
              ],
            ),
          ),
          _buildRouteOrdersPanel(isDark: isDark, isMobile: false),
          _buildSidebarStatusLegend(isDark: isDark, isMobile: false),
          _buildTrackedVehiclesHeader(
            isDark: isDark,
            visibleCount: sidebarVehicles.length,
          ),
          Expanded(
            child: !_sidebarVehiclesExpanded
                ? _buildSidebarVehiclesCollapsedState(isDark)
                : sidebarVehicles.isEmpty
                ? _buildSidebarEmptyFilterState(isDark)
                : ListView.builder(
                    itemCount: sidebarVehicles.length,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemBuilder: (context, index) {
                      final vehicle = sidebarVehicles[index];
                      final isSelected = _plateOf(vehicle) == selectedPlate;
                      final markerState = _visualMarkerState(vehicle);
                      final markerColor = _sidebarStateAccent(vehicle);
                      final baseCardColor = isDark
                          ? AppTheme.colorFF252930
                          : AppTheme.colorFFF8F9FA;
                      final outlineColor = isSelected
                          ? markerColor.withValues(alpha: 0.7)
                          : (isDark
                                ? AppTheme.white.withValues(alpha: 0.05)
                                : AppTheme.black.withValues(alpha: 0.05));

                      return GestureDetector(
                        onTap: () => _selectVehicle(vehicle),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 240),
                          curve: Curves.easeOutCubic,
                          margin: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Color.alphaBlend(
                              markerColor.withValues(
                                alpha: isSelected ? 0.12 : 0.07,
                              ),
                              baseCardColor,
                            ),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: outlineColor,
                              width: isSelected ? 1.5 : 1,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Stack(
                            children: [
                              Positioned.fill(
                                right: null,
                                child: Container(width: 4, color: markerColor),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        AnimatedSwitcher(
                                          duration: const Duration(
                                            milliseconds: 180,
                                          ),
                                          switchInCurve: Curves.easeOut,
                                          switchOutCurve: Curves.easeIn,
                                          child: _buildSidebarStateGlyph(
                                            vehicle: vehicle,
                                            state: markerState,
                                            color: markerColor,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              SelectableText(
                                                _plateLabelOf(vehicle),
                                                style:
                                                    AppTheme.getHeadingStyle(
                                                      context,
                                                      fontSize: 16,
                                                    ).copyWith(
                                                      fontWeight:
                                                          FontWeight.w900,
                                                    ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                _driverLabelOf(vehicle),
                                                style: AppTheme.getCaptionStyle(
                                                  context,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ],
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: markerColor.withValues(
                                              alpha: 0.15,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Text(
                                            _motionStateShortLabel(
                                              vehicle,
                                            ).toUpperCase(),
                                            style:
                                                AppTheme.getCaptionStyle(
                                                  context,
                                                ).copyWith(
                                                  fontWeight: FontWeight.w800,
                                                  color: markerColor,
                                                ),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        _buildSidebarFuelBadge(
                                          vehicle: vehicle,
                                          isDark: isDark,
                                        ),
                                        if (_vehicleExceptionLabels(
                                          vehicle,
                                        ).isNotEmpty) ...[
                                          const SizedBox(width: 6),
                                          _buildSidebarExceptionBadge(
                                            vehicle: vehicle,
                                            isDark: isDark,
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    Row(
                                      children: [
                                        Icon(
                                          _motionStateIcon(vehicle),
                                          size: 14,
                                          color: markerColor,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          '${_speedOf(vehicle)} km/h - ${_motionStateShortLabel(vehicle)}',
                                          style:
                                              AppTheme.getCaptionStyle(
                                                context,
                                              ).copyWith(
                                                fontWeight: FontWeight.w700,
                                                color: markerColor,
                                              ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        const Icon(
                                          Icons.explore_rounded,
                                          size: 14,
                                          color: AppTheme.colorFF27AE60,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          _directionDisplay(vehicle),
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: AppTheme.colorFF27AE60,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Icon(
                                          _ignitionOn(vehicle)
                                              ? Icons.power_settings_new_rounded
                                              : Icons.power_off_rounded,
                                          size: 14,
                                          color: _ignitionOn(vehicle)
                                              ? AppTheme.colorFFFFD166
                                              : AppTheme.colorFF95A5A6,
                                        ),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            _syncLabel(vehicle),
                                            style:
                                                AppTheme.getCaptionStyle(
                                                  context,
                                                ).copyWith(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        const Icon(
                                          Icons.info_outline_rounded,
                                          size: 14,
                                          color: AppTheme.colorFFE74C3C,
                                        ),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: SelectableText(
                                            _lastKnownAddressLabel(vehicle),
                                            style: AppTheme.getCaptionStyle(
                                              context,
                                            ),
                                            maxLines: 1,
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (_shouldShowSidebarContext(vehicle)) ...[
                                      const SizedBox(height: 10),
                                      _buildSidebarContextPills(
                                        vehicle: vehicle,
                                        markerColor: markerColor,
                                        isDark: isDark,
                                        isMobile: false,
                                      ),
                                    ],
                                    if (isSelected) ...[
                                      const SizedBox(height: 12),
                                      _buildSidebarVehicleDetailPanel(
                                        vehicle: vehicle,
                                        markerColor: markerColor,
                                        isDark: isDark,
                                        isMobile: false,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrackedVehiclesHeader({
    required bool isDark,
    required int visibleCount,
  }) {
    return _buildSidebarDropdownHeader(
      isDark: isDark,
      icon: Icons.sensors_rounded,
      title: 'Tracked Vehicles',
      countLabel: '$visibleCount/${_vehicleMarkers.length}',
      expanded: _sidebarVehiclesExpanded,
      onTap: () =>
          setState(() => _sidebarVehiclesExpanded = !_sidebarVehiclesExpanded),
    );
  }

  Widget _buildSidebarDropdownHeader({
    required bool isDark,
    required IconData icon,
    required String title,
    required String countLabel,
    required bool expanded,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
          child: Row(
            children: [
              Icon(icon, size: 16, color: AppTheme.colorFF4B7BE5),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.getCaptionStyle(context).copyWith(
                    fontWeight: FontWeight.w900,
                    color: isDark ? AppTheme.white : AppTheme.colorFF1F2937,
                  ),
                ),
              ),
              _buildSidebarCountPill(countLabel),
              const SizedBox(width: 6),
              AnimatedRotation(
                duration: const Duration(milliseconds: 180),
                turns: expanded ? 0.5 : 0,
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 20,
                  color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSidebarVehiclesCollapsedState(bool isDark) {
    return Center(
      child: TextButton.icon(
        onPressed: () => setState(() => _sidebarVehiclesExpanded = true),
        icon: const Icon(Icons.unfold_more_rounded, size: 16),
        label: const Text('Show tracked vehicles'),
        style: TextButton.styleFrom(
          foregroundColor: AppTheme.colorFF4B7BE5,
          textStyle: const TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
    );
  }

  Widget _buildSidebarCountPill(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w900,
          color: AppTheme.colorFF4B7BE5,
        ),
      ),
    );
  }

  Widget _buildSidebarStatusLegend({
    required bool isDark,
    required bool isMobile,
  }) {
    final expanded = isMobile || _sidebarFleetStatusExpanded;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _buildSidebarDropdownHeader(
          isDark: isDark,
          icon: Icons.filter_alt_rounded,
          title: _sidebarStatusFilter == null
              ? 'Fleet Status'
              : 'Fleet: ${_sidebarStatusFilterLabel(_sidebarStatusFilter!)}',
          countLabel: '${_sidebarVehicles.length}/${_vehicleMarkers.length}',
          expanded: expanded,
          onTap: isMobile
              ? () {}
              : () => setState(
                  () => _sidebarFleetStatusExpanded =
                      !_sidebarFleetStatusExpanded,
                ),
        ),
        if (_sidebarStatusFilter != null)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: TextButton.icon(
                onPressed: () => setState(() => _sidebarStatusFilter = null),
                icon: const Icon(Icons.close_rounded, size: 13),
                label: const Text('Clear'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: AppTheme.colorFF4B7BE5,
                  textStyle: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
          ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: Column(
            children: [
              const SizedBox(height: 6),
              Wrap(
                alignment: WrapAlignment.center,
                runAlignment: WrapAlignment.center,
                spacing: 7,
                runSpacing: 7,
                children: [
                  _buildSidebarLegendChip(
                    label: 'All',
                    count: _vehicleMarkers.length,
                    icon: Icons.select_all_rounded,
                    color: AppTheme.colorFF4B7BE5,
                    state: null,
                    isDark: isDark,
                  ),
                  _buildSidebarLegendChip(
                    label: 'Moving',
                    count: _sidebarCountFor(PioneerMapMarkerStyle.moving),
                    icon: Icons.navigation_rounded,
                    color: AppTheme.successGreen,
                    state: PioneerMapMarkerStyle.moving,
                    isDark: isDark,
                  ),
                  _buildSidebarLegendChip(
                    label: 'Idling',
                    count: _sidebarCountFor(PioneerMapMarkerStyle.idle),
                    icon: Icons.pause_circle_filled_rounded,
                    color: AppTheme.warningOrange,
                    state: PioneerMapMarkerStyle.idle,
                    isDark: isDark,
                  ),
                  _buildSidebarLegendChip(
                    label: 'Stopped',
                    count: _sidebarCountFor(PioneerMapMarkerStyle.offline),
                    icon: Icons.power_settings_new_rounded,
                    color: AppTheme.colorFF64748B,
                    state: PioneerMapMarkerStyle.offline,
                    isDark: isDark,
                  ),
                  _buildSidebarLegendChip(
                    label: 'Offline',
                    count: _sidebarCountFor(PioneerMapMarkerStyle.stale),
                    icon: Icons.cloud_off_rounded,
                    color: AppTheme.colorFF94A3B8,
                    state: PioneerMapMarkerStyle.stale,
                    isDark: isDark,
                  ),
                ],
              ),
            ],
          ),
          crossFadeState: expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 180),
          sizeCurve: Curves.easeOutCubic,
        ),
      ],
    );
  }

  String _sidebarStatusFilterLabel(PioneerMapMarkerStyle state) {
    switch (state) {
      case PioneerMapMarkerStyle.moving:
        return 'Moving';
      case PioneerMapMarkerStyle.idle:
        return 'Idling';
      case PioneerMapMarkerStyle.offline:
        return 'Stopped';
      case PioneerMapMarkerStyle.stale:
        return 'Offline';
    }
  }

  Widget _buildSidebarLegendChip({
    required String label,
    required int count,
    required IconData icon,
    required Color color,
    required PioneerMapMarkerStyle? state,
    required bool isDark,
  }) {
    final selected = _sidebarStatusFilter == state;
    return Tooltip(
      message: state == null ? 'Show all vehicles' : 'Show $label vehicles',
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => setState(() => _sidebarStatusFilter = state),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? color.withValues(alpha: isDark ? 0.24 : 0.16)
                : (isDark
                      ? AppTheme.white.withValues(alpha: 0.05)
                      : AppTheme.white),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? color.withValues(alpha: 0.58)
                  : AppTheme.getBorderColor(context),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  color: isDark ? AppTheme.gray200 : AppTheme.colorFF334155,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSidebarEmptyFilterState(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.filter_alt_off_rounded,
              size: 34,
              color: isDark ? AppTheme.gray500 : AppTheme.gray400,
            ),
            const SizedBox(height: 10),
            Text(
              'No vehicles in this status',
              textAlign: TextAlign.center,
              style: AppTheme.getCaptionStyle(context).copyWith(
                fontWeight: FontWeight.w900,
                color: isDark ? AppTheme.gray300 : AppTheme.colorFF475569,
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => setState(() => _sidebarStatusFilter = null),
              icon: const Icon(Icons.clear_all_rounded, size: 16),
              label: const Text('Show all'),
            ),
          ],
        ),
      ),
    );
  }

  int _sidebarCountFor(PioneerMapMarkerStyle state) {
    return _vehicleMarkers
        .where((vehicle) => _visualMarkerState(vehicle) == state)
        .length;
  }

  Widget _buildSidebarStateGlyph({
    required Map<String, dynamic> vehicle,
    required PioneerMapMarkerStyle state,
    required Color color,
  }) {
    final iconTile = Container(
      key: ValueKey(state),
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.52), width: 2),
        boxShadow: [
          BoxShadow(
            color: color.withValues(
              alpha: state == PioneerMapMarkerStyle.stale ? 0.15 : 0.27,
            ),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Center(
        child: Transform.rotate(
          angle: state == PioneerMapMarkerStyle.moving
              ? (_bearingOf(vehicle) * math.pi / 180)
              : 0,
          child: Icon(
            _motionStateIcon(vehicle),
            color: color,
            size: state == PioneerMapMarkerStyle.moving ? 27 : 22,
          ),
        ),
      ),
    );
    if (state != PioneerMapMarkerStyle.idle) {
      return iconTile;
    }

    return ScaleTransition(
      scale: Tween<double>(begin: 0.94, end: 1.06).animate(
        CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
      ),
      child: iconTile,
    );
  }

  Widget _buildSidebarContextPills({
    required Map<String, dynamic> vehicle,
    required Color markerColor,
    required bool isDark,
    required bool isMobile,
  }) {
    final pills = <Widget>[];

    void addPill({
      required IconData icon,
      required String label,
      required Color color,
    }) {
      if (label.trim().isEmpty) {
        return;
      }
      pills.add(
        _buildSidebarContextPill(
          icon: icon,
          label: label,
          color: color,
          isDark: isDark,
          isMobile: isMobile,
        ),
      );
    }

    final predictiveOnlyWeather =
        !_showWeatherContext && _showPredictiveContext;
    final predictiveOnlyTraffic = !_showTrafficEta && _showPredictiveContext;
    final showWeather = _showWeatherContext || _showPredictiveContext;
    final showTraffic = _showTrafficEta || _showPredictiveContext;
    final showRoute = _showRoutePath || _showPredictiveContext;
    final showTrail = _showVehicleTrail || _showPredictiveContext;

    if (showWeather) {
      addPill(
        icon: Icons.thermostat_rounded,
        label: _selectedTemperatureLabel(
          vehicle,
          forcePredictive: predictiveOnlyWeather,
        ),
        color: AppTheme.colorFFE67E22,
      );
      addPill(
        icon: Icons.water_drop_rounded,
        label: _selectedHumidityLabel(
          vehicle,
          forcePredictive: predictiveOnlyWeather,
        ),
        color: AppTheme.colorFF4B7BE5,
      );
    }
    if (showTraffic) {
      final trafficChips = _selectedTrafficChipData(
        vehicle,
        forcePredictive: predictiveOnlyTraffic,
      );
      for (final chip in trafficChips.take(2)) {
        addPill(
          icon: chip['icon'] as IconData,
          label: chip['label'] as String,
          color: chip['color'] as Color,
        );
      }
    }
    if (showRoute) {
      addPill(
        icon: Icons.alt_route_rounded,
        label: _selectedRoutePathLabel(vehicle),
        color: _routePathIsRoadAware(vehicle)
            ? AppTheme.colorFF7C3AED
            : AppTheme.colorFF64748B,
      );
    }
    if (showTrail) {
      addPill(
        icon: Icons.timeline_rounded,
        label: _selectedTrailLabel(vehicle),
        color: _isVehicleMoving(vehicle)
            ? AppTheme.colorFF0E7A43
            : AppTheme.colorFF64748B,
      );
    }

    if (pills.isEmpty) {
      addPill(
        icon: Icons.sensors_rounded,
        label: _motionStateShortLabel(vehicle),
        color: markerColor,
      );
    }

    return Wrap(spacing: 6, runSpacing: 6, children: pills);
  }

  bool _shouldShowSidebarContext(Map<String, dynamic> vehicle) {
    return _hasEnvironmentOrTraffic(vehicle) ||
        _showWeatherContext ||
        _showTrafficEta ||
        _showRoutePath ||
        _showVehicleTrail ||
        _showPredictiveContext;
  }

  Widget _buildSidebarVehicleDetailPanel({
    required Map<String, dynamic> vehicle,
    required Color markerColor,
    required bool isDark,
    required bool isMobile,
  }) {
    final fuelPercent = _fuelPercentOf(vehicle);
    final fuelColor = _fuelStatusColor(vehicle);
    final exceptions = _vehicleExceptionLabels(vehicle);
    final vehicleTags = _vehicleOperationalTags(vehicle);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      width: double.infinity,
      padding: EdgeInsets.all(isMobile ? 10 : 12),
      decoration: BoxDecoration(
        color: isDark
            ? AppTheme.colorFF111827.withValues(alpha: 0.82)
            : AppTheme.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: markerColor.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in vehicleTags)
                _buildSidebarMiniBadge(
                  label: tag,
                  color: AppTheme.colorFF4B7BE5,
                  isDark: isDark,
                ),
            ],
          ),
          const SizedBox(height: 10),
          _buildSidebarActionGrid(vehicle: vehicle, isMobile: isMobile),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildOperationalMetricTile(
                icon: _ignitionOn(vehicle)
                    ? Icons.power_settings_new_rounded
                    : Icons.power_off_rounded,
                label: 'Ignition',
                value: _ignitionOn(vehicle) ? 'On' : 'Off',
                color: _ignitionOn(vehicle)
                    ? AppTheme.colorFF27AE60
                    : AppTheme.colorFFE74C3C,
                isDark: isDark,
              ),
              _buildOperationalMetricTile(
                icon: Icons.local_gas_station_rounded,
                label: 'Fuel level',
                value: fuelPercent == null ? 'N/A' : '${fuelPercent.round()}%',
                color: fuelColor,
                isDark: isDark,
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildSidebarDetailRow(
            icon: Icons.location_on_rounded,
            label: 'Location',
            value: _lastKnownAddressLabel(vehicle),
            color: AppTheme.colorFF4B7BE5,
            isDark: isDark,
          ),
          _buildSidebarDetailRow(
            icon: Icons.gps_fixed_rounded,
            label: 'GPS',
            value:
                '${_latitudeOf(vehicle).toStringAsFixed(6)}, ${_longitudeOf(vehicle).toStringAsFixed(6)}',
            color: AppTheme.colorFF0EA5E9,
            isDark: isDark,
          ),
          _buildSidebarDetailRow(
            icon: Icons.hexagon_rounded,
            label: 'Zone',
            value: _zoneLabel(vehicle),
            color: AppTheme.colorFFF59E0B,
            isDark: isDark,
          ),
          _buildSidebarDetailRow(
            icon: Icons.person_rounded,
            label: 'Driver',
            value: _driverLabelOf(vehicle),
            color: AppTheme.colorFF0EA5E9,
            isDark: isDark,
          ),
          _buildSidebarDetailRow(
            icon: Icons.access_time_rounded,
            label: 'Status',
            value: _statusLabel(vehicle),
            color: markerColor,
            isDark: isDark,
          ),
          if (exceptions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'Exceptions',
              style: AppTheme.getCaptionStyle(context).copyWith(
                fontWeight: FontWeight.w900,
                color: isDark ? AppTheme.white : AppTheme.colorFF1F2937,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final exception in exceptions.take(3))
                  _buildSidebarMiniBadge(
                    label: exception,
                    color: _exceptionColor(exception),
                    isDark: isDark,
                    icon: Icons.warning_amber_rounded,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSidebarActionGrid({
    required Map<String, dynamic> vehicle,
    required bool isMobile,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = isMobile || constraints.maxWidth < 330 ? 2 : 4;
        return GridView.count(
          crossAxisCount: columns,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: columns == 2 ? 2.55 : 1.08,
          children: [
            _buildSidebarActionButton(
              icon: Icons.my_location_rounded,
              label: 'Locate',
              color: AppTheme.colorFF4B7BE5,
              onTap: () => unawaited(_locateSidebarVehicle(vehicle)),
            ),
            _buildSidebarActionButton(
              icon: Icons.route_rounded,
              label: 'Trip',
              color: AppTheme.colorFF7C3AED,
              onTap: () => unawaited(_focusVehicleTrip(vehicle)),
            ),
            _buildSidebarActionButton(
              icon: Icons.share_location_rounded,
              label: 'Share',
              color: AppTheme.colorFF0EA5E9,
              onTap: () => unawaited(_shareVehicleLocation(vehicle)),
            ),
            _buildSidebarActionButton(
              icon: Icons.streetview_rounded,
              label: 'Street',
              color: AppTheme.colorFF64748B,
              onTap: () => unawaited(_openVehicleOperationsSheet(vehicle)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSidebarActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Tooltip(
      message: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              color: color.withValues(alpha: isDark ? 0.14 : 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: color.withValues(alpha: 0.30)),
            ),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 18, color: color),
                    const SizedBox(height: 5),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w900,
                        color: isDark ? AppTheme.white : AppTheme.colorFF1F2937,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOperationalMetricTile({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    required bool isDark,
  }) {
    return Container(
      constraints: const BoxConstraints(minWidth: 106),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 7),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                  color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  color: isDark ? AppTheme.white : AppTheme.colorFF1F2937,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarDetailRow({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    required bool isDark,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 7),
          SizedBox(
            width: 68,
            child: Text(
              label,
              style: AppTheme.getCaptionStyle(context).copyWith(
                fontWeight: FontWeight.w800,
                color: isDark ? AppTheme.gray400 : AppTheme.gray600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.getCaptionStyle(context).copyWith(
                fontWeight: FontWeight.w800,
                color: isDark ? AppTheme.white : AppTheme.colorFF1F2937,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarMiniBadge({
    required String label,
    required Color color,
    required bool isDark,
    IconData? icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.42)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w900,
              color: isDark ? AppTheme.white : AppTheme.colorFF1F2937,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarFuelBadge({
    required Map<String, dynamic> vehicle,
    required bool isDark,
  }) {
    final percent = _fuelPercentOf(vehicle);
    final color = _fuelStatusColor(vehicle);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.38)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.local_gas_station_rounded, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            percent == null ? 'N/A' : '${percent.round()}%',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarExceptionBadge({
    required Map<String, dynamic> vehicle,
    required bool isDark,
  }) {
    final exceptions = _vehicleExceptionLabels(vehicle);
    final color = _exceptionColor(exceptions.first);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.42)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber_rounded, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            '${exceptions.length}',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarContextPill({
    required IconData icon,
    required String label,
    required Color color,
    required bool isDark,
    required bool isMobile,
  }) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: isMobile ? 148 : 190),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: isMobile ? 7 : 8,
          vertical: isMobile ? 4 : 5,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: isDark ? 0.16 : 0.10),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.24)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: isMobile ? 12 : 13, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: isMobile ? 10 : 10.5,
                  fontWeight: FontWeight.w800,
                  color: isDark ? AppTheme.gray200 : AppTheme.colorFF334155,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRouteOrdersPanel({
    required bool isDark,
    required bool isMobile,
    bool closeOnSelect = false,
  }) {
    final orders = _routeOrders;
    final expanded = isMobile || closeOnSelect || _sidebarRouteOrdersExpanded;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSidebarDropdownHeader(
          isDark: isDark,
          icon: Icons.assignment_rounded,
          title: 'GeoTab Route Orders',
          countLabel: '${orders.length}',
          expanded: expanded,
          onTap: isMobile || closeOnSelect
              ? () {}
              : () => setState(
                  () => _sidebarRouteOrdersExpanded =
                      !_sidebarRouteOrdersExpanded,
                ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 10),
              if (orders.isEmpty)
                Text(
                  'No planned route orders are available yet.',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                  ),
                )
              else
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: isMobile ? 180 : 220),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: orders.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final order = orders[index];
                      return _buildRouteOrderTile(
                        order,
                        isDark: isDark,
                        isMobile: isMobile,
                        closeOnSelect: closeOnSelect,
                      );
                    },
                  ),
                ),
            ],
          ),
          crossFadeState: expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 180),
          sizeCurve: Curves.easeOutCubic,
        ),
      ],
    );
  }

  Widget _buildRouteOrderTile(
    Map<String, dynamic> order, {
    required bool isDark,
    required bool isMobile,
    required bool closeOnSelect,
  }) {
    final vehicle = _routeOrderVehicle(order);
    final isAssigned =
        vehicle.isNotEmpty && vehicle.toLowerCase() != 'unassigned';
    final status =
        order['status']?.toString().trim().toLowerCase() ?? 'pending';
    final stops = ((order['routedPlaces'] as List?) ?? const []).length;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _selectRouteOrder(order, closeOnSelect: closeOnSelect),
      child: Container(
        padding: EdgeInsets.all(isMobile ? 10 : 12),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isAssigned
                ? AppTheme.colorFF4B7BE5.withValues(alpha: 0.18)
                : AppTheme.colorFFF59E0B.withValues(alpha: 0.24),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _routeOrderTitle(order),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: isMobile ? 12 : 13,
                      fontWeight: FontWeight.w900,
                      color: isDark ? AppTheme.white : AppTheme.colorFF1F2937,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: _routeOrderStatusColor(
                      status,
                    ).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    status.toUpperCase(),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                      color: _routeOrderStatusColor(status),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              '${_routeOrderOrigin(order)} to ${_routeOrderDestination(order)}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: isMobile ? 10.5 : 11.5,
                height: 1.3,
                color: isDark ? AppTheme.gray300 : AppTheme.colorFF374151,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  isAssigned
                      ? Icons.local_shipping_rounded
                      : Icons.link_off_rounded,
                  size: 14,
                  color: isAssigned
                      ? AppTheme.colorFF4B7BE5
                      : AppTheme.colorFFF59E0B,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    isAssigned ? vehicle : 'Unassigned route',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  stops == 0 ? 'No stops' : '$stops stops',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectRouteOrder(
    Map<String, dynamic> order, {
    required bool closeOnSelect,
  }) async {
    final plate = _routeOrderVehicle(order);
    if (plate.isEmpty || plate.toLowerCase() == 'unassigned') {
      _showLiveTrackingHint(
        'This route order is not assigned to a vehicle yet.',
      );
      return;
    }

    final vehicle = _vehicleMarkers.cast<Map<String, dynamic>?>().firstWhere(
      (item) => _plateOf(item) == plate,
      orElse: () => null,
    );
    if (vehicle == null) {
      _showLiveTrackingHint('$plate is assigned but is not reporting GPS yet.');
      return;
    }

    await _selectVehicle(vehicle);
    if (closeOnSelect && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  void _showLiveTrackingHint(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _locateSidebarVehicle(Map<String, dynamic> vehicle) async {
    await _selectVehicle(vehicle);
    final zoom = math.max(_currentMapZoom, 17.0);
    _moveMap(_animatedLatLngOf(vehicle), zoom);
    _showLiveTrackingHint('${_plateLabelOf(vehicle)} centered on the map.');
  }

  Future<void> _focusVehicleTrip(Map<String, dynamic> vehicle) async {
    final plate = _plateLabelOf(vehicle);
    if (mounted) {
      setState(() {
        _showRoutePath = true;
        _showVehicleTrail = true;
        _sidebarRouteOrdersExpanded = true;
      });
    }
    await _selectVehicle(vehicle);
    if (!mounted) {
      return;
    }
    _showLiveTrackingHint('Opening $plate trip history and route replay.');
    await Navigator.of(context).pushNamed(
      '/trips',
      arguments: {
        'vehicle': plate,
        'openTripForVehicle': true,
        'source': 'live-tracking',
      },
    );
  }

  Future<void> _shareVehicleLocation(Map<String, dynamic> vehicle) async {
    final point = _animatedLatLngOf(vehicle);
    final fuelPercent = _fuelPercentOf(vehicle);
    final mapsUrl = _googleMapsUrl(point.latitude, point.longitude);
    final text = [
      _plateLabelOf(vehicle),
      _statusLabel(vehicle),
      'Location: ${_lastKnownAddressLabel(vehicle)}',
      'GPS: ${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}',
      'Map: $mapsUrl',
      'Fuel: ${fuelPercent == null ? 'N/A' : '${fuelPercent.round()}%'}',
      'Ignition: ${_ignitionOn(vehicle) ? 'On' : 'Off'}',
      _lastSeenLabel(vehicle),
    ].join('\n');

    await Clipboard.setData(ClipboardData(text: text));
    _showLiveTrackingHint(
      '${_plateLabelOf(vehicle)} exact map link copied for sharing.',
    );
  }

  Future<void> _openVehicleOperationsSheet(Map<String, dynamic> vehicle) async {
    await _openStreetViewForVehicle(vehicle);
  }

  Future<void> _openStreetViewForVehicle(Map<String, dynamic> vehicle) async {
    final point = _animatedLatLngOf(vehicle);
    final url = _streetViewUrl(point.latitude, point.longitude);
    final opened = await openExternalLink(url);
    if (opened) {
      _showLiveTrackingHint(
        'Street View opened for ${_plateLabelOf(vehicle)}.',
      );
      return;
    }

    await Clipboard.setData(ClipboardData(text: url));
    _showLiveTrackingHint(
      'Street View link copied for ${_plateLabelOf(vehicle)}.',
    );
  }

  String _googleMapsUrl(double latitude, double longitude) {
    return 'https://www.google.com/maps/search/?api=1&query=${latitude.toStringAsFixed(6)},${longitude.toStringAsFixed(6)}';
  }

  String _streetViewUrl(double latitude, double longitude) {
    return 'https://www.google.com/maps/@?api=1&map_action=pano&viewpoint=${latitude.toStringAsFixed(6)},${longitude.toStringAsFixed(6)}';
  }

  // ignore: unused_element
  void _showVehicleOperationsSheet(Map<String, dynamic> vehicle) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final markerColor = _sidebarStateAccent(vehicle);
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.colorFF111827 : AppTheme.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: markerColor.withValues(alpha: 0.30)),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.black.withValues(alpha: 0.28),
                  blurRadius: 24,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _buildSidebarStateGlyph(
                      vehicle: vehicle,
                      state: _visualMarkerState(vehicle),
                      color: markerColor,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _plateLabelOf(vehicle),
                            style: AppTheme.getHeadingStyle(
                              context,
                              fontSize: 18,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _statusLabel(vehicle),
                            style: AppTheme.getCaptionStyle(context).copyWith(
                              color: markerColor,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _buildOperationalMetricTile(
                      icon: Icons.speed_rounded,
                      label: 'Speed',
                      value: '${_speedOf(vehicle)} km/h',
                      color: markerColor,
                      isDark: isDark,
                    ),
                    _buildOperationalMetricTile(
                      icon: Icons.local_gas_station_rounded,
                      label: 'Fuel',
                      value: _fuelPercentOf(vehicle) == null
                          ? 'N/A'
                          : '${_fuelPercentOf(vehicle)!.round()}%',
                      color: _fuelStatusColor(vehicle),
                      isDark: isDark,
                    ),
                    _buildOperationalMetricTile(
                      icon: _ignitionOn(vehicle)
                          ? Icons.power_settings_new_rounded
                          : Icons.power_off_rounded,
                      label: 'Ignition',
                      value: _ignitionOn(vehicle) ? 'On' : 'Off',
                      color: _ignitionOn(vehicle)
                          ? AppTheme.colorFF27AE60
                          : AppTheme.colorFFE74C3C,
                      isDark: isDark,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _buildSidebarDetailRow(
                  icon: Icons.location_on_rounded,
                  label: 'Location',
                  value: _lastKnownAddressLabel(vehicle),
                  color: AppTheme.colorFF4B7BE5,
                  isDark: isDark,
                ),
                _buildSidebarDetailRow(
                  icon: Icons.gps_fixed_rounded,
                  label: 'GPS',
                  value:
                      '${_latitudeOf(vehicle).toStringAsFixed(6)}, ${_longitudeOf(vehicle).toStringAsFixed(6)}',
                  color: AppTheme.colorFF0EA5E9,
                  isDark: isDark,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.of(sheetContext).pop();
                          unawaited(_locateSidebarVehicle(vehicle));
                        },
                        icon: const Icon(Icons.my_location_rounded),
                        label: const Text('Locate'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () {
                          Navigator.of(sheetContext).pop();
                          unawaited(_shareVehicleLocation(vehicle));
                        },
                        icon: const Icon(Icons.share_location_rounded),
                        label: const Text('Share'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showVehicleListBottomSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.transparent,
      isScrollControlled: true,
      builder: (context) {
        final sheetVehicles = _sidebarVehicles;
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.85,
          builder: (context, scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
              ),
              child: Column(
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: isDark ? AppTheme.gray700 : AppTheme.gray300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.all(isMobile ? 16 : 20),
                    child: Row(
                      children: [
                        Icon(
                          Icons.route_rounded,
                          color: AppTheme.colorFF4B7BE5,
                          size: isMobile ? 20 : 24,
                        ),
                        SizedBox(width: isMobile ? 8 : 12),
                        Text(
                          'Live Orders',
                          style: AppTheme.getHeadingStyle(
                            context,
                            fontSize: isMobile ? 16 : 18,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _buildRouteOrdersPanel(
                    isDark: isDark,
                    isMobile: isMobile,
                    closeOnSelect: true,
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      isMobile ? 16 : 20,
                      10,
                      isMobile ? 16 : 20,
                      8,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.sensors_rounded,
                          size: isMobile ? 16 : 18,
                          color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                        ),
                        SizedBox(width: isMobile ? 6 : 8),
                        Text(
                          'Tracked Vehicles',
                          style: AppTheme.getCaptionStyle(
                            context,
                          ).copyWith(fontWeight: FontWeight.w900),
                        ),
                        const Spacer(),
                        Text(
                          '${sheetVehicles.length}/${_vehicleMarkers.length}',
                          style: AppTheme.getCaptionStyle(context).copyWith(
                            color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: sheetVehicles.isEmpty
                        ? _buildSidebarEmptyFilterState(isDark)
                        : ListView.builder(
                            controller: scrollController,
                            itemCount: sheetVehicles.length,
                            padding: EdgeInsets.only(
                              bottom: isMobile ? 16 : 20,
                            ),
                            itemBuilder: (context, index) {
                              final vehicle = sheetVehicles[index];
                              final isSelected =
                                  _plateOf(vehicle) == selectedPlate;
                              final markerState = _visualMarkerState(vehicle);
                              final markerColor = _sidebarStateAccent(vehicle);
                              final baseCardColor = isDark
                                  ? AppTheme.colorFF252930
                                  : AppTheme.colorFFF8F9FA;
                              final outlineColor = isSelected
                                  ? markerColor.withValues(alpha: 0.7)
                                  : (isDark
                                        ? AppTheme.white.withValues(alpha: 0.05)
                                        : AppTheme.black.withValues(
                                            alpha: 0.05,
                                          ));

                              return GestureDetector(
                                onTap: () async {
                                  await _selectVehicle(vehicle);
                                  if (mounted) {
                                    Navigator.pop(context);
                                  }
                                },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 240),
                                  curve: Curves.easeOutCubic,
                                  margin: EdgeInsets.symmetric(
                                    horizontal: isMobile ? 12 : 20,
                                    vertical: isMobile ? 4 : 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Color.alphaBlend(
                                      markerColor.withValues(
                                        alpha: isSelected ? 0.12 : 0.07,
                                      ),
                                      baseCardColor,
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: outlineColor,
                                      width: isSelected ? 1.5 : 1,
                                    ),
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: Stack(
                                    children: [
                                      Positioned.fill(
                                        right: null,
                                        child: Container(
                                          width: 4,
                                          color: markerColor,
                                        ),
                                      ),
                                      Padding(
                                        padding: EdgeInsets.all(
                                          isMobile ? 12 : 16,
                                        ),
                                        child: Row(
                                          children: [
                                            _buildSidebarStateGlyph(
                                              vehicle: vehicle,
                                              state: markerState,
                                              color: markerColor,
                                            ),
                                            SizedBox(width: isMobile ? 12 : 16),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  SelectableText(
                                                    _plateLabelOf(vehicle),
                                                    style:
                                                        AppTheme.getHeadingStyle(
                                                          context,
                                                          fontSize: 16,
                                                        ).copyWith(
                                                          fontWeight:
                                                              FontWeight.w900,
                                                        ),
                                                  ),
                                                  SizedBox(
                                                    height: isMobile ? 2 : 4,
                                                  ),
                                                  Text(
                                                    _driverLabelOf(vehicle),
                                                    style:
                                                        AppTheme.getCaptionStyle(
                                                          context,
                                                        ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                  SizedBox(
                                                    height: isMobile ? 6 : 8,
                                                  ),
                                                  Text(
                                                    '${_speedOf(vehicle)} km/h - ${_motionStateShortLabel(vehicle)}',
                                                    style:
                                                        AppTheme.getCaptionStyle(
                                                          context,
                                                        ).copyWith(
                                                          fontWeight:
                                                              FontWeight.w700,
                                                          color: markerColor,
                                                        ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                  const SizedBox(height: 4),
                                                  SelectableText(
                                                    _lastKnownAddressLabel(
                                                      vehicle,
                                                    ),
                                                    style:
                                                        AppTheme.getCaptionStyle(
                                                          context,
                                                        ),
                                                    maxLines: 1,
                                                  ),
                                                  if (_shouldShowSidebarContext(
                                                    vehicle,
                                                  )) ...[
                                                    SizedBox(
                                                      height: isMobile ? 8 : 10,
                                                    ),
                                                    _buildSidebarContextPills(
                                                      vehicle: vehicle,
                                                      markerColor: markerColor,
                                                      isDark: isDark,
                                                      isMobile: isMobile,
                                                    ),
                                                  ],
                                                  if (_plateOf(vehicle) ==
                                                      selectedPlate) ...[
                                                    SizedBox(
                                                      height: isMobile ? 8 : 10,
                                                    ),
                                                    _buildSidebarVehicleDetailPanel(
                                                      vehicle: vehicle,
                                                      markerColor: markerColor,
                                                      isDark: isDark,
                                                      isMobile: isMobile,
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSelectedVehicleCard(Map<String, dynamic> vehicle) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600;

    return Container(
      padding: EdgeInsets.all(isMobile ? 10 : 14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        borderRadius: BorderRadius.circular(isMobile ? 14 : 16),
        boxShadow: [
          BoxShadow(
            color: AppTheme.black.withValues(alpha: isDark ? 0.4 : 0.08),
            blurRadius: 16,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: isMobile ? 40 : 48,
            height: isMobile ? 40 : 48,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: _motionStateGradient(vehicle)),
              borderRadius: BorderRadius.circular(isMobile ? 11 : 13),
            ),
            child: Icon(
              _motionStateIcon(vehicle),
              color: AppTheme.white,
              size: isMobile ? 21 : 27,
            ),
          ),
          SizedBox(width: isMobile ? 9 : 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _plateOf(vehicle),
                  style: TextStyle(
                    fontSize: isMobile ? 14 : 17,
                    fontWeight: FontWeight.w900,
                    color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                  ),
                ),
                SizedBox(height: isMobile ? 3 : 5),
                Wrap(
                  spacing: isMobile ? 7 : 10,
                  runSpacing: 3,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.speed_rounded,
                          size: isMobile ? 13 : 14,
                          color: AppTheme.colorFF4B7BE5,
                        ),
                        SizedBox(width: isMobile ? 4 : 6),
                        Text(
                          '${_speedOf(vehicle)} km/h',
                          style: TextStyle(
                            fontSize: isMobile ? 10.5 : 12,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.colorFF4B7BE5,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.route_rounded,
                          size: isMobile ? 13 : 14,
                          color: AppTheme.colorFF27AE60,
                        ),
                        SizedBox(width: isMobile ? 4 : 6),
                        Text(
                          _statusLabel(vehicle),
                          style: TextStyle(
                            fontSize: isMobile ? 10.5 : 12,
                            color: isDark
                                ? AppTheme.gray300
                                : AppTheme.colorFF2C3E50,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.explore_rounded,
                          size: isMobile ? 13 : 14,
                          color: AppTheme.colorFF27AE60,
                        ),
                        SizedBox(width: isMobile ? 4 : 6),
                        Text(
                          _directionDisplay(vehicle),
                          style: TextStyle(
                            fontSize: isMobile ? 10.5 : 12,
                            color: AppTheme.colorFF27AE60,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _ignitionOn(vehicle)
                              ? Icons.power_settings_new_rounded
                              : Icons.power_off_rounded,
                          size: isMobile ? 13 : 14,
                          color: _ignitionOn(vehicle)
                              ? AppTheme.colorFFFFD166
                              : AppTheme.colorFF95A5A6,
                        ),
                        SizedBox(width: isMobile ? 4 : 6),
                        Text(
                          _syncLabel(vehicle),
                          style: TextStyle(
                            fontSize: isMobile ? 10.5 : 12,
                            color: isDark
                                ? AppTheme.gray300
                                : AppTheme.colorFF2C3E50,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                if (_shouldShowSelectedVehicleIntelligence(vehicle)) ...[
                  SizedBox(height: isMobile ? 6 : 8),
                  _buildSelectedVehicleIntelligenceCard(
                    vehicle: vehicle,
                    isDark: isDark,
                    isMobile: isMobile,
                  ),
                ],
                if (_isFollowingSelected) ...[
                  SizedBox(height: isMobile ? 5 : 7),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.my_location_rounded,
                          size: 12,
                          color: AppTheme.colorFF4B7BE5,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Following ${_plateOf(vehicle)}',
                          style: TextStyle(
                            fontSize: isMobile ? 10.5 : 11,
                            fontWeight: FontWeight.w700,
                            color: isDark
                                ? AppTheme.white
                                : AppTheme.colorFF1F2937,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                SizedBox(height: isMobile ? 5 : 7),
                Text(
                  _secondaryText(vehicle),
                  style: TextStyle(
                    fontSize: isMobile ? 10.5 : 11.5,
                    color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () {
              if (mounted) {
                setState(() {
                  selectedPlate = '';
                  _selectedTrail = const [];
                  _isFollowingSelected = false;
                });
              }
            },
            icon: Icon(
              Icons.close_rounded,
              size: isMobile ? 20 : 24,
              color: isDark ? AppTheme.gray500 : AppTheme.gray600,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  bool _shouldShowSelectedVehicleIntelligence(Map<String, dynamic> vehicle) {
    return _showWeatherContext ||
        _showTrafficEta ||
        _showRoutePath ||
        _showVehicleTrail ||
        _showPredictiveContext;
  }

  Widget _buildSelectedVehicleIntelligenceCard({
    required Map<String, dynamic> vehicle,
    required bool isDark,
    required bool isMobile,
  }) {
    final predictiveOnlyWeather =
        !_showWeatherContext && _showPredictiveContext;
    final predictiveOnlyTraffic = !_showTrafficEta && _showPredictiveContext;
    final showWeather = _showWeatherContext || _showPredictiveContext;
    final showTraffic = _showTrafficEta || _showPredictiveContext;
    final showRoute = _showRoutePath || _showPredictiveContext;
    final showTrail = _showVehicleTrail || _showPredictiveContext;
    final chips = <Widget>[
      _buildContextChip(
        icon: Icons.tune_rounded,
        label: _showPredictiveContext
            ? 'Map Intelligence predictive'
            : 'Map Intelligence active',
        color: AppTheme.colorFF4B7BE5,
        isDark: isDark,
        isMobile: isMobile,
      ),
    ];

    void addChip({
      required IconData icon,
      required String label,
      required Color color,
    }) {
      final cleanLabel = label.trim();
      if (cleanLabel.isEmpty) {
        return;
      }
      chips.add(
        _buildContextChip(
          icon: icon,
          label: cleanLabel,
          color: color,
          isDark: isDark,
          isMobile: isMobile,
        ),
      );
    }

    if (showWeather) {
      addChip(
        icon: Icons.thermostat_rounded,
        label: _selectedTemperatureLabel(
          vehicle,
          forcePredictive: predictiveOnlyWeather,
        ),
        color: AppTheme.colorFFE67E22,
      );
      addChip(
        icon: Icons.water_drop_rounded,
        label: _selectedHumidityLabel(
          vehicle,
          forcePredictive: predictiveOnlyWeather,
        ),
        color: AppTheme.colorFF4B7BE5,
      );
      addChip(
        icon: Icons.cloud_queue_rounded,
        label: _selectedWeatherConditionLabel(
          vehicle,
          forcePredictive: predictiveOnlyWeather,
        ),
        color: AppTheme.colorFF64748B,
      );
    }

    if (showTraffic) {
      for (final chip in _selectedTrafficChipData(
        vehicle,
        forcePredictive: predictiveOnlyTraffic,
      )) {
        addChip(
          icon: chip['icon'] as IconData,
          label: chip['label'] as String,
          color: chip['color'] as Color,
        );
      }
    }

    if (showRoute) {
      addChip(
        icon: Icons.alt_route_rounded,
        label: _selectedRoutePathLabel(vehicle),
        color: _routePathIsRoadAware(vehicle)
            ? AppTheme.colorFF7C3AED
            : AppTheme.colorFF64748B,
      );
    }

    if (showTrail) {
      addChip(
        icon: Icons.timeline_rounded,
        label: _selectedTrailLabel(vehicle),
        color: _visibleSelectedTrail.length > 1
            ? AppTheme.colorFF0E7A43
            : AppTheme.colorFF64748B,
      );
    }

    if (_showPredictiveContext) {
      addChip(
        icon: Icons.auto_graph_rounded,
        label: _selectedPredictiveBasisLabel(vehicle),
        color: AppTheme.colorFFF59E0B,
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: double.infinity,
      padding: EdgeInsets.all(isMobile ? 7 : 8),
      decoration: BoxDecoration(
        color: isDark
            ? AppTheme.colorFF0B1220.withValues(alpha: 0.9)
            : AppTheme.colorFFF8FAFC,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppTheme.colorFF4B7BE5.withValues(alpha: isDark ? 0.28 : 0.22),
        ),
      ),
      child: Wrap(spacing: 8, runSpacing: 8, children: chips),
    );
  }

  String _selectedTemperatureLabel(
    Map<String, dynamic> vehicle, {
    bool forcePredictive = false,
  }) {
    final live = _weatherTemperatureLabel(vehicle);
    if (!forcePredictive && live.isNotEmpty) {
      return live;
    }
    if (_showPredictiveContext) {
      return '${_estimatedAmbientTemperature(vehicle).toStringAsFixed(1)} C est.';
    }
    return 'Weather pending';
  }

  String _selectedHumidityLabel(
    Map<String, dynamic> vehicle, {
    bool forcePredictive = false,
  }) {
    final live = _weatherHumidityLabel(vehicle);
    if (!forcePredictive && live.isNotEmpty) {
      return live;
    }
    if (_showPredictiveContext) {
      return '${_estimatedHumidity(vehicle).toStringAsFixed(0)}% humidity est.';
    }
    return '';
  }

  String _selectedWeatherConditionLabel(
    Map<String, dynamic> vehicle, {
    bool forcePredictive = false,
  }) {
    final live = _weatherConditionLabel(vehicle);
    if (!forcePredictive && live.isNotEmpty) {
      return live;
    }
    if (_showPredictiveContext) {
      final temp = _estimatedAmbientTemperature(vehicle);
      final humidity = _estimatedHumidity(vehicle);
      if (humidity >= 78) {
        return 'Humid conditions est.';
      }
      if (temp >= 33) {
        return 'Heat watch est.';
      }
      return 'Local weather est.';
    }
    return '';
  }

  List<Map<String, Object>> _selectedTrafficChipData(
    Map<String, dynamic> vehicle, {
    bool forcePredictive = false,
  }) {
    if (!_isVehicleMoving(vehicle)) {
      return [
        {
          'icon': Icons.pause_circle_outline_rounded,
          'label': _ignitionOn(vehicle)
              ? 'No traffic ETA - idle'
              : 'No traffic ETA - offline',
          'color': AppTheme.colorFF64748B,
        },
      ];
    }

    final live = _trafficLabel(vehicle);
    if (!forcePredictive && live.isNotEmpty) {
      final traffic = _mapFromAny(vehicle['traffic']);
      final chips = <Map<String, Object>>[
        {
          'icon': Icons.traffic_rounded,
          'label': live,
          'color': _trafficColor(vehicle),
        },
      ];
      final durationMinutes =
          (_doubleFromAny(traffic['durationSeconds']) ?? 0) / 60;
      final delayMinutes = _doubleFromAny(traffic['delayMinutes']);
      final eta = DateTime.tryParse(traffic['eta']?.toString() ?? '');
      if (durationMinutes > 0) {
        chips.add({
          'icon': Icons.schedule_rounded,
          'label': '${durationMinutes.ceil()} min ETA',
          'color': AppTheme.colorFF27AE60,
        });
      }
      if (delayMinutes != null && delayMinutes > 0) {
        chips.add({
          'icon': Icons.timer_rounded,
          'label': '+${delayMinutes.ceil()} min traffic delay',
          'color': AppTheme.colorFFE67E22,
        });
      }
      if (eta != null) {
        chips.add({
          'icon': Icons.flag_rounded,
          'label':
              'Arrives ${eta.toLocal().hour.toString().padLeft(2, '0')}:${eta.toLocal().minute.toString().padLeft(2, '0')}',
          'color': AppTheme.colorFF4B7BE5,
        });
      }
      return chips;
    }

    final speed = _speedOf(vehicle);
    final rushHour = _isRushHour(DateTime.now());
    final severity = rushHour || speed < 12
        ? (_showPredictiveContext
              ? 'Moderate traffic est.'
              : 'Moderate traffic estimate')
        : (_showPredictiveContext
              ? 'Clear roads est.'
              : 'Clear roads estimate');
    final distanceKm = _estimatedDistanceToTargetKm(vehicle);
    final movingSpeed = math.max(speed.toDouble(), rushHour ? 18.0 : 28.0);
    final trafficMultiplier = rushHour ? 1.35 : 1.08;
    final etaMinutes = math.max(
      2,
      ((distanceKm / movingSpeed) * 60 * trafficMultiplier).round(),
    );
    return [
      {
        'icon': Icons.traffic_rounded,
        'label': severity,
        'color': rushHour ? AppTheme.colorFFE67E22 : AppTheme.colorFF27AE60,
      },
      {
        'icon': Icons.schedule_rounded,
        'label': _showPredictiveContext
            ? '$etaMinutes min ETA est.'
            : '$etaMinutes min ETA estimate',
        'color': AppTheme.colorFF27AE60,
      },
      {
        'icon': Icons.route_rounded,
        'label': '${distanceKm.toStringAsFixed(1)} km road est.',
        'color': AppTheme.colorFF4B7BE5,
      },
    ];
  }

  String _selectedRoutePathLabel(Map<String, dynamic> vehicle) {
    final pointCount = _plannedPathForVehicle(vehicle).length;
    if (pointCount < 2) {
      final targetName = _navigationTargetName(vehicle);
      if (_showPredictiveContext && targetName.isNotEmpty) {
        return 'Predicting route to $targetName';
      }
      return _showPredictiveContext
          ? 'Route prediction awaiting target'
          : 'No route path selected';
    }
    if (_routePathIsRoadAware(vehicle)) {
      return 'Road-aware route path';
    }
    return _showPredictiveContext ? 'Predicted waypoint path' : 'Waypoint path';
  }

  String _selectedTrailLabel(Map<String, dynamic> vehicle) {
    if (!_isVehicleMoving(vehicle)) {
      return 'Trail hidden - no movement';
    }
    if (_plateOf(vehicle) != selectedPlate) {
      return 'Trail available on select';
    }
    final trail = _visibleSelectedTrail;
    if (trail.length > 1) {
      final distanceKm = _cumulativeDistanceMeters(trail) / 1000;
      return 'Trail ${distanceKm.toStringAsFixed(1)} km';
    }
    return _showPredictiveContext
        ? 'Trail waiting for GPS movement'
        : 'Trail pending';
  }

  String _selectedPredictiveBasisLabel(Map<String, dynamic> vehicle) {
    final hasLiveWeather =
        _weatherTemperatureLabel(vehicle).isNotEmpty ||
        _weatherHumidityLabel(vehicle).isNotEmpty;
    final hasLiveTraffic = _trafficLabel(vehicle).isNotEmpty;
    if (hasLiveWeather || hasLiveTraffic) {
      return 'Live API enriched';
    }
    return 'Estimated from location and motion';
  }

  double _estimatedAmbientTemperature(Map<String, dynamic> vehicle) {
    final latitude = _doubleFromAny(vehicle['latitude']) ?? 14.6;
    final longitude = _doubleFromAny(vehicle['longitude']) ?? 121.0;
    final now = DateTime.now();
    final hourAngle = ((now.hour + now.minute / 60) - 14) / 24 * 2 * math.pi;
    final dailyHeat = math.cos(hourAngle) * 2.8;
    final locationOffset = ((latitude - 14.5).abs() + (longitude - 121).abs())
        .clamp(0.0, 2.5);
    final movementCooling = _speedOf(vehicle) > 25 ? -0.8 : 0.0;
    return (30.0 + dailyHeat + locationOffset + movementCooling).clamp(
      24.0,
      37.0,
    );
  }

  double _estimatedHumidity(Map<String, dynamic> vehicle) {
    final latitude = _doubleFromAny(vehicle['latitude']) ?? 14.6;
    final longitude = _doubleFromAny(vehicle['longitude']) ?? 121.0;
    final seed =
        ((_plateOf(vehicle).hashCode.abs() % 13) - 6) +
        ((latitude + longitude) % 4);
    final movingAdjustment = _speedOf(vehicle) > 20 ? -3.0 : 2.0;
    return (68.0 + seed + movingAdjustment).clamp(45.0, 92.0);
  }

  bool _isRushHour(DateTime time) {
    final hour = time.hour;
    return (hour >= 7 && hour <= 10) || (hour >= 16 && hour <= 20);
  }

  Widget _buildContextChip({
    required IconData icon,
    required String label,
    required Color color,
    required bool isDark,
    required bool isMobile,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 7 : 8,
        vertical: isMobile ? 4 : 5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.18 : 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: isMobile ? 12 : 13, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: isMobile ? 10 : 10.8,
              fontWeight: FontWeight.w800,
              color: isDark ? AppTheme.white : AppTheme.colorFF1F2937,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMapView(List<Map<String, dynamic>> vehicles) {
    return AnimatedBuilder(
      animation: Listenable.merge([_motionFrame, _pulseController]),
      builder: (context, _) {
        final selectedVehicle = _selectedVehicle;
        final showPulse =
            selectedVehicle != null &&
            _isVehicleMoving(selectedVehicle) &&
            _selectedPulseOffset != null &&
            !_usesCompactMapMarkers;

        return Stack(
          children: [
            PioneerGoogleMap(
              initialCenter: _toGoogleLatLng(_defaultCenter),
              initialZoom: 10,
              zoomControlsEnabled: false,
              trafficEnabled: _showTrafficLayer,
              mapType: _mapType,
              polygons: {
                if (_showZoneOverlays) ..._visibleZoneOverlayPolygons,
                if (_showZoneOverlays) ..._selectedGeofencePolygons,
              },
              circles: _liveTrackingCircles(vehicles),
              onMapCreated: (controller) {
                _mapController = controller;
                _refreshVisibleBounds();
                _scheduleSelectedPulseProjection();
              },
              onCameraMove: (position) {
                final previousMarkerTier = _markerZoomTier;
                _currentMapZoom = position.zoom;
                if (previousMarkerTier != _markerZoomTier && mounted) {
                  setState(() {});
                }
                _scheduleVisibleBoundsRefresh();
                _scheduleSelectedPulseProjection();
              },
              onCameraIdle: _refreshVisibleBounds,
              onTap: (_) {
                if (_isFollowingSelected && mounted) {
                  setState(() => _isFollowingSelected = false);
                }
              },
              polylines: _liveTrackingPolylines(),
              markers: {
                if (!_usesCompactMapMarkers) ..._zoneLabelMarkers,
                ...vehicles.map((vehicle) {
                  final sampleAt = DateTime.now();
                  final isSelected = _plateOf(vehicle) == selectedPlate;
                  final markerState = _visualMarkerState(vehicle);
                  final isDataStale =
                      markerState == PioneerMapMarkerStyle.stale;
                  final animatedPoint = _animatedLatLngOf(vehicle, sampleAt);

                  return gmaps.Marker(
                    markerId: gmaps.MarkerId(_plateOf(vehicle)),
                    position: _toGoogleLatLng(animatedPoint),
                    flat: true,
                    alpha: isDataStale ? 0.82 : 1.0,
                    rotation: isDataStale
                        ? 0
                        : _animatedBearingOf(vehicle, sampleAt),
                    anchor: const Offset(0.5, 0.5),
                    zIndexInt: isSelected ? 20 : 1,
                    icon: _markerIconForVehicle(
                      state: markerState,
                      isSelected: isSelected,
                      compact: _usesCompactMapMarkers,
                      large: _usesCloseMapMarkers,
                    ),
                    infoWindow: gmaps.InfoWindow(
                      title: _plateOf(vehicle),
                      snippet: _statusLabel(vehicle),
                    ),
                    onTap: () => _selectVehicle(vehicle),
                  );
                }),
              },
            ),
            if (showPulse)
              Positioned(
                left: _selectedPulseOffset!.dx - 28,
                top: _selectedPulseOffset!.dy - 28,
                child: IgnorePointer(child: _buildSelectedPulse()),
              ),
          ],
        );
      },
    );
  }

  Widget _buildMapMarkerLegend(BuildContext context, {bool compact = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final rows = [
      (
        icon: Icons.navigation_rounded,
        color: AppTheme.colorFF1A3A6B,
        label: 'Moving',
      ),
      (
        icon: Icons.pause_rounded,
        color: AppTheme.colorFFFFB020,
        label: 'Idle, ignition on',
      ),
      (
        icon: Icons.power_settings_new_rounded,
        color: AppTheme.colorFF64748B,
        label: 'Stopped, ignition off',
      ),
      (
        icon: Icons.schedule_rounded,
        color: AppTheme.colorFF94A3B8,
        label: 'Stale / offline',
      ),
    ];

    if (compact) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in rows) ...[
            _legendRow(
              icon: row.icon,
              color: row.color,
              label: row.label,
              isDark: isDark,
              compact: true,
            ),
            if (row != rows.last) const SizedBox(width: 9),
          ],
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark
            ? AppTheme.colorFF111827.withValues(alpha: 0.9)
            : AppTheme.white.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.getBorderColor(context)),
        boxShadow: [
          BoxShadow(
            color: AppTheme.black.withValues(alpha: 0.14),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final row in rows) ...[
            _legendRow(
              icon: row.icon,
              color: row.color,
              label: row.label,
              isDark: isDark,
            ),
            if (row != rows.last) const SizedBox(height: 7),
          ],
        ],
      ),
    );
  }

  Widget _legendRow({
    required IconData icon,
    required Color color,
    required String label,
    required bool isDark,
    bool compact = false,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: compact ? 18 : 22,
          height: compact ? 18 : 22,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: AppTheme.white, width: compact ? 1.5 : 2),
          ),
          child: Icon(icon, color: AppTheme.white, size: compact ? 10 : 13),
        ),
        SizedBox(width: compact ? 5 : 8),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: compact ? 10.5 : 12,
            fontWeight: FontWeight.w700,
            color: isDark ? AppTheme.white : AppTheme.colorFF1F2937,
          ),
        ),
      ],
    );
  }

  Set<gmaps.Polyline> _liveTrackingPolylines() {
    final visibleTrail = _visibleSelectedTrail;
    return {
      if (_showRoutePath && _selectedPlannedPath.length > 1)
        gmaps.Polyline(
          polylineId: const gmaps.PolylineId('selected-planned-path'),
          points: _selectedPlannedPath.map(_toGoogleLatLng).toList(),
          color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.78),
          width:
              _selectedVehicle != null &&
                  _routePathIsRoadAware(_selectedVehicle!)
              ? 5
              : 3,
          startCap: gmaps.Cap.roundCap,
          endCap: gmaps.Cap.roundCap,
          jointType: gmaps.JointType.round,
        ),
      if (_showVehicleTrail && visibleTrail.length > 1)
        gmaps.Polyline(
          polylineId: const gmaps.PolylineId('selected-live-trail-glow'),
          points: visibleTrail.map(_toGoogleLatLng).toList(),
          color: AppTheme.colorFF27AE60.withValues(alpha: 0.22),
          width: 9,
          startCap: gmaps.Cap.roundCap,
          endCap: gmaps.Cap.roundCap,
          jointType: gmaps.JointType.round,
        ),
      if (_showVehicleTrail && visibleTrail.length > 1)
        gmaps.Polyline(
          polylineId: const gmaps.PolylineId('selected-live-trail'),
          points: visibleTrail.map(_toGoogleLatLng).toList(),
          color: AppTheme.colorFF0E7A43,
          width: 4,
          startCap: gmaps.Cap.roundCap,
          endCap: gmaps.Cap.roundCap,
          jointType: gmaps.JointType.round,
        ),
    };
  }

  Set<gmaps.Circle> _liveTrackingCircles(List<Map<String, dynamic>> vehicles) {
    final pulse = _pulseController.value;
    final circles = <gmaps.Circle>{};
    for (final vehicle in vehicles) {
      final sampleAt = DateTime.now();
      final isSelected = _plateOf(vehicle) == selectedPlate;
      final markerState = _visualMarkerState(vehicle);
      final isMoving = markerState == PioneerMapMarkerStyle.moving;
      final isIdle = markerState == PioneerMapMarkerStyle.idle;
      final position = _toGoogleLatLng(_animatedLatLngOf(vehicle, sampleAt));
      final id = _markerKeyOf(vehicle)
          .split('')
          .map(
            (char) =>
                'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_'
                    .contains(char)
                ? char
                : '_',
          )
          .join();

      if (isIdle && !_usesCompactMapMarkers) {
        circles.add(
          gmaps.Circle(
            circleId: gmaps.CircleId('idle-pulse-$id'),
            center: position,
            radius: 14 + (pulse * 22),
            strokeWidth: 2,
            strokeColor: AppTheme.warningOrange.withValues(
              alpha: (0.62 * (1 - pulse)).clamp(0.0, 0.62),
            ),
            fillColor: AppTheme.warningOrange.withValues(
              alpha: (0.10 * (1 - pulse)).clamp(0.0, 0.10),
            ),
          ),
        );
      }

      if (isSelected) {
        final ringColor = _visualMarkerAccent(vehicle);
        circles.add(
          gmaps.Circle(
            circleId: gmaps.CircleId('selected-ring-$id'),
            center: position,
            radius: isMoving ? 15 : 12,
            strokeWidth: 4,
            strokeColor: ringColor.withValues(alpha: 0.88),
            fillColor: ringColor.withValues(alpha: 0.08),
          ),
        );
      }
    }

    return circles;
  }

  gmaps.BitmapDescriptor _markerIconForVehicle({
    required PioneerMapMarkerStyle state,
    required bool isSelected,
    required bool compact,
    required bool large,
  }) {
    if (compact) {
      switch (state) {
        case PioneerMapMarkerStyle.moving:
          return (isSelected
                  ? _selectedCompactMovingMarkerIcon
                  : _compactMovingMarkerIcon) ??
              gmaps.BitmapDescriptor.defaultMarkerWithHue(
                gmaps.BitmapDescriptor.hueAzure,
              );
        case PioneerMapMarkerStyle.idle:
          return (isSelected
                  ? _selectedCompactIdleMarkerIcon
                  : _compactIdleMarkerIcon) ??
              gmaps.BitmapDescriptor.defaultMarkerWithHue(
                gmaps.BitmapDescriptor.hueOrange,
              );
        case PioneerMapMarkerStyle.offline:
          return (isSelected
                  ? _selectedCompactOfflineMarkerIcon
                  : _compactOfflineMarkerIcon) ??
              gmaps.BitmapDescriptor.defaultMarkerWithHue(
                gmaps.BitmapDescriptor.hueViolet,
              );
        case PioneerMapMarkerStyle.stale:
          return (isSelected
                  ? _selectedCompactStaleMarkerIcon
                  : _compactStaleMarkerIcon) ??
              gmaps.BitmapDescriptor.defaultMarkerWithHue(
                gmaps.BitmapDescriptor.hueViolet,
              );
      }
    }
    if (large) {
      switch (state) {
        case PioneerMapMarkerStyle.moving:
          return (isSelected
                  ? _selectedLargeMovingMarkerIcon
                  : _largeMovingMarkerIcon) ??
              gmaps.BitmapDescriptor.defaultMarkerWithHue(
                gmaps.BitmapDescriptor.hueAzure,
              );
        case PioneerMapMarkerStyle.idle:
          return (isSelected
                  ? _selectedLargeIdleMarkerIcon
                  : _largeIdleMarkerIcon) ??
              gmaps.BitmapDescriptor.defaultMarkerWithHue(
                gmaps.BitmapDescriptor.hueOrange,
              );
        case PioneerMapMarkerStyle.offline:
          return (isSelected
                  ? _selectedLargeOfflineMarkerIcon
                  : _largeOfflineMarkerIcon) ??
              gmaps.BitmapDescriptor.defaultMarkerWithHue(
                gmaps.BitmapDescriptor.hueViolet,
              );
        case PioneerMapMarkerStyle.stale:
          return (isSelected
                  ? _selectedLargeStaleMarkerIcon
                  : _largeStaleMarkerIcon) ??
              gmaps.BitmapDescriptor.defaultMarkerWithHue(
                gmaps.BitmapDescriptor.hueViolet,
              );
      }
    }
    switch (state) {
      case PioneerMapMarkerStyle.moving:
        return (isSelected ? _selectedMovingMarkerIcon : _movingMarkerIcon) ??
            gmaps.BitmapDescriptor.defaultMarkerWithHue(
              gmaps.BitmapDescriptor.hueAzure,
            );
      case PioneerMapMarkerStyle.idle:
        return (isSelected ? _selectedIdleMarkerIcon : _idleMarkerIcon) ??
            gmaps.BitmapDescriptor.defaultMarkerWithHue(
              gmaps.BitmapDescriptor.hueOrange,
            );
      case PioneerMapMarkerStyle.offline:
        return (isSelected ? _selectedOfflineMarkerIcon : _offlineMarkerIcon) ??
            gmaps.BitmapDescriptor.defaultMarkerWithHue(
              gmaps.BitmapDescriptor.hueViolet,
            );
      case PioneerMapMarkerStyle.stale:
        return (isSelected ? _selectedStaleMarkerIcon : _staleMarkerIcon) ??
            gmaps.BitmapDescriptor.defaultMarkerWithHue(
              gmaps.BitmapDescriptor.hueViolet,
            );
    }
  }

  Widget _buildSelectedPulse() {
    final value = _pulseController.value;
    return Transform.scale(
      scale: 1.0 + value,
      child: Opacity(
        opacity: (0.6 * (1 - value)).clamp(0.0, 0.6),
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: AppTheme.colorFF4CAF50, width: 3),
          ),
        ),
      ),
    );
  }

  PioneerMapMarkerStyle _visualMarkerState(Map<String, dynamic> vehicle) {
    final dataStale = _isVehicleStale(vehicle) || _isVehicleDataStale(vehicle);
    if (!dataStale && _hasMovingTelemetry(vehicle)) {
      return PioneerMapMarkerStyle.moving;
    }

    if (!dataStale && _hasIdleTelemetry(vehicle)) {
      return PioneerMapMarkerStyle.idle;
    }

    if (dataStale) {
      return PioneerMapMarkerStyle.stale;
    }

    return PioneerMapMarkerStyle.offline;
  }

  Color _visualMarkerAccent(Map<String, dynamic> vehicle) {
    switch (_visualMarkerState(vehicle)) {
      case PioneerMapMarkerStyle.moving:
        return AppTheme.colorFF1A3A6B;
      case PioneerMapMarkerStyle.idle:
        return AppTheme.colorFFFFB020;
      case PioneerMapMarkerStyle.offline:
        return AppTheme.colorFF64748B;
      case PioneerMapMarkerStyle.stale:
        return AppTheme.colorFF94A3B8;
    }
  }

  bool _hasLiveCoordinates(Map<String, dynamic> vehicle) {
    final latitude = _latitudeOf(vehicle);
    final longitude = _longitudeOf(vehicle);
    return latitude != 0.0 || longitude != 0.0;
  }

  bool _isVehicleMoving(Map<String, dynamic> vehicle) {
    return _hasMovingTelemetry(vehicle) &&
        !_isVehicleStale(vehicle) &&
        !_isVehicleDataStale(vehicle);
  }

  bool _isVehicleIdle(Map<String, dynamic> vehicle) {
    return _visualMarkerState(vehicle) == PioneerMapMarkerStyle.idle;
  }

  void _syncMarkerAnimations() {
    final activeKeys = <String>{};
    final now = DateTime.now();

    // Keep one motion trajectory for each tracked vehicle, even while the
    // marker is off-screen. Recreating state after a pan causes visual jumps.
    for (final vehicle in _vehicleMarkers) {
      final key = _markerKeyOf(vehicle);
      activeKeys.add(key);
      final plateKey = _plateOf(vehicle);
      final existing =
          _markerMotionStates[key] ??
          (plateKey.isNotEmpty && plateKey != key
              ? _markerMotionStates.remove(plateKey)
              : null);

      final rawNextPoint = LatLng(_latitudeOf(vehicle), _longitudeOf(vehicle));
      final nextSpeedKph = _speedKphOf(vehicle);
      final routePath = _movementPathForVehicle(vehicle);
      final nextPoint =
          _snapPointToPath(
            rawNextPoint,
            routePath,
            maxDistanceMeters: _roadLockToleranceMeters,
          ) ??
          rawNextPoint;
      final pathBearing = _bearingAlongPath(routePath, nextPoint);
      final incomingBearing = _tryBearingOf(vehicle);
      final inferredBearing = existing == null
          ? null
          : _bearingFromMovement(existing.pointAt(now), nextPoint);
      final nextBearing =
          pathBearing ??
          incomingBearing ??
          inferredBearing ??
          existing?.baseBearing ??
          0.0;
      final motionIgnitionOn =
          _hasIdleTelemetry(vehicle) || _hasMovingTelemetry(vehicle);
      final hasMotionInputs =
          _trySpeedKphOf(vehicle) != null &&
          (motionIgnitionOn ||
              incomingBearing != null ||
              pathBearing != null ||
              inferredBearing != null ||
              existing?.hasMotionInputs == true);
      final lastGeotabAt = _parseDisplayTimestamp(
        vehicle['lastGeotabAt'] ?? vehicle['lastUpdated'],
      );

      if (existing == null) {
        _markerMotionStates[key] = _MarkerMotionState(
          basePosition: nextPoint,
          baseAt: now,
          baseBearing: nextBearing,
          baseSpeedKph: _normalizedMotionSpeedKph(
            hasMotionInputs ? nextSpeedKph : 0,
          ),
          ignitionOn: motionIgnitionOn,
          hasMotionInputs: hasMotionInputs,
          speedTransitionStartKph: _normalizedMotionSpeedKph(
            hasMotionInputs ? nextSpeedKph : 0,
          ),
          speedTransitionTargetKph: _normalizedMotionSpeedKph(
            hasMotionInputs ? nextSpeedKph : 0,
          ),
          speedTransitionStartedAt: now,
          speedTransitionDuration: Duration.zero,
          correctionMode: _MarkerCorrectionMode.none,
          lastCorrectionMode: _MarkerCorrectionMode.none,
          correctionStartedAt: now,
          correctionDuration: Duration.zero,
          correctionFromPoint: nextPoint,
          correctionToPoint: nextPoint,
          correctionFromBearing: nextBearing,
          correctionToBearing: nextBearing,
          lastServerAt: lastGeotabAt,
          roadPath: routePath,
        );
        continue;
      }

      if (lastGeotabAt != null &&
          existing.lastServerAt != null &&
          !lastGeotabAt.isAfter(existing.lastServerAt!) &&
          !(motionIgnitionOn &&
              nextSpeedKph >= _stationarySpeedThresholdKph &&
              !existing.isMovingAt(
                now,
                stationaryThresholdKph: _stationarySpeedThresholdKph,
              )) &&
          !_hasSameTimestampMotionUpdate(
            existing: existing,
            nextPoint: nextPoint,
            nextSpeedKph: nextSpeedKph,
            nextBearing: nextBearing,
            ignitionOn: motionIgnitionOn,
          )) {
        continue;
      }

      final currentPoint = existing.pointAt(now);
      final currentBearing = existing.bearingAt(now);
      final previousSpeedKph = existing.currentSpeedKph(
        now,
        stationaryThresholdKph: _stationarySpeedThresholdKph,
      );
      final normalizedNextSpeedKph = _normalizedMotionSpeedKph(
        hasMotionInputs ? nextSpeedKph : 0,
      );
      final shouldRotate =
          normalizedNextSpeedKph >= _stationarySpeedThresholdKph &&
          _bearingDeltaAbs(currentBearing, nextBearing) >=
              _bearingCorrectionThresholdDegrees;
      final resolvedBearing = shouldRotate
          ? nextBearing
          : normalizedNextSpeedKph < _stationarySpeedThresholdKph
          ? nextBearing
          : currentBearing;
      final speedTransition = _speedTransitionFor(
        previousSpeedKph: previousSpeedKph,
        nextSpeedKph: normalizedNextSpeedKph,
      );
      final moved = _hasMeaningfulMovement(currentPoint, nextPoint);
      final rotated = shouldRotate;

      if (!moved && !rotated) {
        existing
          ..basePosition = nextPoint
          ..baseAt = now
          ..baseBearing = resolvedBearing
          ..baseSpeedKph = normalizedNextSpeedKph
          ..ignitionOn = motionIgnitionOn
          ..hasMotionInputs = hasMotionInputs
          ..speedTransitionStartKph = speedTransition.startKph
          ..speedTransitionTargetKph = speedTransition.targetKph
          ..speedTransitionStartedAt = now
          ..speedTransitionDuration = speedTransition.duration
          ..correctionMode = _MarkerCorrectionMode.none
          ..lastCorrectionMode = _MarkerCorrectionMode.none
          ..correctionStartedAt = now
          ..correctionDuration = Duration.zero
          ..correctionFromPoint = nextPoint
          ..correctionToPoint = nextPoint
          ..correctionFromBearing = resolvedBearing
          ..correctionToBearing = resolvedBearing
          ..blendLegacyBearing = null
          ..lastRawSampleAt = null
          ..lastEffectiveSampleAt = null
          ..lastServerAt = lastGeotabAt ?? existing.lastServerAt
          ..roadPath = routePath;
        continue;
      }

      if (!hasMotionInputs) {
        final correctionDuration = _pollAlignedLerpDuration;
        existing
          ..basePosition = nextPoint
          ..baseAt = now.add(correctionDuration)
          ..baseBearing = resolvedBearing
          ..baseSpeedKph = 0
          ..ignitionOn = motionIgnitionOn
          ..hasMotionInputs = false
          ..speedTransitionStartKph = 0
          ..speedTransitionTargetKph = 0
          ..speedTransitionStartedAt = now.add(correctionDuration)
          ..speedTransitionDuration = Duration.zero
          ..correctionMode = _MarkerCorrectionMode.strictLerp
          ..lastCorrectionMode = _MarkerCorrectionMode.strictLerp
          ..correctionStartedAt = now
          ..correctionDuration = correctionDuration
          ..correctionFromPoint = currentPoint
          ..correctionToPoint = nextPoint
          ..correctionFromBearing = currentBearing
          ..correctionToBearing = resolvedBearing
          ..blendLegacyBearing = null
          ..lastRawSampleAt = null
          ..lastEffectiveSampleAt = null
          ..lastServerAt = lastGeotabAt ?? existing.lastServerAt
          ..roadPath = routePath;
        continue;
      }

      // Compare the incoming fix with the point currently painted on-screen.
      // Using the preceding server fix here makes an in-flight marker snap.
      final driftMeters = _distanceMeters(currentPoint, nextPoint);
      // GPS fixes arrive in bursts. Always blend toward the newest GeoTab
      // point from the current painted frame instead of snapping there.
      final correctionDuration = _motionCorrectionDuration(
        driftMeters: driftMeters,
        speedKph: normalizedNextSpeedKph,
        routeAware: routePath.length > 1,
      );
      existing
        ..basePosition = nextPoint
        ..baseAt = now.add(correctionDuration)
        ..baseBearing = resolvedBearing
        ..baseSpeedKph = normalizedNextSpeedKph
        ..ignitionOn = motionIgnitionOn
        ..hasMotionInputs = true
        ..speedTransitionStartKph = speedTransition.startKph
        ..speedTransitionTargetKph = speedTransition.targetKph
        ..speedTransitionStartedAt = now.add(correctionDuration)
        ..speedTransitionDuration = speedTransition.duration
        ..correctionMode = _MarkerCorrectionMode.direct
        ..lastCorrectionMode = _MarkerCorrectionMode.direct
        ..correctionStartedAt = now
        ..correctionDuration = correctionDuration
        ..correctionFromPoint = currentPoint
        ..correctionToPoint = nextPoint
        ..correctionFromBearing = currentBearing
        ..correctionToBearing = resolvedBearing
        ..blendLegacyBearing = null
        ..lastRawSampleAt = null
        ..lastEffectiveSampleAt = null
        ..lastServerAt = lastGeotabAt ?? existing.lastServerAt
        ..roadPath = routePath;
    }

    _markerMotionStates.removeWhere((key, _) => !activeKeys.contains(key));
  }

  Duration _motionCorrectionDuration({
    required double driftMeters,
    required double speedKph,
    required bool routeAware,
  }) {
    if (driftMeters < 8) {
      return const Duration(milliseconds: 900);
    }
    if (driftMeters < 35) {
      return const Duration(seconds: 8);
    }

    final visualSpeedKph = speedKph <= _stationarySpeedThresholdKph
        ? 12.0
        : speedKph.clamp(10.0, routeAware ? 38.0 : 30.0).toDouble();
    final distanceSeconds = driftMeters / (visualSpeedKph / 3.6);
    final minimumSeconds = routeAware ? 18.0 : 24.0;
    final maximumSeconds = routeAware ? 58.0 : 75.0;
    final seconds = math.max(
      minimumSeconds,
      math.min(maximumSeconds, distanceSeconds),
    );
    return Duration(milliseconds: (seconds * 1000).round());
  }

  double _latitudeOf(Map<String, dynamic>? vehicle) {
    return (vehicle?['latitude'] as num?)?.toDouble() ?? 0.0;
  }

  double _longitudeOf(Map<String, dynamic>? vehicle) {
    return (vehicle?['longitude'] as num?)?.toDouble() ?? 0.0;
  }

  int _speedOf(Map<String, dynamic>? vehicle) {
    return _speedKphOf(vehicle).round();
  }

  bool _ignitionOn(Map<String, dynamic>? vehicle) {
    return vehicle?['ignitionOn'] == true;
  }

  bool _hasMovingTelemetry(Map<String, dynamic>? vehicle) {
    return vehicle?['isDriving'] == true ||
        _speedKphOf(vehicle) > _stationarySpeedThresholdKph;
  }

  bool _hasIdleTelemetry(Map<String, dynamic>? vehicle) {
    return _ignitionOn(vehicle) || _speedKphOf(vehicle) > 0.1;
  }

  bool _hasMaintenanceBadge(Map<String, dynamic>? vehicle) {
    final status = vehicle?['status']?.toString().trim().toLowerCase() ?? '';
    final maintenanceState =
        vehicle?['maintenanceState']?.toString().trim().toLowerCase() ?? '';
    return status == 'maintenance' ||
        maintenanceState == 'due' ||
        maintenanceState == 'overdue' ||
        maintenanceState == 'active';
  }

  double _bearingOf(Map<String, dynamic>? vehicle) {
    return _tryBearingOf(vehicle) ?? 0.0;
  }

  int? _sourceAgeMsOf(Map<String, dynamic>? vehicle) {
    final raw = vehicle?['sourceAgeMs'];
    if (raw is num) {
      return raw.toInt();
    }
    return int.tryParse(raw?.toString() ?? '');
  }

  bool _isVehicleStale(Map<String, dynamic>? vehicle) {
    final syncState = vehicle?['syncState']?.toString().trim().toLowerCase();
    final sourceAgeMs = _sourceAgeMsOf(vehicle);
    if (sourceAgeMs != null) {
      return sourceAgeMs > _dataStaleThreshold.inMilliseconds;
    }

    if (syncState == 'offline_cached' || syncState == 'stale') {
      return !_hasMovingTelemetry(vehicle) && !_hasIdleTelemetry(vehicle);
    }

    return false;
  }

  String _markerKeyOf(Map<String, dynamic>? vehicle) {
    final geotabId = vehicle?['geotabId']?.toString().trim() ?? '';
    if (geotabId.isNotEmpty) {
      return geotabId;
    }
    return _plateOf(vehicle);
  }

  LatLng _animatedLatLngOf(
    Map<String, dynamic> vehicle, [
    DateTime? sampledAt,
  ]) {
    final state = _markerMotionStates[_markerKeyOf(vehicle)];
    if (state == null) {
      return LatLng(_latitudeOf(vehicle), _longitudeOf(vehicle));
    }
    return state.pointAt(sampledAt ?? DateTime.now());
  }

  double _animatedBearingOf(
    Map<String, dynamic> vehicle, [
    DateTime? sampledAt,
  ]) {
    final state = _markerMotionStates[_markerKeyOf(vehicle)];
    if (state == null) {
      return _bearingOf(vehicle);
    }
    return state.bearingAt(sampledAt ?? DateTime.now());
  }

  bool _isVehicleDataStale(Map<String, dynamic> vehicle, [DateTime? now]) {
    final sampleAt = now ?? DateTime.now();
    final state = _markerMotionStates[_markerKeyOf(vehicle)];
    final lastServerAt =
        state?.lastServerAt ??
        _parseDisplayTimestamp(
          vehicle['lastGeotabAt'] ?? vehicle['lastUpdated'],
        );
    if (lastServerAt == null) {
      return false;
    }
    final age = sampleAt.isAfter(lastServerAt)
        ? sampleAt.difference(lastServerAt)
        : lastServerAt.difference(sampleAt);
    return age > _dataStaleThreshold;
  }

  bool _hasActiveMarkerMotion() {
    final now = DateTime.now();
    for (final state in _markerMotionStates.values) {
      if (state.needsFrameAt(
        now,
        stationaryThresholdKph: _stationarySpeedThresholdKph,
      )) {
        return true;
      }
    }
    return false;
  }

  double _speedKphOf(Map<String, dynamic>? vehicle) {
    return _trySpeedKphOf(vehicle) ?? 0.0;
  }

  double _normalizedMotionSpeedKph(double speedKph) {
    return speedKph >= _stationarySpeedThresholdKph ? speedKph : 0.0;
  }

  _SpeedTransition _speedTransitionFor({
    required double previousSpeedKph,
    required double nextSpeedKph,
  }) {
    final wasMoving = previousSpeedKph >= _stationarySpeedThresholdKph;
    final willMove = nextSpeedKph >= _stationarySpeedThresholdKph;

    if (wasMoving && !willMove) {
      return _SpeedTransition(
        startKph: previousSpeedKph,
        targetKph: 0,
        duration: _decelerationDuration,
      );
    }

    if (!wasMoving && willMove) {
      return _SpeedTransition(
        startKph: 0,
        targetKph: nextSpeedKph,
        duration: _accelerationDuration,
      );
    }

    return _SpeedTransition(
      startKph: nextSpeedKph,
      targetKph: nextSpeedKph,
      duration: Duration.zero,
    );
  }

  double? _trySpeedKphOf(Map<String, dynamic>? vehicle) {
    final raw = vehicle?['speed'];
    if (raw is num) {
      return raw.toDouble();
    }
    return double.tryParse(raw?.toString() ?? '');
  }

  double? _tryBearingOf(Map<String, dynamic>? vehicle) {
    final raw = vehicle?['bearing'];
    if (raw is num) {
      return raw.toDouble();
    }
    return double.tryParse(raw?.toString() ?? '');
  }

  bool _hasSameTimestampMotionUpdate({
    required _MarkerMotionState existing,
    required LatLng nextPoint,
    required double nextSpeedKph,
    required double nextBearing,
    required bool ignitionOn,
  }) {
    return _distanceMeters(existing.basePosition, nextPoint) > 3 ||
        (existing.baseSpeedKph - nextSpeedKph).abs() > 0.5 ||
        _bearingDeltaAbs(existing.baseBearing, nextBearing) > 3 ||
        existing.ignitionOn != ignitionOn;
  }

  double _distanceMeters(LatLng from, LatLng to) {
    final dLat = _degreesToRadians(to.latitude - from.latitude);
    final dLng = _degreesToRadians(to.longitude - from.longitude);
    final lat1 = _degreesToRadians(from.latitude);
    final lat2 = _degreesToRadians(to.latitude);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    const earthRadiusMeters = 6371000.0;
    return earthRadiusMeters * c;
  }

  List<LatLng> _movementPathForVehicle(Map<String, dynamic> vehicle) {
    final roadAware = _roadAwarePathFromVehicle(vehicle);
    if (roadAware.length > 1) {
      return roadAware;
    }

    for (final source in <dynamic>[
      vehicle['roadPath'],
      vehicle['optimizedPath'],
      _mapFromAny(vehicle['traffic'])['roadPath'],
      _mapFromAny(vehicle['traffic'])['optimizedPath'],
    ]) {
      final path = _pathFromAny(source);
      if (path.length > 1) {
        return path;
      }
    }
    return const [];
  }

  LatLng? _snapPointToPath(
    LatLng point,
    List<LatLng> path, {
    required double maxDistanceMeters,
  }) {
    if (path.length < 2) {
      return null;
    }
    final projected = _nearestPointOnPath(point, path);
    if (projected == null) {
      return null;
    }
    return _distanceMeters(point, projected.point) <= maxDistanceMeters
        ? projected.point
        : null;
  }

  double? _bearingAlongPath(List<LatLng> path, LatLng nearPoint) {
    if (path.length < 2) {
      return null;
    }
    final projected = _nearestPointOnPath(nearPoint, path);
    if (projected == null) {
      return null;
    }
    final from = path[projected.segmentIndex];
    final to = path[math.min(projected.segmentIndex + 1, path.length - 1)];
    if (_distanceMeters(from, to) < 2) {
      return null;
    }
    return _bearingBetween(from, to);
  }

  double? _bearingFromMovement(LatLng from, LatLng to) {
    if (_distanceMeters(from, to) < 2.5) {
      return null;
    }
    return _bearingBetween(from, to);
  }

  _PathProjection? _nearestPointOnPath(LatLng point, List<LatLng> path) {
    if (path.length < 2) {
      return null;
    }
    _PathProjection? best;
    for (var i = 0; i < path.length - 1; i++) {
      final candidate = _projectPointToSegment(point, path[i], path[i + 1], i);
      if (best == null || candidate.distanceMeters < best.distanceMeters) {
        best = candidate;
      }
    }
    return best;
  }

  _PathProjection _projectPointToSegment(
    LatLng point,
    LatLng start,
    LatLng end,
    int segmentIndex,
  ) {
    final latScale = LiveTrackingMotionMath.metersPerLatitudeDegree;
    final lngScale =
        latScale *
        math.cos(_degreesToRadians(point.latitude)).abs().clamp(0.000001, 1.0);
    final px = (point.longitude - start.longitude) * lngScale;
    final py = (point.latitude - start.latitude) * latScale;
    final vx = (end.longitude - start.longitude) * lngScale;
    final vy = (end.latitude - start.latitude) * latScale;
    final lengthSquared = (vx * vx) + (vy * vy);
    final t = lengthSquared <= 0
        ? 0.0
        : ((px * vx) + (py * vy)) / lengthSquared;
    final clampedT = t.clamp(0.0, 1.0);
    final projected = LatLng(
      start.latitude + ((end.latitude - start.latitude) * clampedT),
      start.longitude + ((end.longitude - start.longitude) * clampedT),
    );
    return _PathProjection(
      point: projected,
      distanceMeters: _distanceMeters(point, projected),
      segmentIndex: segmentIndex,
      segmentFraction: clampedT.toDouble(),
    );
  }

  double _bearingBetween(LatLng from, LatLng to) {
    final lat1 = _degreesToRadians(from.latitude);
    final lat2 = _degreesToRadians(to.latitude);
    final deltaLng = _degreesToRadians(to.longitude - from.longitude);
    final y = math.sin(deltaLng) * math.cos(lat2);
    final x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(deltaLng);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  double _degreesToRadians(double degrees) {
    return degrees * math.pi / 180;
  }

  bool _isPointInsideBufferedBounds(LatLng point, gmaps.LatLngBounds bounds) {
    return LiveTrackingMotionMath.isPointInsideBufferedBounds(
      point,
      bounds,
      bufferFraction: _viewportBufferFraction,
    );
  }

  double _bearingDeltaAbs(double from, double to) {
    return ((((to - from) % 360) + 540) % 360 - 180.0).abs();
  }

  int _secondsAgo(DateTime value) {
    final diff = DateTime.now().difference(value).inSeconds;
    return diff < 0 ? 0 : diff;
  }

  DateTime? _parseDisplayTimestamp(dynamic value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) {
      return null;
    }

    return DateTime.tryParse(raw)?.toUtc();
  }

  LatLng? _latLngFrom(dynamic raw) {
    if (raw is! Map) {
      return null;
    }

    final latitude = _doubleFromAny(raw['latitude'] ?? raw['lat'] ?? raw['y']);
    final longitude = _doubleFromAny(
      raw['longitude'] ?? raw['lng'] ?? raw['lon'] ?? raw['x'],
    );
    if (latitude == null || longitude == null) {
      return null;
    }

    return LatLng(latitude, longitude);
  }

  List<LatLng> _roadAwarePathFromVehicle(Map<String, dynamic> vehicle) {
    final traffic = _mapFromAny(vehicle['traffic']);
    for (final source in <dynamic>[
      traffic['encodedPolyline'],
      traffic['routePolyline'],
      traffic['polyline'],
      _mapFromAny(traffic['route'])['encodedPolyline'],
      vehicle['encodedPolyline'],
      vehicle['routePolyline'],
    ]) {
      final decoded = _decodeEncodedPolyline(source?.toString() ?? '');
      if (decoded.length > 1) {
        return decoded;
      }
    }

    for (final source in <dynamic>[
      traffic['roadPath'],
      traffic['optimizedPath'],
      traffic['routePath'],
      vehicle['roadPath'],
      vehicle['optimizedPath'],
      vehicle['routePath'],
      vehicle['plannedPath'],
    ]) {
      final path = _pathFromAny(source);
      if (path.length > 1) {
        return path;
      }
    }

    return const [];
  }

  bool _routePathIsRoadAware(Map<String, dynamic> vehicle) {
    final traffic = _mapFromAny(vehicle['traffic']);
    return _decodeEncodedPolyline(
              traffic['encodedPolyline']?.toString() ?? '',
            ).length >
            1 ||
        _decodeEncodedPolyline(
              traffic['routePolyline']?.toString() ?? '',
            ).length >
            1 ||
        _decodeEncodedPolyline(
              vehicle['encodedPolyline']?.toString() ?? '',
            ).length >
            1 ||
        _pathFromAny(traffic['roadPath']).length > 1 ||
        _pathFromAny(traffic['optimizedPath']).length > 1 ||
        _pathFromAny(vehicle['roadPath']).length > 1 ||
        _pathFromAny(vehicle['optimizedPath']).length > 1;
  }

  List<LatLng> _pathFromAny(dynamic raw) {
    if (raw is! List) {
      return const [];
    }
    return raw
        .map((point) => _latLngFrom(point))
        .whereType<LatLng>()
        .where((point) => point.latitude != 0.0 || point.longitude != 0.0)
        .toList();
  }

  List<LatLng> _decodeEncodedPolyline(String encoded) {
    if (encoded.trim().isEmpty) {
      return const [];
    }

    final points = <LatLng>[];
    var index = 0;
    var latitude = 0;
    var longitude = 0;

    while (index < encoded.length) {
      var shift = 0;
      var result = 0;
      int byte;
      do {
        if (index >= encoded.length) {
          return points;
        }
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);
      latitude += (result & 1) != 0 ? ~(result >> 1) : result >> 1;

      shift = 0;
      result = 0;
      do {
        if (index >= encoded.length) {
          return points;
        }
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);
      longitude += (result & 1) != 0 ? ~(result >> 1) : result >> 1;

      points.add(LatLng(latitude / 1e5, longitude / 1e5));
    }

    return points;
  }

  List<LatLng> _dedupeTrailPoints(List<LatLng> points) {
    final deduped = <LatLng>[];
    for (final point in points) {
      if (deduped.isEmpty || _distanceMeters(deduped.last, point) >= 6) {
        deduped.add(point);
      }
    }
    return deduped;
  }

  bool _hasMeaningfulTrailMovement(List<LatLng> points) {
    if (points.length < 2) {
      return false;
    }
    return _cumulativeDistanceMeters(_dedupeTrailPoints(points)) >= 35;
  }

  double _cumulativeDistanceMeters(List<LatLng> points) {
    if (points.length < 2) {
      return 0;
    }
    var distance = 0.0;
    for (var i = 1; i < points.length; i++) {
      distance += _distanceMeters(points[i - 1], points[i]);
    }
    return distance;
  }

  double _estimatedDistanceToTargetKm(Map<String, dynamic> vehicle) {
    final traffic = _mapFromAny(vehicle['traffic']);
    final liveDistance = _doubleFromAny(traffic['distanceKm']);
    if (liveDistance != null && liveDistance > 0) {
      return liveDistance;
    }

    final from = LatLng(_latitudeOf(vehicle), _longitudeOf(vehicle));
    final target = _navigationTargetPoint(vehicle);
    if (target == null) {
      return 4.0;
    }
    final directKm = _distanceMeters(from, target) / 1000;
    return math.max(0.4, directKm * 1.22);
  }

  LatLng? _navigationTargetPoint(Map<String, dynamic> vehicle) {
    final navigationTarget = _mapFromAny(vehicle['navigationTarget']);
    final targetCoordinate = _latLngFrom(navigationTarget['coordinate']);
    if (targetCoordinate != null) {
      return targetCoordinate;
    }

    for (final stop in _routeStopsFor(vehicle)) {
      final point = _latLngFrom(stop['center']) ?? _latLngFrom(stop);
      if (point != null) {
        return point;
      }
    }

    final path = _pathFromAny(vehicle['plannedPath']);
    return path.isNotEmpty ? path.last : null;
  }

  String _navigationTargetName(Map<String, dynamic> vehicle) {
    final navigationTarget = _mapFromAny(vehicle['navigationTarget']);
    final targetName = navigationTarget['name']?.toString().trim() ?? '';
    if (targetName.isNotEmpty) {
      return targetName;
    }

    for (final stop in _routeStopsFor(vehicle)) {
      final name = stop['name']?.toString().trim() ?? '';
      if (name.isNotEmpty) {
        return name;
      }
    }

    final destination = vehicle['destinationZone']?.toString().trim() ?? '';
    if (destination.isNotEmpty) {
      return destination;
    }

    final routeName =
        (vehicle['routeName'] ?? vehicle['assignedRoute'])?.toString().trim() ??
        '';
    return routeName;
  }

  double? _doubleFromAny(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value.trim());
    }
    return null;
  }

  Map<String, dynamic> _mapFromAny(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), item));
    }
    return const {};
  }

  gmaps.LatLng _toGoogleLatLng(LatLng point) {
    return gmaps.LatLng(point.latitude, point.longitude);
  }

  LatLng _polygonCenter(List<LatLng> points) {
    final latitude =
        points.map((point) => point.latitude).reduce((a, b) => a + b) /
        points.length;
    final longitude =
        points.map((point) => point.longitude).reduce((a, b) => a + b) /
        points.length;
    return LatLng(latitude, longitude);
  }

  Future<gmaps.BitmapDescriptor> _zoneLabelIcon(String label) async {
    final cached = _zoneLabelIconCache[label];
    if (cached != null) {
      return cached;
    }

    const width = 320.0;
    const height = 74.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final rect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(0, 0, width, height),
      const Radius.circular(22),
    );
    final fill = Paint()
      ..color = AppTheme.pioneerDeepBlue.withValues(alpha: 0.88);
    final stroke = Paint()
      ..color = AppTheme.accentCyan.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawRRect(rect, fill);
    canvas.drawRRect(rect, stroke);

    final painter = TextPainter(
      text: TextSpan(
        text: label.length > 28 ? '${label.substring(0, 27)}...' : label,
        style: const TextStyle(
          color: AppTheme.white,
          fontSize: 28,
          fontWeight: FontWeight.w800,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '...',
    )..layout(maxWidth: width - 28);
    painter.paint(
      canvas,
      Offset((width - painter.width) / 2, (height - painter.height) / 2),
    );

    final image = await recorder.endRecording().toImage(
      width.toInt(),
      height.toInt(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final descriptor = gmaps.BitmapDescriptor.bytes(
      data!.buffer.asUint8List(),
      width: 128,
      height: 30,
    );
    _zoneLabelIconCache[label] = descriptor;
    return descriptor;
  }

  void _moveMap(LatLng point, double zoom) {
    final controller = _mapController;
    if (controller == null) {
      return;
    }

    final previouslyCompact = _usesCompactMapMarkers;
    _currentMapZoom = zoom;
    if (previouslyCompact != _usesCompactMapMarkers && mounted) {
      setState(() {});
    }
    controller.animateCamera(
      gmaps.CameraUpdate.newCameraPosition(
        gmaps.CameraPosition(target: _toGoogleLatLng(point), zoom: zoom),
      ),
    );
    _scheduleSelectedPulseProjection();
  }

  void _scheduleSelectedPulseProjection() {
    final now = DateTime.now();
    final lastProjectionAt = _lastPulseProjectionAt;
    if (lastProjectionAt != null &&
        now.difference(lastProjectionAt) < const Duration(milliseconds: 180)) {
      return;
    }

    _lastPulseProjectionAt = now;
    unawaited(_updateSelectedPulseOffset());
  }

  void _scheduleVisibleBoundsRefresh() {
    _boundsRefreshDebounce?.cancel();
    _boundsRefreshDebounce = Timer(
      const Duration(milliseconds: 120),
      _refreshVisibleBounds,
    );
  }

  Future<void> _refreshVisibleBounds() async {
    final controller = _mapController;
    if (controller == null || !mounted) {
      return;
    }

    try {
      final bounds = await controller.getVisibleRegion();
      if (!mounted) {
        return;
      }
      setState(() => _visibleBounds = bounds);
      _syncMarkerAnimations();
    } catch (_) {
      // Keep the last known bounds; if none exist, markers render normally.
    }
  }

  Future<void> _updateSelectedPulseOffset() async {
    final controller = _mapController;
    final vehicle = _selectedVehicle;
    if (controller == null || vehicle == null || !mounted) {
      return;
    }

    try {
      final point = _animatedLatLngOf(vehicle, DateTime.now());
      final screenCoordinate = await controller.getScreenCoordinate(
        _toGoogleLatLng(point),
      );
      if (!mounted) {
        return;
      }

      setState(() {
        _selectedPulseOffset = Offset(
          screenCoordinate.x.toDouble(),
          screenCoordinate.y.toDouble(),
        );
      });
    } catch (_) {
      if (mounted && _selectedPulseOffset != null) {
        setState(() => _selectedPulseOffset = null);
      }
    }
  }

  void _zoomBy(double delta) {
    final controller = _mapController;
    if (controller == null) {
      return;
    }

    final previousMarkerTier = _markerZoomTier;
    _currentMapZoom = (_currentMapZoom + delta).clamp(3.0, 20.0);
    if (previousMarkerTier != _markerZoomTier && mounted) {
      setState(() {});
    }
    controller.animateCamera(gmaps.CameraUpdate.zoomTo(_currentMapZoom));
  }

  String _plateOf(Map<String, dynamic>? vehicle) {
    return vehicle?['plate']?.toString().trim() ?? '';
  }

  String _plateLabelOf(Map<String, dynamic>? vehicle) {
    final plate = _plateOf(vehicle);
    return plate.isEmpty ? 'Unknown' : plate;
  }

  String _driverLabelOf(Map<String, dynamic> vehicle) {
    final driver = vehicle['driver']?.toString().trim() ?? '';
    return driver.isEmpty ? 'Unassigned' : driver;
  }

  List<String> _vehicleOperationalTags(Map<String, dynamic> vehicle) {
    final tags = <String>['Vehicle'];
    final fuelType = _fuelTypeLabel(vehicle);
    if (fuelType.isNotEmpty) {
      tags.add(fuelType);
    }
    final group = _zoneLabel(vehicle);
    if (group.isNotEmpty && group != 'No zone') {
      tags.add(group.length > 22 ? '${group.substring(0, 22)}...' : group);
    }
    return tags.take(3).toList();
  }

  String _fuelTypeLabel(Map<String, dynamic> vehicle) {
    final raw =
        (vehicle['fuelType'] ??
                vehicle['powertrain'] ??
                vehicle['powertrainAndFuelType'])
            ?.toString()
            .trim() ??
        '';
    if (raw.isNotEmpty && raw.toLowerCase() != 'n/a') {
      return raw;
    }
    return 'Fuel';
  }

  double? _fuelPercentOf(Map<String, dynamic> vehicle) {
    final ratio =
        _doubleFromAny(vehicle['fuelLevelRatio']) ??
        _doubleFromAny(_mapFromAny(vehicle['diagnostics'])['fuelLevelRatio']);
    if (ratio != null) {
      return ratio <= 1 ? ratio * 100 : ratio;
    }

    final diagnostics = _mapFromAny(vehicle['diagnostics']);
    final fuelLevel = _mapFromAny(diagnostics['fuelLevel']);
    final direct = _doubleFromAny(fuelLevel['value'] ?? vehicle['fuelLevel']);
    if (direct != null) {
      return direct <= 1 ? direct * 100 : direct;
    }
    return null;
  }

  Color _fuelStatusColor(Map<String, dynamic> vehicle) {
    final percent = _fuelPercentOf(vehicle);
    if (percent == null) {
      return AppTheme.colorFF64748B;
    }
    if (percent <= 20) {
      return AppTheme.colorFFE74C3C;
    }
    if (percent <= 45) {
      return AppTheme.colorFFF59E0B;
    }
    return AppTheme.colorFF27AE60;
  }

  String _zoneLabel(Map<String, dynamic> vehicle) {
    final current = vehicle['currentZone']?.toString().trim() ?? '';
    if (current.isNotEmpty) {
      return current;
    }
    final destination = vehicle['destinationZone']?.toString().trim() ?? '';
    if (destination.isNotEmpty) {
      return destination;
    }
    return 'No zone';
  }

  List<String> _vehicleExceptionLabels(Map<String, dynamic> vehicle) {
    final labels = <String>[];
    final recent = vehicle['recentExceptions'];
    if (recent is List) {
      for (final item in recent) {
        if (item is Map) {
          final label =
              (item['ruleName'] ??
                      item['name'] ??
                      item['label'] ??
                      item['type'])
                  ?.toString()
                  .trim() ??
              '';
          if (label.isNotEmpty) {
            labels.add(label);
          }
        } else {
          final label = item?.toString().trim() ?? '';
          if (label.isNotEmpty) {
            labels.add(label);
          }
        }
      }
    }

    final fuelPercent = _fuelPercentOf(vehicle);
    if (fuelPercent != null && fuelPercent <= 20) {
      labels.add('Low fuel ${fuelPercent.round()}%');
    }
    if (!_ignitionOn(vehicle)) {
      labels.add('Ignition off');
    }
    if (_visualMarkerState(vehicle) == PioneerMapMarkerStyle.stale) {
      labels.add('Stale feed');
    }

    return labels.toSet().take(4).toList();
  }

  Color _exceptionColor(String label) {
    final lower = label.toLowerCase();
    if (lower.contains('low fuel') ||
        lower.contains('harsh') ||
        lower.contains('fault') ||
        lower.contains('off')) {
      return AppTheme.colorFFE74C3C;
    }
    if (lower.contains('stale') || lower.contains('warning')) {
      return AppTheme.colorFFF59E0B;
    }
    return AppTheme.colorFF27AE60;
  }

  String _lastKnownAddressLabel(Map<String, dynamic> vehicle) {
    final address = vehicle['currentLocationLabel']?.toString().trim() ?? '';
    return address.isEmpty ? 'Location unavailable.' : address;
  }

  String _motionStateShortLabel(Map<String, dynamic> vehicle) {
    switch (_visualMarkerState(vehicle)) {
      case PioneerMapMarkerStyle.moving:
        return 'Moving';
      case PioneerMapMarkerStyle.idle:
        return 'Idling';
      case PioneerMapMarkerStyle.offline:
        return 'Stopped';
      case PioneerMapMarkerStyle.stale:
        return 'Stale';
    }
  }

  Color _sidebarStateAccent(Map<String, dynamic> vehicle) {
    switch (_visualMarkerState(vehicle)) {
      case PioneerMapMarkerStyle.moving:
        return AppTheme.successGreen;
      case PioneerMapMarkerStyle.idle:
        return AppTheme.warningOrange;
      case PioneerMapMarkerStyle.offline:
        return AppTheme.neutralGray;
      case PioneerMapMarkerStyle.stale:
        return AppTheme.colorFF94A3B8;
    }
  }

  List<Color> _motionStateGradient(Map<String, dynamic> vehicle) {
    switch (_visualMarkerState(vehicle)) {
      case PioneerMapMarkerStyle.moving:
        return const [AppTheme.colorFF1A3A6B, AppTheme.colorFF4B7BE5];
      case PioneerMapMarkerStyle.idle:
        return const [AppTheme.colorFFE08A00, AppTheme.colorFFFFB020];
      case PioneerMapMarkerStyle.offline:
        return const [AppTheme.colorFF475569, AppTheme.colorFF94A3B8];
      case PioneerMapMarkerStyle.stale:
        return const [AppTheme.colorFF64748B, AppTheme.colorFF94A3B8];
    }
  }

  IconData _motionStateIcon(Map<String, dynamic> vehicle) {
    switch (_visualMarkerState(vehicle)) {
      case PioneerMapMarkerStyle.moving:
        return Icons.navigation_rounded;
      case PioneerMapMarkerStyle.idle:
        return Icons.pause_circle_filled_rounded;
      case PioneerMapMarkerStyle.offline:
        return Icons.power_settings_new_rounded;
      case PioneerMapMarkerStyle.stale:
        return Icons.cloud_off_rounded;
    }
  }

  String _statusLabel(Map<String, dynamic> vehicle) {
    switch (_visualMarkerState(vehicle)) {
      case PioneerMapMarkerStyle.moving:
        return 'Moving at ${_speedOf(vehicle)} km/h';
      case PioneerMapMarkerStyle.idle:
        return 'Idling';
      case PioneerMapMarkerStyle.offline:
        return 'Stopped, ignition off';
      case PioneerMapMarkerStyle.stale:
        return 'Stale - ${_lastSeenLabel(vehicle)}';
    }
  }

  String _syncLabel(Map<String, dynamic> vehicle) {
    if (_hasMaintenanceBadge(vehicle)) {
      return 'Maintenance attention';
    }
    if (_hasMovingTelemetry(vehicle) && !_isVehicleStale(vehicle)) {
      return 'Moving at ${_speedOf(vehicle)} km/h';
    }
    if (_hasIdleTelemetry(vehicle) && !_isVehicleStale(vehicle)) {
      return 'Engine on - idling';
    }
    final syncState = vehicle['syncState']?.toString().trim().toLowerCase();
    if (syncState == 'offline_cached') {
      return 'Offline cached';
    }
    if (_visualMarkerState(vehicle) == PioneerMapMarkerStyle.stale) {
      return _lastSeenLabel(vehicle);
    }
    return _statusLabel(vehicle);
  }

  bool _hasEnvironmentOrTraffic(Map<String, dynamic> vehicle) {
    return (_allowWeatherContext(vehicle) &&
            (_weatherTemperatureLabel(vehicle).isNotEmpty ||
                _weatherHumidityLabel(vehicle).isNotEmpty ||
                _weatherConditionLabel(vehicle).isNotEmpty)) ||
        (_allowTrafficContext(vehicle) && _trafficLabel(vehicle).isNotEmpty);
  }

  bool _allowWeatherContext(Map<String, dynamic> vehicle) {
    return _showWeatherContext;
  }

  bool _allowTrafficContext(Map<String, dynamic> vehicle) {
    return _showTrafficEta;
  }

  String _weatherTemperatureLabel(Map<String, dynamic> vehicle) {
    final weather = _mapFromAny(vehicle['weather']);
    final environment = _mapFromAny(vehicle['environment']);
    final temperature =
        _doubleFromAny(weather['temperatureC']) ??
        _doubleFromAny(environment['temperatureC']);
    if (temperature == null) {
      return '';
    }

    final feelsLike = _doubleFromAny(weather['feelsLikeC']);
    final suffix = feelsLike != null
        ? ' feels ${feelsLike.toStringAsFixed(1)} C'
        : '';
    return '${temperature.toStringAsFixed(1)} C$suffix';
  }

  String _weatherHumidityLabel(Map<String, dynamic> vehicle) {
    final weather = _mapFromAny(vehicle['weather']);
    final environment = _mapFromAny(vehicle['environment']);
    final humidity =
        _doubleFromAny(weather['relativeHumidity']) ??
        _doubleFromAny(environment['relativeHumidity']);
    if (humidity == null) {
      return '';
    }

    return '${humidity.toStringAsFixed(0)}% humidity';
  }

  String _weatherConditionLabel(Map<String, dynamic> vehicle) {
    final weather = _mapFromAny(vehicle['weather']);
    final condition = weather['condition']?.toString().trim() ?? '';
    return condition;
  }

  String _trafficLabel(Map<String, dynamic> vehicle) {
    final traffic = _mapFromAny(vehicle['traffic']);
    if (traffic.isEmpty) {
      return '';
    }

    final severity = traffic['severity']?.toString().trim().toLowerCase() ?? '';
    final delayMinutes = _doubleFromAny(traffic['delayMinutes'])?.round();
    final distanceKm = _doubleFromAny(traffic['distanceKm']);
    final target = traffic['targetName']?.toString().trim() ?? '';
    final severityLabel = switch (severity) {
      'heavy' => 'Heavy traffic',
      'moderate' => 'Moderate traffic',
      'light' => 'Light traffic',
      'clear' => 'Clear roads',
      _ => 'Traffic aware',
    };
    final delay = delayMinutes != null && delayMinutes > 0
        ? ' +$delayMinutes min'
        : '';
    final distance = distanceKm != null
        ? ' ${distanceKm.toStringAsFixed(1)} km'
        : '';
    final destination = target.isNotEmpty ? ' to $target' : '';

    return '$severityLabel$delay$distance$destination';
  }

  Color _trafficColor(Map<String, dynamic> vehicle) {
    final traffic = _mapFromAny(vehicle['traffic']);
    switch (traffic['severity']?.toString().trim().toLowerCase()) {
      case 'heavy':
        return AppTheme.colorFFE74C3C;
      case 'moderate':
        return AppTheme.colorFFFFB020;
      case 'light':
        return AppTheme.colorFFE67E22;
      case 'clear':
        return AppTheme.colorFF27AE60;
      default:
        return AppTheme.colorFF64748B;
    }
  }

  String _lastSeenLabel(Map<String, dynamic> vehicle) {
    final lastSeen = _lastSeenAt(vehicle);
    if (lastSeen == null) {
      return 'Last seen over 5 minutes ago';
    }

    final age = DateTime.now().toUtc().difference(lastSeen.toUtc());
    final minutes = age.inMinutes < 0 ? 0 : age.inMinutes;
    if (minutes < 1) {
      return 'Last seen just now';
    }
    if (minutes < 60) {
      return 'Last seen $minutes minute${minutes == 1 ? '' : 's'} ago';
    }

    final hours = minutes ~/ 60;
    return 'Last seen $hours hour${hours == 1 ? '' : 's'} ago';
  }

  DateTime? _lastSeenAt(Map<String, dynamic> vehicle) {
    final state = _markerMotionStates[_markerKeyOf(vehicle)];
    return state?.lastServerAt ??
        _parseDisplayTimestamp(
          vehicle['lastGeotabAt'] ?? vehicle['lastUpdated'],
        );
  }

  void _maybeFollowSelectedVehicle() {
    if (!_isFollowingSelected || selectedPlate.isEmpty || !mounted) {
      return;
    }

    final now = DateTime.now();
    final lastMoveAt = _lastFollowMoveAt;
    if (lastMoveAt != null &&
        now.difference(lastMoveAt) < _followMoveThrottle) {
      return;
    }

    final vehicle = _selectedVehicle;
    if (vehicle == null) {
      return;
    }

    _lastFollowMoveAt = now;
    final point = _animatedLatLngOf(vehicle, now);
    _moveMap(point, _currentMapZoom <= 0 ? 15.0 : _currentMapZoom);
    _scheduleSelectedPulseProjection();
  }

  String _secondaryText(Map<String, dynamic> vehicle) {
    final currentZone = vehicle['currentZone']?.toString().trim() ?? '';
    final destinationZone = vehicle['destinationZone']?.toString().trim() ?? '';
    final currentLocationLabel =
        vehicle['currentLocationLabel']?.toString().trim() ?? '';
    final routeName = vehicle['assignedRoute']?.toString().trim() ?? '';
    final arrivalState = vehicle['arrivalState']?.toString().trim() ?? '';

    if (currentZone.isNotEmpty && destinationZone.isNotEmpty) {
      final state = arrivalState.isNotEmpty ? ' • $arrivalState' : '';
      return '$currentZone -> $destinationZone$state';
    }

    if (currentLocationLabel.isNotEmpty) {
      return currentLocationLabel;
    }

    if (routeName.isNotEmpty) {
      return 'Route: $routeName';
    }

    final comment = vehicle['comment']?.toString().trim() ?? '';
    if (comment.isNotEmpty) {
      return comment;
    }

    final lastUpdated = vehicle['lastUpdated']?.toString().trim() ?? '';
    if (lastUpdated.isNotEmpty) {
      return 'Updated $lastUpdated';
    }

    final serial = vehicle['serialNumber']?.toString().trim() ?? '';
    if (serial.isNotEmpty) {
      return 'Serial $serial';
    }

    return 'Live Geotab vehicle';
  }

  String _directionDisplay(Map<String, dynamic> vehicle) {
    final bearing = _tryBearingOf(vehicle) ?? 0.0;
    final directions = [
      'N',
      'NNE',
      'NE',
      'ENE',
      'E',
      'ESE',
      'SE',
      'SSE',
      'S',
      'SSW',
      'SW',
      'WSW',
      'W',
      'WNW',
      'NW',
      'NNW',
    ];
    final index = ((bearing + 11.25) / 22.5).floor() % 16;
    return directions[index];
  }

  bool _hasMeaningfulMovement(LatLng from, LatLng to) {
    return _distanceMeters(from, to) > 1.0;
  }
}

class _DerivedStopPoint {
  const _DerivedStopPoint({required this.name, required this.center});

  final String name;
  final LatLng? center;
}

enum _MarkerCorrectionMode { none, blended, direct, strictLerp }

class _SpeedTransition {
  const _SpeedTransition({
    required this.startKph,
    required this.targetKph,
    required this.duration,
  });

  final double startKph;
  final double targetKph;
  final Duration duration;
}

class _PathProjection {
  const _PathProjection({
    required this.point,
    required this.distanceMeters,
    required this.segmentIndex,
    required this.segmentFraction,
  });

  final LatLng point;
  final double distanceMeters;
  final int segmentIndex;
  final double segmentFraction;
}

class _MarkerMotionState {
  _MarkerMotionState({
    required this.basePosition,
    required this.baseAt,
    required this.baseBearing,
    required this.baseSpeedKph,
    required this.ignitionOn,
    required this.hasMotionInputs,
    required this.speedTransitionStartKph,
    required this.speedTransitionTargetKph,
    required this.speedTransitionStartedAt,
    required this.speedTransitionDuration,
    required this.correctionMode,
    required this.lastCorrectionMode,
    required this.correctionStartedAt,
    required this.correctionDuration,
    required this.correctionFromPoint,
    required this.correctionToPoint,
    required this.correctionFromBearing,
    required this.correctionToBearing,
    required this.lastServerAt,
    required this.roadPath,
  });

  static const double _stationaryThresholdKph = 2.0;
  static const Duration _maxFrameStep = Duration(milliseconds: 500);
  static const Duration _maxDeadReckoningDuration =
      _LiveTrackingPageEnhancedState._freeDriveProjectionLimit;
  static const Duration _renderDelay =
      _LiveTrackingPageEnhancedState._markerRenderDelay;

  LatLng basePosition;
  DateTime baseAt;
  double baseBearing;
  double baseSpeedKph;
  bool ignitionOn;
  bool hasMotionInputs;
  double speedTransitionStartKph;
  double speedTransitionTargetKph;
  DateTime speedTransitionStartedAt;
  Duration speedTransitionDuration;
  _MarkerCorrectionMode correctionMode;
  _MarkerCorrectionMode lastCorrectionMode;
  DateTime correctionStartedAt;
  Duration correctionDuration;
  LatLng correctionFromPoint;
  LatLng correctionToPoint;
  double correctionFromBearing;
  double correctionToBearing;
  double? blendLegacyBearing;
  DateTime? lastServerAt;
  DateTime? lastRawSampleAt;
  DateTime? lastEffectiveSampleAt;
  List<LatLng> roadPath;

  LatLng pointAt(DateTime now) {
    final effectiveNow = _effectiveNow(now);
    final progress = Curves.easeInOutCubic.transform(_progressAt(effectiveNow));
    switch (correctionMode) {
      case _MarkerCorrectionMode.none:
        return _estimatedPositionAt(effectiveNow);
      case _MarkerCorrectionMode.blended:
        if (progress >= 1.0) {
          return _estimatedPositionAt(effectiveNow);
        }
        return _interpolateAlongRoadPath(
              correctionFromPoint,
              correctionToPoint,
              progress,
            ) ??
            _constrainToRoadPath(
              _lerpLatLng(correctionFromPoint, correctionToPoint, progress),
            );
      case _MarkerCorrectionMode.direct:
      case _MarkerCorrectionMode.strictLerp:
        if (progress >= 1.0) {
          return _estimatedPositionAt(effectiveNow);
        }
        return _interpolateAlongRoadPath(
              correctionFromPoint,
              correctionToPoint,
              progress,
            ) ??
            _constrainToRoadPath(
              _lerpLatLng(correctionFromPoint, correctionToPoint, progress),
            );
    }
  }

  double bearingAt(DateTime now) {
    final effectiveNow = _effectiveNow(now);
    final progress = Curves.easeInOutCubic.transform(_progressAt(effectiveNow));
    final isStationaryOrDecelerating =
        currentSpeedKph(
              effectiveNow,
              stationaryThresholdKph: _stationaryThresholdKph,
            ) <
            _stationaryThresholdKph ||
        _isDecelerating(effectiveNow);
    if (isStationaryOrDecelerating) {
      return _normalizeBearing(baseBearing);
    }

    switch (correctionMode) {
      case _MarkerCorrectionMode.none:
        return _normalizeBearing(baseBearing);
      case _MarkerCorrectionMode.blended:
        if (progress >= 1.0) {
          return _normalizeBearing(baseBearing);
        }
        final previousBearing = blendLegacyBearing ?? correctionFromBearing;
        return _lerpAngle(previousBearing, baseBearing, progress);
      case _MarkerCorrectionMode.direct:
      case _MarkerCorrectionMode.strictLerp:
        if (progress >= 1.0) {
          return _normalizeBearing(baseBearing);
        }
        return _lerpAngle(correctionFromBearing, correctionToBearing, progress);
    }
  }

  bool isCorrectingAt(DateTime now) {
    return correctionMode != _MarkerCorrectionMode.none &&
        _progressAt(now) < 1.0;
  }

  bool isMovingAt(DateTime now, {required double stationaryThresholdKph}) {
    return currentSpeedKph(
          now,
          stationaryThresholdKph: stationaryThresholdKph,
        ) >=
        stationaryThresholdKph;
  }

  bool needsFrameAt(DateTime now, {required double stationaryThresholdKph}) {
    return isCorrectingAt(now) ||
        isMovingAt(now, stationaryThresholdKph: stationaryThresholdKph) ||
        _isSpeedTransitionActive(now);
  }

  double currentSpeedKph(
    DateTime now, {
    required double stationaryThresholdKph,
  }) {
    final effectiveNow = _effectiveNow(now);
    if (!hasMotionInputs) {
      return 0.0;
    }
    if (!ignitionOn) {
      return 0.0;
    }

    if (isCorrectingAt(effectiveNow) &&
        effectiveNow.isBefore(speedTransitionStartedAt)) {
      if (correctionMode == _MarkerCorrectionMode.strictLerp) {
        return 0.0;
      }
      return math.max(speedTransitionStartKph, speedTransitionTargetKph);
    }

    final speed = _speedAt(effectiveNow);
    return speed >= stationaryThresholdKph ? speed : 0.0;
  }

  double _progressAt(DateTime now) {
    if (correctionMode == _MarkerCorrectionMode.none ||
        correctionDuration.inMilliseconds <= 0) {
      return 1.0;
    }

    final elapsedMs = now.difference(correctionStartedAt).inMilliseconds;
    return (elapsedMs / correctionDuration.inMilliseconds).clamp(0.0, 1.0);
  }

  bool _isSpeedTransitionActive(DateTime now) {
    if (speedTransitionDuration.inMilliseconds <= 0) {
      return false;
    }
    return now.isBefore(speedTransitionStartedAt.add(speedTransitionDuration));
  }

  bool _isDecelerating(DateTime now) {
    return speedTransitionDuration.inMilliseconds > 0 &&
        speedTransitionTargetKph <= _stationaryThresholdKph &&
        speedTransitionStartKph > speedTransitionTargetKph &&
        now.isAfter(speedTransitionStartedAt);
  }

  double _speedAt(DateTime now) {
    if (speedTransitionDuration.inMilliseconds <= 0) {
      return speedTransitionTargetKph;
    }
    if (now.isBefore(speedTransitionStartedAt)) {
      return speedTransitionStartKph;
    }

    final elapsedMs = now.difference(speedTransitionStartedAt).inMilliseconds;
    final progress = (elapsedMs / speedTransitionDuration.inMilliseconds).clamp(
      0.0,
      1.0,
    );
    return speedTransitionStartKph +
        ((speedTransitionTargetKph - speedTransitionStartKph) * progress);
  }

  LatLng _estimatedPositionAt(DateTime now) {
    final speedKph = _speedAt(now);
    final elapsed = now.difference(baseAt);
    final projectedSpeedKph = _visualProjectionSpeedKph(speedKph);
    final projectedMeters =
        (projectedSpeedKph / 3.6) *
        math.min(
          math.max(elapsed.inMicroseconds / 1000000.0, 0.0),
          _maxDeadReckoningDuration.inMicroseconds / 1000000.0,
        );
    if (roadPath.length > 1 &&
        ignitionOn &&
        projectedSpeedKph >= _stationaryThresholdKph &&
        elapsed > Duration.zero) {
      return _advanceAlongRoadPath(
            basePosition,
            roadPath,
            projectedMeters,
            baseBearing,
          ) ??
          _constrainToRoadPath(basePosition);
    }

    final estimated = LiveTrackingMotionMath.estimatePosition(
      basePosition: basePosition,
      elapsed: elapsed,
      speedKph: hasMotionInputs ? projectedSpeedKph : 0,
      headingDegrees: baseBearing,
      ignitionOn: ignitionOn,
      stationaryThresholdKph: _stationaryThresholdKph,
      maxDuration: _maxDeadReckoningDuration,
    );
    return _constrainToRoadPath(estimated);
  }

  double _visualProjectionSpeedKph(double speedKph) {
    if (!hasMotionInputs || speedKph < _stationaryThresholdKph) {
      return 0.0;
    }
    return speedKph.clamp(4.0, 16.0).toDouble();
  }

  LatLng _constrainToRoadPath(LatLng point) {
    if (roadPath.length < 2) {
      return point;
    }
    final projected = _nearestPointOnPath(point, roadPath);
    if (projected == null) {
      return point;
    }
    return projected.point;
  }

  LatLng? _interpolateAlongRoadPath(LatLng from, LatLng to, double progress) {
    if (roadPath.length < 2) {
      return null;
    }
    final start = _nearestPointOnPath(from, roadPath);
    final end = _nearestPointOnPath(to, roadPath);
    if (start == null || end == null) {
      return null;
    }

    final startMeters = _distanceAlongPath(start, roadPath);
    final endMeters = _distanceAlongPath(end, roadPath);
    final targetMeters = startMeters + ((endMeters - startMeters) * progress);
    return _pointAtDistanceOnPath(roadPath, targetMeters);
  }

  static double _distanceAlongPath(
    _PathProjection projection,
    List<LatLng> path,
  ) {
    var distance = 0.0;
    for (var index = 0; index < projection.segmentIndex; index++) {
      distance += _distanceMeters(path[index], path[index + 1]);
    }
    distance +=
        _distanceMeters(
          path[projection.segmentIndex],
          path[projection.segmentIndex + 1],
        ) *
        projection.segmentFraction;
    return distance;
  }

  static LatLng _pointAtDistanceOnPath(List<LatLng> path, double meters) {
    if (path.length < 2) {
      return path.first;
    }
    var remaining = meters.clamp(0.0, _pathLengthMeters(path)).toDouble();
    for (var index = 0; index < path.length - 1; index++) {
      final segmentLength = _distanceMeters(path[index], path[index + 1]);
      if (segmentLength < 0.5) {
        continue;
      }
      if (remaining <= segmentLength) {
        return _lerpLatLng(
          path[index],
          path[index + 1],
          remaining / segmentLength,
        );
      }
      remaining -= segmentLength;
    }
    return path.last;
  }

  static double _pathLengthMeters(List<LatLng> path) {
    var distance = 0.0;
    for (var index = 0; index < path.length - 1; index++) {
      distance += _distanceMeters(path[index], path[index + 1]);
    }
    return distance;
  }

  static LatLng? _advanceAlongRoadPath(
    LatLng from,
    List<LatLng> path,
    double meters,
    double headingDegrees,
  ) {
    if (path.length < 2 || meters <= 0) {
      return from;
    }

    final projection = _nearestPointOnPath(from, path);
    if (projection == null) {
      return null;
    }

    var segmentIndex = projection.segmentIndex;
    var distanceOnSegment =
        _distanceMeters(path[segmentIndex], path[segmentIndex + 1]) *
        projection.segmentFraction;
    final segmentBearing = _bearingBetween(
      path[segmentIndex],
      path[segmentIndex + 1],
    );
    final forward =
        _bearingDeltaAbsStatic(segmentBearing, headingDegrees) <= 100;
    var remainingMeters = meters;

    while (remainingMeters > 0 &&
        segmentIndex >= 0 &&
        segmentIndex < path.length - 1) {
      final start = path[segmentIndex];
      final end = path[segmentIndex + 1];
      final segmentLength = _distanceMeters(start, end);
      if (segmentLength < 0.5) {
        segmentIndex += forward ? 1 : -1;
        distanceOnSegment = forward && segmentIndex < path.length - 1
            ? 0
            : segmentIndex >= 0 && segmentIndex < path.length - 1
            ? _distanceMeters(path[segmentIndex], path[segmentIndex + 1])
            : 0;
        continue;
      }

      final available = forward
          ? segmentLength - distanceOnSegment
          : distanceOnSegment;
      if (remainingMeters <= available) {
        final newDistance = forward
            ? distanceOnSegment + remainingMeters
            : distanceOnSegment - remainingMeters;
        final t = (newDistance / segmentLength).clamp(0.0, 1.0);
        return _lerpLatLng(start, end, t);
      }

      remainingMeters -= math.max(available, 0);
      segmentIndex += forward ? 1 : -1;
      if (segmentIndex < 0) {
        return path.first;
      }
      if (segmentIndex >= path.length - 1) {
        return path.last;
      }
      distanceOnSegment = forward
          ? 0
          : _distanceMeters(path[segmentIndex], path[segmentIndex + 1]);
    }

    return forward ? path.last : path.first;
  }

  static _PathProjection? _nearestPointOnPath(LatLng point, List<LatLng> path) {
    if (path.length < 2) {
      return null;
    }
    _PathProjection? best;
    for (var i = 0; i < path.length - 1; i++) {
      final candidate = _projectPointToSegment(point, path[i], path[i + 1], i);
      if (best == null || candidate.distanceMeters < best.distanceMeters) {
        best = candidate;
      }
    }
    return best;
  }

  static _PathProjection _projectPointToSegment(
    LatLng point,
    LatLng start,
    LatLng end,
    int segmentIndex,
  ) {
    final latScale = LiveTrackingMotionMath.metersPerLatitudeDegree;
    final cosLat = math.cos(_degreesToRadians(point.latitude)).abs();
    final lngScale = latScale * math.max(cosLat, 0.000001);
    final px = (point.longitude - start.longitude) * lngScale;
    final py = (point.latitude - start.latitude) * latScale;
    final vx = (end.longitude - start.longitude) * lngScale;
    final vy = (end.latitude - start.latitude) * latScale;
    final lengthSquared = (vx * vx) + (vy * vy);
    final t = lengthSquared <= 0
        ? 0.0
        : ((px * vx) + (py * vy)) / lengthSquared;
    final clampedT = t.clamp(0.0, 1.0);
    final projected = LatLng(
      start.latitude + ((end.latitude - start.latitude) * clampedT),
      start.longitude + ((end.longitude - start.longitude) * clampedT),
    );
    return _PathProjection(
      point: projected,
      distanceMeters: _distanceMeters(point, projected),
      segmentIndex: segmentIndex,
      segmentFraction: clampedT.toDouble(),
    );
  }

  static double _bearingBetween(LatLng from, LatLng to) {
    final lat1 = _degreesToRadians(from.latitude);
    final lat2 = _degreesToRadians(to.latitude);
    final deltaLng = _degreesToRadians(to.longitude - from.longitude);
    final y = math.sin(deltaLng) * math.cos(lat2);
    final x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(deltaLng);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  static double _bearingDeltaAbsStatic(double from, double to) {
    return ((((to - from) % 360) + 540) % 360 - 180.0).abs();
  }

  static double _distanceMeters(LatLng from, LatLng to) {
    final dLat = _degreesToRadians(to.latitude - from.latitude);
    final dLng = _degreesToRadians(to.longitude - from.longitude);
    final lat1 = _degreesToRadians(from.latitude);
    final lat2 = _degreesToRadians(to.latitude);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    const earthRadiusMeters = 6371000.0;
    return earthRadiusMeters * c;
  }

  static double _degreesToRadians(double degrees) {
    return degrees * math.pi / 180;
  }

  DateTime _effectiveNow(DateTime now) {
    final rawNow = now;
    now = now.subtract(_renderDelay);
    if (lastRawSampleAt != null &&
        lastEffectiveSampleAt != null &&
        rawNow == lastRawSampleAt) {
      return lastEffectiveSampleAt!;
    }

    if (lastRawSampleAt == null || lastEffectiveSampleAt == null) {
      lastRawSampleAt = rawNow;
      lastEffectiveSampleAt = now;
      return now;
    }

    final rawDelta = rawNow.difference(lastRawSampleAt!);
    final clampedDelta = rawDelta <= Duration.zero
        ? Duration.zero
        : rawDelta > _maxFrameStep
        ? _maxFrameStep
        : rawDelta;
    lastRawSampleAt = rawNow;
    lastEffectiveSampleAt = lastEffectiveSampleAt!.add(clampedDelta);
    return lastEffectiveSampleAt!;
  }

  static LatLng _lerpLatLng(LatLng from, LatLng to, double t) {
    return LatLng(
      from.latitude + ((to.latitude - from.latitude) * t),
      from.longitude + ((to.longitude - from.longitude) * t),
    );
  }

  static double _lerpAngle(double from, double to, double t) {
    final delta = ((((to - from) % 360) + 540) % 360) - 180;
    return _normalizeBearing(from + (delta * t));
  }

  static double _normalizeBearing(double degrees) {
    return (degrees % 360 + 360) % 360;
  }
}
