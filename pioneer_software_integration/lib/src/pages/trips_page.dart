import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import '../widgets/dashboard_layout.dart';
import '../widgets/pioneer_google_map.dart';
import '../widgets/workflow_timeline.dart';
import '../widgets/shimmer_loading.dart';
import '../widgets/signature_pad.dart';
import '../services/backend_api.dart';
import '../services/clients_store.dart';
import '../services/crud_permissions.dart';
import '../services/drivers_store.dart';
import '../services/fleet_sync_service.dart';
import '../services/page_cache_service.dart';
import '../services/trips_store.dart';
import '../services/vehicles_store.dart';
import '../services/billing_store.dart';
import '../services/notification_service.dart';
import '../services/soa_exporter.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';
import '../utils/form_validation.dart';
import '../utils/workflow_status_helper.dart';

const String tripMapInsufficientPointsMessage =
    'Route data unavailable - insufficient GPS points';

enum _TripListAction { view, edit, advance, cancel }

class TripsPage extends StatefulWidget {
  const TripsPage({super.key});

  @override
  State<TripsPage> createState() => _TripsPageState();
}

class _TripsPageState extends State<TripsPage> {
  static const String _cacheKey = 'trips_page';

  String _searchQuery = '';
  String _statusFilter = 'All Status';
  String _dateFilter = 'All Dates';
  String _clientFilter = 'All Clients';
  String _driverFilter = 'All Drivers';
  String _vehicleFilter = 'All Vehicles';
  String _sortMode = 'Date Newest';
  final Set<String> _selectedTripIds = <String>{};

  @override
  void initState() {
    super.initState();
    tripsNotifier.addListener(_onTripsChanged);
    _restoreFilters();
    _primeTrips();
  }

  void _onTripsChanged() {
    if (!mounted) return;
    final availableIds = tripsNotifier.value
        .map((trip) => trip['tripId']?.toString() ?? '')
        .toSet();
    setState(() {
      _selectedTripIds.removeWhere((tripId) => !availableIds.contains(tripId));
    });
  }

  Future<void> _primeTrips({bool forceRefresh = false}) async {
    await PageCacheService.getOrLoad<int>(
      key: _cacheKey,
      ttl: PageCacheService.tripsTtl,
      forceRefresh: forceRefresh,
      loader: () async {
        await refreshFleetBootstrap(forceRefresh: forceRefresh);
        await refreshFleetSnapshot(forceRefresh: forceRefresh);
        _prewarmTripDetails();
        return tripsNotifier.value.length;
      },
    ).catchError((_) {
      refreshFleetBootstrapSilently(forceRefresh: forceRefresh);
      return tripsNotifier.value.length;
    });
  }

  void _prewarmTripDetails() {
    for (final trip in tripsNotifier.value.take(5)) {
      final tripId = trip['tripId']?.toString().trim() ?? '';
      if (tripId.isEmpty) {
        continue;
      }

      unawaited(
        BackendApiService.getTripMap(tripId)
            .timeout(const Duration(seconds: 8))
            .catchError((_) => <String, dynamic>{}),
      );
    }
  }

  Future<void> _refreshTrips() async {
    await _primeTrips(forceRefresh: true);
    if (mounted) {
      setState(() {});
    }
  }

