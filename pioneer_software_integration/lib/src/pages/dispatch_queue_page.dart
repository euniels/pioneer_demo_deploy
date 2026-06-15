import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import '../widgets/dashboard_layout.dart';
import '../services/backend_api.dart';
import '../services/fleet_sync_service.dart';
import '../services/optimistic_mutation_service.dart';
import '../services/page_cache_service.dart';
import '../services/realtime_stream_service.dart';
import '../services/drivers_store.dart';
import '../services/trips_store.dart' show tripsNotifier;
import '../services/vehicles_store.dart';
import '../utils/workflow_status_helper.dart';
import '../widgets/workflow_timeline.dart';
import '../theme/app_theme.dart';

class DispatchQueuePage extends StatefulWidget {
  const DispatchQueuePage({super.key});

  @override
  State<DispatchQueuePage> createState() => _DispatchQueuePageState();
}

class _DispatchQueuePageState extends State<DispatchQueuePage>
    with SingleTickerProviderStateMixin {
  static const String _cacheKey = 'dispatch_queue_page';

  late TabController _tabController;
  Timer? _dispatchLiveTimer;
  Timer? _dataRebuildDebounce;
  List<Map<String, dynamic>> _geotabRoutes = const [];
  bool _routesLoading = false;
  String? _routesError;
  DateTime? _routesLoadedAt;
  bool _routePlansExpanded = false;
  bool _optimizingOrder = false;
  bool _topSectionCollapsed = false;
  int _availableVehiclesVisibleLimit = 24;
  int _activeDispatchVisibleLimit = 40;
  String? _optimizeOrderMessage;
  List<Map<String, dynamic>> _optimizedStops = const [];
  final Set<String> _collapsedWorkflowGroups = {};
  final Map<String, int> _workflowVisibleLimits = {};
  static const int _initialWorkflowVisibleLimit = 8;
  static const int _workflowPageSize = 8;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    tripsNotifier.addListener(_onDataChanged);
    driversNotifier.addListener(_onDataChanged);
    vehiclesNotifier.addListener(_onDataChanged);
    _primeDispatch();
    _loadGeotabRoutes();
    _ensureDispatchLiveTimer();
  }

  void _onDataChanged() {
    _dataRebuildDebounce?.cancel();
    _dataRebuildDebounce = Timer(const Duration(milliseconds: 120), () {
      if (mounted) {
        setState(() {});
      }
    });
    _ensureDispatchLiveTimer();
  }

  @override
  void dispose() {
    tripsNotifier.removeListener(_onDataChanged);
    driversNotifier.removeListener(_onDataChanged);
    vehiclesNotifier.removeListener(_onDataChanged);
    _dataRebuildDebounce?.cancel();
    _dispatchLiveTimer?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _primeDispatch({bool forceRefresh = false}) async {
    await PageCacheService.getOrLoad<int>(
      key: _cacheKey,
      ttl: PageCacheService.dispatchTtl,
      forceRefresh: forceRefresh,
      loader: () async {
        await refreshFleetBootstrap(forceRefresh: forceRefresh);
        await refreshFleetSnapshot(forceRefresh: forceRefresh);
        return tripsNotifier.value.length + vehiclesNotifier.value.length;
      },
    ).catchError((_) {
      refreshFleetBootstrapSilently(forceRefresh: forceRefresh);
      return tripsNotifier.value.length + vehiclesNotifier.value.length;
    });
  }

  Future<void> _loadGeotabRoutes({bool forceRefresh = false}) async {
    if (mounted) {
      setState(() {
        _routesLoading = true;
        _routesError = null;
      });
    }

    try {
      final routes = await BackendApiService.getFleetRoutes(
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      setState(() {
        _geotabRoutes = routes;
        _routesLoading = false;
        _routesError = null;
        _routesLoadedAt = DateTime.now();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _routesLoading = false;
        _routesError =
            'Could not load GeoTab routes. Pull to refresh or retry.';
      });
    }
  }

  Future<void> _refreshDispatch() async {
    await Future.wait([
      _primeDispatch(forceRefresh: true),
      _loadGeotabRoutes(forceRefresh: true),
    ]);
    await _refreshActiveDispatchLocations();
  }

  List<Map<String, dynamic>> get _pendingTrips {
    return tripsNotifier.value.where((t) => t['status'] == 'pending').toList();
  }

  List<Map<String, dynamic>> get _activeDispatches {
    return tripsNotifier.value.where((t) {
      final status = t['status']?.toString().trim().toLowerCase() ?? '';
      return status == 'dispatched' ||
          status == 'active' ||
          status == 'in transit' ||
          status == 'on trip';
    }).toList();
  }

  List<Map<String, dynamic>> get _workflowTrips {
    return tripsNotifier.value.where((trip) {
      final status = trip['status']?.toString().trim().toLowerCase() ?? '';
      return status != 'cancelled' && status != 'canceled';
    }).toList();
  }

  Map<String, List<Map<String, dynamic>>> get _workflowGroupedTrips {
    final groups = <String, List<Map<String, dynamic>>>{
      'Pending Details': [],
      'Pending Assignment': [],
      'In Transit': [],
      'Arrived': [],
      'Pending POD': [],
      'Billing Review': [],
    };

    for (final trip in _workflowTrips) {
      groups[_workflowGroupForTrip(trip)]!.add(trip);
    }

    return groups;
  }

  int get _availableVehiclesCount {
    return vehiclesNotifier.value
        .where((v) => v['status'] == 'available')
        .length;
  }

  List<Map<String, dynamic>> get _availableVehicles {
    return vehiclesNotifier.value
        .where((vehicle) => vehicle['status'] == 'available')
        .toList();
  }

  Map<String, dynamic>? _vehicleForTrip(Map<String, dynamic> trip) {
    final plate = trip['vehicle']?.toString().trim() ?? '';
    if (plate.isEmpty) {
      return null;
    }

    for (final vehicle in vehiclesNotifier.value) {
      if (vehicle['plate']?.toString().trim() == plate) {
        return vehicle;
      }
    }

    return null;
  }

  void _showDispatchModal(Map<String, dynamic> trip) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _DispatchModal(
        trip: trip,
        onDispatch: (driver, vehicle) {
          unawaited(_dispatchTripOptimistically(trip, driver, vehicle));
        },
      ),
    );
  }

  Future<void> _dispatchTripOptimistically(
    Map<String, dynamic> trip,
    String driver,
    String vehicle,
  ) async {
    final tripId = trip['tripId']?.toString() ?? '';
    if (tripId.isEmpty) {
      return;
    }

    final startedAt = DateTime.now().toIso8601String();
    await OptimisticMutationService.run<void>(
      context: context,
      snapshots: [
        OptimisticSnapshot.mapList(tripsNotifier),
        OptimisticSnapshot.mapList(driversNotifier),
        OptimisticSnapshot.mapList(vehiclesNotifier),
      ],
      apply: () {
        tripsNotifier.value = tripsNotifier.value.map((item) {
          if (item['tripId'] == tripId) {
            return {
              ...item,
              'status': 'dispatched',
              'statusColor': AppTheme.colorFF4B7BE5,
              'driver': driver,
              'vehicle': vehicle,
              'startedAt': startedAt,
              'workflowPhaseNumber': 10,
              'workflowGroup': _workflowGroupForPhase(10),
              'workflowPhaseLabel': _workflowPhaseLabel(10),
              'workflowNextAction': _workflowNextAction(10),
            };
          }
          return item;
        }).toList();
        updateDriverStatus(driver, 'on trip');
        updateVehicle(vehicle, {
          'status': 'on trip',
          'statusColor': AppTheme.colorFF4B7BE5,
          'driver': driver,
        });
        _ensureDispatchLiveTimer();
      },
      commit: () async {
        await _refreshActiveDispatchLocations();
        await BackendApiService.updateTrip(tripId, {
          'status': 'dispatched',
          'driver': driver,
          'vehicle': vehicle,
          'startedAt': startedAt,
          'workflowPhaseNumber': 10,
        });
      },
      errorMessage:
          'Dispatch could not be saved. The trip was restored to pending.',
    );
  }

  void _ensureDispatchLiveTimer() {
    if (_activeDispatches.isEmpty) {
      _dispatchLiveTimer?.cancel();
      _dispatchLiveTimer = null;
      return;
    }

    _dispatchLiveTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      if (!RealtimeStreamService.isConnected) {
        _refreshActiveDispatchLocations();
      }
    });
  }

  Future<void> _refreshActiveDispatchLocations() async {
    if (_activeDispatches.isEmpty) {
      return;
    }

    try {
      final live = await BackendApiService.getFleetLive(forceRefresh: true);
      applyFleetLivePayload(live);
    } catch (_) {
      try {
        await refreshVehicleLocationsFromBackend();
      } catch (_) {}
    }
  }

  Future<void> _suggestOptimalOrder() async {
    if (_pendingTrips.length < 2 || _optimizingOrder) {
      return;
    }

    setState(() {
      _optimizingOrder = true;
      _optimizeOrderMessage = null;
    });

    try {
      final result = await BackendApiService.suggestDispatchOrder(
        _pendingTrips,
      );
      final stops = ((result['stops'] as List?) ?? const [])
          .whereType<Map>()
          .map((stop) => Map<String, dynamic>.from(stop))
          .toList();
      if (!mounted) return;
      setState(() {
        _optimizedStops = stops;
        _optimizeOrderMessage =
            result['message']?.toString().trim().isNotEmpty == true
            ? result['message'].toString()
            : 'Suggested order is ready for dispatcher review.';
        _optimizingOrder = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _optimizeOrderMessage =
            'Could not request Google route optimization right now.';
        _optimizingOrder = false;
      });
    }
  }

  Future<void> _advanceWorkflowPhase(Map<String, dynamic> trip) async {
    final tripId = trip['tripId']?.toString() ?? '';
    if (tripId.isEmpty) return;

    final current = _workflowPhaseNumber(trip);
    if (current >= 12) return;

    final next = current + 1;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final isDark = Theme.of(dialogContext).brightness == Brightness.dark;
        return AlertDialog(
          title: const Text('Mark next workflow phase?'),
          content: Text(
            '${trip['tripId'] ?? 'This trip'} will move to phase $next: '
            '${_workflowPhaseLabel(next)}.\n\n'
            'Next action: ${_workflowNextAction(next)}',
          ),
          backgroundColor: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Confirm Phase'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;

    final previous = List<Map<String, dynamic>>.from(tripsNotifier.value);
    final localUpdates = {
      'workflowPhaseNumber': next,
      'workflowGroup': _workflowGroupForPhase(next),
      'workflowPhaseLabel': _workflowPhaseLabel(next),
      'workflowNextAction': _workflowNextAction(next),
      if (next == 10) 'status': 'dispatched',
      if (next == 12) 'status': 'completed',
    };
    tripsNotifier.value = tripsNotifier.value.map((item) {
      if (item['tripId'] == tripId) {
        return {...item, ...localUpdates};
      }
      return item;
    }).toList();

    try {
      await BackendApiService.updateTrip(tripId, {
        'workflowPhaseNumber': next,
        if (next == 10) 'status': 'dispatched',
        if (next == 12) 'status': 'completed',
      });
      unawaited(refreshFleetSnapshot(forceRefresh: true));
    } catch (_) {
      tripsNotifier.value = previous;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('Workflow phase could not be advanced. Rolled back.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DashboardLayout(
      currentRoute: '/dispatch-queue',
      title: 'Dispatch Queue',
      child: _buildPageContent(isDark),
    );
  }

  Widget _buildPageContent(bool isDark) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600;

    return Column(
      children: [
        AnimatedSize(
          duration: _dispatchChromeAnimationDuration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: AnimatedContainer(
            duration: _dispatchChromeAnimationDuration,
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.all(
              _topSectionCollapsed
                  ? 0
                  : (isMobile ? 14 : 18),
            ),
            color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
            child: AnimatedSwitcher(
              duration: _dispatchChromeAnimationDuration,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                return SizeTransition(
                  sizeFactor: animation,
                  axisAlignment: -1,
                  child: FadeTransition(opacity: animation, child: child),
                );
              },
              child: _topSectionCollapsed
                  ? const SizedBox.shrink(key: ValueKey('dispatchTopHidden'))
                  : Column(
                      key: const ValueKey('dispatchTopVisible'),
                      children: [
                        _buildStatsCards(isDark, isMobile),
                        SizedBox(height: isMobile ? 10 : 12),
                        _buildGeotabRoutesPanel(isDark, isMobile),
                      ],
                    ),
            ),
          ),
        ),
        Expanded(
          child: Column(
            children: [
              Container(
                color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
                child: TabBar(
                  controller: _tabController,
                  indicatorColor: isDark
                      ? AppTheme.colorFF4B7BE5
                      : AppTheme.colorFF1E40AF,
                  indicatorWeight: 3,
                  labelColor: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                  unselectedLabelColor: isDark
                      ? AppTheme.gray500
                      : AppTheme.gray600,
                  labelStyle: TextStyle(
                    fontSize: isMobile ? 12 : 13,
                    fontWeight: FontWeight.w700,
                  ),
                  dividerColor: AppTheme.transparent,
                  tabs: const [
                    Tab(text: 'Order Board'),
                    Tab(text: 'Available Vehicles'),
                    Tab(text: 'Live Transit'),
                  ],
                ),
              ),
              Expanded(
                child: NotificationListener<ScrollNotification>(
                  onNotification: _handleDispatchScroll,
                  child: RefreshIndicator(
                    onRefresh: _refreshDispatch,
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        Builder(
                          builder: (_) =>
                              _buildDispatchQueue(isDark, isMobile),
                        ),
                        Builder(
                          builder: (_) =>
                              _buildAvailableVehicles(isDark, isMobile),
                        ),
                        Builder(
                          builder: (_) =>
                              _buildActiveDispatches(isDark, isMobile),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  bool _handleDispatchScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) {
      return false;
    }

    if (notification.metrics.pixels <= 8 && _topSectionCollapsed) {
      setState(() => _topSectionCollapsed = false);
      return false;
    }

    if (notification is UserScrollNotification) {
      if (notification.direction == ScrollDirection.reverse &&
          notification.metrics.pixels > 24 &&
          !_topSectionCollapsed) {
        setState(() => _topSectionCollapsed = true);
      }
    }

    return false;
  }

  int _visibleWorkflowLimit(String title) {
    return _workflowVisibleLimits[title] ?? _initialWorkflowVisibleLimit;
  }

  bool get _largeDispatchDataset {
    return tripsNotifier.value.length + vehiclesNotifier.value.length > 60;
  }

  Duration get _dispatchChromeAnimationDuration {
    return _largeDispatchDataset
        ? const Duration(milliseconds: 90)
        : const Duration(milliseconds: 220);
  }

  void _showMoreWorkflowTrips(String title) {
    setState(() {
      _workflowVisibleLimits[title] =
          _visibleWorkflowLimit(title) + _workflowPageSize;
    });
  }

  Widget _buildListDisclosureButton({
    required bool isDark,
    required String label,
    required VoidCallback onPressed,
  }) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.expand_more_rounded, size: 18),
        label: Text(label),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          foregroundColor: AppTheme.colorFF00A8E8,
          textStyle: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }

  Widget _buildStatsCards(
    bool isDark,
    bool isMobile, {
    bool compact = false,
  }) {
    final stats = [
      {
        'value': '${_pendingTrips.length}',
        'label': 'Pending Dispatch',
        'icon': Icons.access_time_rounded,
        'color': AppTheme.colorFFF39C12,
      },
      {
        'value': '${_activeDispatches.length}',
        'label': 'Active Dispatches',
        'icon': Icons.send_rounded,
        'color': AppTheme.colorFF4B7BE5,
      },
      {
        'value': '$_availableVehiclesCount',
        'label': 'Vehicles Available',
        'icon': Icons.local_shipping_rounded,
        'color': AppTheme.colorFF27AE60,
      },
      {
        'value': '${_geotabRoutes.length}',
        'label': 'GeoTab Routes',
        'icon': Icons.alt_route_rounded,
        'color': AppTheme.colorFF00A8E8,
      },
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 600) {
          final gap = compact ? 8.0 : 10.0;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: stats.map((stat) {
              return SizedBox(
                width: compact
                    ? (constraints.maxWidth - gap) / 2
                    : constraints.maxWidth,
                child: _buildStatCard(
                  stat,
                  isDark,
                  isMobile,
                  isFullWidth: true,
                  compact: compact,
                ),
              );
            }).toList(),
          );
        }

        return Row(
          children: stats.map((stat) {
            final isLast = stat == stats.last;
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: isLast ? 0 : 12),
                child: _buildStatCard(
                  stat,
                  isDark,
                  false,
                  compact: compact,
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildStatCard(
    Map<String, dynamic> stat,
    bool isDark,
    bool isMobile, {
    bool isFullWidth = false,
    bool compact = false,
  }) {
    final color = stat['color'] as Color;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      constraints: BoxConstraints(minHeight: compact ? 58 : 86),
      padding: EdgeInsets.all(
        compact ? (isMobile ? 8 : 10) : (isMobile ? 12 : 14),
      ),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF171B23 : AppTheme.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color.withValues(alpha: isDark ? 0.34 : 0.20),
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: isDark ? 0.14 : 0.08),
            blurRadius: 22,
            spreadRadius: -14,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: compact ? 32 : 40,
            height: compact ? 32 : 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              stat['icon'] as IconData,
              color: color,
              size: compact ? 16 : 20,
            ),
          ),
          SizedBox(width: compact ? 8 : 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  stat['label'],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: isDark ? AppTheme.gray300 : AppTheme.gray700,
                  ),
                ),
                SizedBox(height: compact ? 1 : 3),
                Text(
                  stat['value'],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: compact ? 18 : (isMobile ? 20 : 22),
                    fontWeight: FontWeight.w900,
                    color: isDark ? AppTheme.white : AppTheme.colorFF233244,
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(height: 2),
                  Text(
                    _dispatchStatSubtitle(stat['label'] as String),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _dispatchStatSubtitle(String label) {
    return switch (label) {
      'Pending Dispatch' => 'waiting for assignment',
      'Active Dispatches' => 'currently moving',
      'Vehicles Available' => 'ready to assign',
      'GeoTab Routes' => 'available route plans',
      _ => 'dispatch metric',
    };
  }

  Widget _buildAvailableVehicles(bool isDark, bool isMobile) {
    final visibleVehicles = _availableVehicles
        .take(_availableVehiclesVisibleLimit)
        .toList();
    final hiddenCount = _availableVehicles.length - visibleVehicles.length;

    return Container(
      color: isDark ? AppTheme.colorFF0A0E1A : AppTheme.colorFFF5F6F8,
      child: _availableVehicles.isEmpty
          ? _buildEmptyState(
              isDark,
              'No available vehicles',
              'Vehicles that are ready for dispatch will appear here',
            )
          : SingleChildScrollView(
              padding: EdgeInsets.all(isMobile ? 16 : 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: EdgeInsets.all(isMobile ? 16 : 20),
                    decoration: BoxDecoration(
                      color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isDark
                            ? AppTheme.white.withValues(alpha: 0.08)
                            : AppTheme.black.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Available Fleet',
                          style: TextStyle(
                            fontSize: isMobile ? 16 : 18,
                            fontWeight: FontWeight.w700,
                            color: isDark
                                ? AppTheme.white
                                : AppTheme.colorFF2C3E50,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Dispatch-ready trucks sourced from the live fleet lane',
                          style: TextStyle(
                            fontSize: isMobile ? 11 : 12,
                            color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  ...visibleVehicles.map((vehicle) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: _buildAvailableVehicleCard(
                        vehicle,
                        isDark,
                        isMobile,
                      ),
                    );
                  }),
                  if (hiddenCount > 0)
                    _buildListDisclosureButton(
                      isDark: isDark,
                      label: 'Show $hiddenCount more vehicles',
                      onPressed: () {
                        setState(() => _availableVehiclesVisibleLimit += 24);
                      },
                    ),
                ],
              ),
            ),
    );
  }

  Widget _buildDispatchQueue(bool isDark, bool isMobile) {
    final groups = _workflowGroupedTrips;
    final hasTrips = groups.values.any((items) => items.isNotEmpty);
    return Container(
      color: isDark ? AppTheme.colorFF0A0E1A : AppTheme.colorFFF5F6F8,
      child: SingleChildScrollView(
        padding: EdgeInsets.all(isMobile ? 14 : 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: EdgeInsets.all(isMobile ? 12 : 14),
              decoration: BoxDecoration(
                color: isDark ? AppTheme.colorFF171B23 : AppTheme.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDark
                      ? AppTheme.white.withValues(alpha: 0.07)
                      : AppTheme.black.withValues(alpha: 0.07),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Operations Order Board',
                          style: TextStyle(
                            fontSize: isMobile ? 16 : 18,
                            fontWeight: FontWeight.w700,
                            color: isDark
                                ? AppTheme.white
                                : AppTheme.colorFF2C3E50,
                          ),
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: _pendingTrips.length < 2 || _optimizingOrder
                            ? null
                            : _suggestOptimalOrder,
                        icon: _optimizingOrder
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.auto_awesome_rounded),
                        label: Text(
                          isMobile ? 'Optimize' : 'Suggest Optimal Order',
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.colorFF1A3A6B,
                          foregroundColor: AppTheme.white,
                          textStyle: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Track each delivery from assignment to completion. Route optimization remains advisory and never auto-dispatches.',
                    style: TextStyle(
                      fontSize: isMobile ? 11 : 12,
                      color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                    ),
                  ),
                  if (_optimizeOrderMessage != null ||
                      _optimizedStops.isNotEmpty)
                    _buildOptimizedOrderPreview(isDark, isMobile),
                ],
              ),
            ),
            if (!hasTrips) ...[
              const SizedBox(height: 16),
              _buildPendingEmptyState(isDark, isMobile),
            ],
            const SizedBox(height: 14),
            ...groups.entries.map(
              (entry) => _buildWorkflowGroupSection(
                entry.key,
                entry.value,
                isDark,
                isMobile,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWorkflowGroupSection(
    String title,
    List<Map<String, dynamic>> trips,
    bool isDark,
    bool isMobile,
  ) {
    final collapsed = _collapsedWorkflowGroups.contains(title);
    final color = _workflowGroupColor(title);
    final visibleLimit = _visibleWorkflowLimit(title);
    final visibleTrips = trips.take(visibleLimit).toList();
    final hiddenCount = trips.length - visibleTrips.length;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF111722 : AppTheme.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              setState(() {
                if (collapsed) {
                  _collapsedWorkflowGroups.remove(title);
                } else {
                  _collapsedWorkflowGroups.add(title);
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    collapsed
                        ? Icons.keyboard_arrow_right_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: color,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: isMobile ? 14 : 15,
                            fontWeight: FontWeight.w900,
                            color: isDark
                                ? AppTheme.white
                                : AppTheme.colorFF111827,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _workflowGroupDescription(title),
                          style: TextStyle(
                            fontSize: 11,
                            color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${trips.length}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        color: color,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!collapsed && trips.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Column(
                children: [
                  ...visibleTrips.map((trip) {
                    return Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: _buildPendingTripCard(trip, isDark, isMobile),
                    );
                  }),
                  if (hiddenCount > 0) ...[
                    const SizedBox(height: 10),
                    _buildListDisclosureButton(
                      isDark: isDark,
                      label: 'Show $hiddenCount more in $title',
                      onPressed: () => _showMoreWorkflowTrips(title),
                    ),
                  ],
                ],
              ),
            ),
          if (!collapsed && trips.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'No trips in this workflow section.',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? AppTheme.gray500 : AppTheme.gray600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPendingEmptyState(bool isDark, bool isMobile) {
    final routeMessage = _geotabRoutes.isEmpty
        ? (_routesLoading
              ? 'Checking GeoTab route plans now.'
              : 'New deliveries will appear here when they are created.')
        : '${_geotabRoutes.length} GeoTab route plans are available above. '
              'They will appear here as pending route trips after the fleet snapshot refreshes.';
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(isMobile ? 16 : 18),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.inbox_outlined,
              size: 26,
              color: AppTheme.colorFF4B7BE5,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No delivery orders in the board',
                    style: TextStyle(
                    fontSize: isMobile ? 14 : 15,
                    fontWeight: FontWeight.w800,
                    color: isDark ? AppTheme.white : AppTheme.colorFF1A1D23,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  routeMessage,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOptimizedOrderPreview(bool isDark, bool isMobile) {
    final hasStops = _optimizedStops.isNotEmpty;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 14),
      padding: EdgeInsets.all(isMobile ? 12 : 14),
      decoration: BoxDecoration(
        color: isDark
            ? AppTheme.colorFF1A3A6B.withValues(alpha: 0.22)
            : AppTheme.colorFFEAF2FF,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppTheme.colorFF1A3A6B.withValues(alpha: 0.24),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.route_rounded,
                size: 18,
                color: AppTheme.colorFF1A3A6B,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _optimizeOrderMessage ?? 'Suggested order ready',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppTheme.white : AppTheme.colorFF1A3A6B,
                  ),
                ),
              ),
            ],
          ),
          if (hasStops) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _optimizedStops.take(8).map((stop) {
                final sequence =
                    stop['optimizedSequence'] ?? stop['currentSequence'] ?? '?';
                final tripId = stop['tripId']?.toString() ?? 'Trip';
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: isDark
                        ? AppTheme.white.withValues(alpha: 0.08)
                        : AppTheme.white,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: AppTheme.colorFF1A3A6B.withValues(alpha: 0.20),
                    ),
                  ),
                  child: Text(
                    '$sequence. $tripId',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: isDark ? AppTheme.white : AppTheme.colorFF1A3A6B,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPendingTripCard(
    Map<String, dynamic> trip,
    bool isDark,
    bool isMobile,
  ) {
    final isRoutePlan =
        trip['isRoutePlan'] == true ||
        trip['source']?.toString().trim().toLowerCase() == 'geotab_route_plan';
    final routeStops = (trip['routedPlaces'] as List?) ?? const [];
    final assignedVehicle = _dispatchValue(
      trip['vehicle'],
      'Unassigned vehicle',
    );
    final driverName = _dispatchValue(trip['driver'], 'Unassigned driver');
    final customer = _dispatchValue(trip['customer'], 'Unassigned client');
    final destination = _dispatchValue(trip['destination'], 'No destination');
    final origin = _dispatchValue(trip['origin'], 'No origin');
    final phaseNumber = _workflowPhaseNumber(trip);
    final status = _dispatchValue(trip['status'], 'pending');
    final phone = _driverPhoneForTrip(trip);
    final hasDriver = driverName.toLowerCase() != 'unassigned driver';
    final hasVehicle = assignedVehicle.toLowerCase() != 'unassigned vehicle';
    final canDispatch =
        !isRoutePlan && phaseNumber <= 9 && status.toLowerCase() == 'pending';
    final statusPresentation = WorkflowStatusHelper.trip(
      canDispatch ? 'ready' : status,
    );
    final statusColor = statusPresentation.color;
    final dispatchDisabledReason = WorkflowStatusHelper.disabledActionReason(
      action: 'dispatch',
      status: status,
      hasDriver: hasDriver,
      hasVehicle: hasVehicle,
    );
    final value = _orderValue(trip);
    final qualifiesForFreeDelivery =
        trip['freeDeliveryCandidate'] == true || value >= 100000;
    final routeDistance = _routeDistanceLabel(trip);

    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = (constraints.maxWidth / 800).clamp(0.82, 1.04);
        return Container(
          padding: EdgeInsets.all(14 * scale),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.colorFF171B23 : AppTheme.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _workflowGroupColor(
                _workflowGroupForTrip(trip),
              ).withValues(alpha: 0.34),
            ),
            boxShadow: [
              BoxShadow(
                color: _workflowGroupColor(
                  _workflowGroupForTrip(trip),
                ).withValues(alpha: isDark ? 0.10 : 0.06),
                blurRadius: 18,
                spreadRadius: -14,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          assignedVehicle.toUpperCase(),
                          style: TextStyle(
                            fontSize: 18 * scale,
                            fontWeight: FontWeight.w900,
                            color: isDark
                                ? AppTheme.white
                                : AppTheme.colorFF111827,
                          ),
                        ),
                        SizedBox(height: 4 * scale),
                        Text(
                          driverName,
                          style: TextStyle(
                            fontSize: 12.5 * scale,
                            fontWeight: FontWeight.w600,
                            color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: 12 * scale),
                  Flexible(
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8 * scale,
                      runSpacing: 8 * scale,
                      children: [
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 10 * scale,
                            vertical: 5 * scale,
                          ),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            statusPresentation.label.toUpperCase(),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: statusColor,
                            ),
                          ),
                        ),
                        if (isRoutePlan)
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 9 * scale,
                              vertical: 5 * scale,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.colorFF00A8E8.withValues(
                                alpha: 0.14,
                              ),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              'GEOTAB ROUTE PLAN',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                                color: AppTheme.colorFF00A8E8,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: 12 * scale),
              Row(
                children: [
                  Text(
                      _dispatchValue(trip['tripId'], 'Trip'),
                      style: TextStyle(
                      fontSize: 11.5 * scale,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.colorFF4B7BE5,
                    ),
                  ),
                  SizedBox(width: 10 * scale),
                  Expanded(
                    child: Text(
                      customer,
                      style: TextStyle(
                        fontSize: 14.5 * scale,
                        fontWeight: FontWeight.w800,
                        color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              SizedBox(height: 9 * scale),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.location_on_rounded,
                    size: 17 * scale,
                    color: AppTheme.colorFFC0392B,
                  ),
                  SizedBox(width: 7 * scale),
                  Expanded(
                    child: Text(
                      '$destination  |  From $origin',
                      style: TextStyle(
                        fontSize: 12.5 * scale,
                        height: 1.35,
                        color: isDark ? AppTheme.gray300 : AppTheme.gray700,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
                    ),
                  ),
                ],
              ),
              SizedBox(height: 14 * scale),
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(12 * scale),
                decoration: BoxDecoration(
                  color: isDark
                      ? AppTheme.colorFF0F1117
                      : AppTheme.colorFFF8FAFD,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Wrap(
                  spacing: 18 * scale,
                  runSpacing: 12 * scale,
                  children: [
                    _buildPendingMetaChip(
                      isDark,
                      scale,
                      Icons.schedule_rounded,
                      'Departure',
                      _formattedDispatchTime(trip),
                    ),
                    _buildPendingMetaChip(
                      isDark,
                      scale,
                      Icons.inventory_2_outlined,
                      'Cargo',
                      _cargoLabel(trip),
                    ),
                    _buildPendingMetaChip(
                      isDark,
                      scale,
                      Icons.payments_outlined,
                      'Order value',
                      _currencyLabel(value, fallback: trip['amount']),
                      valueColor: AppTheme.colorFF27AE60,
                    ),
                    if (routeDistance != null)
                      _buildPendingMetaChip(
                        isDark,
                        scale,
                        Icons.route_outlined,
                        'Route',
                        routeDistance,
                      ),
                    if (isRoutePlan)
                      _buildPendingMetaChip(
                        isDark,
                        scale,
                        Icons.pin_drop_outlined,
                        'Stops',
                        routeStops.isEmpty
                            ? 'No stops'
                            : '${routeStops.length} stops',
                      ),
                  ],
                ),
              ),
              if (qualifiesForFreeDelivery) ...[
                SizedBox(height: 10 * scale),
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 10 * scale,
                    vertical: 6 * scale,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.colorFF27AE60.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'FREE DELIVERY CANDIDATE - PHP 100,000+ ORDER',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.colorFF27AE60,
                    ),
                  ),
                ),
              ],
              SizedBox(height: 12 * scale),
              _buildWorkflowPreview(trip, isDark, scale),
              if (_workflowGroupForTrip(trip) == 'In Transit') ...[
                SizedBox(height: 10 * scale),
                _buildLiveTransitIndicator(trip, isDark, scale),
              ],
              SizedBox(height: 12 * scale),
              Wrap(
                spacing: 10 * scale,
                runSpacing: 10 * scale,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Tooltip(
                    message: phone == null
                        ? 'No driver phone number recorded'
                        : 'Contact $driverName',
                    child: OutlinedButton.icon(
                      onPressed: phone == null
                          ? null
                          : () => _showDriverContact(driverName, phone),
                      icon: const Icon(Icons.phone_outlined),
                      label: const Text('Contact Driver'),
                    ),
                  ),
                  if (!isRoutePlan)
                    Tooltip(
                      message: canDispatch
                          ? 'Dispatch this trip'
                          : dispatchDisabledReason,
                      child: FilledButton.icon(
                        onPressed: canDispatch
                            ? () => _showDispatchModal(trip)
                            : null,
                        icon: const Icon(Icons.send_rounded),
                        label: const Text('Dispatch'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.colorFF4B7BE5,
                          foregroundColor: AppTheme.white,
                        ),
                      ),
                    ),
                  if (!isRoutePlan && phaseNumber < 12)
                    FilledButton.icon(
                      onPressed: () => _advanceWorkflowPhase(trip),
                      icon: const Icon(Icons.arrow_forward_rounded),
                      label: const Text('Mark Next Phase'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.colorFF1A3A6B,
                        foregroundColor: AppTheme.white,
                      ),
                    ),
                  Text(
                    _statusUpdateLabel(trip),
                    style: TextStyle(
                      fontSize: 12 * scale,
                      color: isDark ? AppTheme.gray500 : AppTheme.gray600,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  String _dispatchValue(dynamic value, String fallback) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty || text.toLowerCase() == 'n/a') return fallback;
    return text;
  }

  double _numericValue(dynamic value) {
    if (value is num) return value.toDouble();
    final raw = value?.toString().replaceAll(RegExp(r'[^0-9.-]'), '') ?? '';
    return double.tryParse(raw) ?? 0;
  }

  double _orderValue(Map<String, dynamic> trip) {
    final configured = _numericValue(trip['orderValue']);
    return configured > 0 ? configured : _numericValue(trip['amount']);
  }

  String _currencyLabel(double value, {dynamic fallback}) {
    if (value <= 0 && fallback != null) {
      return _dispatchValue(fallback, 'PHP 0.00');
    }
    final fixed = value.toStringAsFixed(2);
    final parts = fixed.split('.');
    final digits = parts.first;
    final buffer = StringBuffer();
    for (var index = 0; index < digits.length; index++) {
      final fromEnd = digits.length - index;
      buffer.write(digits[index]);
      if (fromEnd > 1 && fromEnd % 3 == 1) buffer.write(',');
    }
    return 'PHP ${buffer.toString()}.${parts.last}';
  }

  String _cargoLabel(Map<String, dynamic> trip) {
    final cargo = _dispatchValue(trip['cargoType'], 'General');
    final weight = _numericValue(trip['totalWeightKg']);
    if (weight <= 0) return '$cargo - weight pending';
    return '$cargo - ${weight.toStringAsFixed(weight % 1 == 0 ? 0 : 1)} kg';
  }

  DateTime? _tripTimestamp(Map<String, dynamic> trip, List<String> keys) {
    for (final key in keys) {
      final parsed = DateTime.tryParse(trip[key]?.toString() ?? '');
      if (parsed != null) return parsed.toLocal();
    }
    return null;
  }

  String _clockLabel(DateTime date) {
    final hour = date.hour == 0
        ? 12
        : date.hour > 12
        ? date.hour - 12
        : date.hour;
    final minute = date.minute.toString().padLeft(2, '0');
    final meridian = date.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $meridian';
  }

  String _formattedDispatchTime(Map<String, dynamic> trip) {
    final date = _tripTimestamp(trip, const [
      'scheduledDepartureAt',
      'departureTime',
      'date',
    ]);
    if (date == null) return 'Not scheduled';
    final today = DateTime.now();
    final dateOnly = DateTime(date.year, date.month, date.day);
    final todayOnly = DateTime(today.year, today.month, today.day);
    final difference = dateOnly.difference(todayOnly).inDays;
    if (difference == 0) return 'Today ${_clockLabel(date)}';
    if (difference == 1) return 'Tomorrow ${_clockLabel(date)}';
    const months = [
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
    return '${months[date.month - 1]} ${date.day}, ${_clockLabel(date)}';
  }

  String? _routeDistanceLabel(Map<String, dynamic> trip) {
    for (final key in const [
      'estimatedRouteDistanceKm',
      'plannedDistanceKm',
      'distanceKm',
    ]) {
      final distance = _numericValue(trip[key]);
      if (distance > 0) return '${distance.toStringAsFixed(1)} km estimated';
    }
    return null;
  }

  String _relativeAge(DateTime value) {
    final elapsed = DateTime.now().difference(value);
    if (elapsed.inMinutes < 1) return 'just now';
    if (elapsed.inMinutes < 60) return '${elapsed.inMinutes} min ago';
    if (elapsed.inHours < 24) return '${elapsed.inHours} hr ago';
    return '${elapsed.inDays} d ago';
  }

  String _statusUpdateLabel(Map<String, dynamic> trip) {
    final updated = _tripTimestamp(trip, const [
      'updatedAt',
      'lastUpdated',
      'startedAt',
      'scheduledDepartureAt',
      'date',
    ]);
    return updated == null
        ? 'Status time unavailable'
        : 'Updated ${_relativeAge(updated)}';
  }

  String? _driverPhoneForTrip(Map<String, dynamic> trip) {
    final driverName = trip['driver']?.toString().trim().toLowerCase() ?? '';
    if (driverName.isEmpty || driverName == 'unassigned') return null;
    for (final driver in driversNotifier.value) {
      if (driver['name']?.toString().trim().toLowerCase() == driverName) {
        final phone =
            driver['phone']?.toString().trim() ??
            driver['contactNumber']?.toString().trim() ??
            '';
        if (phone.isNotEmpty && phone.toLowerCase() != 'n/a') return phone;
      }
    }
    return null;
  }

  Future<void> _showDriverContact(String driverName, String phone) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Contact $driverName'),
        content: SelectableText(phone),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: phone));
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  behavior: SnackBarBehavior.floating,
                  content: Text('Driver phone number copied.'),
                ),
              );
            },
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy Number'),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveTransitIndicator(
    Map<String, dynamic> trip,
    bool isDark,
    double scale,
  ) {
    final vehicle = _vehicleForTrip(trip);
    final speed = _numericValue(vehicle?['speed']);
    final ignitionOn = vehicle?['ignitionOn'] == true;
    final lastUpdate = _tripTimestamp(vehicle ?? const {}, const [
      'lastGeotabAt',
      'lastUpdated',
    ]);
    final syncState = vehicle?['syncState']?.toString().toLowerCase() ?? '';
    final sourceAgeMs = _numericValue(vehicle?['sourceAgeMs']);
    final stale =
        vehicle == null ||
        syncState.contains('stale') ||
        syncState.contains('offline') ||
        sourceAgeMs > const Duration(minutes: 5).inMilliseconds ||
        (lastUpdate != null &&
            DateTime.now().difference(lastUpdate) > const Duration(minutes: 5));

    final Color color;
    final IconData icon;
    final String label;
    if (stale) {
      color = AppTheme.colorFFEF4444;
      icon = Icons.warning_amber_rounded;
      label = lastUpdate == null
          ? 'Live state unavailable'
          : 'Last seen ${_relativeAge(lastUpdate)}';
    } else if (speed > 2 || vehicle['isDriving'] == true) {
      color = AppTheme.colorFF27AE60;
      icon = Icons.navigation_rounded;
      label = 'Moving at ${speed.toStringAsFixed(0)} km/h';
    } else if (ignitionOn) {
      color = AppTheme.colorFFF59E0B;
      icon = Icons.circle;
      label = 'Idling - engine on';
    } else {
      color = isDark ? AppTheme.gray400 : AppTheme.gray600;
      icon = Icons.stop_circle_outlined;
      label = 'Stopped - engine off';
    }

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: 12 * scale,
        vertical: 9 * scale,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16 * scale, color: color),
          SizedBox(width: 8 * scale),
          Text(
            'LIVE  $label',
            style: TextStyle(
              fontSize: 12 * scale,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWorkflowPreview(
    Map<String, dynamic> trip,
    bool isDark,
    double scale,
  ) {
    final phase =
        trip['workflowPhaseLabel']?.toString().trim().isNotEmpty == true
        ? trip['workflowPhaseLabel'].toString()
        : 'Dispatch assignment';
    final next =
        trip['workflowNextAction']?.toString().trim().isNotEmpty == true
        ? trip['workflowNextAction'].toString()
        : 'Confirm assignment and receiving schedule.';
    final phaseNumber = _workflowPhaseNumber(trip);
    final method =
        trip['fulfillmentLabel']?.toString().trim().isNotEmpty == true
        ? trip['fulfillmentLabel'].toString()
        : 'Delivery / pickup review';

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(12 * scale),
      decoration: BoxDecoration(
        color: AppTheme.colorFF4B7BE5.withValues(alpha: isDark ? 0.12 : 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 26 * scale,
                height: 26 * scale,
                decoration: BoxDecoration(
                  color: AppTheme.colorFF4B7BE5,
                  borderRadius: BorderRadius.circular(999),
                ),
                alignment: Alignment.center,
                child: Text(
                  '$phaseNumber',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.white,
                  ),
                ),
              ),
              SizedBox(width: 10 * scale),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$phase - $method',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12 * scale,
                        fontWeight: FontWeight.w900,
                        color: isDark ? AppTheme.white : AppTheme.colorFF18212F,
                      ),
                    ),
                    SizedBox(height: 3 * scale),
                    Text(
                      'Phase $phaseNumber',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 10 * scale),
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(
              horizontal: 10 * scale,
              vertical: 8 * scale,
            ),
            decoration: BoxDecoration(
              color: AppTheme.colorFFF59E0B.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              'NEXT ACTION  $next',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.3,
                fontWeight: FontWeight.w800,
                color: isDark ? AppTheme.colorFFF59E0B : AppTheme.colorFF9A5B00,
              ),
            ),
          ),
          if ((trip['workflowSteps'] as List?)?.isNotEmpty == true) ...[
            SizedBox(height: 10 * scale),
            WorkflowTimeline(
              steps: ((trip['workflowSteps'] as List?) ?? const [])
                  .whereType<Map>()
                  .map((step) => Map<String, dynamic>.from(step))
                  .toList(),
              currentPhaseNumber: phaseNumber,
              compact: true,
            ),
          ],
        ],
      ),
    );
  }

  int _workflowPhaseNumber(Map<String, dynamic> trip) {
    final raw = trip['workflowPhaseNumber'];
    if (raw is num) return raw.toInt().clamp(1, 12);
    final parsed = int.tryParse(raw?.toString() ?? '');
    if (parsed != null) return parsed.clamp(1, 12);

    switch (trip['status']?.toString().trim().toLowerCase()) {
      case 'completed':
        return 12;
      case 'arrived':
        return 8;
      case 'dispatched':
      case 'active':
      case 'in transit':
      case 'on trip':
        return 7;
      case 'pending':
        return 1;
      default:
        return 5;
    }
  }

  String _workflowGroupForTrip(Map<String, dynamic> trip) {
    return _workflowGroupForPhase(_workflowPhaseNumber(trip));
  }

  String _workflowGroupForPhase(int phase) {
    if (phase <= 2) return 'Pending Details';
    if (phase <= 6) return 'Pending Assignment';
    if (phase == 7) return 'In Transit';
    if (phase == 8) return 'Arrived';
    if (phase <= 10) return 'Pending POD';
    return 'Billing Review';
  }

  String _workflowPhaseLabel(int phase) {
    if (phase <= 2) return 'Trip request';
    if (phase <= 6) return 'Dispatch assignment';
    if (phase <= 8) return 'Delivery execution';
    if (phase <= 10) return 'POD verification';
    return 'Billing review';
  }

  String _workflowNextAction(int phase) {
    if (phase <= 2) return 'Complete the delivery trip details.';
    if (phase <= 6) return 'Assign vehicle, driver, and dispatch notification.';
    if (phase == 7) return 'Dispatch the truck and share live tracking.';
    if (phase == 8) return 'Confirm arrival at the destination.';
    if (phase <= 10) return 'Submit and verify proof of delivery.';
    return 'Review, issue, or settle the trip-linked invoice.';
  }

  Color _workflowGroupColor(String title) {
    switch (title) {
      case 'Pending Details':
        return AppTheme.colorFFF59E0B;
      case 'Pending Assignment':
        return AppTheme.colorFFF59E0B;
      case 'In Transit':
        return AppTheme.colorFF4B7BE5;
      case 'Arrived':
        return AppTheme.colorFF14B8A6;
      case 'Pending POD':
        return AppTheme.colorFFF59E0B;
      case 'Billing Review':
        return AppTheme.colorFF16A34A;
      default:
        return AppTheme.colorFF16A34A;
    }
  }

  String _workflowGroupDescription(String title) {
    switch (title) {
      case 'Pending Details':
        return 'Delivery requests needing complete trip details';
      case 'Pending Assignment':
        return 'Trips requiring vehicle and driver assignment';
      case 'In Transit':
        return 'Active delivery movement with live vehicle condition';
      case 'Arrived':
        return 'At destination, awaiting delivery receipt confirmation';
      case 'Pending POD':
        return 'Completed or arrived trips waiting for proof-of-delivery review';
      case 'Billing Review':
        return 'POD-backed trips ready for invoice and payment follow-up';
      default:
        return 'Delivery workflow status';
    }
  }

  Widget _buildPendingMetaChip(
    bool isDark,
    double scale,
    IconData icon,
    String label,
    String value, {
    Color? valueColor,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 16 * scale,
          color: isDark ? AppTheme.gray500 : AppTheme.gray600,
        ),
        SizedBox(width: 6 * scale),
        Text(
          '$label: ',
          style: TextStyle(
            fontSize: 12 * scale,
            color: isDark ? AppTheme.gray500 : AppTheme.gray600,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 13 * scale,
            fontWeight: FontWeight.w800,
            color:
                valueColor ??
                (isDark ? AppTheme.white : AppTheme.colorFF111827),
          ),
        ),
      ],
    );
  }

  Widget _buildAvailableVehicleCard(
    Map<String, dynamic> vehicle,
    bool isDark,
    bool isMobile,
  ) {
    final driver = vehicle['driver']?.toString().trim();
    final routeName = vehicle['assignedRoute']?.toString().trim();
    final maintenanceState =
        vehicle['maintenanceState']?.toString().trim().toLowerCase() ?? '';
    final needsAttention =
        maintenanceState == 'due' ||
        maintenanceState == 'overdue' ||
        maintenanceState == 'active';

    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 18),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.08)
              : AppTheme.black.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.colorFF1A3A6B.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.local_shipping_rounded,
                  color: AppTheme.colorFF1A3A6B,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      vehicle['plate']?.toString() ?? 'N/A',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: isDark ? AppTheme.white : AppTheme.colorFF1A1D23,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      vehicle['truckType']?.toString() ?? 'N/A',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color:
                      (needsAttention
                              ? AppTheme.colorFFC0392B
                              : AppTheme.colorFF27AE60)
                          .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  needsAttention ? 'Maintenance' : 'Available',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: needsAttention
                        ? AppTheme.colorFFC0392B
                        : AppTheme.colorFF27AE60,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _buildMiniInfo(
                isDark,
                Icons.person_rounded,
                'Driver',
                (driver == null || driver.isEmpty) ? 'Unassigned' : driver,
              ),
              _buildMiniInfo(
                isDark,
                Icons.route_rounded,
                'Route',
                (routeName == null || routeName.isEmpty)
                    ? 'Standby'
                    : routeName,
              ),
              _buildMiniInfo(
                isDark,
                Icons.speed_rounded,
                'Speed',
                '${vehicle['speed'] ?? 0} km/h',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGeotabRoutesPanel(bool isDark, bool isMobile) {
    final assigned = _geotabRoutes.where((route) {
      return route['deviceId']?.toString().trim().isNotEmpty == true;
    }).length;
    final plannedStops = _geotabRoutes.fold<int>(
      0,
      (sum, route) => sum + ((route['stops'] as List?)?.length ?? 0),
    );
    final loadedAt = _routesLoadedAt;
    final loadedLabel = loadedAt == null
        ? null
        : '${loadedAt.hour.toString().padLeft(2, '0')}:${loadedAt.minute.toString().padLeft(2, '0')}';
    final hasRoutes = _geotabRoutes.isNotEmpty;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 12 : 14,
        vertical: isMobile ? 10 : 12,
      ),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF171B23 : AppTheme.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppTheme.colorFF4B7BE5.withValues(alpha: isDark ? 0.26 : 0.18),
        ),
        boxShadow: [
          BoxShadow(
            color: AppTheme.colorFF4B7BE5.withValues(alpha: isDark ? 0.10 : 0.06),
            blurRadius: 22,
            spreadRadius: -16,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.alt_route_rounded,
                  color: AppTheme.colorFF4B7BE5,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Route plan readiness',
                      style: TextStyle(
                        fontSize: isMobile ? 13 : 14,
                        fontWeight: FontWeight.w900,
                        color: isDark ? AppTheme.white : AppTheme.colorFF1A1D23,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _routesLoading && !hasRoutes
                          ? 'Fetching route plans...'
                          : _routesError != null && !hasRoutes
                          ? 'Route plans unavailable. Retry when GeoTab is reachable.'
                          : hasRoutes
                          ? '${_geotabRoutes.length} plans, $assigned assigned, $plannedStops stops${loadedLabel == null ? '' : ' - checked $loadedLabel'}'
                          : 'No GeoTab route plans returned yet.',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                      ),
                    ),
                  ],
                ),
              ),
              if (_routesLoading && hasRoutes) ...[
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
              ],
              if (_routesError != null)
                IconButton(
                  tooltip: 'Retry route plans',
                  onPressed: () => _loadGeotabRoutes(forceRefresh: true),
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                ),
              if (hasRoutes)
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  onPressed: () {
                    setState(() {
                      _routePlansExpanded = !_routePlansExpanded;
                    });
                  },
                  icon: Icon(
                    _routePlansExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                  ),
                  label: Text(_routePlansExpanded ? 'Hide' : 'View plans'),
                ),
            ],
          ),
          if (_routesLoading && !hasRoutes) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Fetching GeoTab routes from the backend route snapshot.',
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                    ),
                  ),
                ),
              ],
            ),
          ] else if (_routesError != null && !hasRoutes) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: AppTheme.colorFFF59E0B,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _routesError!,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: isDark ? AppTheme.gray300 : AppTheme.gray700,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _loadGeotabRoutes(forceRefresh: true),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ],
          if (_routesError != null && _geotabRoutes.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: AppTheme.colorFFF59E0B,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Showing the last loaded routes. Refresh failed recently.',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => _loadGeotabRoutes(forceRefresh: true),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ],
          if (hasRoutes && _routePlansExpanded) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _routeMetricPill(
                  isDark,
                  Icons.route_outlined,
                  '${_geotabRoutes.length} plans',
                  AppTheme.colorFF4B7BE5,
                ),
                _routeMetricPill(
                  isDark,
                  Icons.local_shipping_outlined,
                  '$assigned assigned',
                  assigned > 0 ? AppTheme.colorFF27AE60 : AppTheme.colorFFF39C12,
                ),
                _routeMetricPill(
                  isDark,
                  Icons.pin_drop_outlined,
                  '$plannedStops stops',
                  AppTheme.colorFF00A8E8,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              assigned == 0
                  ? 'Route plans are visible here, but none are assigned to assets yet.'
                  : '$assigned route plans are assigned and ready to reflect in route orders and trip planning.',
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: isDark ? AppTheme.gray400 : AppTheme.gray600,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _geotabRoutes.take(4).map((route) {
                final stopsList = (route['stops'] as List?) ?? const [];
                final stops = stopsList.length;
                final asset = route['assignedAsset']?.toString().trim();
                final deviceId = route['deviceId']?.toString().trim();
                final origin = stopsList.isNotEmpty
                    ? ((stopsList.first as Map?)?['name']?.toString().trim())
                    : null;
                final destination = stopsList.isNotEmpty
                    ? ((stopsList.last as Map?)?['name']?.toString().trim())
                    : null;
                final routeAvailable = route['routeAvailable'] == true;
                return _routePlanChip(
                  isDark,
                  route['name']?.toString() ?? 'Unnamed Route',
                  stops == 0 ? 'No stops yet' : '$stops stops',
                  (asset != null && asset.isNotEmpty)
                      ? asset
                      : (deviceId != null && deviceId.isNotEmpty)
                      ? deviceId
                      : 'Unassigned',
                  origin != null && origin.isNotEmpty ? origin : 'No origin',
                  destination != null && destination.isNotEmpty
                      ? destination
                      : 'No destination',
                  routeAvailable ? 'Route ready' : 'Needs GPS/stop points',
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _routeMetricPill(
    bool isDark,
    IconData icon,
    String label,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.13 : 0.09),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.20)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: isDark ? AppTheme.gray200 : color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _routePlanChip(
    bool isDark,
    String name,
    String stops,
    String assignment,
    String origin,
    String destination,
    String availability,
  ) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.20),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: isDark ? AppTheme.white : AppTheme.colorFF1F2937,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '$stops - $assignment',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '$origin to $destination',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              height: 1.25,
              color: isDark ? AppTheme.gray300 : AppTheme.colorFF374151,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: availability == 'Route ready'
                  ? AppTheme.colorFF27AE60.withValues(alpha: 0.14)
                  : AppTheme.colorFFF59E0B.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              availability,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: availability == 'Route ready'
                    ? AppTheme.colorFF27AE60
                    : AppTheme.colorFFF59E0B,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMiniInfo(
    bool isDark,
    IconData icon,
    String label,
    String value,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF8FAFD,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 15,
            color: isDark ? AppTheme.gray400 : AppTheme.materialGrey,
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? AppTheme.gray500 : AppTheme.gray600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: isDark ? AppTheme.white : AppTheme.colorFF1A1D23,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActiveDispatches(bool isDark, bool isMobile) {
    return Container(
      color: isDark ? AppTheme.colorFF0A0E1A : AppTheme.colorFFF5F6F8,
      child: _activeDispatches.isEmpty
          ? _buildEmptyState(
              isDark,
              'No active dispatches',
              'Dispatch trips from the queue',
            )
          : SingleChildScrollView(
              padding: EdgeInsets.all(isMobile ? 16 : 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: EdgeInsets.all(isMobile ? 16 : 20),
                    decoration: BoxDecoration(
                      color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isDark
                            ? AppTheme.white.withValues(alpha: 0.08)
                            : AppTheme.black.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'IN TRANSIT',
                          style: TextStyle(
                            fontSize: isMobile ? 18 : 20,
                            fontWeight: FontWeight.w700,
                            color: isDark
                                ? AppTheme.white
                                : AppTheme.colorFF2C3E50,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Active trips with live location refresh every 30 seconds',
                          style: TextStyle(
                            fontSize: isMobile ? 12 : 14,
                            color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  _buildActiveDispatchesTable(isDark, isMobile),
                ],
              ),
            ),
    );
  }

  Widget _buildActiveDispatchesTable(bool isDark, bool isMobile) {
    final visibleDispatches = _activeDispatches
        .take(_activeDispatchVisibleLimit)
        .toList();
    final hiddenCount = _activeDispatches.length - visibleDispatches.length;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.08)
              : AppTheme.black.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth:
                    MediaQuery.of(context).size.width - (isMobile ? 32 : 48),
              ),
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(
                  isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF8FAFD,
                ),
                columnSpacing: isMobile ? 16 : 32,
                horizontalMargin: isMobile ? 16 : 24,
                dataRowMinHeight: 60,
                dataRowMaxHeight: 70,
                columns: [
                  _buildDataColumn('TRIP', isDark, isMobile),
                  _buildDataColumn('CLIENT', isDark, isMobile),
                  _buildDataColumn('ROUTE', isDark, isMobile),
                  _buildDataColumn('VEHICLE', isDark, isMobile),
                  _buildDataColumn('LOCATION', isDark, isMobile),
                  _buildDataColumn('DRIVER', isDark, isMobile),
                  _buildDataColumn('AMOUNT', isDark, isMobile),
                ],
                rows: visibleDispatches.map((trip) {
                  final vehicle = _vehicleForTrip(trip);
                  final location =
                      vehicle?['currentLocationLabel']?.toString().trim() ?? '';
                  return DataRow(
                    cells: [
                      DataCell(
                        Text(
                          trip['tripId'],
                          style: TextStyle(
                            fontSize: isMobile ? 12 : 13,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.colorFF4B7BE5,
                          ),
                        ),
                      ),
                      DataCell(
                        SizedBox(
                          width: isMobile ? 120 : 150,
                          child: Text(
                            trip['customer'],
                            style: TextStyle(
                              fontSize: isMobile ? 12 : 13,
                              color: isDark
                                  ? AppTheme.white
                                  : AppTheme.colorFF2C3E50,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      DataCell(
                        SizedBox(
                          width: isMobile ? 200 : 280,
                          child: Text(
                            '${trip['origin']} -> ${trip['destination']}',
                            style: TextStyle(
                              fontSize: isMobile ? 11 : 12,
                              color: isDark
                                  ? AppTheme.gray400
                                  : AppTheme.gray700,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      DataCell(
                        Text(
                          trip['vehicle'],
                          style: TextStyle(
                            fontSize: isMobile ? 12 : 13,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? AppTheme.white
                                : AppTheme.colorFF2C3E50,
                          ),
                        ),
                      ),
                      DataCell(
                        SizedBox(
                          width: isMobile ? 150 : 220,
                          child: Text(
                            location.isEmpty ? 'Fetching location...' : location,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: isMobile ? 12 : 13,
                              color: isDark
                                  ? AppTheme.white70
                                  : AppTheme.colorFF5A6070,
                            ),
                          ),
                        ),
                      ),
                      DataCell(
                        Text(
                          trip['driver'],
                          style: TextStyle(
                            fontSize: isMobile ? 12 : 13,
                            color: isDark ? AppTheme.gray300 : AppTheme.gray800,
                          ),
                        ),
                      ),
                      DataCell(
                        Text(
                          trip['amount'],
                          style: TextStyle(
                            fontSize: isMobile ? 12 : 13,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.colorFF27AE60,
                          ),
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
          if (hiddenCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: _buildListDisclosureButton(
                isDark: isDark,
                label: 'Show $hiddenCount more active dispatches',
                onPressed: () {
                  setState(() => _activeDispatchVisibleLimit += 40);
                },
              ),
            ),
        ],
      ),
    );
  }

  DataColumn _buildDataColumn(String label, bool isDark, bool isMobile) {
    return DataColumn(
      label: Text(
        label,
        style: TextStyle(
          fontSize: isMobile ? 10 : 11,
          fontWeight: FontWeight.w700,
          color: isDark ? AppTheme.gray400 : AppTheme.gray600,
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark, String title, String subtitle) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.inbox_rounded,
            size: 80,
            color: isDark ? AppTheme.gray700 : AppTheme.gray300,
          ),
          const SizedBox(height: 24),
          Text(
            title,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.gray600 : AppTheme.gray400,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 14,
              color: isDark ? AppTheme.gray500 : AppTheme.gray500,
            ),
          ),
        ],
      ),
    );
  }
}

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
// DISPATCH MODAL
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

class _DispatchModal extends StatefulWidget {
  final Map<String, dynamic> trip;
  final void Function(String driver, String vehicle) onDispatch;
  const _DispatchModal({required this.trip, required this.onDispatch});

  @override
  State<_DispatchModal> createState() => _DispatchModalState();
}

class _DispatchModalState extends State<_DispatchModal> {
  String? _selectedDriver;
  String? _selectedVehicle;
  bool _dispatching = false;

  List<String> get _availableDrivers {
    return driversNotifier.value
        .where((d) => d['status'] == 'available')
        .map((d) => d['name'] as String)
        .toList();
  }

  List<String> get _availableVehicles {
    return vehiclesNotifier.value
        .where((v) => v['status'] == 'available')
        .map((v) => v['plate'] as String)
        .toList();
  }

  void _dispatch() {
    if (_selectedDriver == null || _selectedVehicle == null) return;
    setState(() => _dispatching = true);

    // Small delay to ensure smooth transition
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        widget.onDispatch(_selectedDriver!, _selectedVehicle!);
        Navigator.of(context, rootNavigator: true).pop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMobile = MediaQuery.of(context).size.width < 600;

    return Dialog(
          backgroundColor: AppTheme.transparent,
          insetPadding: EdgeInsets.symmetric(
            horizontal: isMobile ? 16 : 80,
            vertical: 40,
          ),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 500),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isDark
                    ? AppTheme.white.withValues(alpha: 0.08)
                    : AppTheme.black.withValues(alpha: 0.08),
              ),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.black.withValues(alpha: 0.3),
                  blurRadius: 40,
                  offset: const Offset(0, 16),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [AppTheme.colorFF4B7BE5, AppTheme.colorFF1B2A4A],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(24),
                      topRight: Radius.circular(24),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppTheme.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.send_rounded,
                          color: AppTheme.white,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Dispatch Trip',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.white,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.trip['tripId'],
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppTheme.white70,
                              ),
                            ),
                          ],
                        ),
                      ),
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: AppTheme.white.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.close_rounded,
                            color: AppTheme.white,
                            size: 20,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Content
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      // Trip info
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isDark
                              ? AppTheme.colorFF0F1117
                              : AppTheme.colorFFF8FAFD,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isDark
                                ? AppTheme.white.withValues(alpha: 0.08)
                                : AppTheme.black.withValues(alpha: 0.08),
                          ),
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.person_rounded,
                                  size: 16,
                                  color: isDark
                                      ? AppTheme.gray500
                                      : AppTheme.gray600,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Customer: ',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: isDark
                                        ? AppTheme.gray500
                                        : AppTheme.gray600,
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    widget.trip['customer'],
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: isDark
                                          ? AppTheme.white
                                          : AppTheme.colorFF2C3E50,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Icon(
                                  Icons.location_on_rounded,
                                  size: 16,
                                  color: isDark
                                      ? AppTheme.gray500
                                      : AppTheme.gray600,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '${widget.trip['origin']} -> ${widget.trip['destination']}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isDark
                                          ? AppTheme.gray400
                                          : AppTheme.gray700,
                                    ),
                                    maxLines: 2,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Driver dropdown
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Select Driver',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? AppTheme.gray300
                                  : AppTheme.colorFF2C3E50,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            height: 52,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? AppTheme.colorFF0F1117
                                  : AppTheme.colorFFF5F6F8,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isDark
                                    ? AppTheme.white.withValues(alpha: 0.1)
                                    : AppTheme.black.withValues(alpha: 0.1),
                              ),
                            ),
                            child: DropdownButton<String>(
                              value: _selectedDriver,
                              hint: Text(
                                'Choose available driver',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: isDark
                                      ? AppTheme.gray600
                                      : AppTheme.gray500,
                                ),
                              ),
                              underline: const SizedBox(),
                              isExpanded: true,
                              icon: Icon(
                                Icons.keyboard_arrow_down_rounded,
                                color: isDark
                                    ? AppTheme.gray400
                                    : AppTheme.gray600,
                              ),
                              style: TextStyle(
                                fontSize: 14,
                                color: isDark
                                    ? AppTheme.white
                                    : AppTheme.colorFF2C3E50,
                              ),
                              dropdownColor: isDark
                                  ? AppTheme.colorFF1A1D23
                                  : AppTheme.white,
                              items: _availableDrivers
                                  .map(
                                    (d) => DropdownMenuItem(
                                      value: d,
                                      child: Text(d),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) =>
                                  setState(() => _selectedDriver = v),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Vehicle dropdown
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Select Vehicle',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? AppTheme.gray300
                                  : AppTheme.colorFF2C3E50,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            height: 52,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? AppTheme.colorFF0F1117
                                  : AppTheme.colorFFF5F6F8,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isDark
                                    ? AppTheme.white.withValues(alpha: 0.1)
                                    : AppTheme.black.withValues(alpha: 0.1),
                              ),
                            ),
                            child: DropdownButton<String>(
                              value: _selectedVehicle,
                              hint: Text(
                                'Choose available vehicle',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: isDark
                                      ? AppTheme.gray600
                                      : AppTheme.gray500,
                                ),
                              ),
                              underline: const SizedBox(),
                              isExpanded: true,
                              icon: Icon(
                                Icons.keyboard_arrow_down_rounded,
                                color: isDark
                                    ? AppTheme.gray400
                                    : AppTheme.gray600,
                              ),
                              style: TextStyle(
                                fontSize: 14,
                                color: isDark
                                    ? AppTheme.white
                                    : AppTheme.colorFF2C3E50,
                              ),
                              dropdownColor: isDark
                                  ? AppTheme.colorFF1A1D23
                                  : AppTheme.white,
                              items: _availableVehicles
                                  .map(
                                    (v) => DropdownMenuItem(
                                      value: v,
                                      child: Text(v),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) =>
                                  setState(() => _selectedVehicle = v),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),

                      // Buttons
                      Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () => Navigator.pop(context),
                              child: Container(
                                height: 50,
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? AppTheme.colorFF0F1117
                                      : AppTheme.colorFFF5F6F8,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isDark
                                        ? AppTheme.white.withValues(alpha: 0.1)
                                        : AppTheme.black.withValues(alpha: 0.1),
                                  ),
                                ),
                                child: Center(
                                  child: Text(
                                    'Cancel',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: isDark
                                          ? AppTheme.gray300
                                          : AppTheme.gray700,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap:
                                    (_dispatching ||
                                        _selectedDriver == null ||
                                        _selectedVehicle == null)
                                    ? null
                                    : _dispatch,
                                child: Container(
                                  height: 50,
                                  decoration: BoxDecoration(
                                    gradient:
                                        (_selectedDriver != null &&
                                            _selectedVehicle != null)
                                        ? const LinearGradient(
                                            colors: [
                                              AppTheme.colorFF4B7BE5,
                                              AppTheme.colorFF00D4FF,
                                            ],
                                          )
                                        : null,
                                    color:
                                        (_selectedDriver == null ||
                                            _selectedVehicle == null)
                                        ? (isDark
                                              ? AppTheme.gray800
                                              : AppTheme.gray300)
                                        : null,
                                    borderRadius: BorderRadius.circular(12),
                                    boxShadow:
                                        (_selectedDriver != null &&
                                            _selectedVehicle != null)
                                        ? [
                                            BoxShadow(
                                              color: const Color(
                                                0xFF4B7BE5,
                                              ).withValues(alpha: 0.4),
                                              blurRadius: 12,
                                              offset: const Offset(0, 4),
                                            ),
                                          ]
                                        : null,
                                  ),
                                  child: Center(
                                    child: _dispatching
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              color: AppTheme.white,
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Text(
                                            'Dispatch Now',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700,
                                              color: AppTheme.white,
                                            ),
                                          ),
                                  ),
                                ),
                              ),
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
  }
}
