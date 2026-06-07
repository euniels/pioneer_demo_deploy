import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart';

import '../services/backend_api.dart';
import '../services/fleet_sync_service.dart';
import '../services/google_map_marker_factory.dart';
import '../services/live_tracking_freshness.dart';
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
  late final DateTime _launchedAt;
  static const Duration _livePollInterval = Duration(seconds: 30);
  static const Duration _pollAlignedLerpDuration = Duration(seconds: 28);
  static const Duration _accelerationDuration = Duration(milliseconds: 900);
  static const Duration _decelerationDuration = Duration(milliseconds: 1200);
  static const Duration _dataStaleThreshold = Duration(minutes: 5);
  static const Duration _followMoveThrottle = Duration(milliseconds: 220);
  static const double _stationarySpeedThresholdKph = 2.0;
  static const double _bearingCorrectionThresholdDegrees = 5.0;
  static const Duration _markerRenderDelay = Duration(milliseconds: 900);
  static const double _viewportBufferFraction = 0.20;
  static const double _compactMarkerZoomThreshold = 12.0;

  bool get _usesCompactMapMarkers =>
      _currentMapZoom < _compactMarkerZoomThreshold;

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
    final routeStops = _selectedVehicle?['routeStops'];
    if (routeStops is! List) {
      return const [];
    }

    return routeStops.whereType<Map>().map((stop) {
      return stop.map((key, value) => MapEntry(key.toString(), value));
    }).toList();
  }

  List<LatLng> get _selectedPlannedPath {
    return _selectedRouteStops
        .map((stop) => _latLngFrom(stop['center']))
        .whereType<LatLng>()
        .toList();
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
        setState(() => _selectedTrail = points);
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
    final fleetFreshness = LiveTrackingFreshnessResolver.forFleet(
      _vehicleMarkers,
    );

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
                  child: _buildTopStats(
                        moving,
                        idle,
                        stopped,
                        stale,
                        total,
                        fleetFreshness,
                      )
                      .animate()
                      .fadeIn(duration: 600.ms)
                      .slideY(begin: 0.2, end: 0, duration: 500.ms),
                ),
                if (_selectedVehicle != null)
                  Positioned(
                    bottom: 24,
                    left: 24,
                    right: 24,
                    child: _buildSelectedVehicleCard(_selectedVehicle!)
                        .animate()
                        .fadeIn(duration: 700.ms)
                        .slideY(begin: 0.2, end: 0, duration: 500.ms),
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
          SizedBox(
            width: 380,
            child: _buildVehicleListSidebar(),
          ).animate().fadeIn(duration: 900.ms).slideY(begin: 0.2, end: 0),
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
          child: _buildTopStats(
                moving,
                idle,
                stopped,
                stale,
                total,
                fleetFreshness,
              )
              .animate()
              .fadeIn(duration: 600.ms)
              .slideY(begin: 0.2, end: 0, duration: 500.ms),
        ),
        if (_selectedVehicle != null)
          Positioned(
            bottom: 16,
            left: 12,
            right: 12,
            child: _buildSelectedVehicleCard(_selectedVehicle!)
                .animate()
                .fadeIn(duration: 700.ms)
                .slideY(begin: 0.2, end: 0, duration: 500.ms),
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
    LiveTrackingFreshness fleetFreshness,
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
                  ? fleetFreshness.label
                  : '${fleetFreshness.label} ${_secondsAgo(_lastLiveSyncAt!)}s',
              color: fleetFreshness.color,
              isDark: isDark,
              isMobile: isMobile,
              icon: fleetFreshness.icon,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatChip({
    required String label,
    required Color color,
    required bool isDark,
    required bool isMobile,
    IconData? icon,
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
          if (icon != null) ...[
            Icon(icon, size: isMobile ? 11 : 13, color: color),
            SizedBox(width: isMobile ? 3 : 5),
          ],
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
            onTap: _showVehicleListBottomSheet,
            isDark: isDark,
            isMobile: isMobile,
          ),
          SizedBox(height: isMobile ? 8 : 12),
        ],
        _buildControlButton(
          icon: Icons.my_location_rounded,
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
          onTap: () => _loadVehicles(fullRefresh: true, refreshTrail: true),
          isDark: isDark,
          isMobile: isMobile,
        ),
        SizedBox(height: isMobile ? 8 : 12),
        _buildControlButton(
          icon: Icons.add_rounded,
          onTap: () => _zoomBy(1),
          isDark: isDark,
          isMobile: isMobile,
        ),
        SizedBox(height: isMobile ? 8 : 12),
        _buildControlButton(
          icon: Icons.remove_rounded,
          onTap: () => _zoomBy(-1),
          isDark: isDark,
          isMobile: isMobile,
        ),
      ],
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required VoidCallback onTap,
    required bool isDark,
    required bool isMobile,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: isMobile ? 40 : 48,
        height: isMobile ? 40 : 48,
        decoration: BoxDecoration(
          color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
          borderRadius: BorderRadius.circular(isMobile ? 10 : 12),
          boxShadow: [
            BoxShadow(
              color: AppTheme.black.withValues(alpha: isDark ? 0.4 : 0.08),
              blurRadius: 12,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(
          icon,
          color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
          size: isMobile ? 20 : 24,
        ),
      ),
    );
  }

  Widget _buildVehicleListSidebar() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
            padding: const EdgeInsets.all(20),
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
                  size: 24,
                ),
                const SizedBox(width: 12),
                Text(
                  'Live Orders',
                  style: AppTheme.getHeadingStyle(context, fontSize: 18),
                ),
              ],
            ),
          ),
          _buildRouteOrdersPanel(isDark: isDark, isMobile: false),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Row(
              children: [
                Icon(
                  Icons.sensors_rounded,
                  size: 18,
                  color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                ),
                const SizedBox(width: 8),
                Text(
                  'Tracked Vehicles',
                  style: AppTheme.getCaptionStyle(
                    context,
                  ).copyWith(fontWeight: FontWeight.w900),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _sortedVehicles.length,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemBuilder: (context, index) {
                final vehicle = _sortedVehicles[index];
                final isSelected = _plateOf(vehicle) == selectedPlate;
                final markerState = _visualMarkerState(vehicle);
                final markerColor = _sidebarStateAccent(vehicle);
                final freshness = LiveTrackingFreshnessResolver.forVehicle(
                  vehicle,
                );
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
                  child: Container(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Color.alphaBlend(
                        markerColor.withValues(alpha: isSelected ? 0.12 : 0.07),
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
                                    duration: const Duration(milliseconds: 180),
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
                                                fontWeight: FontWeight.w900,
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
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      _motionStateShortLabel(
                                        vehicle,
                                      ).toUpperCase(),
                                      style: AppTheme.getCaptionStyle(context)
                                          .copyWith(
                                            fontWeight: FontWeight.w800,
                                            color: markerColor,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              _buildFreshnessPill(freshness),
                              const SizedBox(height: 8),
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
                                    style: AppTheme.getCaptionStyle(context)
                                        .copyWith(
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
                                      style: AppTheme.getCaptionStyle(
                                        context,
                                      ).copyWith(fontWeight: FontWeight.w600),
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
                                      style: AppTheme.getCaptionStyle(context),
                                      maxLines: 1,
                                    ),
                                  ),
                                ],
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

  Widget _buildFreshnessPill(
    LiveTrackingFreshness freshness, {
    bool compact = false,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 9,
        vertical: compact ? 3 : 4,
      ),
      decoration: BoxDecoration(
        color: freshness.color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: freshness.color.withValues(alpha: 0.32)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            freshness.icon,
            size: compact ? 11 : 12,
            color: freshness.color,
          ),
          SizedBox(width: compact ? 4 : 5),
          Flexible(
            child: Text(
              compact
                  ? freshness.label
                  : '${freshness.label} - ${freshness.detail}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: compact ? 10 : 11,
                fontWeight: FontWeight.w800,
                color: freshness.color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRouteOrdersPanel({
    required bool isDark,
    required bool isMobile,
    bool closeOnSelect = false,
  }) {
    final orders = _routeOrders;

    return Container(
      margin: EdgeInsets.fromLTRB(isMobile ? 12 : 16, 0, isMobile ? 12 : 16, 0),
      padding: EdgeInsets.all(isMobile ? 12 : 14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF111827 : AppTheme.colorFFF3F7FF,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.22),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.assignment_rounded,
                  color: AppTheme.colorFF4B7BE5,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'GeoTab Route Orders',
                  style: TextStyle(
                    fontSize: isMobile ? 13 : 14,
                    fontWeight: FontWeight.w900,
                    color: isDark ? AppTheme.white : AppTheme.colorFF1A1D23,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${orders.length}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.colorFF4B7BE5,
                  ),
                ),
              ),
            ],
          ),
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
              constraints: BoxConstraints(maxHeight: isMobile ? 180 : 250),
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

  void _showVehicleListBottomSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.transparent,
      isScrollControlled: true,
      builder: (context) {
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
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      controller: scrollController,
                      itemCount: _sortedVehicles.length,
                      padding: EdgeInsets.only(bottom: isMobile ? 16 : 20),
                      itemBuilder: (context, index) {
                        final vehicle = _sortedVehicles[index];
                        final isSelected = _plateOf(vehicle) == selectedPlate;
                        final markerState = _visualMarkerState(vehicle);
                        final markerColor = _sidebarStateAccent(vehicle);
                        final freshness =
                            LiveTrackingFreshnessResolver.forVehicle(vehicle);
                        final baseCardColor = isDark
                            ? AppTheme.colorFF252930
                            : AppTheme.colorFFF8F9FA;
                        final outlineColor = isSelected
                            ? markerColor.withValues(alpha: 0.7)
                            : (isDark
                                  ? AppTheme.white.withValues(alpha: 0.05)
                                  : AppTheme.black.withValues(alpha: 0.05));

                        return GestureDetector(
                          onTap: () async {
                            await _selectVehicle(vehicle);
                            if (mounted) {
                              Navigator.pop(context);
                            }
                          },
                          child: Container(
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
                                  padding: EdgeInsets.all(isMobile ? 12 : 16),
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
                                                    fontWeight: FontWeight.w900,
                                                  ),
                                            ),
                                            SizedBox(height: isMobile ? 2 : 4),
                                            Text(
                                              _driverLabelOf(vehicle),
                                              style: AppTheme.getCaptionStyle(
                                                context,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            SizedBox(height: isMobile ? 6 : 8),
                                            Text(
                                              '${_speedOf(vehicle)} km/h - ${_motionStateShortLabel(vehicle)}',
                                              style:
                                                  AppTheme.getCaptionStyle(
                                                    context,
                                                  ).copyWith(
                                                    fontWeight: FontWeight.w700,
                                                    color: markerColor,
                                                  ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 4),
                                            _buildFreshnessPill(
                                              freshness,
                                              compact: true,
                                            ),
                                            const SizedBox(height: 4),
                                            SelectableText(
                                              _lastKnownAddressLabel(vehicle),
                                              style: AppTheme.getCaptionStyle(
                                                context,
                                              ),
                                              maxLines: 1,
                                            ),
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
      padding: EdgeInsets.all(isMobile ? 12 : 20),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        borderRadius: BorderRadius.circular(isMobile ? 16 : 20),
        boxShadow: [
          BoxShadow(
            color: AppTheme.black.withValues(alpha: isDark ? 0.4 : 0.08),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: isMobile ? 44 : 60,
            height: isMobile ? 44 : 60,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: _motionStateGradient(vehicle)),
              borderRadius: BorderRadius.circular(isMobile ? 12 : 16),
            ),
            child: Icon(
              _motionStateIcon(vehicle),
              color: AppTheme.white,
              size: isMobile ? 22 : 32,
            ),
          ),
          SizedBox(width: isMobile ? 10 : 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _plateOf(vehicle),
                  style: TextStyle(
                    fontSize: isMobile ? 15 : 20,
                    fontWeight: FontWeight.w900,
                    color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                  ),
                ),
                SizedBox(height: isMobile ? 4 : 8),
                Wrap(
                  spacing: isMobile ? 8 : 16,
                  runSpacing: 4,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.speed_rounded,
                          size: isMobile ? 14 : 16,
                          color: AppTheme.colorFF4B7BE5,
                        ),
                        SizedBox(width: isMobile ? 4 : 6),
                        Text(
                          '${_speedOf(vehicle)} km/h',
                          style: TextStyle(
                            fontSize: isMobile ? 11 : 14,
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
                          size: isMobile ? 14 : 16,
                          color: AppTheme.colorFF27AE60,
                        ),
                        SizedBox(width: isMobile ? 4 : 6),
                        Text(
                          _statusLabel(vehicle),
                          style: TextStyle(
                            fontSize: isMobile ? 11 : 14,
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
                          size: isMobile ? 14 : 16,
                          color: AppTheme.colorFF27AE60,
                        ),
                        SizedBox(width: isMobile ? 4 : 6),
                        Text(
                          _directionDisplay(vehicle),
                          style: TextStyle(
                            fontSize: isMobile ? 11 : 14,
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
                          size: isMobile ? 14 : 16,
                          color: _ignitionOn(vehicle)
                              ? AppTheme.colorFFFFD166
                              : AppTheme.colorFF95A5A6,
                        ),
                        SizedBox(width: isMobile ? 4 : 6),
                        Text(
                          _syncLabel(vehicle),
                          style: TextStyle(
                            fontSize: isMobile ? 11 : 14,
                            color: isDark
                                ? AppTheme.gray300
                                : AppTheme.colorFF2C3E50,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                if (_isFollowingSelected) ...[
                  SizedBox(height: isMobile ? 6 : 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
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
                          size: 14,
                          color: AppTheme.colorFF4B7BE5,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Following ${_plateOf(vehicle)}',
                          style: TextStyle(
                            fontSize: isMobile ? 11 : 12,
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
                SizedBox(height: isMobile ? 6 : 10),
                Text(
                  _secondaryText(vehicle),
                  style: TextStyle(
                    fontSize: isMobile ? 11 : 13,
                    color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                  ),
                  maxLines: 2,
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
              polygons: {
                ..._visibleZoneOverlayPolygons,
                ..._selectedGeofencePolygons,
              },
              circles: _liveTrackingCircles(vehicles),
              onMapCreated: (controller) {
                _mapController = controller;
                _refreshVisibleBounds();
                _scheduleSelectedPulseProjection();
              },
              onCameraMove: (position) {
                final previouslyCompact = _usesCompactMapMarkers;
                _currentMapZoom = position.zoom;
                if (previouslyCompact != _usesCompactMapMarkers && mounted) {
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
            Positioned(
              right: 14,
              bottom: 14,
              child: _buildMapMarkerLegend(context),
            ),
          ],
        );
      },
    );
  }

  Widget _buildMapMarkerLegend(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
          _legendRow(
            icon: Icons.navigation_rounded,
            color: AppTheme.colorFF1A3A6B,
            label: 'Moving',
            isDark: isDark,
          ),
          const SizedBox(height: 7),
          _legendRow(
            icon: Icons.pause_rounded,
            color: AppTheme.colorFFFFB020,
            label: 'Idle, ignition on',
            isDark: isDark,
          ),
          const SizedBox(height: 7),
          _legendRow(
            icon: Icons.power_settings_new_rounded,
            color: AppTheme.colorFF64748B,
            label: 'Stopped, ignition off',
            isDark: isDark,
          ),
          const SizedBox(height: 7),
          _legendRow(
            icon: Icons.schedule_rounded,
            color: AppTheme.colorFF94A3B8,
            label: 'Stale / offline',
            isDark: isDark,
          ),
        ],
      ),
    );
  }

  Widget _legendRow({
    required IconData icon,
    required Color color,
    required String label,
    required bool isDark,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: AppTheme.white, width: 2),
          ),
          child: Icon(icon, color: AppTheme.white, size: 13),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: isDark ? AppTheme.white : AppTheme.colorFF1F2937,
          ),
        ),
      ],
    );
  }

  Set<gmaps.Polyline> _liveTrackingPolylines() {
    return {
      if (_selectedPlannedPath.length > 1)
        gmaps.Polyline(
          polylineId: const gmaps.PolylineId('selected-planned-path'),
          points: _selectedPlannedPath.map(_toGoogleLatLng).toList(),
          color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.78),
          width: 3,
        ),
      if (_selectedTrail.length > 1)
        gmaps.Polyline(
          polylineId: const gmaps.PolylineId('selected-live-trail-glow'),
          points: _selectedTrail.map(_toGoogleLatLng).toList(),
          color: AppTheme.colorFF27AE60.withValues(alpha: 0.22),
          width: 9,
        ),
      if (_selectedTrail.length > 1)
        gmaps.Polyline(
          polylineId: const gmaps.PolylineId('selected-live-trail'),
          points: _selectedTrail.map(_toGoogleLatLng).toList(),
          color: AppTheme.colorFF0E7A43,
          width: 4,
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
    final freshness = LiveTrackingFreshnessResolver.forVehicle(vehicle);
    if (freshness.state == LiveTrackingFreshnessState.stale ||
        freshness.state == LiveTrackingFreshnessState.geotabUnavailable ||
        _isVehicleStale(vehicle) ||
        _isVehicleDataStale(vehicle)) {
      return PioneerMapMarkerStyle.stale;
    }

    if (_ignitionOn(vehicle) &&
        _speedKphOf(vehicle) > _stationarySpeedThresholdKph) {
      return PioneerMapMarkerStyle.moving;
    }

    if (_ignitionOn(vehicle)) {
      return PioneerMapMarkerStyle.idle;
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
    return _visualMarkerState(vehicle) == PioneerMapMarkerStyle.moving;
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

      final nextPoint = LatLng(_latitudeOf(vehicle), _longitudeOf(vehicle));
      final nextBearing = _bearingOf(vehicle);
      final nextSpeedKph = _speedKphOf(vehicle);
      final hasMotionInputs = _hasDeadReckoningInputs(vehicle);
      final lastGeotabAt = _parseDisplayTimestamp(
        vehicle['lastGeotabAt'] ?? vehicle['lastUpdated'],
      );
      final existing = _markerMotionStates[key];

      if (existing == null) {
        _markerMotionStates[key] = _MarkerMotionState(
          basePosition: nextPoint,
          baseAt: now,
          baseBearing: nextBearing,
          baseSpeedKph: _normalizedMotionSpeedKph(
            hasMotionInputs ? nextSpeedKph : 0,
          ),
          ignitionOn: _ignitionOn(vehicle),
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
        );
        continue;
      }

      if (lastGeotabAt != null &&
          existing.lastServerAt != null &&
          !lastGeotabAt.isAfter(existing.lastServerAt!)) {
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
          ..ignitionOn = _ignitionOn(vehicle)
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
          ..lastServerAt = lastGeotabAt ?? existing.lastServerAt;
        continue;
      }

      if (!hasMotionInputs) {
        final correctionDuration = _pollAlignedLerpDuration;
        existing
          ..basePosition = nextPoint
          ..baseAt = now.add(correctionDuration)
          ..baseBearing = resolvedBearing
          ..baseSpeedKph = 0
          ..ignitionOn = _ignitionOn(vehicle)
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
          ..lastServerAt = lastGeotabAt ?? existing.lastServerAt;
        continue;
      }

      // Compare the incoming fix with the point currently painted on-screen.
      // Using the preceding server fix here makes an in-flight marker snap.
      final driftMeters = _distanceMeters(currentPoint, nextPoint);
      final snapThresholdMeters = _snapThresholdMeters(
        previousSpeedKph: previousSpeedKph,
        nextSpeedKph: normalizedNextSpeedKph,
      );
      if (driftMeters > snapThresholdMeters) {
        existing
          ..basePosition = nextPoint
          ..baseAt = now
          ..baseBearing = resolvedBearing
          ..baseSpeedKph = normalizedNextSpeedKph
          ..ignitionOn = _ignitionOn(vehicle)
          ..hasMotionInputs = hasMotionInputs
          ..speedTransitionStartKph = normalizedNextSpeedKph
          ..speedTransitionTargetKph = normalizedNextSpeedKph
          ..speedTransitionStartedAt = now
          ..speedTransitionDuration = Duration.zero
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
          ..lastServerAt = lastGeotabAt ?? existing.lastServerAt;
        continue;
      }

      // GPS fixes arrive every 30 seconds. Render the next leg over the
      // interval minus a small buffer, always starting at the current frame.
      final correctionDuration = _pollAlignedLerpDuration;
      existing
        ..basePosition = nextPoint
        ..baseAt = now.add(correctionDuration)
        ..baseBearing = resolvedBearing
        ..baseSpeedKph = normalizedNextSpeedKph
        ..ignitionOn = _ignitionOn(vehicle)
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
        ..lastServerAt = lastGeotabAt ?? existing.lastServerAt;
    }

    _markerMotionStates.removeWhere((key, _) => !activeKeys.contains(key));
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
    if (syncState == 'offline_cached' || syncState == 'stale') {
      return true;
    }

    final sourceAgeMs = _sourceAgeMsOf(vehicle);
    return sourceAgeMs != null &&
        sourceAgeMs > _dataStaleThreshold.inMilliseconds;
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

  bool _hasDeadReckoningInputs(Map<String, dynamic>? vehicle) {
    return _trySpeedKphOf(vehicle) != null && _tryBearingOf(vehicle) != null;
  }

  double _snapThresholdMeters({
    required double previousSpeedKph,
    required double nextSpeedKph,
  }) {
    return LiveTrackingMotionMath.snapThresholdMeters(
      previousSpeedKph: previousSpeedKph,
      nextSpeedKph: nextSpeedKph,
      pollInterval: _livePollInterval,
    );
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

  double? _doubleFromAny(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value.trim());
    }
    return null;
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

    final previouslyCompact = _usesCompactMapMarkers;
    _currentMapZoom = (_currentMapZoom + delta).clamp(3.0, 20.0);
    if (previouslyCompact != _usesCompactMapMarkers && mounted) {
      setState(() {});
    }
    controller.animateCamera(gmaps.CameraUpdate.zoomTo(_currentMapZoom));
  }

  String _plateOf(Map<String, dynamic>? vehicle) {
    return vehicle?['plate']?.toString().trim() ?? '';
  }

  String _plateLabelOf(Map<String, dynamic>? vehicle) {
    final plate = _plateOf(vehicle);
    return plate.isEmpty ? 'Unknown plate' : plate;
  }

  String _driverLabelOf(Map<String, dynamic> vehicle) {
    final driver = vehicle['driver']?.toString().trim() ?? '';
    return driver.isEmpty ? 'Unassigned' : driver;
  }

  String _lastKnownAddressLabel(Map<String, dynamic> vehicle) {
    final address = vehicle['currentLocationLabel']?.toString().trim() ?? '';
    return address.isEmpty ? 'Location unavailable' : address;
  }

  String _motionStateShortLabel(Map<String, dynamic> vehicle) {
    final freshness = LiveTrackingFreshnessResolver.forVehicle(vehicle);
    if (freshness.state == LiveTrackingFreshnessState.geotabUnavailable) {
      return 'GeoTab unavailable';
    }
    if (freshness.state == LiveTrackingFreshnessState.stale) {
      return 'Stale';
    }

    switch (_visualMarkerState(vehicle)) {
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

  Color _sidebarStateAccent(Map<String, dynamic> vehicle) {
    switch (_visualMarkerState(vehicle)) {
      case PioneerMapMarkerStyle.moving:
        return AppTheme.successGreen;
      case PioneerMapMarkerStyle.idle:
        return AppTheme.warningOrange;
      case PioneerMapMarkerStyle.offline:
        return AppTheme.neutralGray;
      case PioneerMapMarkerStyle.stale:
        return AppTheme.errorRed;
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
    final freshness = LiveTrackingFreshnessResolver.forVehicle(vehicle);
    if (freshness.state == LiveTrackingFreshnessState.geotabUnavailable ||
        freshness.state == LiveTrackingFreshnessState.stale) {
      return freshness.detail;
    }

    switch (_visualMarkerState(vehicle)) {
      case PioneerMapMarkerStyle.moving:
        return 'Moving at ${_speedOf(vehicle)} km/h';
      case PioneerMapMarkerStyle.idle:
        return 'Idling';
      case PioneerMapMarkerStyle.offline:
        return 'Stopped, ignition off';
      case PioneerMapMarkerStyle.stale:
        return _lastSeenLabel(vehicle);
    }
  }

  String _syncLabel(Map<String, dynamic> vehicle) {
    if (_hasMaintenanceBadge(vehicle)) {
      return 'Maintenance attention';
    }
    final freshness = LiveTrackingFreshnessResolver.forVehicle(vehicle);
    if (freshness.state == LiveTrackingFreshnessState.geotabUnavailable ||
        freshness.state == LiveTrackingFreshnessState.cached ||
        freshness.state == LiveTrackingFreshnessState.stale) {
      return freshness.detail;
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
  });

  static const double _stationaryThresholdKph = 2.0;
  static const Duration _maxFrameStep = Duration(milliseconds: 500);
  static const Duration _maxDeadReckoningDuration = Duration(seconds: 32);
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
        return _lerpLatLng(correctionFromPoint, correctionToPoint, progress);
      case _MarkerCorrectionMode.direct:
      case _MarkerCorrectionMode.strictLerp:
        if (progress >= 1.0) {
          return _estimatedPositionAt(effectiveNow);
        }
        return _lerpLatLng(correctionFromPoint, correctionToPoint, progress);
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
    return LiveTrackingMotionMath.estimatePosition(
      basePosition: basePosition,
      elapsed: now.difference(baseAt),
      speedKph: hasMotionInputs ? speedKph : 0,
      headingDegrees: baseBearing,
      ignitionOn: ignitionOn,
      stationaryThresholdKph: _stationaryThresholdKph,
      maxDuration: _maxDeadReckoningDuration,
    );
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