  void _showNewTripModal() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _TripLifecycleDialog(onSave: addTrip),
    );
  }

  @override
  void dispose() {
    tripsNotifier.removeListener(_onTripsChanged);
    super.dispose();
  }

  Future<void> _restoreFilters() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) {
      return;
    }

    setState(() {
      _statusFilter = prefs.getString('trips_status_filter') ?? 'All Status';
      _dateFilter = prefs.getString('trips_date_filter') ?? 'All Dates';
      _clientFilter = prefs.getString('trips_client_filter') ?? 'All Clients';
      _driverFilter = prefs.getString('trips_driver_filter') ?? 'All Drivers';
      _vehicleFilter =
          prefs.getString('trips_vehicle_filter') ?? 'All Vehicles';
      _sortMode = prefs.getString('trips_sort_mode') ?? 'Date Newest';
    });
  }

  Future<void> _persistFilters() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('trips_status_filter', _statusFilter);
    await prefs.setString('trips_date_filter', _dateFilter);
    await prefs.setString('trips_client_filter', _clientFilter);
    await prefs.setString('trips_driver_filter', _driverFilter);
    await prefs.setString('trips_vehicle_filter', _vehicleFilter);
    await prefs.setString('trips_sort_mode', _sortMode);
  }

  List<Map<String, dynamic>> get _filteredTrips {
    var filtered = tripsNotifier.value;

    if (_searchQuery.isNotEmpty) {
      filtered = filtered.where((trip) {
        final searchLower = _searchQuery.toLowerCase();
        return trip['tripId'].toString().toLowerCase().contains(searchLower) ||
            trip['customer'].toString().toLowerCase().contains(searchLower) ||
            trip['driver'].toString().toLowerCase().contains(searchLower) ||
            trip['vehicle'].toString().toLowerCase().contains(searchLower);
      }).toList();
    }

    if (_statusFilter != 'All Status') {
      final filterMap = {
        'Completed': 'completed',
        'In Progress': 'inprogress',
        'Dispatched': 'dispatched',
        'Pending': 'pending',
        'Pending Approval': 'pending_approval',
        'Cancelled': 'cancelled',
      };
      final targetStatus =
          filterMap[_statusFilter] ?? _statusFilter.toLowerCase();
      filtered = filtered.where((trip) {
        final tripStatus = trip['status'].toString().toLowerCase();
        return tripStatus == targetStatus ||
            tripStatus.replaceAll(' ', '') == targetStatus;
      }).toList();
    }

    if (_dateFilter != 'All Dates') {
      final now = DateTime.now();
      filtered = filtered.where((trip) {
        final tripDate = _tripDateOf(trip);
        if (tripDate == null) {
          return false;
        }

        switch (_dateFilter) {
          case 'Today':
            return _isSameDate(tripDate, now);
          case 'Last 7 Days':
            return !tripDate.isBefore(now.subtract(const Duration(days: 7)));
          case 'This Month':
            return tripDate.year == now.year && tripDate.month == now.month;
          default:
            return true;
        }
      }).toList();
    }

    if (_clientFilter != 'All Clients') {
      filtered = filtered
          .where((trip) => trip['customer']?.toString() == _clientFilter)
          .toList();
    }

    if (_driverFilter != 'All Drivers') {
      filtered = filtered
          .where((trip) => trip['driver']?.toString() == _driverFilter)
          .toList();
    }

    if (_vehicleFilter != 'All Vehicles') {
      filtered = filtered
          .where((trip) => trip['vehicle']?.toString() == _vehicleFilter)
          .toList();
    }

    filtered = [...filtered]..sort(_compareTrips);

    return filtered;
  }

  int _compareTrips(Map<String, dynamic> a, Map<String, dynamic> b) {
    return switch (_sortMode) {
      'Date Oldest' => _compareTripDates(a, b, newestFirst: false),
      'Status A-Z' => _statusSortRank(a).compareTo(_statusSortRank(b)),
      'Status Z-A' => _statusSortRank(b).compareTo(_statusSortRank(a)),
      'Client A-Z' => _compareTripText(a, b, 'customer'),
      'Client Z-A' => _compareTripText(b, a, 'customer'),
      'Driver A-Z' => _compareTripText(a, b, 'driver'),
      'Driver Z-A' => _compareTripText(b, a, 'driver'),
      'Vehicle A-Z' => _compareTripText(a, b, 'vehicle'),
      'Vehicle Z-A' => _compareTripText(b, a, 'vehicle'),
      _ => _compareTripDates(a, b, newestFirst: true),
    };
  }

  int _compareTripDates(
    Map<String, dynamic> a,
    Map<String, dynamic> b, {
    required bool newestFirst,
  }) {
    final dateA = _tripDateOf(a);
    final dateB = _tripDateOf(b);
    if (dateA == null && dateB == null) {
      return _statusSortRank(a).compareTo(_statusSortRank(b));
    }
    if (dateA == null) return 1;
    if (dateB == null) return -1;
    final byDate = newestFirst
        ? dateB.compareTo(dateA)
        : dateA.compareTo(dateB);
    return byDate != 0
        ? byDate
        : _statusSortRank(a).compareTo(_statusSortRank(b));
  }

  int _compareTripText(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
    String field,
  ) {
    return (a[field]?.toString().toLowerCase() ?? '').compareTo(
      b[field]?.toString().toLowerCase() ?? '',
    );
  }

  int _statusSortRank(Map<String, dynamic> trip) {
    final status = trip['status']?.toString().trim().toLowerCase() ?? '';
    switch (status.replaceAll(' ', '')) {
      case 'pending':
        return 0;
      case 'pending_approval':
      case 'pendingapproval':
        return 1;
      case 'dispatched':
      case 'inprogress':
        return 2;
      case 'completed':
        return 3;
      case 'cancelled':
      case 'canceled':
        return 4;
      default:
        return 5;
    }
  }

  DateTime? _tripDateOf(Map<String, dynamic> trip) {
    for (final candidate in [
      trip['startedAt'],
      trip['endedAt'],
      trip['date'],
    ]) {
      final parsed = _parseTripDate(candidate?.toString() ?? '');
      if (parsed != null) {
        return parsed;
      }
    }
    return null;
  }

  DateTime? _parseTripDate(String raw) {
    final value = raw.trim();
    if (value.isEmpty || value == 'N/A') {
      return null;
    }

    final direct = DateTime.tryParse(value);
    if (direct != null) {
      return direct;
    }

    // ignore: deprecated_member_use
    final isoMatch = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(value);
    if (isoMatch != null) {
      return DateTime(
        int.parse(isoMatch.group(1)!),
        int.parse(isoMatch.group(2)!),
        int.parse(isoMatch.group(3)!),
      );
    }

    // ignore: deprecated_member_use
    final shortMonthMatch = RegExp(
      r'^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{1,2})',
      caseSensitive: false,
    ).firstMatch(value);
    if (shortMonthMatch == null) {
      return null;
    }

    const months = {
      'jan': 1,
      'feb': 2,
      'mar': 3,
      'apr': 4,
      'may': 5,
      'jun': 6,
      'jul': 7,
      'aug': 8,
      'sep': 9,
      'oct': 10,
      'nov': 11,
      'dec': 12,
    };
    final month = months[shortMonthMatch.group(1)!.toLowerCase()];
    if (month == null) {
      return null;
    }

    return DateTime(
      DateTime.now().year,
      month,
      int.parse(shortMonthMatch.group(2)!),
    );
  }

  bool _isSameDate(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  int get _completedTripsCount => tripsNotifier.value
      .where(
        (trip) =>
            trip['status']?.toString().trim().toLowerCase() == 'completed',
      )
      .length;

  int get _activeTripsCount => tripsNotifier.value.where((trip) {
    final status = trip['status']?.toString().trim().toLowerCase() ?? '';
    return status == 'in progress' ||
        status == 'inprogress' ||
        status == 'dispatched' ||
        status == 'on trip';
  }).length;

  int get _pendingTripsCount => tripsNotifier.value.where((trip) {
    final status = trip['status']?.toString().trim().toLowerCase() ?? '';
    return status == 'pending' || status == 'pending_approval';
  }).length;

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      currentRoute: '/trips',
      title: 'Trips',
      child: _buildPageContent(),
    );
  }

  Widget _buildPageContent() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMobile = screenWidth < 600;

    return Column(
      children: [
        Container(
              padding: EdgeInsets.all(isMobile ? 16 : 24),
              decoration: BoxDecoration(
                color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
                border: Border(
                  bottom: BorderSide(
                    color: isDark
                        ? AppTheme.white.withValues(alpha: 0.08)
                        : AppTheme.black.withValues(alpha: 0.08),
                  ),
                ),
              ),
              child: _buildSearchBar(isDark, isMobile),
            )
            .animate()
            .fadeIn(duration: 500.ms)
            .slideY(
              begin: 0.2,
              end: 0,
              duration: 500.ms,
              curve: Curves.easeOut,
            ),
        Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(
            isMobile ? 16 : 24,
            0,
            isMobile ? 16 : 24,
            12,
          ),
          color: isDark ? AppTheme.colorFF0A0E1A : AppTheme.colorFFF5F6F8,
          child: _buildAdvancedFilters(isDark, isMobile),
        ),
        Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(
            isMobile ? 16 : 24,
            16,
            isMobile ? 16 : 24,
            0,
          ),
          color: isDark ? AppTheme.colorFF0A0E1A : AppTheme.colorFFF5F6F8,
          child: _buildSummaryStrip(isDark, isMobile),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refreshTrips,
            child: isMobile
                ? _buildMobileTripsList(isDark)
                      .animate()
                      .fadeIn(duration: 600.ms)
                      .slideY(
                        begin: 0.2,
                        end: 0,
                        duration: 600.ms,
                        curve: Curves.easeOut,
                      )
                : _buildDesktopTripsTable(isDark)
                      .animate()
                      .fadeIn(duration: 600.ms)
                      .slideY(
                        begin: 0.2,
                        end: 0,
                        duration: 600.ms,
                        curve: Curves.easeOut,
                      ),
          ),
        ),
      ],
    );
  }

  Widget _buildAdvancedFilters(bool isDark, bool isMobile) {
    final clientOptions = _filterOptions(
      'All Clients',
      tripsNotifier.value.map((trip) => trip['customer']?.toString() ?? ''),
    );
    final driverOptions = _filterOptions(
      'All Drivers',
      tripsNotifier.value.map((trip) => trip['driver']?.toString() ?? ''),
    );
    final vehicleOptions = _filterOptions(
      'All Vehicles',
      tripsNotifier.value.map((trip) => trip['vehicle']?.toString() ?? ''),
    );

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        SizedBox(
          width: isMobile ? double.infinity : 240,
          child: _filterDropdown(
            value: _clientFilter,
            values: clientOptions,
            isDark: isDark,
            icon: Icons.business_rounded,
            onChanged: (value) {
              setState(() => _clientFilter = value);
              _persistFilters();
            },
          ),
        ),
        SizedBox(
          width: isMobile ? double.infinity : 220,
          child: _filterDropdown(
            value: _driverFilter,
            values: driverOptions,
            isDark: isDark,
            icon: Icons.badge_rounded,
            onChanged: (value) {
              setState(() => _driverFilter = value);
              _persistFilters();
            },
          ),
        ),
        SizedBox(
          width: isMobile ? double.infinity : 220,
          child: _filterDropdown(
            value: _vehicleFilter,
            values: vehicleOptions,
            isDark: isDark,
            icon: Icons.local_shipping_rounded,
            onChanged: (value) {
              setState(() => _vehicleFilter = value);
              _persistFilters();
            },
          ),
        ),
        SizedBox(
          width: isMobile ? double.infinity : 220,
          child: _filterDropdown(
            value: _sortMode,
            values: const [
              'Date Newest',
              'Date Oldest',
              'Status A-Z',
              'Status Z-A',
              'Client A-Z',
              'Client Z-A',
              'Driver A-Z',
              'Driver Z-A',
              'Vehicle A-Z',
              'Vehicle Z-A',
            ],
            isDark: isDark,
            icon: Icons.sort_rounded,
            onChanged: (value) {
              setState(() => _sortMode = value);
              _persistFilters();
            },
          ),
        ),
      ],
    );
  }

  List<String> _filterOptions(String allLabel, Iterable<String> values) {
    final cleaned =
        values
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty && value != 'N/A')
            .toSet()
            .toList()
          ..sort();
    return [allLabel, ...cleaned];
  }

  Widget _filterDropdown({
    required String value,
    required List<String> values,
    required bool isDark,
    required IconData icon,
    required ValueChanged<String> onChanged,
  }) {
    final safeValue = values.contains(value) ? value : values.first;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF0F1117 : AppTheme.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.08)
              : AppTheme.black.withValues(alpha: 0.08),
        ),
      ),
      child: DropdownButton<String>(
        value: safeValue,
        underline: const SizedBox.shrink(),
        isExpanded: true,
        icon: Icon(
          Icons.keyboard_arrow_down_rounded,
          color: isDark ? AppTheme.gray400 : AppTheme.gray700,
          size: 20,
        ),
        dropdownColor: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        style: TextStyle(
          fontSize: 13,
          color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
          fontWeight: FontWeight.w600,
        ),
        selectedItemBuilder: (_) => values
            .map(
              (item) => Row(
                children: [
                  Icon(
                    icon,
                    size: 16,
                    color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(item, overflow: TextOverflow.ellipsis)),
                ],
              ),
            )
            .toList(),
        items: values
            .map((item) => DropdownMenuItem(value: item, child: Text(item)))
            .toList(),
        onChanged: (value) {
          if (value != null) onChanged(value);
        },
      ),
    );
  }

  Widget _buildSearchBar(bool isDark, bool isMobile) {
    return isMobile
        ? Column(
            children: [
              Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: isDark
                      ? AppTheme.colorFF0F1117
                      : AppTheme.colorFFF5F6F8,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isDark
                        ? AppTheme.white.withValues(alpha: 0.08)
                        : AppTheme.black.withValues(alpha: 0.08),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.search_rounded,
                      color: isDark ? AppTheme.gray600 : AppTheme.gray500,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        onChanged: (value) =>
                            setState(() => _searchQuery = value),
                        style: TextStyle(
                          fontSize: 14,
                          color: isDark
                              ? AppTheme.white
                              : AppTheme.colorFF2C3E50,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Search by trip ID, customer, driver...',
                          hintStyle: TextStyle(
                            color: isDark ? AppTheme.gray600 : AppTheme.gray500,
                            fontSize: 14,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 44,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: isDark
                            ? AppTheme.colorFF0F1117
                            : AppTheme.colorFFF5F6F8,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isDark
                              ? AppTheme.white.withValues(alpha: 0.08)
                              : AppTheme.black.withValues(alpha: 0.08),
                        ),
                      ),
                      child: DropdownButton<String>(
                        value: _statusFilter,
                        underline: const SizedBox(),
                        isExpanded: true,
                        icon: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: isDark ? AppTheme.gray400 : AppTheme.gray700,
                          size: 20,
                        ),
                        style: TextStyle(
                          fontSize: 14,
                          color: isDark
                              ? AppTheme.white
                              : AppTheme.colorFF2C3E50,
                          fontWeight: FontWeight.w500,
                        ),
                        dropdownColor: isDark
                            ? AppTheme.colorFF1A1D23
                            : AppTheme.white,
                        items:
                            [
                                  'All Status',
                                  'Completed',
                                  'In Progress',
                                  'Dispatched',
                                  'Pending',
                                  'Pending Approval',
                                  'Cancelled',
                                ]
                                .map(
                                  (status) => DropdownMenuItem(
                                    value: status,
                                    child: Text(status),
                                  ),
                                )
                                .toList(),
                        onChanged: (value) {
                          setState(() => _statusFilter = value!);
                          _persistFilters();
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Container(
                      height: 44,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: isDark
                            ? AppTheme.colorFF0F1117
                            : AppTheme.colorFFF5F6F8,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isDark
                              ? AppTheme.white.withValues(alpha: 0.08)
                              : AppTheme.black.withValues(alpha: 0.08),
                        ),
                      ),
                      child: DropdownButton<String>(
                        value: _dateFilter,
                        underline: const SizedBox(),
                        isExpanded: true,
                        icon: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: isDark ? AppTheme.gray400 : AppTheme.gray700,
                          size: 20,
                        ),
                        style: TextStyle(
                          fontSize: 14,
                          color: isDark
                              ? AppTheme.white
                              : AppTheme.colorFF2C3E50,
                          fontWeight: FontWeight.w500,
                        ),
                        dropdownColor: isDark
                            ? AppTheme.colorFF1A1D23
                            : AppTheme.white,
                        items:
                            const [
                                  'All Dates',
                                  'Today',
                                  'Last 7 Days',
                                  'This Month',
                                ]
                                .map(
                                  (range) => DropdownMenuItem(
                                    value: range,
                                    child: Text(range),
                                  ),
                                )
                                .toList(),
                        onChanged: (value) {
                          setState(() => _dateFilter = value!);
                          _persistFilters();
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (CrudPermissions.canCreate(CrudEntity.trips))
                    GestureDetector(
                      onTap: _showNewTripModal,
                      child: Container(
                        height: 44,
                        width: 44,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [
                              AppTheme.colorFF4B7BE5,
                              AppTheme.colorFF00D4FF,
                            ],
                          ),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.colorFF4B7BE5.withValues(
                                alpha: 0.3,
                              ),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.add_rounded,
                          color: AppTheme.white,
                          size: 20,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          )
        : Row(
            children: [
              Expanded(
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: isDark
                        ? AppTheme.colorFF0F1117
                        : AppTheme.colorFFF5F6F8,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isDark
                          ? AppTheme.white.withValues(alpha: 0.08)
                          : AppTheme.black.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.search_rounded,
                        color: isDark ? AppTheme.gray600 : AppTheme.gray500,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          onChanged: (value) =>
                              setState(() => _searchQuery = value),
                          style: TextStyle(
                            fontSize: 14,
                            color: isDark
                                ? AppTheme.white
                                : AppTheme.colorFF2C3E50,
                          ),
                          decoration: InputDecoration(
                            hintText: 'Search by trip ID, customer, driver...',
                            hintStyle: TextStyle(
                              color: isDark
                                  ? AppTheme.gray600
                                  : AppTheme.gray500,
                              fontSize: 14,
                            ),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: isDark
                      ? AppTheme.colorFF0F1117
                      : AppTheme.colorFFF5F6F8,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isDark
                        ? AppTheme.white.withValues(alpha: 0.08)
                        : AppTheme.black.withValues(alpha: 0.08),
                  ),
                ),
                child: DropdownButton<String>(
                  value: _statusFilter,
                  underline: const SizedBox(),
                  icon: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: isDark ? AppTheme.gray400 : AppTheme.gray700,
                    size: 20,
                  ),
                  style: TextStyle(
                    fontSize: 14,
                    color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                    fontWeight: FontWeight.w500,
                  ),
                  dropdownColor: isDark
                      ? AppTheme.colorFF1A1D23
                      : AppTheme.white,
                  items:
                      [
                            'All Status',
                            'Completed',
                            'In Progress',
                            'Dispatched',
                            'Pending',
                            'Pending Approval',
                            'Cancelled',
                          ]
                          .map(
                            (status) => DropdownMenuItem(
                              value: status,
                              child: Text(status),
                            ),
                          )
                          .toList(),
                  onChanged: (value) {
                    setState(() => _statusFilter = value!);
                    _persistFilters();
                  },
                ),
              ),
              const SizedBox(width: 12),
              Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: isDark
                      ? AppTheme.colorFF0F1117
                      : AppTheme.colorFFF5F6F8,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isDark
                        ? AppTheme.white.withValues(alpha: 0.08)
                        : AppTheme.black.withValues(alpha: 0.08),
                  ),
                ),
                child: DropdownButton<String>(
                  value: _dateFilter,
                  underline: const SizedBox(),
                  icon: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: isDark ? AppTheme.gray400 : AppTheme.gray700,
                    size: 20,
                  ),
                  style: TextStyle(
                    fontSize: 14,
                    color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                    fontWeight: FontWeight.w500,
                  ),
                  dropdownColor: isDark
                      ? AppTheme.colorFF1A1D23
                      : AppTheme.white,
                  items:
                      const ['All Dates', 'Today', 'Last 7 Days', 'This Month']
                          .map(
                            (range) => DropdownMenuItem(
                              value: range,
                              child: Text(range),
                            ),
                          )
                          .toList(),
                  onChanged: (value) {
                    setState(() => _dateFilter = value!);
                    _persistFilters();
                  },
                ),
              ),
              const SizedBox(width: 12),
              if (CrudPermissions.canCreate(CrudEntity.trips))
                InkWell(
                  onTap: _showNewTripModal,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [
                          AppTheme.colorFF4B7BE5,
                          AppTheme.colorFF00D4FF,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      children: const [
                        Icon(
                          Icons.add_rounded,
                          color: AppTheme.white,
                          size: 18,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'New Trip',
                          style: TextStyle(
                            color: AppTheme.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
  }

  Widget _buildSummaryStrip(bool isDark, bool isMobile) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _summaryCard(
          title: 'Trips',
          value: '${tripsNotifier.value.length} total',
          color: AppTheme.colorFF4B7BE5,
          icon: Icons.route_rounded,
          isDark: isDark,
          isMobile: isMobile,
        ),
        _summaryCard(
          title: 'Active',
          value: '$_activeTripsCount in motion',
          color: AppTheme.colorFF27AE60,
          icon: Icons.alt_route_rounded,
          isDark: isDark,
          isMobile: isMobile,
        ),
        _summaryCard(
          title: 'Pending',
          value: '$_pendingTripsCount review',
          color: AppTheme.colorFFF39C12,
          icon: Icons.pending_actions_rounded,
          isDark: isDark,
          isMobile: isMobile,
        ),
        _summaryCard(
          title: 'Completed',
          value: '$_completedTripsCount closed',
          color: AppTheme.colorFF14B8A6,
          icon: Icons.task_alt_rounded,
          isDark: isDark,
          isMobile: isMobile,
        ),
        InkWell(
          onTap: () => refreshFleetSnapshotSilently(forceRefresh: true),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: isMobile ? 14 : 16,
              vertical: isMobile ? 12 : 14,
            ),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.colorFF171B23 : AppTheme.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark
                    ? AppTheme.white.withValues(alpha: 0.08)
                    : AppTheme.black.withValues(alpha: 0.08),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.refresh_rounded,
                  size: 18,
                  color: AppTheme.colorFF4B7BE5,
                ),
                const SizedBox(width: 8),
                Text(
                  'Refresh trips',
                  style: TextStyle(
                    fontSize: isMobile ? 12 : 13,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppTheme.white : AppTheme.colorFF233244,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _summaryCard({
    required String title,
    required String value,
    required Color color,
    required IconData icon,
    required bool isDark,
    required bool isMobile,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 14 : 16,
        vertical: isMobile ? 12 : 14,
      ),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF171B23 : AppTheme.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.08)
              : AppTheme.black.withValues(alpha: 0.08),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: isMobile ? 11 : 12,
                  color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(
                  fontSize: isMobile ? 13 : 14,
                  fontWeight: FontWeight.w800,
                  color: isDark ? AppTheme.white : AppTheme.colorFF233244,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  bool _tripCanChange(Map<String, dynamic> trip) {
    final status = trip['status']?.toString().trim().toLowerCase() ?? '';
    return status != 'completed' &&
        status != 'cancelled' &&
        status != 'canceled';
  }

  int _tripPhase(Map<String, dynamic> trip) {
    final raw = trip['workflowPhaseNumber'];
    return raw is num ? raw.toInt().clamp(1, 12) : 1;
  }

  void _toggleTripSelection(String tripId, bool selected) {
    setState(() {
      if (selected) {
        _selectedTripIds.add(tripId);
      } else {
        _selectedTripIds.remove(tripId);
      }
    });
  }

  void _toggleAllVisibleTrips(bool selected) {
    setState(() {
      final visible = _filteredTrips
          .map((trip) => trip['tripId']?.toString() ?? '')
          .where((tripId) => tripId.isNotEmpty);
      if (selected) {
        _selectedTripIds.addAll(visible);
      } else {
        _selectedTripIds.removeAll(visible);
      }
    });
  }

  Future<void> _editTrip(Map<String, dynamic> trip) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _TripLifecycleDialog(
        initialTrip: trip,
        onSave: (updates) async {
          await updateTrip(trip['tripId'].toString(), updates);
        },
      ),
    );
  }

  Future<void> _advanceTrip(Map<String, dynamic> trip) async {
    final current = _tripPhase(trip);
    if (!_tripCanChange(trip) || current >= 12) return;
    final next = current + 1;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Advance workflow phase?'),
        content: Text(
          '${trip['tripId']} will move from phase $current to phase $next.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep Current'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Next Phase'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await updateTrip(trip['tripId'].toString(), {
        'workflowPhaseNumber': next,
        if (next >= 10 && next < 12) 'status': 'dispatched',
        if (next == 12) 'status': 'completed',
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            next == 12
                ? 'Trip completed. Billing is now available for this trip.'
                : 'Trip advanced to workflow phase $next.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            FormValidation.backendError(error, 'Trip phase was not updated.'),
          ),
        ),
      );
    }
  }

  Future<bool> _cancelTrip(
    Map<String, dynamic> trip, {
    String? suppliedReason,
  }) async {
    if (!_tripCanChange(trip)) return false;
    String? reason = suppliedReason;
    if (reason == null) {
      final controller = TextEditingController();
      reason = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Cancel ${trip['tripId']}?'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Cancellation reason',
              hintText: 'Required to preserve the trip audit trail',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Keep Trip'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isEmpty) return;
                Navigator.pop(dialogContext, value);
              },
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.colorFFE74C3C,
              ),
              child: const Text('Cancel Trip'),
            ),
          ],
        ),
      );
      controller.dispose();
    }
    if (reason == null || reason.trim().isEmpty || !mounted) return false;
    try {
      await updateTrip(trip['tripId'].toString(), {
        'status': 'cancelled',
        'statusColor': AppTheme.colorFF6B7280,
        'cancellationReason': reason.trim(),
        'cancelledAt': DateTime.now().toIso8601String(),
      });
      if (!mounted) return true;
      setState(() => _selectedTripIds.remove(trip['tripId'].toString()));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('${trip['tripId']} cancelled.'),
        ),
      );
      return true;
    } catch (error) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            FormValidation.backendError(error, 'Trip could not be cancelled.'),
          ),
        ),
      );
      return false;
    }
  }

  Future<void> _handleTripAction(
    _TripListAction action,
    Map<String, dynamic> trip,
  ) async {
    switch (action) {
      case _TripListAction.view:
        _showTripDetails(trip);
        return;
      case _TripListAction.edit:
        await _editTrip(trip);
        return;
      case _TripListAction.advance:
        await _advanceTrip(trip);
        return;
      case _TripListAction.cancel:
        await _cancelTrip(trip);
        return;
    }
  }

  Future<void> _bulkCancelTrips() async {
    final selected = _filteredTrips
        .where(
          (trip) =>
              _selectedTripIds.contains(trip['tripId']?.toString()) &&
              _tripCanChange(trip),
        )
        .toList();
    if (selected.isEmpty) return;
    final reasonController = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Cancel ${selected.length} selected trips?'),
        content: TextField(
          controller: reasonController,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Cancellation reason for selected trips',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Keep Trips'),
          ),
          FilledButton(
            onPressed: () {
              final value = reasonController.text.trim();
              if (value.isNotEmpty) Navigator.pop(dialogContext, value);
            },
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.colorFFE74C3C,
            ),
            child: const Text('Bulk Cancel'),
          ),
        ],
      ),
    );
    reasonController.dispose();
    if (reason == null) return;
    for (final trip in selected) {
      await _cancelTrip(trip, suppliedReason: reason);
    }
  }

  Future<void> _exportSelectedTrips() async {
    final selected = _filteredTrips
        .where((trip) => _selectedTripIds.contains(trip['tripId']?.toString()))
        .toList();
    if (selected.isEmpty) return;
    final rows = <List<String>>[
      const [
        'Trip ID',
        'Date',
        'Origin',
        'Destination',
        'Client',
        'Driver',
        'Vehicle',
        'Status',
      ],
      ...selected.map(
        (trip) => [
          '${trip['tripId'] ?? ''}',
          '${trip['date'] ?? ''}',
          '${trip['origin'] ?? ''}',
          '${trip['destination'] ?? ''}',
          '${trip['customer'] ?? ''}',
          '${trip['driver'] ?? ''}',
          '${trip['vehicle'] ?? ''}',
          '${trip['status'] ?? ''}',
        ],
      ),
    ];
    final csv = rows
        .map(
          (row) =>
              row.map((cell) => '"${cell.replaceAll('"', '""')}"').join(','),
        )
        .join('\r\n');
    final downloaded = await exportSoaCsv(
      'pioneerpath-trips-${DateTime.now().millisecondsSinceEpoch}.csv',
      csv,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          downloaded
              ? 'Selected trips exported to CSV.'
              : 'CSV export is available in the web build.',
        ),
      ),
    );
  }

  Widget _buildMobileTripsList(bool isDark) {
    if (_filteredTrips.isEmpty) return _buildEmptyState(isDark);

    return Column(
      children: [
        if (_selectedTripIds.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: _buildBulkActionBar(isDark),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _filteredTrips.length,
            itemBuilder: (context, index) {
              final trip = _filteredTrips[index];
              return _buildMobileTripCard(
                trip,
                isDark,
                index == _filteredTrips.length - 1,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMobileTripCard(
    Map<String, dynamic> trip,
    bool isDark,
    bool isLast,
  ) {
    final tripId = trip['tripId']?.toString() ?? '';
    final canChange =
        CrudPermissions.canEdit(CrudEntity.trips) && _tripCanChange(trip);
    return InkWell(
      onTap: () => _showTripDetails(trip),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        margin: EdgeInsets.only(bottom: isLast ? 0 : 12),
        padding: const EdgeInsets.all(16),
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
                Checkbox(
                  value: _selectedTripIds.contains(tripId),
                  onChanged: (value) =>
                      _toggleTripSelection(tripId, value == true),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      trip['tripId'],
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      trip['date'],
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? AppTheme.gray500 : AppTheme.gray600,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: (trip['statusColor'] as Color).withValues(
                      alpha: 0.15,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _getStatusText(trip['status']),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: trip['statusColor'] as Color,
                    ),
                  ),
                ),
                PopupMenuButton<_TripListAction>(
                  tooltip: 'Trip actions',
                  onSelected: (action) => _handleTripAction(action, trip),
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: _TripListAction.view,
                      child: Text('View Details'),
                    ),
                    if (canChange)
                      const PopupMenuItem(
                        value: _TripListAction.edit,
                        child: Text('Edit'),
                      ),
                    if (canChange && _tripPhase(trip) < 12)
                      const PopupMenuItem(
                        value: _TripListAction.advance,
                        child: Text('Advance Phase'),
                      ),
                    if (canChange)
                      const PopupMenuItem(
                        value: _TripListAction.cancel,
                        child: Text('Cancel'),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _buildInfoColumn('Customer', trip['customer'], isDark),
                ),
                Expanded(
                  child: _buildInfoColumn('Driver', trip['driver'], isDark),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildRouteInfo(trip, isDark),
            if (trip['hasDelay']) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.colorFFE74C3C.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppTheme.colorFFE74C3C.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.warning_rounded,
                      size: 16,
                      color: AppTheme.colorFFE74C3C,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        trip['delay'],
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.colorFFE74C3C,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  trip['amount'],
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  size: 16,
                  color: isDark ? AppTheme.gray500 : AppTheme.gray600,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopTripsTable(bool isDark) {
    if (_filteredTrips.isEmpty) return _buildEmptyState(isDark);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final visibleIds = _filteredTrips
              .map((trip) => trip['tripId']?.toString() ?? '')
              .where((tripId) => tripId.isNotEmpty)
              .toList();
          final allSelected =
              visibleIds.isNotEmpty &&
              visibleIds.every(_selectedTripIds.contains);
          return Container(
            width: constraints.maxWidth,
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
              children: [
                if (_selectedTripIds.isNotEmpty) _buildBulkActionBar(isDark),
                _buildTableHeader(isDark, allSelected),
                Expanded(
                  child: ListView.builder(
                    itemCount: _filteredTrips.length,
                    itemBuilder: (context, index) =>
                        _buildTableRow(_filteredTrips[index], isDark, index),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildBulkActionBar(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.colorFF4B7BE5.withValues(alpha: isDark ? 0.16 : 0.08),
      ),
      child: Row(
        children: [
          Text(
            '${_selectedTripIds.length} selected',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.white : AppTheme.primaryBlue,
            ),
          ),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: _exportSelectedTrips,
            icon: const Icon(Icons.download_rounded, size: 17),
            label: const Text('Bulk Export'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _bulkCancelTrips,
            icon: const Icon(Icons.cancel_outlined, size: 17),
            label: const Text('Bulk Cancel'),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.colorFFE74C3C,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTableHeader(bool isDark, bool allSelected) {
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      decoration: const BoxDecoration(color: AppTheme.primaryBlue),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Checkbox(
              value: allSelected,
              onChanged: (selected) => _toggleAllVisibleTrips(selected == true),
              checkColor: AppTheme.primaryBlue,
              fillColor: const WidgetStatePropertyAll(AppTheme.white),
            ),
          ),
          _tableColumn('DATE / TRIP', 12, header: true),
          _tableColumn('ORIGIN', 15, header: true),
          _tableColumn('DESTINATION', 15, header: true),
          _tableColumn('CLIENT', 15, header: true),
          _tableColumn('DRIVER', 12, header: true),
          _tableColumn('VEHICLE', 10, header: true),
          _tableColumn('STATUS', 10, header: true),
          _tableColumn('ACTIONS', 11, header: true),
        ],
      ),
    );
  }

  Widget _tableColumn(
    String text,
    int flex, {
    bool header = false,
    TextAlign textAlign = TextAlign.left,
    FontWeight? weight,
    Color? color,
  }) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(
          text,
          textAlign: textAlign,
          maxLines: header ? 1 : 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: header ? 12 : 13,
            fontWeight: header ? FontWeight.w700 : weight,
            color: header ? AppTheme.white : color,
          ),
        ),
      ),
    );
  }

  Widget _buildTableRow(Map<String, dynamic> trip, bool isDark, int index) {
    final tripId = trip['tripId']?.toString() ?? '';
    final selected = _selectedTripIds.contains(tripId);
    final statusPresentation = WorkflowStatusHelper.trip(trip['status']);
    final statusColor = statusPresentation.color;
    final canChange =
        CrudPermissions.canEdit(CrudEntity.trips) && _tripCanChange(trip);
    return InkWell(
      onTap: () => _showTripDetails(trip),
      child: Container(
        constraints: const BoxConstraints(minHeight: 60),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.colorFF4B7BE5.withValues(alpha: 0.10)
              : isDark
              ? (index.isEven ? AppTheme.colorFF1A1D23 : AppTheme.colorFF171B23)
              : (index.isEven ? AppTheme.white : AppTheme.colorFFF8FBFF),
          border: Border(
            bottom: BorderSide(
              color: isDark
                  ? AppTheme.white.withValues(alpha: 0.06)
                  : AppTheme.black.withValues(alpha: 0.06),
            ),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              child: Checkbox(
                value: selected,
                onChanged: (value) =>
                    _toggleTripSelection(tripId, value == true),
              ),
            ),
            Expanded(
              flex: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${trip['date'] ?? ''}',
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tripId,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.colorFF4B7BE5,
                    ),
                  ),
                ],
              ),
            ),
            _tableColumn(
              '${trip['origin'] ?? ''}',
              15,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
            _tableColumn(
              '${trip['destination'] ?? ''}',
              15,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
            _tableColumn(
              '${trip['customer'] ?? ''}',
              15,
              weight: FontWeight.w600,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
            _tableColumn(
              '${trip['driver'] ?? ''}',
              12,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
            _tableColumn(
              '${trip['vehicle'] ?? ''}',
              10,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
            Expanded(
              flex: 10,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      statusPresentation.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: statusColor,
                        decoration: statusPresentation.strikethrough
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 11,
              child: Align(
                alignment: Alignment.centerLeft,
                child: PopupMenuButton<_TripListAction>(
                  tooltip: 'Trip actions',
                  onSelected: (action) => _handleTripAction(action, trip),
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: _TripListAction.view,
                      child: Text('View Details'),
                    ),
                    if (canChange)
                      const PopupMenuItem(
                        value: _TripListAction.edit,
                        child: Text('Edit'),
                      ),
                    if (canChange && _tripPhase(trip) < 12)
                      const PopupMenuItem(
                        value: _TripListAction.advance,
                        child: Text('Advance Phase'),
                      ),
                    if (canChange)
                      const PopupMenuItem(
                        value: _TripListAction.cancel,
                        child: Text('Cancel'),
                      ),
                  ],
                  icon: Icon(
                    Icons.more_vert_rounded,
                    color: isDark ? AppTheme.gray300 : AppTheme.gray700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoColumn(String label, String value, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: isDark ? AppTheme.gray500 : AppTheme.gray600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _buildRouteInfo(Map<String, dynamic> trip, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: AppTheme.colorFF27AE60,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                trip['origin'],
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
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
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: AppTheme.colorFFE74C3C,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                trip['destination'],
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 80,
            color: isDark ? AppTheme.gray700 : AppTheme.gray300,
          ),
          const SizedBox(height: 24),
          Text(
            'No trips found',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.gray600 : AppTheme.gray400,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _searchQuery.isNotEmpty
                ? 'Try adjusting your search'
                : 'No trips match the selected filter',
            style: TextStyle(
              fontSize: 14,
              color: isDark ? AppTheme.gray500 : AppTheme.gray500,
            ),
          ),
        ],
      ),
    );
  }

  void _showTripDetails(Map<String, dynamic> trip) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TripDetailsPage(trip: trip)),
    );
  }

  String _getStatusText(String status) {
    return WorkflowStatusHelper.trip(status).label;
  }
}

// ============================================
// TRIP DETAILS PAGE WITH KEBAB MENU
// ============================================

class TripDetailsPage extends StatefulWidget {
  final Map trip;
  const TripDetailsPage({super.key, required this.trip});

  @override
  State<TripDetailsPage> createState() => _TripDetailsPageState();
}

class _TripDetailsPageState extends State<TripDetailsPage> {
  late Map<String, dynamic> trip;
  late Future<Map<String, dynamic>> _tripMapFuture;

  @override
  void initState() {
    super.initState();
    trip = Map<String, dynamic>.from(widget.trip);
    _tripMapFuture = _loadTripMap(forceRefresh: true);
    tripsNotifier.addListener(_onTripsChanged);
  }

  @override
  void dispose() {
    tripsNotifier.removeListener(_onTripsChanged);
    super.dispose();
  }

  void _onTripsChanged() {
    Map<String, dynamic>? updatedTrip;
    try {
      updatedTrip =
          tripsNotifier.value.firstWhere(
                (t) => t['tripId'] == widget.trip['tripId'],
              )
              as Map<String, dynamic>?;
    } catch (e) {
      updatedTrip = null;
    }
    if (updatedTrip != null && mounted) {
      setState(() {
        trip = updatedTrip!;
        _tripMapFuture = _loadTripMap(forceRefresh: true);
      });
    }
  }

  Future<Map<String, dynamic>> _loadTripMap({bool forceRefresh = false}) {
    final tripId = trip['tripId']?.toString().trim() ?? '';
    if (tripId.isEmpty) {
      return Future.value(const <String, dynamic>{});
    }

    return BackendApiService.getTripMap(tripId, forceRefresh: forceRefresh);
  }

  Map<String, dynamic>? _cachedTripMap() {
    final tripId = trip['tripId']?.toString().trim() ?? '';
    if (tripId.isEmpty) {
      return null;
    }
    return BackendApiService.peekCachedDataMap('/fleet/trips/$tripId/map');
  }

  Widget _buildTripMapSection(
    bool isDark,
    bool isMobile,
    Map<String, dynamic> data,
  ) {
    final actualTrail = ((data['actualTrail'] as List?) ?? const [])
        .whereType<Map>()
        .map(_latLngFromMap)
        .whereType<gmaps.LatLng>()
        .toList();
    final plannedPath = ((data['plannedPath'] as List?) ?? const [])
        .whereType<Map>()
        .map(_latLngFromMap)
        .whereType<gmaps.LatLng>()
        .toList();
    final geofences = ((data['geofences'] as List?) ?? const [])
        .whereType<Map>()
        .map(_polygonFromGeofence)
        .whereType<gmaps.Polygon>()
        .toList();

    gmaps.LatLng center = const gmaps.LatLng(14.5995, 120.9842);
    if (actualTrail.isNotEmpty) {
      center = actualTrail.last;
    } else if (plannedPath.isNotEmpty) {
      center = plannedPath.first;
    }

    final routeStops = ((data['routeStops'] as List?) ?? const [])
        .whereType<Map>()
        .toList();
    final completed =
        data['status']?.toString().trim().toLowerCase() == 'completed';
    final canRenderMap = actualTrail.length > 1 || plannedPath.length > 1;
    final routeMessage =
        data['routeMessage']?.toString().trim().isNotEmpty == true
        ? data['routeMessage'].toString()
        : tripMapInsufficientPointsMessage;

    if (!canRenderMap) {
      return _buildSection(isDark, 'Trip Map', [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: isDark
                ? AppTheme.white.withValues(alpha: 0.04)
                : AppTheme.colorFFF8FAFC,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark
                  ? AppTheme.white.withValues(alpha: 0.08)
                  : AppTheme.black.withValues(alpha: 0.08),
            ),
          ),
          child: Text(
            routeMessage,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.gray300 : AppTheme.colorFF5A6070,
            ),
          ),
        ),
      ], isMobile);
    }

    return _buildSection(isDark, 'Trip Map', [
      Container(
        height: isMobile ? 260 : 340,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark
                ? AppTheme.white.withValues(alpha: 0.08)
                : AppTheme.black.withValues(alpha: 0.08),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: PioneerGoogleMap(
          initialCenter: center,
          initialZoom: 13,
          zoomControlsEnabled: false,
          polygons: geofences.toSet(),
          polylines: {
            if (plannedPath.length > 1)
              gmaps.Polyline(
                polylineId: const gmaps.PolylineId('planned-path'),
                points: plannedPath,
                color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.85),
                width: 3,
              ),
            if (actualTrail.length > 1)
              gmaps.Polyline(
                polylineId: const gmaps.PolylineId('actual-trail'),
                points: actualTrail,
                color: AppTheme.colorFF1A3A6B,
                width: 4,
              ),
          },
          markers: {
            if (actualTrail.isNotEmpty)
              gmaps.Marker(
                markerId: const gmaps.MarkerId('actual-start'),
                position: actualTrail.first,
                icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
                  gmaps.BitmapDescriptor.hueGreen,
                ),
                infoWindow: const gmaps.InfoWindow(title: 'Trip start'),
              ),
            if (actualTrail.length > 1)
              gmaps.Marker(
                markerId: const gmaps.MarkerId('actual-end'),
                position: actualTrail.last,
                icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
                  completed
                      ? gmaps.BitmapDescriptor.hueRed
                      : gmaps.BitmapDescriptor.hueAzure,
                ),
                infoWindow: gmaps.InfoWindow(
                  title: completed ? 'Actual end' : 'Current position',
                ),
              ),
            if (actualTrail.length < 2 && plannedPath.isNotEmpty)
              gmaps.Marker(
                markerId: const gmaps.MarkerId('planned-start'),
                position: plannedPath.first,
                icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
                  gmaps.BitmapDescriptor.hueGreen,
                ),
                infoWindow: const gmaps.InfoWindow(title: 'Planned start'),
              ),
            if (actualTrail.length < 2 && plannedPath.length > 1)
              gmaps.Marker(
                markerId: const gmaps.MarkerId('planned-destination'),
                position: plannedPath.last,
                icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
                  gmaps.BitmapDescriptor.hueRed,
                ),
                infoWindow: const gmaps.InfoWindow(title: 'Destination'),
              ),
            ..._routeStopMarkers(routeStops, actualTrail.length < 2),
          },
        ),
      ),
      const SizedBox(height: 12),
      if (actualTrail.length < 2 && plannedPath.length > 1) ...[
        _tripMapNotice(isDark, routeMessage),
        const SizedBox(height: 12),
      ],
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _tripMapChip(
            isDark,
            'Actual trail',
            actualTrail.length > 1
                ? '${actualTrail.length} points'
                : 'No log trail',
            AppTheme.colorFF27AE60,
          ),
          _tripMapChip(
            isDark,
            'Planned route',
            plannedPath.length > 1
                ? '${plannedPath.length} waypoints'
                : 'No planned path',
            AppTheme.colorFF4B7BE5,
          ),
          _tripMapChip(
            isDark,
            'Geofences',
            '${geofences.length} zones',
            AppTheme.colorFFF39C12,
          ),
        ],
      ),
      if (routeStops.isNotEmpty) ...[
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: routeStops.take(6).map((stop) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                stop['name']?.toString() ?? 'Route stop',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.colorFF4B7BE5,
                ),
              ),
            );
          }).toList(),
        ),
      ],
    ], isMobile);
  }

  Widget _buildTripMapSkeleton(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Trip Map',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
          ),
        ),
        const SizedBox(height: 16),
        Container(
          height: 360,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF8FAFD,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isDark
                  ? AppTheme.white.withValues(alpha: 0.08)
                  : AppTheme.black.withValues(alpha: 0.08),
            ),
          ),
          child: const ShimmerLoading(height: double.infinity),
        ),
      ],
    );
  }

  Widget _tripMapChip(bool isDark, String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: isDark ? AppTheme.gray400 : AppTheme.gray700,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tripMapNotice(bool isDark, String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.20),
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
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: isDark ? AppTheme.gray200 : AppTheme.colorFF1F2937,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Set<gmaps.Marker> _routeStopMarkers(List<Map> routeStops, bool showStops) {
    if (!showStops) {
      return const <gmaps.Marker>{};
    }

    return routeStops.indexed
        .map((entry) {
          final (index, stop) = entry;
          final center = _latLngFromMap((stop['center'] as Map?) ?? const {});
          if (center == null) {
            return null;
          }

          return gmaps.Marker(
            markerId: gmaps.MarkerId('route-stop-$index'),
            position: center,
            icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
              gmaps.BitmapDescriptor.hueOrange,
            ),
            infoWindow: gmaps.InfoWindow(
              title: stop['name']?.toString() ?? 'Stop ${index + 1}',
            ),
          );
        })
        .whereType<gmaps.Marker>()
        .toSet();
  }

  gmaps.LatLng? _latLngFromMap(Map raw) {
    final latitude = (raw['latitude'] as num?)?.toDouble();
    final longitude = (raw['longitude'] as num?)?.toDouble();
    if (latitude == null || longitude == null) {
      return null;
    }

    return gmaps.LatLng(latitude, longitude);
  }

  gmaps.Polygon? _polygonFromGeofence(Map raw) {
    final points = ((raw['points'] as List?) ?? const [])
        .whereType<Map>()
        .map(_latLngFromMap)
        .whereType<gmaps.LatLng>()
        .toList();

    if (points.length < 3) {
      return null;
    }

    return gmaps.Polygon(
      polygonId: gmaps.PolygonId(
        raw['id']?.toString() ?? raw['name']?.toString() ?? 'geofence',
      ),
      points: points,
      fillColor: AppTheme.colorFF4B7BE5.withValues(alpha: 0.08),
      strokeWidth: 2,
      strokeColor: AppTheme.colorFF4B7BE5.withValues(alpha: 0.45),
    );
  }

  void _showKebabMenu(BuildContext context, bool isDark) {
    final status = trip['status'].toString().toLowerCase();
    final normalizedStatus = status.replaceAll(' ', '');
    final roleCanEditTrips = CrudPermissions.canEdit(CrudEntity.trips);
    final canEdit =
        roleCanEditTrips &&
        normalizedStatus != 'completed' &&
        normalizedStatus != 'cancelled' &&
        normalizedStatus != 'canceled';
    final canAdvance = canEdit && _workflowPhaseNumber(trip) < 12;

    showMenu(
      context: context,
      position: const RelativeRect.fromLTRB(1000, 100, 0, 0),
      color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        PopupMenuItem(
          enabled: canEdit,
          child: Row(
            children: [
              Icon(
                Icons.edit_rounded,
                size: 18,
                color: canEdit
                    ? (isDark ? AppTheme.white : AppTheme.colorFF2C3E50)
                    : AppTheme.gray600,
              ),
              const SizedBox(width: 12),
              Text(
                'Edit Trip',
                style: TextStyle(
                  fontSize: 14,
                  color: canEdit
                      ? (isDark ? AppTheme.white : AppTheme.colorFF2C3E50)
                      : AppTheme.gray600,
                ),
              ),
            ],
          ),
          onTap: canEdit
              ? () {
                  Future.delayed(
                    Duration.zero,
                    () => showDialog(
                      context: context,
                      builder: (ctx) => _TripLifecycleDialog(
                        initialTrip: trip,
                        onSave: (updatedTrip) async {
                          await updateTrip(
                            trip['tripId'] as String,
                            updatedTrip,
                          );
                        },
                      ),
                    ),
                  );
                }
              : null,
        ),
        PopupMenuItem(
          enabled: canAdvance,
          child: Row(
            children: [
              Icon(
                Icons.skip_next_rounded,
                size: 18,
                color: canAdvance ? AppTheme.colorFF4B7BE5 : AppTheme.gray600,
              ),
              const SizedBox(width: 12),
              Text(
                'Next Phase',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: canAdvance ? FontWeight.w700 : FontWeight.normal,
                  color: canAdvance ? AppTheme.colorFF4B7BE5 : AppTheme.gray600,
                ),
              ),
            ],
          ),
          onTap: canAdvance
              ? () {
                  Future.delayed(
                    Duration.zero,
                    () => _showAdvanceWorkflowConfirmation(context, isDark),
                  );
                }
              : null,
        ),
        PopupMenuItem(
          // Allow upload for dispatched / in-progress only; completed and pending_approval should not allow upload
          enabled:
              roleCanEditTrips &&
              (status == 'dispatched' ||
                  status == 'inprogress' ||
                  status == 'in progress'),
          child: Row(
            children: [
              Icon(
                Icons.upload_file_rounded,
                size: 18,
                color: status != 'pending' && status != 'pending_approval'
                    ? (isDark ? AppTheme.white : AppTheme.colorFF2C3E50)
                    : AppTheme.gray600,
              ),
              const SizedBox(width: 12),
              Text(
                'Upload Proof',
                style: TextStyle(
                  fontSize: 14,
                  color:
                      (status == 'dispatched' ||
                          status == 'inprogress' ||
                          status == 'in progress')
                      ? (isDark ? AppTheme.white : AppTheme.colorFF2C3E50)
                      : AppTheme.gray600,
                ),
              ),
            ],
          ),
          onTap:
              roleCanEditTrips &&
                  (status == 'dispatched' ||
                      status == 'inprogress' ||
                      status == 'in progress')
              ? () {
                  Future.delayed(
                    Duration.zero,
                    () => _showUploadProofModal(context, isDark),
                  );
                }
              : null,
        ),
        // â”€â”€ Review & Approve (for pending_approval trips) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        PopupMenuItem(
          enabled: status == 'pending_approval',
          child: Row(
            children: [
              Icon(
                Icons.fact_check_rounded,
                size: 18,
                color: status == 'pending_approval'
                    ? AppTheme.colorFF27AE60
                    : AppTheme.gray600,
              ),
              const SizedBox(width: 12),
              Text(
                'Review & Approve',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: status == 'pending_approval'
                      ? FontWeight.w600
                      : FontWeight.normal,
                  color: status == 'pending_approval'
                      ? AppTheme.colorFF27AE60
                      : AppTheme.gray600,
                ),
              ),
            ],
          ),
          onTap: status == 'pending_approval'
              ? () {
                  Future.delayed(
                    Duration.zero,
                    () => _showApprovalSignOffModal(context, isDark),
                  );
                }
              : null,
        ),
        PopupMenuItem(
          enabled: canEdit,
          child: Row(
            children: [
              Icon(
                Icons.cancel_rounded,
                size: 18,
                color: canEdit ? AppTheme.colorFFE74C3C : AppTheme.gray600,
              ),
              const SizedBox(width: 12),
              Text(
                'Cancel Trip',
                style: TextStyle(
                  fontSize: 14,
                  color: canEdit ? AppTheme.colorFFE74C3C : AppTheme.gray600,
                ),
              ),
            ],
          ),
          onTap: canEdit
              ? () {
                  Future.delayed(
                    Duration.zero,
                    () => _showCancelConfirmationDialog(context, isDark),
                  );
                }
              : null,
        ),
      ],
    );
  }

  void _showUploadProofModal(BuildContext context, bool isDark) {
    showDialog(
      context: context,
      builder: (ctx) => _UploadProofDialog(trip: trip, isDark: isDark),
    );
  }

  void _showApprovalSignOffModal(BuildContext context, bool isDark) {
    showDialog(
      context: context,
      builder: (ctx) => _ApprovalSignOffDialog(trip: trip, isDark: isDark),
    );
  }

  void _showAdvanceWorkflowConfirmation(BuildContext context, bool isDark) {
    final currentPhase = _workflowPhaseNumber(trip);
    final nextPhase = (currentPhase + 1).clamp(1, 12);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Advance workflow phase?',
          style: TextStyle(
            color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          'Trip ${trip['tripId']} will move from phase $currentPhase to phase $nextPhase.',
          style: TextStyle(color: isDark ? AppTheme.gray300 : AppTheme.gray700),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Keep Current',
              style: TextStyle(
                color: isDark ? AppTheme.gray300 : AppTheme.gray700,
              ),
            ),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              final updates = <String, dynamic>{
                'workflowPhaseNumber': nextPhase,
                if (nextPhase >= 10 && nextPhase < 12) 'status': 'dispatched',
                if (nextPhase == 12) 'status': 'completed',
              };
              try {
                await updateTrip(trip['tripId'] as String, updates);
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    behavior: SnackBarBehavior.floating,
                    content: Text(
                      nextPhase == 12
                          ? 'Trip completed. Billing is now available for this trip.'
                          : 'Trip advanced to workflow phase $nextPhase.',
                    ),
                  ),
                );
              } catch (error) {
                if (!ctx.mounted) return;
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(
                    behavior: SnackBarBehavior.floating,
                    content: Text(
                      FormValidation.backendError(
                        error,
                        'Trip phase was not updated.',
                      ),
                    ),
                  ),
                );
              }
            },
            icon: const Icon(Icons.skip_next_rounded, size: 16),
            label: const Text('Next Phase'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.colorFF4B7BE5,
              foregroundColor: AppTheme.white,
            ),
          ),
        ],
      ),
    );
  }

  void _showCancelConfirmationDialog(BuildContext context, bool isDark) {
    final formKey = GlobalKey<FormState>();
    final reasonController = TextEditingController();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: AppTheme.transparent,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: isDark
                      ? AppTheme.colorFF252930
                      : AppTheme.colorFFF8F9FA,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Cancel Trip',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                      ),
                    ),
                    GestureDetector(
                      onTap: () => Navigator.pop(ctx),
                      child: Icon(
                        Icons.close_rounded,
                        color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                        size: 20,
                      ),
                    ),
                  ],
                ),
              ),
              // Body
              Padding(
                padding: const EdgeInsets.all(20),
                child: Form(
                  key: formKey,
                  child: Column(
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: AppTheme.colorFFE74C3C.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.warning_rounded,
                          color: AppTheme.colorFFE74C3C,
                          size: 28,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Are you sure you want to cancel this trip?',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? AppTheme.white
                              : AppTheme.colorFF2C3E50,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Trip ${trip['tripId']} will stay in history with a Cancelled badge and will be excluded from dispatch and live tracking.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: reasonController,
                        maxLines: 3,
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? 'Cancellation reason is required'
                            : null,
                        style: TextStyle(
                          color: isDark
                              ? AppTheme.white
                              : AppTheme.colorFF2C3E50,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Cancellation reason',
                          labelStyle: TextStyle(
                            color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                          ),
                          filled: true,
                          fillColor: isDark
                              ? AppTheme.colorFF0F1117
                              : AppTheme.colorFFF8F9FA,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Footer - Buttons
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: isDark
                          ? AppTheme.white.withValues(alpha: 0.1)
                          : AppTheme.black.withValues(alpha: 0.1),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 44,
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                              color: isDark
                                  ? AppTheme.gray600
                                  : AppTheme.gray300,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: Text(
                            'Keep Trip',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? AppTheme.white
                                  : AppTheme.colorFF2C3E50,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 44,
                        child: ElevatedButton(
                          onPressed: () async {
                            if (!formKey.currentState!.validate()) {
                              return;
                            }
                            try {
                              await updateTrip(trip['tripId'] as String, {
                                'status': 'cancelled',
                                'statusColor': AppTheme.colorFF6B7280,
                                'cancellationReason': reasonController.text
                                    .trim(),
                                'cancelledAt': DateTime.now().toIso8601String(),
                              });
                              if (!ctx.mounted) return;
                              Navigator.pop(ctx);
                              Navigator.pop(context);
                            } catch (error) {
                              if (!ctx.mounted) return;
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                SnackBar(
                                  behavior: SnackBarBehavior.floating,
                                  content: Text(
                                    FormValidation.backendError(
                                      error,
                                      'Trip could not be cancelled.',
                                    ),
                                  ),
                                ),
                              );
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.colorFFE74C3C,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: const Text(
                            'Cancel Trip',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMobile = MediaQuery.of(context).size.width < 600;

    return DashboardLayout(
      currentRoute: '/trips',
      title: 'Trip Details',
      subtitle: trip['tripId'] ?? '',
      actions: [
        OutlinedButton.icon(
          onPressed: _printTripManifest,
          icon: const Icon(Icons.assignment_rounded),
          label: const Text('Print Manifest'),
        ),
        if (_isCompletedTrip)
          FilledButton.icon(
            onPressed: _printDeliveryReceipt,
            icon: const Icon(Icons.receipt_long_rounded),
            label: const Text('Delivery Receipt'),
          ),
        IconButton(
          icon: Icon(
            Icons.arrow_back_rounded,
            color: isDark ? AppTheme.gray400 : AppTheme.gray700,
          ),
          onPressed: () => Navigator.pop(context),
          tooltip: 'Back to Trips',
        ),
      ],
      child: SingleChildScrollView(
        padding: EdgeInsets.all(isMobile ? 16 : 24),
        child:
            Container(
                  padding: EdgeInsets.all(isMobile ? 20 : 28),
                  decoration: BoxDecoration(
                    color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isDark
                          ? AppTheme.white.withValues(alpha: 0.08)
                          : AppTheme.black.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // â”€â”€ Header: tripId + status + kebab â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                      if (isMobile) ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  trip['tripId'],
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w900,
                                    color: isDark
                                        ? AppTheme.white
                                        : AppTheme.colorFF2C3E50,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  trip['date'],
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: isDark
                                        ? AppTheme.gray400
                                        : AppTheme.gray600,
                                  ),
                                ),
                              ],
                            ),
                            IconButton(
                              onPressed: () => _showKebabMenu(context, isDark),
                              icon: Icon(
                                Icons.more_vert_rounded,
                                color: isDark
                                    ? AppTheme.gray400
                                    : AppTheme.gray600,
                              ),
                              style: IconButton.styleFrom(
                                backgroundColor: isDark
                                    ? AppTheme.colorFF0F1117
                                    : AppTheme.colorFFF5F6F8,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: (trip['statusColor'] as Color).withValues(
                              alpha: 0.15,
                            ),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: (trip['statusColor'] as Color).withValues(
                                alpha: 0.3,
                              ),
                              width: 2,
                            ),
                          ),
                          child: Text(
                            _getStatusText(trip['status']),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: trip['statusColor'] as Color,
                            ),
                          ),
                        ),
                      ] else
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    trip['tripId'],
                                    style: TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.w900,
                                      color: isDark
                                          ? AppTheme.white
                                          : AppTheme.colorFF2C3E50,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    trip['date'],
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: isDark
                                          ? AppTheme.gray400
                                          : AppTheme.gray600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: (trip['statusColor'] as Color)
                                        .withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: (trip['statusColor'] as Color)
                                          .withValues(alpha: 0.3),
                                      width: 2,
                                    ),
                                  ),
                                  child: Text(
                                    _getStatusText(trip['status']),
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: trip['statusColor'] as Color,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                IconButton(
                                  onPressed: () =>
                                      _showKebabMenu(context, isDark),
                                  icon: Icon(
                                    Icons.more_vert_rounded,
                                    color: isDark
                                        ? AppTheme.gray400
                                        : AppTheme.gray600,
                                  ),
                                  style: IconButton.styleFrom(
                                    backgroundColor: isDark
                                        ? AppTheme.colorFF0F1117
                                        : AppTheme.colorFFF5F6F8,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      const SizedBox(height: 32),
                      _buildSection(isDark, 'Customer Information', [
                        _buildInfoRow(
                          'Customer',
                          trip['customer'],
                          isDark,
                          isMobile,
                        ),
                        _buildInfoRow('Phone', trip['phone'], isDark, isMobile),
                      ], isMobile),
                      const SizedBox(height: 24),
                      _buildSection(isDark, 'Route Details', [
                        _buildInfoRow(
                          'Origin',
                          trip['origin'],
                          isDark,
                          isMobile,
                        ),
                        _buildInfoRow(
                          'Destination',
                          trip['destination'],
                          isDark,
                          isMobile,
                        ),
                      ], isMobile),
                      const SizedBox(height: 24),
                      _buildWorkflowTimeline(isDark, isMobile),
                      const SizedBox(height: 24),
                      FutureBuilder<Map<String, dynamic>>(
                        future: _tripMapFuture,
                        initialData: _cachedTripMap(),
                        builder: (context, snapshot) {
                          if (snapshot.connectionState ==
                                  ConnectionState.waiting &&
                              !snapshot.hasData) {
                            return _buildTripMapSkeleton(isDark);
                          }

                          return _buildTripMapSection(
                            isDark,
                            isMobile,
                            snapshot.data ?? const <String, dynamic>{},
                          );
                        },
                      ),
                      const SizedBox(height: 24),
                      _buildSection(isDark, 'Trip Details', [
                        isMobile
                            ? Column(
                                children: [
                                  _buildInfoBlock(
                                    'Vehicle',
                                    trip['vehicle'],
                                    isDark,
                                  ),
                                  const SizedBox(height: 12),
                                  _buildInfoBlock(
                                    'Driver',
                                    trip['driver'],
                                    isDark,
                                  ),
                                  const SizedBox(height: 12),
                                  _buildInfoBlock(
                                    'Amount',
                                    trip['amount'],
                                    isDark,
                                  ),
                                ],
                              )
                            : Row(
                                children: [
                                  Expanded(
                                    child: _buildInfoBlock(
                                      'Vehicle',
                                      trip['vehicle'],
                                      isDark,
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: _buildInfoBlock(
                                      'Driver',
                                      trip['driver'],
                                      isDark,
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: _buildInfoBlock(
                                      'Amount',
                                      trip['amount'],
                                      isDark,
                                    ),
                                  ),
                                ],
                              ),
                      ], isMobile),
                      if (trip['hasDelay']) ...[
                        const SizedBox(height: 24),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: AppTheme.colorFFE74C3C.withValues(
                              alpha: 0.1,
                            ),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: AppTheme.colorFFE74C3C.withValues(
                                alpha: 0.3,
                              ),
                              width: 2,
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.warning_rounded,
                                color: AppTheme.colorFFE74C3C,
                                size: 24,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Delay Warning',
                                      style: TextStyle(
                                        color: AppTheme.colorFFE74C3C,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      trip['delay'] ?? '',
                                      style: const TextStyle(
                                        color: AppTheme.colorFFE74C3C,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                )
                .animate()
                .fadeIn(duration: 500.ms)
                .slideY(
                  begin: 0.2,
                  end: 0,
                  duration: 500.ms,
                  curve: Curves.easeOut,
                ),
      ),
    );
  }

  Widget _buildSection(
    bool isDark,
    String title,
    List<Widget> children,
    bool isMobile,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: isMobile ? 16 : 18,
            fontWeight: FontWeight.w700,
            color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
          ),
        ),
        const SizedBox(height: 16),
        ...children,
      ],
    );
  }

  Widget _buildWorkflowTimeline(bool isDark, bool isMobile) {
    final rawSteps = (trip['workflowSteps'] as List?) ?? const [];
    final steps = rawSteps
        .whereType<Map>()
        .map((step) => Map<String, dynamic>.from(step))
        .toList();
    final visibleSteps = steps.isEmpty ? <Map<String, dynamic>>[] : steps;
    final phase =
        trip['workflowPhaseLabel']?.toString().trim().isNotEmpty == true
        ? trip['workflowPhaseLabel'].toString()
        : 'Delivery trip workflow';
    final next =
        trip['workflowNextAction']?.toString().trim().isNotEmpty == true
        ? trip['workflowNextAction'].toString()
        : 'Confirm the next handoff before dispatch.';

    return _buildSection(isDark, 'Delivery Trip Workflow', [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF8FAFD,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark
                ? AppTheme.white.withValues(alpha: 0.08)
                : AppTheme.black.withValues(alpha: 0.08),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _workflowChip('Phase', phase, AppTheme.colorFF4B7BE5, isDark),
                _workflowChip(
                  'Delivery method',
                  trip['fulfillmentLabel']?.toString() ?? 'TBA',
                  AppTheme.colorFF10B981,
                  isDark,
                ),
                _workflowChip(
                  'Delivery value',
                  trip['orderValueLabel']?.toString() ?? 'PHP 0.00',
                  AppTheme.colorFFF59E0B,
                  isDark,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              next,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: isDark ? AppTheme.white70 : AppTheme.colorFF475569,
              ),
            ),
            if (visibleSteps.isNotEmpty) ...[
              const SizedBox(height: 14),
              WorkflowTimeline(
                steps: visibleSteps,
                currentPhaseNumber: _workflowPhaseNumber(trip),
              ),
            ],
          ],
        ),
      ),
    ], isMobile);
  }

  bool get _isCompletedTrip {
    final status = trip['status']?.toString().trim().toLowerCase() ?? '';
    return status == 'completed' || status == 'complete';
  }

  Future<void> _printTripManifest() async {
    final ok = await printHtmlDocument(
      'Trip Manifest ${_field('tripId')}',
      _tripManifestHtml(),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Trip manifest opened for printing.'
              : 'Trip manifest printing is available in the web build.',
        ),
      ),
    );
  }

  Future<void> _printDeliveryReceipt() async {
    final ok = await printHtmlDocument(
      'Delivery Receipt ${_field('tripId')}',
      _deliveryReceiptHtml(),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Delivery receipt opened for printing.'
              : 'Delivery receipt printing is available in the web build.',
        ),
      ),
    );
  }

  String _tripManifestHtml() {
    final route = _field('routeName', fallback: _field('assignedRoute'));
    return '''
      <h1>PioneerPath Trip Manifest</h1>
      <div class="muted">Generated ${_escapeHtml(DateTime.now().toLocal())}</div>
      <div class="grid">
        ${_printField('Trip ID', _field('tripId'))}
        ${_printField('Status', _getStatusText(_field('status')))}
        ${_printField('Vehicle Plate', _field('vehicle'))}
        ${_printField('Driver', _field('driver'))}
        ${_printField('Client', _field('customer'))}
        ${_printField('Departure Time', _field('scheduledDeparture', fallback: _field('date')))}
        ${_printField('Origin', _field('origin'))}
        ${_printField('Destination', _field('destination'))}
        ${_printField('Cargo Type', _field('cargoType'))}
        ${_printField('Cargo Weight', _field('cargoWeightKg', fallback: _field('cargoWeight')))}
        ${_printField('Assigned Route', route.isEmpty ? 'Not assigned' : route)}
        ${_printField('Order Value', _field('orderValueLabel', fallback: _field('amount')))}
      </div>
      <h2>Special Instructions</h2>
      <div class="box">${_escapeHtml(_field('specialInstructions', fallback: 'No special instructions recorded.'))}</div>
    ''';
  }

  String _deliveryReceiptHtml() {
    return '''
      <h1>PioneerPath Delivery Receipt</h1>
      <div class="muted">Generated ${_escapeHtml(DateTime.now().toLocal())}</div>
      <div class="grid">
        ${_printField('Trip ID', _field('tripId'))}
        ${_printField('Client', _field('customer'))}
        ${_printField('Destination', _field('destination'))}
        ${_printField('Vehicle Plate', _field('vehicle'))}
        ${_printField('Driver', _field('driver'))}
        ${_printField('Arrival Time', _field('arrivalTime', fallback: _field('completedAt', fallback: _field('estimatedArrival'))))}
        ${_printField('POD Reference', _field('podPhotoReference', fallback: _field('podReference', fallback: 'Attach photo or signed document reference')))}
        ${_printField('DR Number', _field('drNumber', fallback: 'For ERP entry'))}
      </div>
      <h2>Delivery Confirmation</h2>
      <div class="box">Delivery has been marked completed in PioneerPath. Verify the signed documents and POD photo before final ERP posting.</div>
      <h2>Driver Signature</h2>
      <div class="signature"></div>
      <div class="muted">Driver name and signature</div>
    ''';
  }

  String _printField(String label, String value) {
    return '''
      <div>
        <div class="label">${_escapeHtml(label)}</div>
        <div class="value">${_escapeHtml(value.trim().isEmpty ? 'N/A' : value)}</div>
      </div>
    ''';
  }

  String _field(String key, {String fallback = ''}) {
    final value = trip[key];
    if (value == null) return fallback;
    final text = value.toString().trim();
    return text.isEmpty ? fallback : text;
  }

  String _escapeHtml(Object? value) {
    return (value?.toString() ?? '')
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  Widget _workflowChip(String label, String value, Color color, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w900,
          color: color,
        ),
      ),
    );
  }

  int _workflowPhaseNumber(Map<String, dynamic> trip) {
    final raw = trip['workflowPhaseNumber'];
    if (raw is num) return raw.toInt().clamp(1, 12);
    final parsed = int.tryParse(raw?.toString() ?? '');
    return (parsed ?? 7).clamp(1, 12);
  }

  Widget _buildInfoRow(
    String label,
    String? value,
    bool isDark,
    bool isMobile,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: isMobile ? 100 : 140,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: isDark ? AppTheme.gray500 : AppTheme.gray600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value ?? '-',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoBlock(String label, String? value, bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF8FAFD,
        borderRadius: BorderRadius.circular(12),
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
            label,
            style: TextStyle(
              fontSize: 12,
              color: isDark ? AppTheme.gray500 : AppTheme.gray600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value ?? '-',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
          ),
        ],
      ),
    );
  }

  String _getStatusText(String status) {
    return WorkflowStatusHelper.trip(status).label;
  }
}

