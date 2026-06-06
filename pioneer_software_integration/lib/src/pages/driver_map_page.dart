import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart';
import '../widgets/dashboard_layout.dart';
import '../widgets/app_state_widgets.dart';
import '../widgets/page_skeletons.dart';
import '../widgets/pioneer_google_map.dart';
import '../services/api.dart';
import '../services/auth.dart';
import '../services/backend_api.dart';
import '../services/google_map_marker_factory.dart';
import '../theme/app_theme.dart';
import '../services/trips_store.dart';
import 'package:flutter_animate/flutter_animate.dart';

class DriverMapPage extends StatefulWidget {
  const DriverMapPage({super.key});

  @override
  State<DriverMapPage> createState() => _DriverMapPageState();
}

class _DriverMapPageState extends State<DriverMapPage>
    with TickerProviderStateMixin {
  Map<String, dynamic>? _vehicle;
  gmaps.GoogleMapController? _mapController;
  late Timer _updateTimer;
  late AnimationController _pulseController;
  late AnimationController _dotController;
  gmaps.BitmapDescriptor? _movingMarkerIcon;
  gmaps.BitmapDescriptor? _idleMarkerIcon;

  bool _isLoading = true;
  bool _isFollowing = true; // auto-pan to vehicle
  bool _mapReady = false;
  double _currentMapZoom = _trackingZoom;

  final List<LatLng> _trail = [];

  static const double _trackingZoom = 16.0;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _dotController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);

    _loadInitialData();
    _loadMarkerIcons();
    tripsNotifier.addListener(_onStoreChanged);
    _updateTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      _updateVehicle();
    });
  }

  Future<void> _loadMarkerIcons() async {
    final icons = await Future.wait<gmaps.BitmapDescriptor>([
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.moving,
        selected: true,
      ),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.idle,
        selected: true,
      ),
    ]);
    if (!mounted) {
      return;
    }

    setState(() {
      _movingMarkerIcon = icons[0];
      _idleMarkerIcon = icons[1];
    });
  }

  void _onStoreChanged() {
    if (mounted) _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    try {
      final locations = await Api.getVehicleLocations();
      final firstVehicle = locations.isNotEmpty ? locations.first : null;
      final trail = await _loadTrail(firstVehicle);
      if (mounted) {
        setState(() {
          _vehicle = firstVehicle;
          _isLoading = false;
          _trail
            ..clear()
            ..addAll(trail);
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_mapReady && _vehicle != null && _isFollowing) {
            _centerOnVehicle();
          }
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _updateVehicle() async {
    try {
      final locations = await Api.getVehicleLocations();
      if (!mounted || locations.isEmpty) return;

      final updated = locations.first;
      final trail = await _loadTrail(updated);
      if (!mounted) return;

      setState(() {
        _vehicle = updated;
        _trail
          ..clear()
          ..addAll(trail);
      });

      if (_isFollowing && _mapReady) {
        _centerOnVehicle();
      }
    } catch (_) {}
  }

  Future<List<LatLng>> _loadTrail(Map<String, dynamic>? vehicle) async {
    final authorizedTrail = (vehicle?['authorizedTrail'] as List? ?? const [])
        .whereType<Map>()
        .map((point) {
          final latitude = (point['latitude'] as num?)?.toDouble();
          final longitude = (point['longitude'] as num?)?.toDouble();
          if (latitude == null || longitude == null) {
            return null;
          }
          return LatLng(latitude, longitude);
        })
        .whereType<LatLng>()
        .toList();
    if (authorizedTrail.isNotEmpty) {
      return authorizedTrail;
    }

    final geotabId = vehicle?['geotabId']?.toString() ?? '';
    if (geotabId.isEmpty || AuthService.currentManagedRole == 'driver') {
      final latitude = (vehicle?['latitude'] as num?)?.toDouble();
      final longitude = (vehicle?['longitude'] as num?)?.toDouble();
      if (latitude == null || longitude == null) {
        return const [];
      }
      return [LatLng(latitude, longitude)];
    }

    try {
      final trail = await BackendApiService.getVehicleTrail(geotabId);
      final points = trail
          .where((entry) {
            final latitude = (entry['latitude'] as num?)?.toDouble() ?? 0.0;
            final longitude = (entry['longitude'] as num?)?.toDouble() ?? 0.0;
            return latitude != 0.0 || longitude != 0.0;
          })
          .map(
            (entry) => LatLng(
              (entry['latitude'] as num).toDouble(),
              (entry['longitude'] as num).toDouble(),
            ),
          )
          .toList();

      if (points.isNotEmpty) {
        return points;
      }
    } catch (_) {
      // Fall back to the latest point below.
    }

    final latitude = (vehicle?['latitude'] as num?)?.toDouble();
    final longitude = (vehicle?['longitude'] as num?)?.toDouble();
    if (latitude == null || longitude == null) {
      return const [];
    }
    return [LatLng(latitude, longitude)];
  }

  void _centerOnVehicle() {
    if (_vehicle == null) return;
    final controller = _mapController;
    if (controller == null) return;
    controller.animateCamera(
      gmaps.CameraUpdate.newCameraPosition(
        gmaps.CameraPosition(
          target: gmaps.LatLng(
            (_vehicle!['latitude'] as num).toDouble(),
            (_vehicle!['longitude'] as num).toDouble(),
          ),
          zoom: _trackingZoom,
        ),
      ),
    );
  }

  @override
  void dispose() {
    tripsNotifier.removeListener(_onStoreChanged);
    _updateTimer.cancel();
    _pulseController.dispose();
    _dotController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      currentRoute: '/driver-map',
      title: 'My Location',
      child: _isLoading
          ? const PioneerRouteSkeletonBody(routeName: '/driver-map')
          : _vehicle == null
          ? _buildNoVehicle()
          : _buildTracker(),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  NO VEHICLE STATE
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildNoVehicle() {
    return Padding(
      padding: const EdgeInsets.all(AppTheme.space20),
      child: PioneerStateCard(
        icon: Icons.location_off_rounded,
        title: 'No live location yet',
        message:
            'Your assigned vehicle will appear once it reports GPS data from GeoTab.',
        actionLabel: 'Retry',
        onAction: _loadInitialData,
        tone: PioneerStateTone.empty,
      ),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  MAIN TRACKER LAYOUT
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildTracker() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isLarge = screenWidth >= 1024;

    if (isLarge) {
      return Row(
        children: [
          Expanded(flex: 7, child: _buildMapStack()),
          SizedBox(width: 340, child: _buildInfoPanel()),
        ],
      );
    }

    return Stack(
      children: [
        _buildMapView(),
        _buildTopStatusBar(),
        _buildMapControls(),
        _buildBottomCard(),
      ],
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  MAP STACK (desktop)
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildMapStack() {
    return Stack(
      children: [_buildMapView(), _buildTopStatusBar(), _buildMapControls()],
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  MAP
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildMapView() {
    final lat = (_vehicle!['latitude'] as num).toDouble();
    final lng = (_vehicle!['longitude'] as num).toDouble();
    final isMoving = (_vehicle!['speed'] as num) > 0;

    return PioneerGoogleMap(
      initialCenter: gmaps.LatLng(lat, lng),
      initialZoom: _trackingZoom,
      zoomControlsEnabled: false,
      onMapCreated: (controller) {
        _mapController = controller;
        if (mounted) {
          setState(() => _mapReady = true);
        }
        if (_isFollowing) _centerOnVehicle();
      },
      onCameraMove: (position) {
        _currentMapZoom = position.zoom;
      },
      onTap: (_) {
        if (_isFollowing && mounted) {
          setState(() => _isFollowing = false);
        }
      },
      polylines: {
        if (_trail.length > 1)
          gmaps.Polyline(
            polylineId: const gmaps.PolylineId('driver-trail'),
            points: _trail.map(_toGoogleLatLng).toList(),
            color: AppTheme.colorFF27AE60.withValues(alpha: 0.6),
            width: 4,
          ),
      },
      markers: {
        gmaps.Marker(
          markerId: const gmaps.MarkerId('driver-vehicle'),
          position: gmaps.LatLng(lat, lng),
          flat: true,
          anchor: const Offset(0.5, 0.5),
          icon:
              (isMoving ? _movingMarkerIcon : _idleMarkerIcon) ??
              gmaps.BitmapDescriptor.defaultMarkerWithHue(
                isMoving
                    ? gmaps.BitmapDescriptor.hueAzure
                    : gmaps.BitmapDescriptor.hueOrange,
              ),
          onTap: () {
            setState(() => _isFollowing = true);
            _centerOnVehicle();
          },
          infoWindow: gmaps.InfoWindow(
            title: _vehicle!['plate']?.toString() ?? 'Vehicle',
            snippet: isMoving ? 'In Transit' : 'Parked',
          ),
        ),
      },
    );
  }

  gmaps.LatLng _toGoogleLatLng(LatLng point) {
    return gmaps.LatLng(point.latitude, point.longitude);
  }

  void _zoomBy(double delta) {
    final controller = _mapController;
    if (controller == null) return;
    _currentMapZoom = (_currentMapZoom + delta).clamp(3.0, 20.0);
    controller.animateCamera(gmaps.CameraUpdate.zoomTo(_currentMapZoom));
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  TOP STATUS BAR
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildTopStatusBar() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMoving = (_vehicle!['speed'] as num) > 0;
    final speed = _vehicle!['speed'];
    final plate = _vehicle!['plate'];

    return Positioned(
      top: 16,
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: AppTheme.black.withValues(alpha: isDark ? 0.4 : 0.1),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            // GPS live dot
            AnimatedBuilder(
              animation: _dotController,
              builder: (_, __) => Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color.lerp(
                    AppTheme.colorFF27AE60,
                    AppTheme.colorFF2ECC71,
                    _dotController.value,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(
                        0xFF27AE60,
                      ).withValues(alpha: 0.5 * _dotController.value),
                      blurRadius: 6,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'GPS Live',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppTheme.colorFF27AE60,
              ),
            ),
            const SizedBox(width: 16),
            Container(
              width: 1,
              height: 20,
              color: isDark ? AppTheme.white12 : AppTheme.black12,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    plate,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                    ),
                  ),
                  Text(
                    AuthService.currentUserData?.fullName ??
                        AuthService.currentUser,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                    ),
                  ),
                ],
              ),
            ),
            // Speed chip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isMoving
                    ? AppTheme.colorFF27AE60.withValues(alpha: 0.15)
                    : AppTheme.colorFFF39C12.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isMoving
                      ? AppTheme.colorFF27AE60.withValues(alpha: 0.4)
                      : AppTheme.colorFFF39C12.withValues(alpha: 0.4),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$speed',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: isMoving
                          ? AppTheme.colorFF27AE60
                          : AppTheme.colorFFF39C12,
                    ),
                  ),
                  Text(
                    'km/h',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isMoving
                          ? AppTheme.colorFF27AE60
                          : AppTheme.colorFFF39C12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ).animate().fadeIn(duration: 400.ms).slideY(begin: -0.2, end: 0),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  MAP CONTROLS
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildMapControls() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600;

    return Positioned(
      right: 16,
      top: isMobile ? 100 : 90,
      child: Column(
        children: [
          // Re-center / follow button
          _buildControlBtn(
            icon: _isFollowing
                ? Icons.my_location_rounded
                : Icons.location_searching_rounded,
            color: _isFollowing
                ? AppTheme.colorFF27AE60
                : (isDark ? AppTheme.gray400 : AppTheme.gray700),
            isDark: isDark,
            onTap: () {
              setState(() => _isFollowing = true);
              _centerOnVehicle();
            },
            tooltip: _isFollowing ? 'Following' : 'Re-center',
          ),
          const SizedBox(height: 10),
          _buildControlBtn(
            icon: Icons.add_rounded,
            isDark: isDark,
            onTap: () => _zoomBy(1),
          ),
          const SizedBox(height: 10),
          _buildControlBtn(
            icon: Icons.remove_rounded,
            isDark: isDark,
            onTap: () => _zoomBy(-1),
          ),
        ],
      ).animate().fadeIn(duration: 500.ms),
    );
  }

  Widget _buildControlBtn({
    required IconData icon,
    required bool isDark,
    required VoidCallback onTap,
    Color? color,
    String? tooltip,
  }) {
    return Tooltip(
      message: tooltip ?? '',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: AppTheme.black.withValues(alpha: isDark ? 0.4 : 0.1),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(
            icon,
            size: 22,
            color: color ?? (isDark ? AppTheme.white : AppTheme.colorFF2C3E50),
          ),
        ),
      ),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  BOTTOM CARD (mobile only)
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildBottomCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Positioned(
      bottom: 16,
      left: 16,
      right: 16,
      child: _buildTripCard(
        isDark,
      ).animate().fadeIn(duration: 500.ms).slideY(begin: 0.3, end: 0),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  INFO PANEL (desktop right side)
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildInfoPanel() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      color: isDark ? AppTheme.colorFF13161E : AppTheme.colorFFF5F6F8,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        physics: const BouncingScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionLabel('Live Status', isDark),
            const SizedBox(height: 12),
            _buildStatusCard(isDark),
            const SizedBox(height: 20),
            _buildSectionLabel('Current Trip', isDark),
            const SizedBox(height: 12),
            _buildTripCard(isDark),
            const SizedBox(height: 20),
            _buildSectionLabel('GPS Info', isDark),
            const SizedBox(height: 12),
            _buildGpsCard(isDark),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionLabel(String label, bool isDark) {
    return Text(
      label.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: isDark ? AppTheme.gray600 : AppTheme.gray500,
        letterSpacing: 1.2,
      ),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  STATUS CARD
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildStatusCard(bool isDark) {
    final isMoving = (_vehicle!['speed'] as num) > 0;
    final speed = _vehicle!['speed'];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(isDark),
      child: Row(
        children: [
          // Animated pulse indicator
          AnimatedBuilder(
            animation: _pulseController,
            builder: (_, __) {
              return Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 44 + (_pulseController.value * 10),
                    height: 44 + (_pulseController.value * 10),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color:
                          (isMoving
                                  ? AppTheme.colorFF27AE60
                                  : AppTheme.colorFFF39C12)
                              .withValues(
                                alpha: 0.15 * (1 - _pulseController.value),
                              ),
                    ),
                  ),
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: isMoving
                            ? [AppTheme.colorFF27AE60, AppTheme.colorFF2ECC71]
                            : [AppTheme.colorFFF39C12, AppTheme.colorFFFFB84D],
                      ),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isMoving
                          ? Icons.local_shipping_rounded
                          : Icons.pause_circle_rounded,
                      color: AppTheme.white,
                      size: 22,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isMoving ? 'In Transit' : 'Parked',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _vehicle!['plate'],
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$speed',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  color: isMoving
                      ? AppTheme.colorFF27AE60
                      : AppTheme.colorFFF39C12,
                ),
              ),
              Text(
                'km/h',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? AppTheme.gray500 : AppTheme.gray600,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  TRIP CARD
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildTripCard(bool isDark) {
    final destination = _vehicle!['destination'] ?? 'No destination set';
    final driver =
        _vehicle!['driver'] as String? ??
        AuthService.currentUserData?.fullName ??
        AuthService.currentUser;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTripRow(
            icon: Icons.person_rounded,
            color: AppTheme.colorFF4B7BE5,
            label: 'Driver',
            value: driver,
            isDark: isDark,
          ),
          const SizedBox(height: 14),
          _buildTripRow(
            icon: Icons.location_on_rounded,
            color: AppTheme.colorFFE74C3C,
            label: 'Destination',
            value: destination,
            isDark: isDark,
          ),
          const SizedBox(height: 14),
          _buildTripRow(
            icon: Icons.local_shipping_rounded,
            color: AppTheme.colorFF27AE60,
            label: 'Vehicle',
            value: _vehicle!['plate'],
            isDark: isDark,
          ),
          const SizedBox(height: 16),
          // Status badge
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.colorFF27AE60.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: AppTheme.colorFF27AE60.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedBuilder(
                  animation: _dotController,
                  builder: (_, __) => Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color.lerp(
                        AppTheme.colorFF27AE60,
                        AppTheme.colorFF2ECC71,
                        _dotController.value,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'GPS Tracking Active',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.colorFF27AE60,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTripRow({
    required IconData icon,
    required Color color,
    required String label,
    required String value,
    required bool isDark,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: color, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? AppTheme.gray500 : AppTheme.gray500,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  GPS CARD
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildGpsCard(bool isDark) {
    final lat = (_vehicle!['latitude'] as num).toDouble();
    final lng = (_vehicle!['longitude'] as num).toDouble();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(isDark),
      child: Column(
        children: [
          _buildGpsRow('Latitude', lat.toStringAsFixed(6), isDark),
          const SizedBox(height: 12),
          _buildGpsRow('Longitude', lng.toStringAsFixed(6), isDark),
          const SizedBox(height: 12),
          _buildGpsRow('Trail Points', '${_trail.length} recorded', isDark),
          const SizedBox(height: 12),
          _buildGpsRow(
            'Auto-Follow',
            _isFollowing ? 'On' : 'Off (tap ðŸ“ to resume)',
            isDark,
            valueColor: _isFollowing
                ? AppTheme.colorFF27AE60
                : AppTheme.colorFFF39C12,
          ),
        ],
      ),
    );
  }

  Widget _buildGpsRow(
    String label,
    String value,
    bool isDark, {
    Color? valueColor,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: isDark ? AppTheme.gray500 : AppTheme.gray600,
            fontWeight: FontWeight.w500,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color:
                valueColor ??
                (isDark ? AppTheme.white : AppTheme.colorFF2C3E50),
          ),
        ),
      ],
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  SHARED CARD DECORATION
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  BoxDecoration _cardDecoration(bool isDark) {
    return BoxDecoration(
      color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: isDark
            ? AppTheme.white.withValues(alpha: 0.06)
            : AppTheme.black.withValues(alpha: 0.06),
      ),
      boxShadow: [
        BoxShadow(
          color: AppTheme.black.withValues(alpha: isDark ? 0.3 : 0.05),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ],
    );
  }
}
