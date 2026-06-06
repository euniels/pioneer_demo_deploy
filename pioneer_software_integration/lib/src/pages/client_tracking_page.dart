import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;

import '../services/backend_api.dart';
import '../services/auth.dart';
import '../services/google_map_marker_factory.dart';
import '../services/role_service.dart';
import '../theme/app_theme.dart';
import '../utils/display_format.dart';
import '../widgets/dashboard_layout.dart';
import '../widgets/page_skeletons.dart';
import '../widgets/pioneer_google_map.dart';

class ClientTrackingPage extends StatefulWidget {
  const ClientTrackingPage({super.key});

  @override
  State<ClientTrackingPage> createState() => _ClientTrackingPageState();
}

class _ClientTrackingPageState extends State<ClientTrackingPage>
    with TickerProviderStateMixin {
  final _tripController = TextEditingController();
  Future<Map<String, dynamic>>? _future;
  Timer? _pollTimer;
  late final AnimationController _markerAnimation;
  late final Animation<double> _markerCurve;
  late final AnimationController _livePulseAnimation;
  gmaps.LatLng? _markerFrom;
  gmaps.LatLng? _markerTo;
  gmaps.BitmapDescriptor? _activeVehicleIcon;
  gmaps.BitmapDescriptor? _completedVehicleIcon;
  List<Map<String, dynamic>> _suggestedTrips = const [];
  bool _suggestionsLoading = false;

  @override
  void initState() {
    super.initState();
    _markerAnimation =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 800),
        )..addListener(() {
          if (mounted) {
            setState(() {});
          }
        });
    _markerCurve = CurvedAnimation(
      parent: _markerAnimation,
      curve: Curves.easeInOut,
    );
    _livePulseAnimation =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 1500),
        )..addListener(() {
          if (mounted && _livePulseAnimation.isAnimating) {
            setState(() {});
          }
        });
    _loadTripSuggestions();
    _loadMarkerIcons();
    _primeClientDemo();
  }

  Future<void> _loadMarkerIcons() async {
    final icons = await Future.wait<gmaps.BitmapDescriptor>([
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.moving,
        selected: true,
      ),
      PioneerGoogleMapMarkerFactory.marker(
        PioneerMapMarkerStyle.offline,
        selected: true,
      ),
    ]);
    if (!mounted) {
      return;
    }
    setState(() {
      _activeVehicleIcon = icons[0];
      _completedVehicleIcon = icons[1];
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _markerAnimation.dispose();
    _livePulseAnimation.dispose();
    _tripController.dispose();
    super.dispose();
  }

  void _load() {
    final tripId = _tripController.text.trim();
    if (tripId.isEmpty) {
      return;
    }
    setState(() {
      _future = _fetchTracking(tripId, forceRefresh: true);
    });
  }

  Map<String, dynamic>? _cachedTrackingData() {
    final tripId = _tripController.text.trim();
    if (tripId.isEmpty) {
      return null;
    }
    return BackendApiService.peekCachedDataMap(
      '/fleet/client-tracking/$tripId',
    );
  }

  Future<Map<String, dynamic>> _fetchTracking(
    String tripId, {
    bool forceRefresh = false,
  }) async {
    final data = await BackendApiService.getClientTracking(
      tripId,
      forceRefresh: forceRefresh,
    );
    _applyTrackingData(data);
    return data;
  }

  void _applyTrackingData(Map<String, dynamic> data) {
    final isLive =
        !_isCompletedTrackingStatus(data['status']) && data['isLive'] != false;
    final next = _latLngFromLocation(_mapOf(data['location']));
    if (next != null) {
      if (isLive) {
        final current = _currentAnimatedMarker() ?? _markerTo ?? next;
        if (_distanceMeters(current, next) > 500) {
          _markerAnimation.stop();
          _markerFrom = next;
          _markerTo = next;
          _markerAnimation.value = 1;
        } else {
          _markerFrom = current;
          _markerTo = next;
          _markerAnimation.forward(from: 0);
        }
      } else {
        _markerAnimation.stop();
        _markerFrom = next;
        _markerTo = next;
        _markerAnimation.value = 1;
      }
    }

    if (isLive) {
      if (!_livePulseAnimation.isAnimating) {
        _livePulseAnimation.repeat();
      }
      _pollTimer ??= Timer.periodic(const Duration(seconds: 30), (_) async {
        final tripId = _tripController.text.trim();
        if (tripId.isEmpty) {
          return;
        }
        final nextData = await _fetchTracking(tripId, forceRefresh: true);
        if (mounted) {
          setState(() => _future = Future.value(nextData));
        }
      });
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
      _livePulseAnimation.stop();
      _livePulseAnimation.value = 0;
    }
  }

  Future<void> _primeClientDemo() async {
    if (AuthService.currentRole != UserRole.client) {
      return;
    }

    try {
      final summary = await BackendApiService.getFleetSummary();
      final trips = (summary['trips'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (trip) => trip.map((key, value) => MapEntry(key.toString(), value)),
          )
          .cast<Map<String, dynamic>>()
          .toList();
      if (trips.isEmpty) {
        return;
      }

      final preferredTrip = trips.cast<Map<String, dynamic>>().firstWhere(
        (trip) => (trip['status']?.toString().trim().isNotEmpty ?? false),
        orElse: () => trips.first,
      );
      final tripId = preferredTrip['tripId']?.toString().trim() ?? '';
      if (!mounted || tripId.isEmpty) {
        return;
      }

      setState(() {
        _tripController.text = tripId;
        _future = _fetchTracking(tripId);
      });
    } catch (_) {
      // Keep the client portal usable even when the initial demo lookup fails.
    }
  }

  Future<void> _loadTripSuggestions() async {
    if (mounted) {
      setState(() => _suggestionsLoading = true);
    }

    final suggestions = <Map<String, dynamic>>[];
    final seen = <String>{};

    void addSuggestion(Map<String, dynamic> raw) {
      final tripId =
          (raw['tripId'] ??
                  raw['trip_id'] ??
                  raw['id'] ??
                  raw['assignmentId'] ??
                  raw['assignment_id'])
              ?.toString()
              .trim() ??
          '';
      if (tripId.isEmpty || !seen.add(tripId)) {
        return;
      }

      suggestions.add({
        'tripId': tripId,
        'vehicle':
            raw['vehicle'] ??
            raw['plate'] ??
            raw['vehiclePlate'] ??
            raw['vehicle_plate'] ??
            raw['truck'],
        'customer': raw['customer'] ?? raw['clientName'] ?? raw['client_name'],
        'status': raw['status'] ?? raw['assignmentStatus'],
      });
    }

    try {
      final summary = await BackendApiService.getFleetSummary();
      for (final trip in _listOfMaps(summary['trips'])) {
        addSuggestion(trip);
      }
      for (final trip in _listOfMaps(summary['recentTrips'])) {
        addSuggestion(trip);
      }
    } catch (_) {
      // Suggestions are helpful, not required for manual trip lookup.
    }

    try {
      final assignments = await BackendApiService.getClientAssignments();
      for (final assignment in assignments) {
        addSuggestion(assignment);
      }
    } catch (_) {
      // Keep the page usable for roles without assignment access.
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _suggestedTrips = suggestions.take(6).toList(growable: false);
      _suggestionsLoading = false;
    });
  }

  gmaps.LatLng? _currentAnimatedMarker() {
    final from = _markerFrom;
    final to = _markerTo;
    if (from == null || to == null) {
      return to;
    }

    final t = _markerCurve.value;
    return gmaps.LatLng(
      from.latitude + ((to.latitude - from.latitude) * t),
      from.longitude + ((to.longitude - from.longitude) * t),
    );
  }

  gmaps.LatLng? _latLngFromLocation(Map<String, dynamic> location) {
    final latitude = _toDouble(location['latitude']);
    final longitude = _toDouble(location['longitude']);
    if (latitude == 0 && longitude == 0) {
      return null;
    }

    return gmaps.LatLng(latitude, longitude);
  }

  Widget _buildTrackingMap(
    BuildContext context,
    Map<String, dynamic> data,
    List<Map<String, dynamic>> route,
    Map<String, dynamic> location, {
    double height = 360,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final routePoints = route
        .map(_latLngFromLocation)
        .whereType<gmaps.LatLng>()
        .toList();
    final plannedPoints = _listOfMaps(
      data['plannedPath'],
    ).map(_latLngFromLocation).whereType<gmaps.LatLng>().toList();
    final current = _currentAnimatedMarker() ?? _latLngFromLocation(location);
    final center =
        current ??
        (routePoints.isNotEmpty
            ? routePoints.last
            : const gmaps.LatLng(14.5995, 120.9842));
    final isLive = data['isLive'] == true;
    final pulseValue = _livePulseAnimation.value;
    final routeMessage =
        data['routeMessage']?.toString().trim().isNotEmpty == true
        ? data['routeMessage'].toString()
        : 'No route points recorded yet';
    final markers = <gmaps.Marker>{
      if (routePoints.isNotEmpty)
        gmaps.Marker(
          markerId: const gmaps.MarkerId('route-start'),
          position: routePoints.first,
          icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
            gmaps.BitmapDescriptor.hueGreen,
          ),
          infoWindow: const gmaps.InfoWindow(title: 'Trip start'),
        ),
      if (routePoints.length > 1)
        gmaps.Marker(
          markerId: const gmaps.MarkerId('route-end'),
          position: routePoints.last,
          icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
            gmaps.BitmapDescriptor.hueRed,
          ),
          infoWindow: const gmaps.InfoWindow(title: 'Trip end'),
        ),
      if (current != null)
        gmaps.Marker(
          markerId: const gmaps.MarkerId('vehicle-current'),
          position: current,
          flat: true,
          rotation: _toDouble(location['bearing']),
          anchor: const Offset(0.5, 0.5),
          icon:
              (isLive ? _activeVehicleIcon : _completedVehicleIcon) ??
              gmaps.BitmapDescriptor.defaultMarkerWithHue(
                isLive
                    ? gmaps.BitmapDescriptor.hueAzure
                    : gmaps.BitmapDescriptor.hueViolet,
              ),
          infoWindow: gmaps.InfoWindow(
            title: formatValue(data['vehicle']),
            snippet: formatValue(data['status']),
          ),
        ),
    };
    final polylines = <gmaps.Polyline>{
      if (plannedPoints.length > 1)
        gmaps.Polyline(
          polylineId: const gmaps.PolylineId('client-planned-route'),
          points: plannedPoints,
          color: AppTheme.accentCyan.withValues(alpha: 0.75),
          width: 3,
        ),
      if (routePoints.length > 1)
        gmaps.Polyline(
          polylineId: const gmaps.PolylineId('client-route'),
          points: routePoints,
          color: AppTheme.primaryBlue,
          width: 4,
        ),
    };
    final circles = <gmaps.Circle>{
      if (isLive && current != null)
        gmaps.Circle(
          circleId: const gmaps.CircleId('client-live-pulse'),
          center: current,
          radius: 20 + (pulseValue * 40),
          fillColor: AppTheme.successGreen.withValues(
            alpha: (0.12 * (1 - pulseValue)).clamp(0.0, 0.12),
          ),
          strokeColor: AppTheme.successGreen.withValues(
            alpha: (0.6 * (1 - pulseValue)).clamp(0.0, 0.6),
          ),
          strokeWidth: 2,
        ),
    };

    return SizedBox(
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          children: [
            PioneerGoogleMap(
              initialCenter: center,
              initialZoom: 13,
              markers: markers,
              polylines: polylines,
              circles: circles,
              zoomControlsEnabled: false,
            ),
            if (routePoints.length < 2)
              Positioned(
                left: 12,
                right: 12,
                bottom: 56,
                child: _mapRouteStateBanner(context, routeMessage),
              ),
            Positioned(left: 12, bottom: 12, child: _mapLegend(isDark)),
            Positioned(right: 12, top: 12, child: _mapInfoCard(context, data)),
          ],
        ),
      ),
    );
  }

  Widget _mapRouteStateBanner(BuildContext context, String message) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 360),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isDark
              ? AppTheme.colorFF111827.withValues(alpha: 0.92)
              : AppTheme.white.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.getBorderColor(context)),
          boxShadow: [
            BoxShadow(
              color: AppTheme.black.withValues(alpha: 0.12),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.route_outlined,
              color: AppTheme.primaryBlue,
              size: 16,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isDark ? AppTheme.white : AppTheme.colorFF111827,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mapLegend(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF141924 : AppTheme.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.black.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _legendRow(AppTheme.primaryBlue, 'Blue arrow = vehicle moving'),
          _legendRow(AppTheme.colorFF9E9E9E, 'Gray dot = vehicle idle'),
          _legendRow(AppTheme.colorFF27AE60, 'Trip start'),
          _legendRow(AppTheme.errorRed, 'Trip end'),
        ],
      ),
    );
  }

  Widget _legendRow(Color color, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Widget _mapInfoCard(BuildContext context, Map<String, dynamic> data) {
    final status = clientTrackingHeadlineStatus(data);

    return Container(
      constraints: const BoxConstraints(maxWidth: 238),
      decoration: BoxDecoration(
        color: AppTheme.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.black.withValues(alpha: 0.08)),
        boxShadow: [
          BoxShadow(
            color: AppTheme.black.withValues(alpha: 0.12),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 6,
            decoration: const BoxDecoration(
              color: AppTheme.primaryBlue,
              borderRadius: BorderRadius.horizontal(left: Radius.circular(8)),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _statusBadge(status),
                  const SizedBox(height: AppTheme.space10),
                  _mapInfoValue('ETA', clientTrackingArrivalLabel(data)),
                  const SizedBox(height: AppTheme.space8),
                  _mapInfoValue('Driver', formatValue(data['driver'])),
                  const SizedBox(height: AppTheme.space8),
                  _mapInfoValue('Vehicle', formatValue(data['vehicle'])),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mapInfoValue(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: AppTheme.gray600,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 12,
            color: AppTheme.colorFF111827,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  Widget _statusBadge(String status) {
    final color = clientTrackingStatusColor(status);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        status,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildTripSuggestions() {
    if (_suggestionsLoading && _suggestedTrips.isEmpty) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            'Loading recent orders',
            style: AppTheme.getCaptionStyle(context),
          ),
        ],
      );
    }

    if (_suggestedTrips.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Recent orders', style: AppTheme.getCaptionStyle(context)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _suggestedTrips.map((trip) {
            final tripId = formatValue(trip['tripId']);
            final subtitle = [
              formatValue(trip['vehicle']),
              formatValue(trip['customer']),
              formatValue(trip['status']),
            ].where((value) => value != 'N/A').join(' / ');

            return ActionChip(
              label: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tripId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                  ],
                ),
              ),
              avatar: const Icon(Icons.local_shipping_outlined, size: 16),
              onPressed: () {
                _tripController.text = tripId;
                _load();
              },
            );
          }).toList(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      currentRoute: '/client-tracking',
      title: 'Client Tracking',
      subtitle: 'Share-safe delivery visibility and proof-of-delivery state',
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: Theme.of(context).brightness == Brightness.dark
                ? const [
                    AppTheme.colorFF08101D,
                    AppTheme.colorFF0A1220,
                    AppTheme.colorFF0A0E1A,
                  ]
                : const [
                    AppTheme.colorFFF7FAFF,
                    AppTheme.colorFFF4F7FB,
                    AppTheme.colorFFEFF5FC,
                  ],
          ),
        ),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppTheme.getCardBg(context),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: AppTheme.getBorderColor(context)),
                boxShadow: AppTheme.getCardShadow(context),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Lookup delivery status',
                    style: AppTheme.getHeadingStyle(context, fontSize: 24),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Enter a trip ID to see the client-safe live status, location, progress, and proof-of-delivery state.',
                    style: AppTheme.getSubtitleStyle(context),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _tripController,
                          decoration: const InputDecoration(
                            labelText: 'Trip ID',
                            hintText: 'Example: TRP-ABC123',
                          ),
                          onSubmitted: (_) => _load(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(onPressed: _load, child: const Text('Load')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildTripSuggestions(),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (_future == null)
              const _ClientTrackingEmpty(
                title: 'Ready for live client tracking',
                message:
                    'This screen is now connected to the backend client-tracking endpoint. Load a trip to preview what a client-facing tracking portal can show.',
              )
            else
              FutureBuilder<Map<String, dynamic>>(
                future: _future,
                initialData: _cachedTrackingData(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting &&
                      !snapshot.hasData) {
                    return const PioneerRouteSkeletonBody(
                      routeName: '/client-tracking',
                    );
                  }

                  if (snapshot.hasError || !snapshot.hasData) {
                    return const _ClientTrackingEmpty(
                      title: 'Tracking lookup failed',
                      message:
                          'The trip was not found or the backend response was unavailable.',
                    );
                  }

                  final data = snapshot.data!;
                  final location = _mapOf(data['location']);
                  final pod = _mapOf(data['proofOfDelivery']);
                  final route = _listOfMaps(data['route']);

                  return _buildClientDeliveryView(
                    context,
                    data: data,
                    location: location,
                    pod: pod,
                    route: route,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildClientDeliveryView(
    BuildContext context, {
    required Map<String, dynamic> data,
    required Map<String, dynamic> location,
    required Map<String, dynamic> pod,
    required List<Map<String, dynamic>> route,
  }) {
    final isMobile = MediaQuery.sizeOf(context).width < 1020;
    final mapHeight = isMobile
        ? (MediaQuery.sizeOf(context).height * 0.55).clamp(340.0, 520.0)
        : 540.0;
    final mapColumn = Column(
      children: [
        _buildTrackingMap(context, data, route, location, height: mapHeight),
        const SizedBox(height: AppTheme.space16),
        _buildCustomerStatusTimeline(context, data, pod),
      ],
    );
    final details = _buildClientDetailPanel(context, data, pod);

    return Container(
      padding: const EdgeInsets.all(AppTheme.space20),
      decoration: BoxDecoration(
        color: AppTheme.getCardBg(context),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppTheme.getBorderColor(context)),
        boxShadow: AppTheme.getCardShadow(context),
      ),
      child: isMobile
          ? Column(
              children: [
                mapColumn,
                const SizedBox(height: AppTheme.space16),
                details,
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: mapColumn),
                const SizedBox(width: AppTheme.space20),
                Expanded(flex: 2, child: details),
              ],
            ),
    );
  }

  Widget _buildClientDetailPanel(
    BuildContext context,
    Map<String, dynamic> data,
    Map<String, dynamic> pod,
  ) {
    final progress = (_toDouble(data['progressPercent']) / 100).clamp(0.0, 1.0);
    final cargoType = data['cargoType']?.toString().trim() ?? '';
    final weight = _toDouble(data['totalWeightKg']);
    final contact = formatValue(data['driverContactMasked']) == 'N/A'
        ? 'Contact through Pioneer dispatch'
        : formatValue(data['driverContactMasked']);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppTheme.space20),
      decoration: BoxDecoration(
        color: AppTheme.getSecondaryBg(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.getBorderColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            clientTrackingHeadlineStatus(data),
            style: AppTheme.getHeadingStyle(
              context,
              fontSize: 28,
            ).copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: AppTheme.space8),
          Text(
            clientTrackingArrivalLabel(data),
            style: AppTheme.getHeadingStyle(
              context,
              fontSize: 20,
            ).copyWith(color: AppTheme.primaryBlue),
          ),
          if (formatValue(data['etaDistance']) != 'N/A') ...[
            const SizedBox(height: AppTheme.space4),
            Text(
              '${formatValue(data['etaDistance'])} remaining by road',
              style: AppTheme.getDashboardSecondaryStyle(context),
            ),
          ],
          const SizedBox(height: AppTheme.space20),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 10,
              value: progress,
              backgroundColor: AppTheme.getBorderColor(context),
              valueColor: const AlwaysStoppedAnimation<Color>(
                AppTheme.primaryBlue,
              ),
            ),
          ),
          const SizedBox(height: AppTheme.space8),
          Text(
            '${(progress * 100).toStringAsFixed(0)}% delivery progress',
            style: AppTheme.getDashboardSecondaryStyle(context),
          ),
          const SizedBox(height: AppTheme.space20),
          _ClientDetailRow(
            icon: Icons.person_outline_rounded,
            label: 'Driver',
            value: formatValue(data['driver']),
          ),
          _ClientDetailRow(
            icon: Icons.phone_outlined,
            label: 'Contact',
            value: contact,
          ),
          _ClientDetailRow(
            icon: Icons.local_shipping_outlined,
            label: 'Vehicle plate',
            value: formatValue(data['vehicle']),
          ),
          const SizedBox(height: AppTheme.space12),
          _buildRouteDetail(context, data),
          if (cargoType.isNotEmpty || weight > 0) ...[
            const SizedBox(height: AppTheme.space16),
            _ClientDetailRow(
              icon: Icons.inventory_2_outlined,
              label: 'Cargo',
              value: [
                if (cargoType.isNotEmpty) cargoType,
                if (weight > 0) '${weight.toStringAsFixed(1)} kg',
              ].join(' - '),
            ),
          ],
          const SizedBox(height: AppTheme.space16),
          _buildProofOfDelivery(context, data, pod),
        ],
      ),
    );
  }

  Widget _buildRouteDetail(BuildContext context, Map<String, dynamic> data) {
    return Container(
      padding: const EdgeInsets.all(AppTheme.space16),
      decoration: BoxDecoration(
        color: AppTheme.getCardBg(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.getBorderColor(context)),
      ),
      child: Column(
        children: [
          _ClientDetailRow(
            icon: Icons.trip_origin_rounded,
            label: 'Origin',
            value: formatValue(data['origin']),
            color: AppTheme.successGreen,
          ),
          Padding(
            padding: const EdgeInsets.only(
              left: AppTheme.space10,
              bottom: AppTheme.space8,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 2,
                height: 16,
                color: AppTheme.primaryBlue.withValues(alpha: 0.42),
              ),
            ),
          ),
          _ClientDetailRow(
            icon: Icons.location_on_rounded,
            label: 'Destination',
            value: formatValue(data['destination']),
            color: AppTheme.errorRed,
          ),
        ],
      ),
    );
  }

  Widget _buildProofOfDelivery(
    BuildContext context,
    Map<String, dynamic> data,
    Map<String, dynamic> pod,
  ) {
    final completed =
        _isCompletedTrackingStatus(data['status']) ||
        _workflowPhaseNumber(data) >= 12;
    final attachments = _listOfMaps(pod['attachments']);
    final deliveredAt = clientTrackingTimestamp(pod['deliveredAt']);
    final attachmentUrl = attachments.isEmpty
        ? ''
        : attachments.first['url']?.toString().trim() ?? '';
    final token = BackendApiService.accessTokenForRealtime;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppTheme.space16),
      decoration: BoxDecoration(
        color: AppTheme.getCardBg(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.getBorderColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Proof of delivery',
            style: AppTheme.getHeadingStyle(context, fontSize: 18),
          ),
          const SizedBox(height: AppTheme.space8),
          if (!completed || pod.isEmpty)
            Text(
              'Awaiting delivery',
              style: AppTheme.getDashboardBodyStyle(context),
            )
          else ...[
            Row(
              children: [
                const Icon(
                  Icons.verified_rounded,
                  size: 20,
                  color: AppTheme.successGreen,
                ),
                const SizedBox(width: AppTheme.space8),
                Expanded(
                  child: Text(
                    deliveredAt == 'N/A'
                        ? 'Delivery confirmed'
                        : 'Delivered $deliveredAt',
                    style: AppTheme.getDashboardBodyStyle(context),
                  ),
                ),
              ],
            ),
            if (attachmentUrl.isNotEmpty) ...[
              const SizedBox(height: AppTheme.space12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  attachmentUrl,
                  headers: token == null || token.trim().isEmpty
                      ? null
                      : {'Authorization': 'Bearer ${token.trim()}'},
                  width: double.infinity,
                  height: 132,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => Container(
                    height: 84,
                    alignment: Alignment.center,
                    color: AppTheme.getSecondaryBg(context),
                    child: Text(
                      'POD photo is securely stored.',
                      style: AppTheme.getSubtitleStyle(context),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildCustomerStatusTimeline(
    BuildContext context,
    Map<String, dynamic> data,
    Map<String, dynamic> pod,
  ) {
    final activeIndex = clientTrackingPublicTimelineIndex(data);
    final completed = activeIndex == 4;
    final milestones = <_ClientMilestone>[
      _ClientMilestone('Order Received', clientTrackingTimestamp(data['date'])),
      _ClientMilestone(
        'Dispatched',
        clientTrackingTimestamp(
          data['startedAt'] ?? data['scheduledDepartureAt'],
        ),
      ),
      _ClientMilestone(
        'In Transit',
        clientTrackingTimestamp(data['startedAt'] ?? data['lastUpdated']),
      ),
      _ClientMilestone('Arrived', clientTrackingTimestamp(data['endedAt'])),
      _ClientMilestone(
        'Delivered',
        clientTrackingTimestamp(pod['deliveredAt'] ?? data['endedAt']),
      ),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppTheme.space16),
      decoration: BoxDecoration(
        color: AppTheme.getSecondaryBg(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.getBorderColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Delivery journey',
            style: AppTheme.getHeadingStyle(context, fontSize: 20),
          ),
          const SizedBox(height: AppTheme.space4),
          Text(
            clientTrackingWorkflowMilestone(data),
            style: AppTheme.getDashboardSecondaryStyle(context),
          ),
          const SizedBox(height: AppTheme.space16),
          LayoutBuilder(
            builder: (context, constraints) {
              final vertical = constraints.maxWidth < 560;
              if (vertical) {
                return Column(
                  children: List.generate(
                    milestones.length,
                    (index) => _ClientMilestoneRow(
                      milestone: milestones[index],
                      completed: completed || index < activeIndex,
                      current: !completed && index == activeIndex,
                      pulse: _livePulseAnimation,
                      isLast: index == milestones.length - 1,
                    ),
                  ),
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: List.generate(
                  milestones.length,
                  (index) => Expanded(
                    child: _ClientMilestoneColumn(
                      milestone: milestones[index],
                      completed: completed || index < activeIndex,
                      current: !completed && index == activeIndex,
                      pulse: _livePulseAnimation,
                      isLast: index == milestones.length - 1,
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ClientTrackingEmpty extends StatelessWidget {
  final String title;
  final String message;

  const _ClientTrackingEmpty({required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: AppTheme.getCardBg(context),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppTheme.getBorderColor(context)),
      ),
      child: Column(
        children: [
          const Icon(Icons.public_rounded, size: 40),
          const SizedBox(height: 12),
          Text(
            title,
            style: AppTheme.getHeadingStyle(context, fontSize: 20),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: AppTheme.getSubtitleStyle(context),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _ClientDetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _ClientDetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.color = AppTheme.primaryBlue,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.space8),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: AppTheme.space10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: AppTheme.getDashboardSecondaryStyle(context),
                    ),
                    const SizedBox(height: AppTheme.space2),
                    Text(
                      value,
                      style: AppTheme.getDashboardBodyStyle(
                        context,
                      ).copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ClientMilestone {
  const _ClientMilestone(this.label, this.timestamp);

  final String label;
  final String timestamp;
}

class _ClientMilestoneColumn extends StatelessWidget {
  const _ClientMilestoneColumn({
    required this.milestone,
    required this.completed,
    required this.current,
    required this.pulse,
    required this.isLast,
  });

  final _ClientMilestone milestone;
  final bool completed;
  final bool current;
  final Animation<double> pulse;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _ClientMilestoneCircle(
              completed: completed,
              current: current,
              pulse: pulse,
            ),
            if (!isLast)
              Expanded(
                child: Container(
                  height: 2,
                  color: completed
                      ? AppTheme.primaryBlue
                      : AppTheme.getBorderColor(context),
                ),
              ),
          ],
        ),
        const SizedBox(height: AppTheme.space8),
        Text(
          milestone.label,
          style: AppTheme.getDashboardBodyStyle(
            context,
          ).copyWith(fontWeight: current ? FontWeight.w700 : FontWeight.w500),
        ),
        const SizedBox(height: AppTheme.space4),
        Text(
          completed || current ? milestone.timestamp : 'Pending',
          style: AppTheme.getDashboardSecondaryStyle(context),
        ),
      ],
    );
  }
}

class _ClientMilestoneRow extends StatelessWidget {
  const _ClientMilestoneRow({
    required this.milestone,
    required this.completed,
    required this.current,
    required this.pulse,
    required this.isLast,
  });

  final _ClientMilestone milestone;
  final bool completed;
  final bool current;
  final Animation<double> pulse;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              _ClientMilestoneCircle(
                completed: completed,
                current: current,
                pulse: pulse,
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    color: completed
                        ? AppTheme.primaryBlue
                        : AppTheme.getBorderColor(context),
                  ),
                ),
            ],
          ),
          const SizedBox(width: AppTheme.space12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppTheme.space16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    milestone.label,
                    style: AppTheme.getDashboardBodyStyle(context).copyWith(
                      fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  Text(
                    completed || current ? milestone.timestamp : 'Pending',
                    style: AppTheme.getDashboardSecondaryStyle(context),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClientMilestoneCircle extends StatelessWidget {
  const _ClientMilestoneCircle({
    required this.completed,
    required this.current,
    required this.pulse,
  });

  final bool completed;
  final bool current;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    Widget circle = Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: completed || current
            ? AppTheme.primaryBlue
            : AppTheme.transparent,
        border: Border.all(
          color: completed || current
              ? AppTheme.primaryBlue
              : AppTheme.materialGrey,
          width: 2,
        ),
      ),
      child: completed
          ? const Icon(Icons.check_rounded, size: 16, color: AppTheme.white)
          : null,
    );

    if (!current) return circle;
    return AnimatedBuilder(
      animation: pulse,
      child: circle,
      builder: (context, child) => Container(
        padding: EdgeInsets.all(2 + (pulse.value * 4)),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppTheme.primaryBlue.withValues(
            alpha: 0.12 * (1 - pulse.value),
          ),
        ),
        child: child,
      ),
    );
  }
}

Map<String, dynamic> _mapOf(dynamic raw) {
  if (raw is Map) {
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }
  return {};
}

List<Map<String, dynamic>> _listOfMaps(dynamic raw) {
  if (raw is! List) {
    return const [];
  }

  return raw
      .whereType<Map>()
      .map((item) => item.map((key, value) => MapEntry(key.toString(), value)))
      .cast<Map<String, dynamic>>()
      .toList();
}

double _toDouble(dynamic value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0.0;
}

double _distanceMeters(gmaps.LatLng from, gmaps.LatLng to) {
  final dLat = _degreesToRadians(to.latitude - from.latitude);
  final dLng = _degreesToRadians(to.longitude - from.longitude);
  final lat1 = _degreesToRadians(from.latitude);
  final lat2 = _degreesToRadians(to.latitude);
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLng / 2) * math.sin(dLng / 2);
  return 6371000.0 * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

double _degreesToRadians(double degrees) => degrees * math.pi / 180.0;

bool _isCompletedTrackingStatus(dynamic status) {
  final normalized = status?.toString().trim().toLowerCase() ?? '';
  return const {'completed', 'delivered', 'arrived'}.contains(normalized);
}

int _workflowPhaseNumber(Map<String, dynamic> data) {
  final raw = data['workflowPhaseNumber'];
  if (raw is num) return raw.toInt().clamp(1, 12);
  return (int.tryParse(raw?.toString() ?? '') ?? 7).clamp(1, 12);
}

String clientTrackingEtaLabel(Map<String, dynamic> data) {
  if (_isCompletedTrackingStatus(data['status'])) {
    return 'Arrived';
  }

  return formatValue(data['eta'] ?? data['estimatedArrival']);
}

String clientTrackingArrivalLabel(Map<String, dynamic> data) {
  if (_isCompletedTrackingStatus(data['status']) ||
      _workflowPhaseNumber(data) >= 12) {
    return 'Delivery completed';
  }

  final eta = clientTrackingEtaLabel(data);
  if (eta == 'N/A') {
    return 'Estimated arrival updating';
  }
  if (data['etaSource']?.toString() == 'google_distance_matrix' ||
      data['etaDurationSeconds'] != null) {
    return 'Arriving in $eta';
  }
  return 'Estimated arrival: $eta';
}

String clientTrackingHeadlineStatus(Map<String, dynamic> data) {
  final phase = _workflowPhaseNumber(data);
  final normalized = data['status']?.toString().trim().toLowerCase() ?? '';
  if (_isCompletedTrackingStatus(data['status']) || phase >= 12) {
    return 'DELIVERED';
  }
  if (phase >= 11 || normalized.contains('arriv')) {
    return 'ARRIVED AT DESTINATION';
  }
  if (phase >= 10 ||
      (!data.containsKey('workflowPhaseNumber') &&
          (normalized.contains('transit') ||
              normalized.contains('active') ||
              normalized.contains('dispatch')))) {
    return 'IN TRANSIT';
  }
  return 'ORDER DISPATCHED';
}

int clientTrackingPublicTimelineIndex(Map<String, dynamic> data) {
  final phase = _workflowPhaseNumber(data);
  final normalized = data['status']?.toString().trim().toLowerCase() ?? '';
  if (_isCompletedTrackingStatus(data['status']) || phase >= 12) return 4;
  if (phase >= 11 || normalized.contains('arriv')) return 3;
  if (phase >= 10 ||
      (!data.containsKey('workflowPhaseNumber') &&
          (normalized.contains('transit') ||
              normalized.contains('active') ||
              normalized.contains('dispatch')))) {
    return 2;
  }
  if (phase >= 7) return 1;
  return 0;
}

String clientTrackingTimestamp(dynamic raw) {
  final value = raw?.toString().trim() ?? '';
  if (value.isEmpty) return 'Time pending';
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  final local = parsed.toLocal();
  const months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final hour = local.hour == 0
      ? 12
      : (local.hour > 12 ? local.hour - 12 : local.hour);
  final minute = local.minute.toString().padLeft(2, '0');
  final meridiem = local.hour >= 12 ? 'PM' : 'AM';
  return '${months[local.month - 1]} ${local.day}, $hour:$minute $meridiem';
}

String clientTrackingWorkflowStatus(Map<String, dynamic> data) {
  final provided = data['clientWorkflowStatus']?.toString().trim();
  if (provided != null && provided.isNotEmpty) return provided;

  final phase = _workflowPhaseNumber(data);
  if (phase <= 6) return 'Your order is being prepared';
  if (phase <= 9) return 'Your delivery is being arranged';
  if (phase == 10) return 'Your delivery is on its way';
  if (phase == 11) return 'Your delivery has arrived';
  return 'Delivery complete';
}

String clientTrackingWorkflowMilestone(Map<String, dynamic> data) {
  final provided = data['clientWorkflowMilestone']?.toString().trim();
  if (provided != null && provided.isNotEmpty) return provided;

  final phase = _workflowPhaseNumber(data);
  if (phase <= 6) {
    return 'Next: Pioneer confirms your order details.';
  }
  if (phase <= 9) {
    return 'Next: We assign your delivery truck and schedule.';
  }
  if (phase == 10) return 'Next: Your truck travels to your location.';
  if (phase == 11) return 'Next: Receive and sign delivery documents.';
  return 'Proof of delivery has been recorded.';
}

Color clientTrackingStatusColor(String status) {
  final normalized = status.trim().toLowerCase();
  if (_isCompletedTrackingStatus(normalized) ||
      normalized.contains('arrived') ||
      normalized.contains('deliver')) {
    return AppTheme.successGreen;
  }
  if (normalized.contains('cancel') || normalized.contains('failed')) {
    return AppTheme.errorRed;
  }
  if (normalized.contains('transit') ||
      normalized.contains('active') ||
      normalized.contains('live') ||
      normalized.contains('moving')) {
    return AppTheme.primaryBlue;
  }

  return AppTheme.warningOrange;
}