// UPLOAD PROOF MODAL
class _UploadProofDialog extends StatefulWidget {
  final Map<String, dynamic> trip;
  final bool isDark;
  const _UploadProofDialog({required this.trip, required this.isDark});

  @override
  State<_UploadProofDialog> createState() => _UploadProofDialogState();
}

class _UploadProofDialogState extends State<_UploadProofDialog> {
  bool _showSignatureForm = false;

  @override
  Widget build(BuildContext context) {
    final sw = MediaQuery.of(context).size.width;
    final isVerySmall = sw < 360;
    return Dialog(
      backgroundColor: AppTheme.transparent,
      insetPadding: EdgeInsets.symmetric(
        horizontal: isVerySmall ? 8 : 16,
        vertical: isVerySmall ? 16 : 24,
      ),
      child: Container(
        constraints: BoxConstraints(maxWidth: isVerySmall ? sw - 16 : 400),
        decoration: BoxDecoration(
          color: widget.isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
          borderRadius: BorderRadius.circular(isVerySmall ? 12 : 16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: EdgeInsets.all(isVerySmall ? 14 : 20),
              decoration: BoxDecoration(
                color: widget.isDark
                    ? AppTheme.colorFF252930
                    : AppTheme.colorFFF8F9FA,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(isVerySmall ? 12 : 16),
                  topRight: Radius.circular(isVerySmall ? 12 : 16),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _showSignatureForm
                        ? 'Customer Signature'
                        : 'Upload Delivery Proof',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: widget.isDark
                          ? AppTheme.white
                          : AppTheme.colorFF2C3E50,
                    ),
                  ),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Icon(
                        Icons.close_rounded,
                        color: widget.isDark
                            ? AppTheme.gray400
                            : AppTheme.gray600,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Body
            if (!_showSignatureForm)
              Padding(
                padding: EdgeInsets.all(isVerySmall ? 14 : 20),
                child: Column(
                  children: [
                    Text(
                      'Upload signature or delivery confirmation for ${widget.trip['tripId']}',
                      style: TextStyle(
                        fontSize: 13,
                        color: widget.isDark
                            ? AppTheme.gray400
                            : AppTheme.gray600,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Container(
                      height: 120,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: widget.isDark
                            ? AppTheme.colorFF0F1117
                            : AppTheme.colorFFF5F6F8,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: widget.isDark
                              ? AppTheme.white.withValues(alpha: 0.1)
                              : AppTheme.black.withValues(alpha: 0.1),
                          style: BorderStyle.solid,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.upload_file_rounded,
                            size: 40,
                            color: widget.isDark
                                ? AppTheme.gray600
                                : AppTheme.gray400,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Choose File',
                            style: TextStyle(
                              fontSize: 12,
                              color: widget.isDark
                                  ? AppTheme.gray500
                                  : AppTheme.gray600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'No file chosen',
                            style: TextStyle(
                              fontSize: 12,
                              color: widget.isDark
                                  ? AppTheme.gray600
                                  : AppTheme.gray500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        onPressed: () {
                          setState(() => _showSignatureForm = true);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.colorFF4B7BE5,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text(
                          'Sign',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else
              Padding(
                padding: EdgeInsets.all(isVerySmall ? 14 : 20),
                child: Column(
                  children: [
                    Text(
                      'Please sign below',
                      style: TextStyle(
                        fontSize: 13,
                        color: widget.isDark
                            ? AppTheme.gray400
                            : AppTheme.gray600,
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Signature Canvas Area
                    Container(
                      height: 150,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: widget.isDark
                            ? AppTheme.colorFF0F1117
                            : AppTheme.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: widget.isDark
                              ? AppTheme.white.withValues(alpha: 0.2)
                              : AppTheme.black.withValues(alpha: 0.2),
                          width: 2,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          'Signature Area',
                          style: TextStyle(
                            fontSize: 14,
                            color: widget.isDark
                                ? AppTheme.gray500
                                : AppTheme.gray400,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 48,
                            child: OutlinedButton(
                              onPressed: () async {
                                setState(() => _showSignatureForm = false);
                              },
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(
                                  color: widget.isDark
                                      ? AppTheme.gray600
                                      : AppTheme.gray300,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: Text(
                                'Back',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: widget.isDark
                                      ? AppTheme.white
                                      : AppTheme.colorFF2C3E50,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: SizedBox(
                            height: 48,
                            child: ElevatedButton(
                              onPressed: () async {
                                // Complete and Bill action - Create new billing invoice
                                final trip = widget.trip;
                                final amountStr = trip['amount']
                                    .replaceAll('PHP ', '')
                                    .replaceAll(',', '');
                                final totalAmount =
                                    double.tryParse(amountStr) ?? 0;

                                // Calculate charges that total to the amount
                                final baseRate = totalAmount * 0.40;
                                final distanceCost = totalAmount * 0.25;
                                final fuelCost = totalAmount * 0.15;
                                final driverPay = totalAmount * 0.08;
                                final helperPay = totalAmount * 0.05;
                                final tollFees = totalAmount * 0.02;

                                // Subtotal is main service charges
                                final subtotal =
                                    baseRate + distanceCost + fuelCost;
                                final serviceFee =
                                    totalAmount -
                                    subtotal -
                                    (totalAmount * 0.12);
                                final vat = totalAmount * 0.12;

                                // Generate invoice ID from trip ID
                                final tripNumber = trip['tripId'].replaceAll(
                                  'TRP-',
                                  '',
                                );
                                final invoiceId = 'INV-$tripNumber';

                                // Create new billing record
                                final newBilling = {
                                  'id': invoiceId,
                                  'invoiceNumber': invoiceId,
                                  'client': trip['customer'],
                                  'tripId': trip['tripId'],
                                  'issueDate': DateTime.now().toString().split(
                                    ' ',
                                  )[0],
                                  'dueDate': null,
                                  'status': 'sent',
                                  'amount': trip['amount'],
                                  'baseRate':
                                      'PHP ${baseRate.toStringAsFixed(2)}',
                                  'distanceCost':
                                      'PHP ${distanceCost.toStringAsFixed(2)}',
                                  'fuelCost':
                                      'PHP ${fuelCost.toStringAsFixed(2)}',
                                  'driverPay':
                                      'PHP ${driverPay.toStringAsFixed(2)}',
                                  'helperPay':
                                      'PHP ${helperPay.toStringAsFixed(2)}',
                                  'tollFees':
                                      'PHP ${tollFees.toStringAsFixed(2)}',
                                  'parking': 'PHP 50.00',
                                  'maintenanceAlloc':
                                      'PHP ${(totalAmount * 0.04).toStringAsFixed(2)}',
                                  'insuranceAlloc':
                                      'PHP ${(totalAmount * 0.02).toStringAsFixed(2)}',
                                  'subtotal':
                                      'PHP ${subtotal.toStringAsFixed(2)}',
                                  'serviceFee':
                                      'PHP ${serviceFee.toStringAsFixed(2)}',
                                  'vat': 'PHP ${vat.toStringAsFixed(2)}',
                                  'discount': '-PHP 0',
                                };

                                // Update trip status to completed and add billing

                                try {
                                  await completeTripAndFreeResources(
                                    trip['tripId'],
                                  );
                                  addBilling(newBilling);
                                  if (context.mounted) Navigator.pop(context);
                                } catch (error) {
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      behavior: SnackBarBehavior.floating,
                                      content: Text(
                                        FormValidation.backendError(
                                          error,
                                          'Trip completion could not be saved.',
                                        ),
                                      ),
                                    ),
                                  );
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.colorFF4B7BE5,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: const Text(
                                'Complete and Bill',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.white,
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

// ADMIN APPROVAL SIGN-OFF MODAL
// Shows driver's submission info + client signature status + admin signature pad.
// On Approve: calls completeTripAndFreeResources + addBilling + notifies driver.
// On Return:  reverts trip to 'dispatched' + notifies driver.
class _ApprovalSignOffDialog extends StatefulWidget {
  final Map<String, dynamic> trip;
  final bool isDark;
  const _ApprovalSignOffDialog({required this.trip, required this.isDark});

  @override
  State<_ApprovalSignOffDialog> createState() => _ApprovalSignOffDialogState();
}

class _ApprovalSignOffDialogState extends State<_ApprovalSignOffDialog> {
  final _sigKey = GlobalKey<SignaturePadState>();
  bool _sigIsEmpty = true;
  bool _submitting = false;

  Future<void> _approve() async {
    if (_sigIsEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please sign to confirm your approval.'),
          backgroundColor: AppTheme.colorFFE74C3C,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          margin: const EdgeInsets.all(16),
        ),
      );
      return;
    }
    setState(() => _submitting = true);
    await Future.delayed(const Duration(milliseconds: 600));

    final trip = widget.trip;
    final amountStr = trip['amount']
        .toString()
        .replaceAll('PHP ', '')
        .replaceAll(',', '');
    final totalAmount = double.tryParse(amountStr) ?? 0;
    final baseRate = totalAmount * 0.40;
    final distanceCost = totalAmount * 0.25;
    final fuelCost = totalAmount * 0.15;
    final driverPay = totalAmount * 0.08;
    final helperPay = totalAmount * 0.05;
    final tollFees = totalAmount * 0.02;
    final subtotal = baseRate + distanceCost + fuelCost;
    final serviceFee = totalAmount - subtotal - (totalAmount * 0.12);
    final vat = totalAmount * 0.12;
    final tripNumber = trip['tripId'].toString().replaceAll('TRP-', '');
    final invoiceId = 'INV-$tripNumber';

    // Complete trip + free resources + create billing invoice
    try {
      await completeTripAndFreeResources(trip['tripId'] as String);
    } catch (error) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            FormValidation.backendError(
              error,
              'Trip completion could not be approved.',
            ),
          ),
        ),
      );
      return;
    }
    addBilling({
      'id': invoiceId,
      'invoiceNumber': invoiceId,
      'client': trip['customer'],
      'tripId': trip['tripId'],
      'issueDate': DateTime.now().toString().split(' ')[0],
      'dueDate': null,
      'status': 'sent',
      'amount': trip['amount'],
      'baseRate': 'PHP ${baseRate.toStringAsFixed(2)}',
      'distanceCost': 'PHP ${distanceCost.toStringAsFixed(2)}',
      'fuelCost': 'PHP ${fuelCost.toStringAsFixed(2)}',
      'driverPay': 'PHP ${driverPay.toStringAsFixed(2)}',
      'helperPay': 'PHP ${helperPay.toStringAsFixed(2)}',
      'tollFees': 'PHP ${tollFees.toStringAsFixed(2)}',
      'parking': 'PHP 50.00',
      'maintenanceAlloc': 'PHP ${(totalAmount * 0.04).toStringAsFixed(2)}',
      'insuranceAlloc': 'PHP ${(totalAmount * 0.02).toStringAsFixed(2)}',
      'subtotal': 'PHP ${subtotal.toStringAsFixed(2)}',
      'serviceFee': 'PHP ${serviceFee.toStringAsFixed(2)}',
      'vat': 'PHP ${vat.toStringAsFixed(2)}',
      'discount': '-PHP 0',
    });

    // Notify driver
    final svc = NotificationService.instance;
    svc.addNotification(
      NotificationItem(
        id: svc.nextId(),
        title: 'Trip Approved \u2014 ${trip['tripId']}',
        message:
            'Your delivery to ${trip['customer']} has been approved and completed. '
            'Amount: ${trip['amount']}.',
        time: 'Just now',
        timestamp: DateTime.now(),
        category: NotificationCategory.trip,
        isRead: false,
      ),
    );

    if (mounted) Navigator.pop(context);
  }

  Future<void> _returnTrip() async {
    // Revert to dispatched so driver can resubmit
    try {
      await updateTrip(widget.trip['tripId'] as String, {
        'status': 'dispatched',
        'statusColor': AppTheme.colorFF4B7BE5,
        'driverNotes': null,
        'clientSignatureCaptured': null,
        'completionRequestedBy': null,
        'completionRequestedAt': null,
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            FormValidation.backendError(
              error,
              'Trip could not be returned for correction.',
            ),
          ),
        ),
      );
      return;
    }

    // Notify driver
    final svc = NotificationService.instance;
    svc.addNotification(
      NotificationItem(
        id: svc.nextId(),
        title: 'Trip Returned \u2014 ${widget.trip['tripId']}',
        message:
            'Your completion request for ${widget.trip['customer']} was not approved. '
            'Please contact your manager for details.',
        time: 'Just now',
        timestamp: DateTime.now(),
        category: NotificationCategory.trip,
        isRead: false,
      ),
    );

    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final trip = widget.trip;
    final isDark = widget.isDark;
    final submittedBy = trip['completionRequestedBy']?.toString() ?? '-';
    final submittedAt = trip['completionRequestedAt']?.toString() ?? '-';
    final driverNotes = trip['driverNotes']?.toString() ?? '';
    final hasSignature = trip['clientSignatureCaptured'] == true;
    final sw = MediaQuery.of(context).size.width;
    final isVerySmall = sw < 360;

    return Dialog(
      backgroundColor: AppTheme.transparent,
      insetPadding: EdgeInsets.symmetric(
        horizontal: isVerySmall ? 8 : 18,
        vertical: isVerySmall ? 16 : 24,
      ),
      child: Container(
        constraints: BoxConstraints(maxWidth: isVerySmall ? sw - 16 : 460),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
          borderRadius: BorderRadius.circular(isVerySmall ? 14 : 20),
          boxShadow: [
            BoxShadow(
              color: AppTheme.black.withValues(alpha: 0.25),
              blurRadius: 30,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // â”€â”€ HEADER â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
              Container(
                padding: EdgeInsets.all(isVerySmall ? 14 : 20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppTheme.colorFF27AE60, AppTheme.colorFF1A8A4A],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(isVerySmall ? 14 : 20),
                    topRight: Radius.circular(isVerySmall ? 14 : 20),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppTheme.white.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.fact_check_rounded,
                        color: AppTheme.white,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Review & Approve Delivery',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: AppTheme.white,
                            ),
                          ),
                          Text(
                            trip['tripId']?.toString() ?? '',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.white.withValues(alpha: 0.75),
                            ),
                          ),
                        ],
                      ),
                    ),
                    GestureDetector(
                      onTap: _submitting ? null : () => Navigator.pop(context),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: AppTheme.white.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          color: AppTheme.white,
                          size: 16,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // â”€â”€ BODY â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
              Padding(
                padding: EdgeInsets.all(isVerySmall ? 14 : 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Driver submission card
                    _ApprovalSectionLabel('Driver Submission', isDark),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: isDark
                            ? AppTheme.colorFF0F1117
                            : AppTheme.colorFFF8F9FA,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isDark
                              ? AppTheme.white.withValues(alpha: 0.07)
                              : AppTheme.black.withValues(alpha: 0.07),
                        ),
                      ),
                      child: Column(
                        children: [
                          _ApprovalInfoRow('Submitted by', submittedBy, isDark),
                          const SizedBox(height: 6),
                          _ApprovalInfoRow('Time', submittedAt, isDark),
                          if (driverNotes.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            _ApprovalInfoRow('Notes', driverNotes, isDark),
                          ],
                          const SizedBox(height: 6),
                          _ApprovalInfoRow(
                            'Route',
                            '${trip['origin'] ?? '-'} -> ${trip['destination'] ?? '-'}',
                            isDark,
                          ),
                          const SizedBox(height: 6),
                          _ApprovalInfoRow(
                            'Amount',
                            trip['amount']?.toString() ?? '-',
                            isDark,
                            valueColor: AppTheme.colorFF27AE60,
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Client signature status badge
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: hasSignature
                            ? AppTheme.colorFF27AE60.withValues(alpha: 0.08)
                            : (isDark
                                  ? AppTheme.colorFF0F1117
                                  : AppTheme.colorFFF8F9FA),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: hasSignature
                              ? AppTheme.colorFF27AE60.withValues(alpha: 0.3)
                              : (isDark
                                    ? AppTheme.white.withValues(alpha: 0.07)
                                    : AppTheme.black.withValues(alpha: 0.07)),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            hasSignature
                                ? Icons.check_circle_rounded
                                : Icons.pending_outlined,
                            color: hasSignature
                                ? AppTheme.colorFF27AE60
                                : AppTheme.materialGrey,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  hasSignature
                                      ? 'Client signature captured'
                                      : 'No client signature on record',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: hasSignature
                                        ? AppTheme.colorFF27AE60
                                        : AppTheme.materialGrey,
                                  ),
                                ),
                                if (hasSignature) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    'Driver obtained client sign-off at delivery.',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isDark
                                          ? AppTheme.gray500
                                          : AppTheme.gray600,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Admin signature section
                    Row(
                      children: [
                        _ApprovalSectionLabel('Your Signature', isDark),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.colorFFE74C3C.withValues(
                              alpha: 0.1,
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'Required to Approve',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.colorFFE74C3C,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Sign below to confirm and approve this completed trip.',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? AppTheme.gray500 : AppTheme.gray600,
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Signature canvas
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _sigIsEmpty
                              ? (isDark ? AppTheme.gray700 : AppTheme.gray300)
                              : AppTheme.colorFF27AE60.withValues(alpha: 0.6),
                          width: 2,
                        ),
                      ),
                      child: SignaturePad(
                        key: _sigKey,
                        height: 150,
                        onChanged: (empty) =>
                            setState(() => _sigIsEmpty = empty),
                      ),
                    ),

                    // Clear button
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () => _sigKey.currentState?.clear(),
                        icon: const Icon(Icons.refresh_rounded, size: 14),
                        label: const Text(
                          'Clear',
                          style: TextStyle(fontSize: 12),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: isDark
                              ? AppTheme.gray400
                              : AppTheme.gray600,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 20),

                    // â”€â”€ ACTION BUTTONS â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                    Row(
                      children: [
                        // Return / Reject button
                        Expanded(
                          child: SizedBox(
                            height: 48,
                            child: OutlinedButton.icon(
                              onPressed: _submitting ? null : _returnTrip,
                              icon: const Icon(Icons.undo_rounded, size: 16),
                              label: const Text(
                                'Return',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppTheme.colorFFE74C3C,
                                side: const BorderSide(
                                  color: AppTheme.colorFFE74C3C,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),

                        // Approve & Complete button
                        Expanded(
                          flex: 2,
                          child: SizedBox(
                            height: isVerySmall ? 42 : 48,
                            child: ElevatedButton.icon(
                              onPressed: _submitting ? null : _approve,
                              icon: _submitting
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: AppTheme.white,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.check_circle_rounded,
                                      size: 17,
                                      color: AppTheme.white,
                                    ),
                              label: Text(
                                _submitting
                                    ? 'Approving...'
                                    : 'Approve & Complete',
                                style: const TextStyle(
                                  color: AppTheme.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.colorFF27AE60,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                elevation: 0,
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
      ),
    );
  }
}

// Helper widgets for _ApprovalSignOffDialog
class _ApprovalSectionLabel extends StatelessWidget {
  final String text;
  final bool isDark;
  const _ApprovalSectionLabel(this.text, this.isDark);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
      ),
    );
  }
}

class _ApprovalInfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isDark;
  final Color? valueColor;
  const _ApprovalInfoRow(
    this.label,
    this.value,
    this.isDark, {
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: isDark ? AppTheme.gray500 : AppTheme.gray600,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color:
                  valueColor ??
                  (isDark ? AppTheme.white : AppTheme.colorFF2C3E50),
            ),
          ),
        ),
      ],
    );
  }
}

class _TripLifecycleDialog extends StatefulWidget {
  final Map<String, dynamic>? initialTrip;
  final FutureOr<void> Function(Map<String, dynamic>) onSave;

  const _TripLifecycleDialog({required this.onSave, this.initialTrip});

  @override
  State<_TripLifecycleDialog> createState() => _TripLifecycleDialogState();
}

class _TripLifecycleDialogState extends State<_TripLifecycleDialog> {
  static const _cargoTypes = ['General', 'Fragile', 'Perishable', 'Hazardous'];

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _clientController;
  late final TextEditingController _originController;
  late final TextEditingController _destinationController;
  late final TextEditingController _weightController;
  late final TextEditingController _orderValueController;
  late final TextEditingController _instructionsController;
  String _cargoType = 'General';
  String? _vehicle;
  String? _driver;
  DateTime? _scheduledDeparture;
  DateTime? _estimatedArrival;
  bool _saving = false;
  bool _saved = false;

  bool get _editing => widget.initialTrip != null;

  @override
  void initState() {
    super.initState();
    final trip = widget.initialTrip ?? const <String, dynamic>{};
    _clientController = TextEditingController(
      text: trip['customer']?.toString() ?? '',
    );
    _originController = TextEditingController(
      text: trip['origin']?.toString() ?? '',
    );
    _destinationController = TextEditingController(
      text: trip['destination']?.toString() ?? '',
    );
    _weightController = TextEditingController(
      text: _cleanNumber(trip['totalWeightKg']),
    );
    _orderValueController = TextEditingController(
      text: _cleanNumber(trip['orderValue'] ?? trip['amount']),
    );
    _instructionsController = TextEditingController(
      text:
          trip['specialInstructions']?.toString() ??
          trip['notes']?.toString() ??
          '',
    );
    _cargoType = _cargoTypes.contains(trip['cargoType']?.toString())
        ? trip['cargoType'].toString()
        : 'General';
    _vehicle = _nonEmpty(trip['vehicle']);
    _driver = _nonEmpty(trip['driver']);
    _scheduledDeparture =
        _parseDate(trip['scheduledDepartureAt']) ?? _parseDate(trip['date']);
    _estimatedArrival = _parseDate(trip['estimatedArrivalAt']);
    _scheduledDeparture ??= DateTime.now().add(const Duration(hours: 2));
    clientsNotifier.addListener(_onClientsChanged);
    if (clientsNotifier.value.isEmpty) {
      refreshClients().catchError((_) {});
    }
  }

  @override
  void dispose() {
    _clientController.dispose();
    _originController.dispose();
    _destinationController.dispose();
    _weightController.dispose();
    _orderValueController.dispose();
    _instructionsController.dispose();
    clientsNotifier.removeListener(_onClientsChanged);
    super.dispose();
  }

  void _onClientsChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 640;
    final freeDeliveryThreshold = _freeDeliveryThreshold;
    final freeDelivery = _orderValue >= freeDeliveryThreshold;

    return Dialog(
      backgroundColor: AppTheme.transparent,
      insetPadding: EdgeInsets.symmetric(
        horizontal: isMobile ? 12 : 64,
        vertical: 24,
      ),
      child: Container(
        constraints: BoxConstraints(maxWidth: isMobile ? width - 24 : 760),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isDark
                ? AppTheme.white.withValues(alpha: 0.08)
                : AppTheme.black.withValues(alpha: 0.08),
          ),
          boxShadow: [
            BoxShadow(
              color: AppTheme.black.withValues(alpha: 0.28),
              blurRadius: 34,
              offset: const Offset(0, 16),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(isDark),
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(isMobile ? 16 : 24),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _sectionTitle('Client and route', isDark),
                        const SizedBox(height: 12),
                        _responsiveRow(isMobile, [
                          _autocompleteField(
                            controller: _clientController,
                            label: 'Client',
                            hint: 'Select or enter client',
                            icon: Icons.business_rounded,
                            suggestions: _knownClients,
                            isDark: isDark,
                          ),
                          _autocompleteField(
                            controller: _originController,
                            label: 'Origin',
                            hint: 'Manual address or known stop',
                            icon: Icons.trip_origin_rounded,
                            suggestions: _knownPlaces,
                            isDark: isDark,
                          ),
                        ]),
                        const SizedBox(height: 12),
                        _autocompleteField(
                          controller: _destinationController,
                          label: 'Destination',
                          hint: 'Manual address or known stop',
                          icon: Icons.flag_rounded,
                          suggestions: _knownPlaces,
                          isDark: isDark,
                        ),
                        const SizedBox(height: 20),
                        _sectionTitle('Cargo and billing trigger', isDark),
                        const SizedBox(height: 12),
                        _responsiveRow(isMobile, [
                          _dropdownField(
                            label: 'Cargo type',
                            value: _cargoType,
                            values: _cargoTypes,
                            icon: Icons.inventory_2_rounded,
                            isDark: isDark,
                            onChanged: (value) =>
                                setState(() => _cargoType = value),
                          ),
                          _textField(
                            controller: _weightController,
                            label: 'Cargo weight in kg',
                            hint: 'Required',
                            icon: Icons.scale_rounded,
                            isDark: isDark,
                            keyboardType: TextInputType.number,
                            validator: _positiveNumberValidator,
                          ),
                          _textField(
                            controller: _orderValueController,
                            label: 'Order value in PHP',
                            hint: 'Required',
                            icon: Icons.payments_rounded,
                            isDark: isDark,
                            keyboardType: TextInputType.number,
                            validator: _positiveNumberValidator,
                            onChanged: (_) => setState(() {}),
                          ),
                        ]),
                        if (freeDelivery) ...[
                          const SizedBox(height: 10),
                          _freeDeliveryBanner(isDark, freeDeliveryThreshold),
                        ],
                        const SizedBox(height: 20),
                        _sectionTitle('Assignment and schedule', isDark),
                        const SizedBox(height: 12),
                        _responsiveRow(isMobile, [
                          _dropdownField(
                            label: 'Assigned vehicle',
                            value: _vehicle,
                            values: _vehicleOptions,
                            icon: Icons.local_shipping_rounded,
                            isDark: isDark,
                            validator: (value) =>
                                value == null || value.trim().isEmpty
                                ? 'Vehicle is required'
                                : null,
                            onChanged: (value) =>
                                setState(() => _vehicle = value),
                          ),
                          _dropdownField(
                            label: 'Assigned driver',
                            value: _driver,
                            values: _driverOptions,
                            icon: Icons.badge_rounded,
                            isDark: isDark,
                            validator: (value) =>
                                value == null || value.trim().isEmpty
                                ? 'Driver is required'
                                : null,
                            onChanged: (value) =>
                                setState(() => _driver = value),
                          ),
                        ]),
                        const SizedBox(height: 12),
                        _responsiveRow(isMobile, [
                          _dateTile(
                            label: 'Scheduled departure',
                            value: _scheduledDeparture,
                            isRequired: true,
                            isDark: isDark,
                            onTap: () => _pickDateTime(
                              current: _scheduledDeparture,
                              onSelected: (value) =>
                                  setState(() => _scheduledDeparture = value),
                            ),
                          ),
                          _dateTile(
                            label: 'Estimated arrival',
                            value: _estimatedArrival,
                            isRequired: false,
                            isDark: isDark,
                            onTap: () => _pickDateTime(
                              current: _estimatedArrival ?? _scheduledDeparture,
                              onSelected: (value) =>
                                  setState(() => _estimatedArrival = value),
                            ),
                          ),
                        ]),
                        const SizedBox(height: 12),
                        _textField(
                          controller: _instructionsController,
                          label: 'Special instructions',
                          hint: 'Optional delivery notes',
                          icon: Icons.notes_rounded,
                          isDark: isDark,
                          maxLines: 4,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              _buildActions(isDark),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [AppTheme.colorFF1A3A6B, AppTheme.colorFF4B7BE5],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
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
            child: Icon(
              _editing ? Icons.edit_road_rounded : Icons.add_road_rounded,
              color: AppTheme.white,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _editing ? 'Edit Trip' : 'Create Trip',
                  style: const TextStyle(
                    color: AppTheme.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _editing
                      ? 'Update pending or active trip details.'
                      : 'Trip starts at workflow phase 1 and remains pending until dispatch.',
                  style: TextStyle(
                    color: AppTheme.white.withValues(alpha: 0.78),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded, color: AppTheme.white),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF111827 : AppTheme.colorFFF8FAFC,
        border: Border(
          top: BorderSide(
            color: isDark
                ? AppTheme.white.withValues(alpha: 0.08)
                : AppTheme.black.withValues(alpha: 0.08),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _saving ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: ElevatedButton.icon(
              onPressed: _saving ? null : _submit,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppTheme.white,
                      ),
                    )
                  : const Icon(Icons.check_rounded, size: 18),
              label: Text(
                _saved
                    ? 'Saved'
                    : (_editing ? 'Save Trip' : 'Create Pending Trip'),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.colorFF4B7BE5,
                foregroundColor: AppTheme.white,
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title, bool isDark) {
    return Text(
      title,
      style: TextStyle(
        color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
        fontWeight: FontWeight.w900,
        fontSize: 13,
      ),
    );
  }

  Widget _responsiveRow(bool isMobile, List<Widget> children) {
    if (isMobile) {
      return Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i != children.length - 1) const SizedBox(height: 12),
          ],
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          Expanded(child: children[i]),
          if (i != children.length - 1) const SizedBox(width: 12),
        ],
      ],
    );
  }

  Widget _autocompleteField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required List<String> suggestions,
    required bool isDark,
  }) {
    return Autocomplete<String>(
      initialValue: TextEditingValue(text: controller.text),
      optionsBuilder: (textEditingValue) {
        final query = textEditingValue.text.trim().toLowerCase();
        if (query.isEmpty) return suggestions;
        return suggestions.where((item) => item.toLowerCase().contains(query));
      },
      onSelected: (value) => controller.text = value,
      fieldViewBuilder: (_, fieldController, focusNode, onSubmitted) {
        fieldController.addListener(() {
          if (controller.text != fieldController.text) {
            controller.text = fieldController.text;
          }
        });
        return _textField(
          controller: fieldController,
          label: label,
          hint: hint,
          icon: icon,
          isDark: isDark,
          focusNode: focusNode,
          validator: (value) => value == null || value.trim().isEmpty
              ? '$label is required'
              : null,
        );
      },
    );
  }

  Widget _textField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required bool isDark,
    FocusNode? focusNode,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
    ValueChanged<String>? onChanged,
    int maxLines = 1,
  }) {
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      keyboardType: keyboardType,
      validator: validator,
      onChanged: onChanged,
      maxLines: maxLines,
      style: TextStyle(
        color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
        fontWeight: FontWeight.w600,
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, size: 18),
        filled: true,
        fillColor: isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF8FAFD,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _dropdownField({
    required String label,
    required String? value,
    required List<String> values,
    required IconData icon,
    required bool isDark,
    required ValueChanged<String> onChanged,
    String? Function(String?)? validator,
  }) {
    final options = values
        .toSet()
        .where((item) => item.trim().isNotEmpty)
        .toList();
    final safeValue = value != null && options.contains(value) ? value : null;
    return DropdownButtonFormField<String>(
      initialValue: safeValue,
      hint: const Text('Select...'),
      items: options
          .map((item) => DropdownMenuItem(value: item, child: Text(item)))
          .toList(),
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
      validator: validator,
      dropdownColor: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
      style: TextStyle(
        color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
        fontWeight: FontWeight.w600,
      ),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 18),
        filled: true,
        fillColor: isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF8FAFD,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _dateTile({
    required String label,
    required DateTime? value,
    required bool isRequired,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: isRequired ? '$label *' : label,
          prefixIcon: const Icon(Icons.event_rounded, size: 18),
          filled: true,
          fillColor: isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF8FAFD,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Text(
          value == null ? 'Not set' : _formatDateTime(value),
          style: TextStyle(
            color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _freeDeliveryBanner(bool isDark, double threshold) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.colorFF10B981.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppTheme.colorFF10B981.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.verified_rounded, color: AppTheme.colorFF10B981),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Free delivery candidate: order value meets this client threshold (${_formatCurrency(threshold)}).',
              style: TextStyle(
                color: isDark ? AppTheme.white : AppTheme.colorFF0B7A3B,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDateTime({
    required DateTime? current,
    required ValueChanged<DateTime> onSelected,
  }) async {
    final base = current ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: base.isBefore(DateTime.now()) ? DateTime.now() : base,
      firstDate: DateTime(
        DateTime.now().year,
        DateTime.now().month,
        DateTime.now().day,
      ),
      lastDate: DateTime.now().add(const Duration(days: 730)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (time == null) return;
    onSelected(
      DateTime(date.year, date.month, date.day, time.hour, time.minute),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final scheduled = _scheduledDeparture;
    if (scheduled == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Scheduled departure is required.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (!_editing && scheduled.isBefore(DateTime.now())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Scheduled departure cannot be in the past.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    setState(() {
      _saving = true;
      _saved = false;
    });

    final orderValue = _orderValue;
    final tripId =
        widget.initialTrip?['tripId']?.toString() ??
        'TRP-${DateTime.now().millisecondsSinceEpoch.toRadixString(16).toUpperCase()}';
    final payload = <String, dynamic>{
      'tripId': tripId,
      'customer': _clientController.text.trim(),
      'origin': _originController.text.trim(),
      'destination': _destinationController.text.trim(),
      'cargoType': _cargoType,
      'totalWeightKg': double.tryParse(_weightController.text.trim()) ?? 0,
      'orderValue': orderValue,
      'amount': _formatCurrency(orderValue),
      'vehicle': _vehicle ?? '',
      'driver': _driver ?? '',
      'scheduledDepartureAt': scheduled.toIso8601String(),
      'estimatedArrivalAt': _estimatedArrival?.toIso8601String(),
      'specialInstructions': _instructionsController.text.trim(),
      'notes': _instructionsController.text.trim(),
      'freeDeliveryCandidate': orderValue >= _freeDeliveryThreshold,
      'freeDeliveryThreshold': _freeDeliveryThreshold,
      if (!_editing) ...{
        'status': 'pending',
        'statusColor': AppTheme.colorFFF39C12,
        'workflowPhaseNumber': 1,
        'workflowPhaseLocked': true,
        'date': scheduled.toIso8601String(),
      },
    };
    try {
      await widget.onSave(payload);
      if (!mounted) return;
      setState(() => _saved = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_editing ? 'Trip updated.' : 'Pending trip created.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            FormValidation.backendError(error, 'Trip could not be saved.'),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<String> get _knownClients {
    final clients = activeClientNames().toSet();
    final current = _clientController.text.trim();
    if (current.isNotEmpty) clients.add(current);
    if (clients.isEmpty) {
      clients.addAll(
        tripsNotifier.value
            .map((trip) => trip['customer']?.toString().trim() ?? '')
            .where((item) => item.isNotEmpty),
      );
    }
    return clients.toList()..sort();
  }

  double get _freeDeliveryThreshold {
    final selected = _clientController.text.trim().toLowerCase();
    if (selected.isEmpty) return 100000;
    for (final client in clientsNotifier.value) {
      if (client['companyName']?.toString().trim().toLowerCase() == selected) {
        return double.tryParse('${client['freeDeliveryThreshold']}') ?? 100000;
      }
    }
    return 100000;
  }

  List<String> get _knownPlaces {
    final places = <String>{};
    for (final trip in tripsNotifier.value) {
      final origin = trip['origin']?.toString().trim() ?? '';
      final destination = trip['destination']?.toString().trim() ?? '';
      if (origin.isNotEmpty) places.add(origin);
      if (destination.isNotEmpty) places.add(destination);
    }
    return places.toList()..sort();
  }

  List<String> get _vehicleOptions {
    final values =
        vehiclesNotifier.value
            .where((vehicle) {
              final status = vehicle['status']?.toString().toLowerCase() ?? '';
              final plate = vehicle['plate']?.toString().trim() ?? '';
              return plate.isNotEmpty &&
                  (status == 'available' || plate == (_vehicle ?? ''));
            })
            .map((vehicle) => vehicle['plate'].toString())
            .toSet()
            .toList()
          ..sort();
    if (_vehicle != null && !values.contains(_vehicle)) values.add(_vehicle!);
    return values;
  }

  List<String> get _driverOptions {
    final values =
        driversNotifier.value
            .where((driver) {
              final status = driver['status']?.toString().toLowerCase() ?? '';
              final name = driver['name']?.toString().trim() ?? '';
              return name.isNotEmpty &&
                  (status != 'inactive' && status != 'deactivated' ||
                      name == (_driver ?? ''));
            })
            .map((driver) => driver['name'].toString())
            .toSet()
            .toList()
          ..sort();
    if (_driver != null && !values.contains(_driver)) values.add(_driver!);
    return values;
  }

  double get _orderValue {
    final raw = _orderValueController.text.replaceAll(',', '').trim();
    return double.tryParse(raw) ?? 0;
  }

  String? _positiveNumberValidator(String? value) {
    final parsed = double.tryParse((value ?? '').replaceAll(',', '').trim());
    if (parsed == null || parsed <= 0) {
      return 'Enter a number greater than zero';
    }
    return null;
  }

  String _cleanNumber(dynamic value) {
    final raw = value?.toString() ?? '';
    // ignore: deprecated_member_use
    final cleaned = raw.replaceAll(RegExp(r'[^0-9.]'), '');
    return cleaned;
  }

  String? _nonEmpty(dynamic value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty || text == 'N/A' || text == 'Unassigned') return null;
    return text;
  }

  DateTime? _parseDate(dynamic value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty || raw == 'N/A') return null;
    return DateTime.tryParse(raw);
  }

  String _formatCurrency(double value) {
    return 'PHP ${value.toStringAsFixed(2)}';
  }

  String _formatDateTime(DateTime value) {
    final hour = value.hour > 12
        ? value.hour - 12
        : (value.hour == 0 ? 12 : value.hour);
    final minute = value.minute.toString().padLeft(2, '0');
    final meridian = value.hour >= 12 ? 'PM' : 'AM';
    return '${value.month}/${value.day}/${value.year} $hour:$minute $meridian';
  }
}

// EDIT TRIP MODAL
class _EditTripDialog extends StatefulWidget {
  final Map<String, dynamic> trip;
  final void Function(Map<String, dynamic>) onSave;
  const _EditTripDialog({required this.trip, required this.onSave});

  @override
  State<_EditTripDialog> createState() => _EditTripDialogState();
}

class _EditTripDialogState extends State<_EditTripDialog> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _customerCtrl;
  late TextEditingController _phoneCtrl;
  late TextEditingController _originCtrl;
  late TextEditingController _destinationCtrl;
  late TextEditingController _amountCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _customerCtrl = TextEditingController(text: widget.trip['customer'] ?? '');
    _phoneCtrl = TextEditingController(text: widget.trip['phone'] ?? '');
    _originCtrl = TextEditingController(text: widget.trip['origin'] ?? '');
    _destinationCtrl = TextEditingController(
      text: widget.trip['destination'] ?? '',
    );
    _amountCtrl = TextEditingController(
      text: widget.trip['amount']?.toString().replaceAll('PHP ', '') ?? '',
    );
  }

  @override
  void dispose() {
    _customerCtrl.dispose();
    _phoneCtrl.dispose();
    _originCtrl.dispose();
    _destinationCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final updatedTrip = {
      'customer': _customerCtrl.text.trim(),
      'phone': _phoneCtrl.text.trim(),
      'origin': _originCtrl.text.trim(),
      'destination': _destinationCtrl.text.trim(),
      'amount': 'PHP ${_amountCtrl.text.trim()}',
    };

    widget.onSave(updatedTrip);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sw = MediaQuery.of(context).size.width;
    final sh = MediaQuery.of(context).size.height;
    final keyboardH = MediaQuery.of(context).viewInsets.bottom;
    final isVerySmall = sw < 360;
    final isMobile = sw < 600;
    final verticalInset = isVerySmall ? 16.0 : 24.0;

    return Dialog(
          backgroundColor: AppTheme.transparent,
          insetPadding: EdgeInsets.symmetric(
            horizontal: isVerySmall ? 8 : (isMobile ? 16 : 80),
            vertical: verticalInset,
          ),
          child: Container(
            constraints: BoxConstraints(
              maxWidth: isVerySmall ? sw - 16 : 520,
              maxHeight: sh - keyboardH - verticalInset * 2,
            ),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
              borderRadius: BorderRadius.circular(isVerySmall ? 14 : 24),
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
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: EdgeInsets.all(isVerySmall ? 16 : 24),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [
                          AppTheme.colorFF4B7BE5,
                          AppTheme.colorFF1B2A4A,
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(isVerySmall ? 14 : 24),
                        topRight: Radius.circular(isVerySmall ? 14 : 24),
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
                            Icons.edit_road_rounded,
                            color: AppTheme.white,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Edit Trip',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.white,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Update trip: ${widget.trip['tripId']}',
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
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        children: [
                          // Customer Name with autocomplete from existing customers
                          Builder(
                            builder: (ctx) {
                              final existingCustomers = tripsNotifier.value
                                  .map((t) => t['customer'] as String)
                                  .toSet()
                                  .toList();
                              return Autocomplete<String>(
                                optionsBuilder:
                                    (TextEditingValue textEditingValue) {
                                      if (textEditingValue.text.isEmpty)
                                        return const Iterable<String>.empty();
                                      return existingCustomers.where(
                                        (c) => c.toLowerCase().contains(
                                          textEditingValue.text.toLowerCase(),
                                        ),
                                      );
                                    },
                                onSelected: (selection) =>
                                    _customerCtrl.text = selection,
                                fieldViewBuilder:
                                    (
                                      context,
                                      controller,
                                      focusNode,
                                      onFieldSubmitted,
                                    ) {
                                      // keep backing controller in sync
                                      controller.text = _customerCtrl.text;
                                      controller.selection =
                                          TextSelection.fromPosition(
                                            TextPosition(
                                              offset: controller.text.length,
                                            ),
                                          );
                                      return TextFormField(
                                        controller: controller,
                                        focusNode: focusNode,
                                        validator: (v) =>
                                            (v == null || v.trim().isEmpty)
                                            ? 'Customer name is required'
                                            : null,
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: isDark
                                              ? AppTheme.white
                                              : AppTheme.colorFF2C3E50,
                                        ),
                                        decoration: InputDecoration(
                                          hintText: 'e.g. ABC Manufacturing',
                                          hintStyle: TextStyle(
                                            color: isDark
                                                ? AppTheme.gray600
                                                : AppTheme.gray500,
                                            fontSize: 14,
                                          ),
                                          prefixIcon: Icon(
                                            Icons.person_rounded,
                                            size: 18,
                                            color: isDark
                                                ? AppTheme.gray500
                                                : AppTheme.gray600,
                                          ),
                                          filled: true,
                                          fillColor: isDark
                                              ? AppTheme.colorFF0F1117
                                              : AppTheme.colorFFF5F6F8,
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            borderSide: BorderSide(
                                              color: isDark
                                                  ? AppTheme.white.withValues(
                                                      alpha: 0.1,
                                                    )
                                                  : AppTheme.black.withValues(
                                                      alpha: 0.1,
                                                    ),
                                            ),
                                          ),
                                          enabledBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            borderSide: BorderSide(
                                              color: isDark
                                                  ? AppTheme.white.withValues(
                                                      alpha: 0.1,
                                                    )
                                                  : AppTheme.black.withValues(
                                                      alpha: 0.1,
                                                    ),
                                            ),
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            borderSide: const BorderSide(
                                              color: AppTheme.colorFF4B7BE5,
                                              width: 2,
                                            ),
                                          ),
                                        ),
                                        onChanged: (v) =>
                                            _customerCtrl.text = v,
                                      );
                                    },
                                optionsViewBuilder:
                                    (context, onSelected, options) {
                                      return Align(
                                        alignment: Alignment.topLeft,
                                        child: Material(
                                          color: isDark
                                              ? AppTheme.colorFF1A1D23
                                              : AppTheme.white,
                                          elevation: 4,
                                          child: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              maxHeight: 200,
                                              maxWidth: 480,
                                            ),
                                            child: ListView.separated(
                                              padding: EdgeInsets.zero,
                                              itemCount: options.length,
                                              separatorBuilder: (_, __) =>
                                                  const Divider(height: 1),
                                              itemBuilder: (context, index) {
                                                final option = options
                                                    .elementAt(index);
                                                return ListTile(
                                                  title: Text(
                                                    option,
                                                    style: TextStyle(
                                                      color: isDark
                                                          ? AppTheme.white
                                                          : AppTheme.black,
                                                    ),
                                                  ),
                                                  onTap: () =>
                                                      onSelected(option),
                                                );
                                              },
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                              );
                            },
                          ),
                          const SizedBox(height: 16),
                          _formField(
                            controller: _phoneCtrl,
                            label: 'Phone Number',
                            hint: 'e.g. +63 917 123 4567',
                            icon: Icons.phone_rounded,
                            isDark: isDark,
                            keyboardType: TextInputType.phone,
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Phone number is required'
                                : null,
                          ),
                          const SizedBox(height: 16),
                          _formField(
                            controller: _originCtrl,
                            label: 'Origin',
                            hint: 'e.g. SM City Cabuyao, Laguna',
                            icon: Icons.location_on_rounded,
                            isDark: isDark,
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Origin is required'
                                : null,
                          ),
                          const SizedBox(height: 16),
                          _formField(
                            controller: _destinationCtrl,
                            label: 'Destination',
                            hint: 'e.g. Calamba Industrial Park, Laguna',
                            icon: Icons.flag_rounded,
                            isDark: isDark,
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Destination is required'
                                : null,
                          ),
                          const SizedBox(height: 16),
                          _formField(
                            controller: _amountCtrl,
                            label: 'Amount (PHP)',
                            hint: 'e.g. 25000',
                            icon: Icons.attach_money_rounded,
                            isDark: isDark,
                            keyboardType: TextInputType.number,
                            validator: (v) {
                              if (v == null || v.trim().isEmpty)
                                return 'Amount is required';
                              if (int.tryParse(v.trim()) == null)
                                return 'Enter a valid number';
                              return null;
                            },
                          ),
                          const SizedBox(height: 28),
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
                                            ? AppTheme.white.withValues(
                                                alpha: 0.1,
                                              )
                                            : AppTheme.black.withValues(
                                                alpha: 0.1,
                                              ),
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
                                    onTap: _saving ? null : _submit,
                                    child: Container(
                                      height: 50,
                                      decoration: BoxDecoration(
                                        gradient: const LinearGradient(
                                          colors: [
                                            AppTheme.colorFF4B7BE5,
                                            AppTheme.colorFF00D4FF,
                                          ],
                                        ),
                                        borderRadius: BorderRadius.circular(12),
                                        boxShadow: [
                                          BoxShadow(
                                            color: AppTheme.colorFF4B7BE5
                                                .withValues(alpha: 0.4),
                                            blurRadius: 12,
                                            offset: const Offset(0, 4),
                                          ),
                                        ],
                                      ),
                                      child: Center(
                                        child: _saving
                                            ? const SizedBox(
                                                width: 20,
                                                height: 20,
                                                child:
                                                    CircularProgressIndicator(
                                                      color: AppTheme.white,
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : const Text(
                                                'Save Changes',
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
                  ),
                ],
              ),
            ),
          ),
        )
        .animate()
        .fadeIn(duration: 200.ms)
        .scale(
          begin: const Offset(0.95, 0.95),
          end: const Offset(1, 1),
          duration: 200.ms,
        );
  }

  Widget _formField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required bool isDark,
    required String? Function(String?) validator,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isDark ? AppTheme.gray300 : AppTheme.colorFF2C3E50,
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          validator: validator,
          keyboardType: keyboardType,
          style: TextStyle(
            fontSize: 14,
            color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              color: isDark ? AppTheme.gray600 : AppTheme.gray500,
              fontSize: 14,
            ),
            prefixIcon: Icon(
              icon,
              size: 18,
              color: isDark ? AppTheme.gray500 : AppTheme.gray600,
            ),
            filled: true,
            fillColor: isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF5F6F8,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: isDark
                    ? AppTheme.white.withValues(alpha: 0.1)
                    : AppTheme.black.withValues(alpha: 0.1),
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: isDark
                    ? AppTheme.white.withValues(alpha: 0.1)
                    : AppTheme.black.withValues(alpha: 0.1),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(
                color: AppTheme.colorFF4B7BE5,
                width: 2,
              ),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppTheme.colorFFE74C3C),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(
                color: AppTheme.colorFFE74C3C,
                width: 2,
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            isDense: true,
            errorMaxLines: 1,
            errorStyle: const TextStyle(fontSize: 12, height: 0.8),
          ),
        ),
      ],
    );
  }
}

// NEW TRIP MODAL - UNCHANGED
class _NewTripDialog extends StatefulWidget {
  final void Function(Map<String, dynamic>) onAdd;
  const _NewTripDialog({required this.onAdd});

  @override
  State<_NewTripDialog> createState() => _NewTripDialogState();
}

class _NewTripDialogState extends State<_NewTripDialog> {
  final _formKey = GlobalKey<FormState>();
  final _customerCtrl = TextEditingController();
  final _originCtrl = TextEditingController();
  final _destinationCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _customerCtrl.dispose();
    _originCtrl.dispose();
    _destinationCtrl.dispose();
    _phoneCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final existingTrips = tripsNotifier.value;
    int maxId = 1287;
    for (var trip in existingTrips) {
      final tripId = trip['tripId'] as String;
      final num = int.tryParse(tripId.replaceAll('TRP-', '')) ?? 0;
      if (num > maxId) maxId = num;
    }
    final newTripId = 'TRP-${(maxId + 1).toString().padLeft(6, '0')}';

    final newTrip = {
      'tripId': newTripId,
      'date': _formatDate(DateTime.now()),
      'customer': _customerCtrl.text.trim(),
      'phone': _phoneCtrl.text.trim(),
      'origin': _originCtrl.text.trim(),
      'destination': _destinationCtrl.text.trim(),
      'vehicle': '',
      'driver': '',
      'status': 'pending',
      'statusColor': AppTheme.colorFFF39C12,
      'amount': 'PHP ${_amountCtrl.text.trim()}',
      'delay': '',
      'hasDelay': false,
    };

    widget.onAdd(newTrip);
    Navigator.pop(context);
  }

  String _formatDate(DateTime dt) {
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
    final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '${months[dt.month - 1]} ${dt.day}, ${hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')} $period';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sw = MediaQuery.of(context).size.width;
    final sh = MediaQuery.of(context).size.height;
    final keyboardH = MediaQuery.of(context).viewInsets.bottom;
    final isVerySmall = sw < 360;
    final isMobile = sw < 600;
    final verticalInset = isVerySmall ? 16.0 : 24.0;

    return Dialog(
          backgroundColor: AppTheme.transparent,
          insetPadding: EdgeInsets.symmetric(
            horizontal: isVerySmall ? 8 : (isMobile ? 16 : 80),
            vertical: verticalInset,
          ),
          child: Container(
            constraints: BoxConstraints(
              maxWidth: isVerySmall ? sw - 16 : 520,
              maxHeight: sh - keyboardH - verticalInset * 2,
            ),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
              borderRadius: BorderRadius.circular(isVerySmall ? 14 : 24),
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
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: EdgeInsets.all(isVerySmall ? 16 : 24),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [
                          AppTheme.colorFF4B7BE5,
                          AppTheme.colorFF1B2A4A,
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(isVerySmall ? 14 : 24),
                        topRight: Radius.circular(isVerySmall ? 14 : 24),
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
                            Icons.add_location_alt_rounded,
                            color: AppTheme.white,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 14),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'New Trip',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.white,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Create a new trip request',
                                style: TextStyle(
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
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        children: [
                          // Customer Name with autocomplete from existing customers
                          Builder(
                            builder: (ctx) {
                              final existingCustomers = tripsNotifier.value
                                  .map((t) => t['customer'] as String)
                                  .toSet()
                                  .toList();
                              return Autocomplete<String>(
                                optionsBuilder:
                                    (TextEditingValue textEditingValue) {
                                      if (textEditingValue.text.isEmpty)
                                        return existingCustomers;
                                      return existingCustomers.where(
                                        (c) => c.toLowerCase().contains(
                                          textEditingValue.text.toLowerCase(),
                                        ),
                                      );
                                    },
                                onSelected: (selection) =>
                                    _customerCtrl.text = selection,
                                fieldViewBuilder:
                                    (
                                      context,
                                      controller,
                                      focusNode,
                                      onFieldSubmitted,
                                    ) {
                                      controller.text = _customerCtrl.text;
                                      controller.selection =
                                          TextSelection.fromPosition(
                                            TextPosition(
                                              offset: controller.text.length,
                                            ),
                                          );
                                      return TextFormField(
                                        controller: controller,
                                        focusNode: focusNode,
                                        validator: (v) =>
                                            (v == null || v.trim().isEmpty)
                                            ? 'Customer name is required'
                                            : null,
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: isDark
                                              ? AppTheme.white
                                              : AppTheme.colorFF2C3E50,
                                        ),
                                        decoration: InputDecoration(
                                          hintText: 'e.g. ABC Manufacturing',
                                          hintStyle: TextStyle(
                                            color: isDark
                                                ? AppTheme.gray600
                                                : AppTheme.gray500,
                                            fontSize: 14,
                                          ),
                                          prefixIcon: Icon(
                                            Icons.person_rounded,
                                            size: 18,
                                            color: isDark
                                                ? AppTheme.gray500
                                                : AppTheme.gray600,
                                          ),
                                          filled: true,
                                          fillColor: isDark
                                              ? AppTheme.colorFF0F1117
                                              : AppTheme.colorFFF5F6F8,
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            borderSide: BorderSide(
                                              color: isDark
                                                  ? AppTheme.white.withValues(
                                                      alpha: 0.1,
                                                    )
                                                  : AppTheme.black.withValues(
                                                      alpha: 0.1,
                                                    ),
                                            ),
                                          ),
                                          enabledBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            borderSide: BorderSide(
                                              color: isDark
                                                  ? AppTheme.white.withValues(
                                                      alpha: 0.1,
                                                    )
                                                  : AppTheme.black.withValues(
                                                      alpha: 0.1,
                                                    ),
                                            ),
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            borderSide: const BorderSide(
                                              color: AppTheme.colorFF4B7BE5,
                                              width: 2,
                                            ),
                                          ),
                                        ),
                                        onChanged: (v) =>
                                            _customerCtrl.text = v,
                                      );
                                    },
                                optionsViewBuilder:
                                    (context, onSelected, options) {
                                      return Align(
                                        alignment: Alignment.topLeft,
                                        child: Material(
                                          color: isDark
                                              ? AppTheme.colorFF1A1D23
                                              : AppTheme.white,
                                          elevation: 4,
                                          child: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              maxHeight: 200,
                                              maxWidth: 480,
                                            ),
                                            child: ListView.separated(
                                              padding: EdgeInsets.zero,
                                              itemCount: options.length,
                                              separatorBuilder: (_, __) =>
                                                  const Divider(height: 1),
                                              itemBuilder: (context, index) {
                                                final option = options
                                                    .elementAt(index);
                                                return ListTile(
                                                  title: Text(
                                                    option,
                                                    style: TextStyle(
                                                      color: isDark
                                                          ? AppTheme.white
                                                          : AppTheme.black,
                                                    ),
                                                  ),
                                                  onTap: () =>
                                                      onSelected(option),
                                                );
                                              },
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                              );
                            },
                          ),
                          const SizedBox(height: 16),
                          _formField(
                            controller: _phoneCtrl,
                            label: 'Phone Number',
                            hint: 'e.g. +63 917 123 4567',
                            icon: Icons.phone_rounded,
                            isDark: isDark,
                            keyboardType: TextInputType.phone,
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Phone number is required'
                                : null,
                          ),
                          const SizedBox(height: 16),
                          _formField(
                            controller: _originCtrl,
                            label: 'Origin',
                            hint: 'e.g. SM City Cabuyao, Laguna',
                            icon: Icons.location_on_rounded,
                            isDark: isDark,
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Origin is required'
                                : null,
                          ),
                          const SizedBox(height: 16),
                          _formField(
                            controller: _destinationCtrl,
                            label: 'Destination',
                            hint: 'e.g. Calamba Industrial Park, Laguna',
                            icon: Icons.flag_rounded,
                            isDark: isDark,
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Destination is required'
                                : null,
                          ),
                          const SizedBox(height: 16),
                          _formField(
                            controller: _amountCtrl,
                            label: 'Amount (PHP)',
                            hint: 'e.g. 25000',
                            icon: Icons.attach_money_rounded,
                            isDark: isDark,
                            keyboardType: TextInputType.number,
                            validator: (v) {
                              if (v == null || v.trim().isEmpty)
                                return 'Amount is required';
                              if (int.tryParse(v.trim()) == null)
                                return 'Enter a valid number';
                              return null;
                            },
                          ),
                          const SizedBox(height: 28),
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
                                            ? AppTheme.white.withValues(
                                                alpha: 0.1,
                                              )
                                            : AppTheme.black.withValues(
                                                alpha: 0.1,
                                              ),
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
                                    onTap: _saving ? null : _submit,
                                    child: Container(
                                      height: 50,
                                      decoration: BoxDecoration(
                                        gradient: const LinearGradient(
                                          colors: [
                                            AppTheme.colorFF4B7BE5,
                                            AppTheme.colorFF00D4FF,
                                          ],
                                        ),
                                        borderRadius: BorderRadius.circular(12),
                                        boxShadow: [
                                          BoxShadow(
                                            color: AppTheme.colorFF4B7BE5
                                                .withValues(alpha: 0.4),
                                            blurRadius: 12,
                                            offset: const Offset(0, 4),
                                          ),
                                        ],
                                      ),
                                      child: Center(
                                        child: _saving
                                            ? const SizedBox(
                                                width: 20,
                                                height: 20,
                                                child:
                                                    CircularProgressIndicator(
                                                      color: AppTheme.white,
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : const Text(
                                                'Create Trip',
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
                  ),
                ],
              ),
            ),
          ),
        )
        .animate()
        .fadeIn(duration: 200.ms)
        .scale(
          begin: const Offset(0.95, 0.95),
          end: const Offset(1, 1),
          duration: 200.ms,
        );
  }

  Widget _formField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required bool isDark,
    required String? Function(String?) validator,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isDark ? AppTheme.gray300 : AppTheme.colorFF2C3E50,
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          validator: validator,
          keyboardType: keyboardType,
          style: TextStyle(
            fontSize: 14,
            color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              color: isDark ? AppTheme.gray600 : AppTheme.gray500,
              fontSize: 14,
            ),
            prefixIcon: Icon(
              icon,
              size: 18,
              color: isDark ? AppTheme.gray500 : AppTheme.gray600,
            ),
            filled: true,
            fillColor: isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF5F6F8,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: isDark
                    ? AppTheme.white.withValues(alpha: 0.1)
                    : AppTheme.black.withValues(alpha: 0.1),
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: isDark
                    ? AppTheme.white.withValues(alpha: 0.1)
                    : AppTheme.black.withValues(alpha: 0.1),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(
                color: AppTheme.colorFF4B7BE5,
                width: 2,
              ),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppTheme.colorFFE74C3C),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(
                color: AppTheme.colorFFE74C3C,
                width: 2,
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            isDense: true,
            errorMaxLines: 1,
            errorStyle: const TextStyle(fontSize: 12, height: 0.8),
          ),
        ),
      ],
    );
  }
}
