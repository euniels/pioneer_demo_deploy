import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../services/api.dart';
import '../services/app_logger.dart';
import '../services/trips_store.dart';
import '../services/driver_data_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_state_widgets.dart';
import '../widgets/dashboard_layout.dart';
import '../widgets/page_skeletons.dart';
import '../widgets/trip_completion_modal.dart';

class DriverTripsPage extends StatefulWidget {
  const DriverTripsPage({super.key});

  @override
  State<DriverTripsPage> createState() => _DriverTripsPageState();
}

class _DriverTripsPageState extends State<DriverTripsPage>
    with SingleTickerProviderStateMixin {
  // â”€â”€ State â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  List<Map<String, dynamic>> _trips = [];
  bool _loading = true;
  String? _loadError;
  String _filter = 'All';
  String _search = '';
  late TabController _tabCtrl;

  static const _filters = [
    'All',
    'Pending',
    'In Progress',
    'Awaiting Approval',
    'Completed',
  ];

  // â”€â”€ Lifecycle â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: _filters.length, vsync: this);
    _tabCtrl.addListener(() {
      if (!_tabCtrl.indexIsChanging) {
        setState(() => _filter = _filters[_tabCtrl.index]);
      }
    });
    // Listen to real store â€” refresh when admin dispatches a trip
    tripsNotifier.addListener(_onStoreChanged);
    _loadTrips();
  }

  @override
  void dispose() {
    tripsNotifier.removeListener(_onStoreChanged);
    _tabCtrl.dispose();
    super.dispose();
  }

  void _onStoreChanged() => _loadTrips();

  Future<void> _loadTrips() async {
    try {
      final data = await Api.getDriverTrips();
      if (mounted) {
        setState(() {
          _trips = data;
          _loading = false;
          _loadError = null;
        });
      }
    } catch (error) {
      AppLogger.warning('Driver trips load failed', {
        'error': error.toString(),
      });
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = 'Unable to refresh trips.';
        });
      }
    }
  }

  // â”€â”€ Complete a trip â€” shows signature modal, then submits for admin approval â”€â”€
  Future<void> _completeTrip(String driverTripId) async {
    final realId = DriverDataService.findRealTripId(driverTripId);
    if (realId == null) {
      _showSnack('Trip not found in system.', isError: true);
      return;
    }

    // Find the full trip data so the modal can show trip summary
    final tripData = tripsNotifier.value.firstWhere(
      (t) => t['tripId'] == realId,
      orElse: () => {},
    );

    // Show signature capture modal
    final submitted = await showTripCompletionModal(
      context,
      tripId: realId,
      tripData: tripData,
    );

    if (submitted == true) {
      _showSnack('Trip submitted for approval! Awaiting admin sign-off.');
    }
    // Listener will auto-refresh via _onStoreChanged
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? AppTheme.errorRed : AppTheme.successGreen,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: AppTheme.getButtonRadius()),
        margin: const EdgeInsets.all(AppTheme.space16),
      ),
    );
  }

  // â”€â”€ Filtered list â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  List<Map<String, dynamic>> get _filtered {
    return _trips.where((t) {
      final status = (t['status'] ?? '').toString();
      final search = _search.toLowerCase();
      final matchF = _filter == 'All' || status == _filter;
      final matchS =
          search.isEmpty ||
          (t['id'] ?? '').toString().toLowerCase().contains(search) ||
          (t['pickup'] ?? '').toString().toLowerCase().contains(search) ||
          (t['dropoff'] ?? '').toString().toLowerCase().contains(search) ||
          (t['customer'] ?? '').toString().toLowerCase().contains(search);
      return matchF && matchS;
    }).toList();
  }

  // â”€â”€ Build â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMobile = MediaQuery.of(context).size.width < 700;

    return DashboardLayout(
      currentRoute: '/driver-trips',
      title: 'My Trips',
      subtitle: 'View and manage your assigned trips',
      child: _loading
          ? const PioneerRouteSkeletonBody(routeName: '/driver-trips')
          : Column(
              children: [
                if (_loadError != null) ...[
                  PioneerErrorBanner(message: _loadError!, onRetry: _loadTrips),
                  const SizedBox(height: AppTheme.space12),
                ],
                // â”€â”€ Header stats â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                _buildStatsRow(isDark, isMobile)
                    .animate()
                    .fadeIn(duration: 400.ms)
                    .slideY(begin: 0.1, end: 0, duration: 400.ms),

                const SizedBox(height: 16),

                // â”€â”€ Search bar â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                _buildSearchBar(isDark).animate().fadeIn(duration: 500.ms),

                const SizedBox(height: 12),

                // â”€â”€ Tab bar (filter) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                _buildTabBar(isDark).animate().fadeIn(duration: 600.ms),

                const SizedBox(height: 16),

                // â”€â”€ Trip list â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                Expanded(
                  child: _filtered.isEmpty
                      ? _buildEmptyState(isDark)
                      : ListView.builder(
                          padding: const EdgeInsets.only(bottom: 24),
                          itemCount: _filtered.length,
                          itemBuilder: (ctx, i) =>
                              _buildTripCard(
                                _filtered[i],
                                isDark,
                                isMobile,
                              ).animate().fadeIn(
                                duration: Duration(milliseconds: 300 + i * 60),
                              ),
                        ),
                ),
              ],
            ),
    );
  }

  // â”€â”€ Stats row â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildStatsRow(bool isDark, bool isMobile) {
    final pending = _trips.where((t) => t['status'] == 'Pending').length;
    final inProgress = _trips.where((t) => t['status'] == 'In Progress').length;
    final completed = _trips.where((t) => t['status'] == 'Completed').length;

    return Row(
      children: [
        _statChip(isDark, 'Total', '${_trips.length}', AppTheme.colorFF4B7BE5),
        const SizedBox(width: 10),
        _statChip(isDark, 'Pending', '$pending', AppTheme.colorFFF39C12),
        const SizedBox(width: 10),
        _statChip(isDark, 'Active', '$inProgress', AppTheme.colorFF4B7BE5),
        const SizedBox(width: 10),
        _statChip(isDark, 'Completed', '$completed', AppTheme.colorFF27AE60),
      ],
    );
  }

  Widget _statChip(bool isDark, String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDark
                ? AppTheme.white.withValues(alpha: 0.07)
                : color.withValues(alpha: 0.15),
          ),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isDark ? AppTheme.gray400 : AppTheme.gray600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // â”€â”€ Search bar â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildSearchBar(bool isDark) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.07)
              : AppTheme.black.withValues(alpha: 0.07),
        ),
      ),
      child: TextField(
        onChanged: (v) => setState(() => _search = v),
        style: TextStyle(
          fontSize: 13,
          color: isDark ? AppTheme.white : AppTheme.colorFF1A1D23,
        ),
        decoration: InputDecoration(
          hintText: 'Search by trip ID, pickup, dropoff...',
          hintStyle: TextStyle(
            fontSize: 12,
            color: isDark ? AppTheme.gray500 : AppTheme.gray500,
          ),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 18,
            color: AppTheme.gray500,
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 13,
          ),
        ),
      ),
    );
  }

  // â”€â”€ Tab bar â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildTabBar(bool isDark) {
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: isDark
            ? AppTheme.white.withValues(alpha: 0.04)
            : AppTheme.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
      ),
      child: TabBar(
        controller: _tabCtrl,
        tabs: _filters
            .map(
              (f) => Tab(
                child: Text(
                  f,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            )
            .toList(),
        indicator: BoxDecoration(
          color: AppTheme.colorFF27AE60,
          borderRadius: BorderRadius.circular(8),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        labelColor: AppTheme.white,
        unselectedLabelColor: isDark ? AppTheme.gray400 : AppTheme.gray600,
        dividerColor: AppTheme.transparent,
        padding: const EdgeInsets.all(3),
        splashFactory: NoSplash.splashFactory,
        overlayColor: WidgetStateProperty.all(AppTheme.transparent),
      ),
    );
  }

  // â”€â”€ Empty state â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: PioneerStateCard(
        icon: Icons.route_rounded,
        title: _search.isNotEmpty
            ? 'No trips match your search'
            : 'No ${_filter == 'All' ? '' : _filter.toLowerCase()} trips',
        message: 'Trips dispatched by your manager will appear here.',
        actionLabel: 'Refresh',
        onAction: _loadTrips,
        tone: PioneerStateTone.empty,
        compact: true,
      ),
    );
  }

  // â”€â”€ Trip card â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildTripCard(Map<String, dynamic> trip, bool isDark, bool isMobile) {
    final status = trip['status'] ?? 'Pending';
    final isActive = status == 'In Progress';
    final isCompleted = status == 'Completed';
    final isAwaiting = status == 'Awaiting Approval';

    final statusColor = isCompleted
        ? AppTheme.colorFF27AE60
        : isActive
        ? AppTheme.colorFF4B7BE5
        : isAwaiting
        ? AppTheme.colorFF9B59B6
        : AppTheme.colorFFF39C12;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isActive
              ? AppTheme.colorFF4B7BE5.withValues(alpha: 0.3)
              : isDark
              ? AppTheme.white.withValues(alpha: 0.06)
              : AppTheme.black.withValues(alpha: 0.06),
        ),
        boxShadow: isActive
            ? [
                BoxShadow(
                  color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.1),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // â”€â”€ Card header â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.06),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isCompleted
                      ? Icons.check_circle_rounded
                      : isActive
                      ? Icons.local_shipping_rounded
                      : Icons.schedule_rounded,
                  size: 16,
                  color: statusColor,
                ),
                const SizedBox(width: 8),
                Text(
                  trip['id'] ?? '-',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: isDark ? AppTheme.white : AppTheme.colorFF1A1D23,
                  ),
                ),
                const Spacer(),
                // Status badge
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: statusColor.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: statusColor,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // â”€â”€ Card body â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Route
                Row(
                  children: [
                    Column(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: AppTheme.colorFF27AE60,
                            shape: BoxShape.circle,
                          ),
                        ),
                        Container(
                          width: 1.5,
                          height: 20,
                          color: isDark ? AppTheme.gray700 : AppTheme.gray300,
                        ),
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: AppTheme.colorFFE74C3C,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            trip['pickup'] ?? '-',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? AppTheme.white
                                  : AppTheme.colorFF1A1D23,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            trip['dropoff'] ?? '-',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? AppTheme.white
                                  : AppTheme.colorFF1A1D23,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 14),
                Divider(
                  color: isDark
                      ? AppTheme.white.withValues(alpha: 0.05)
                      : AppTheme.black.withValues(alpha: 0.05),
                ),
                const SizedBox(height: 10),

                // Details row
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    _infoChip(
                      isDark,
                      Icons.business_rounded,
                      trip['customer'] ?? '-',
                    ),
                    _infoChip(
                      isDark,
                      Icons.payments_rounded,
                      trip['payment'] ?? '-',
                    ),
                    _infoChip(
                      isDark,
                      Icons.calendar_today_rounded,
                      trip['date'] ?? '-',
                    ),
                    if ((trip['cargo'] ?? '').toString().isNotEmpty &&
                        trip['cargo'] != 'General Merchandise')
                      _infoChip(
                        isDark,
                        Icons.inventory_2_rounded,
                        trip['cargo'] ?? '',
                      ),
                  ],
                ),

                // â”€â”€ Complete button (dispatched / in-progress trips) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                if (isActive) ...[
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => _completeTrip(trip['id'] ?? ''),
                      icon: const Icon(
                        Icons.check_circle_rounded,
                        size: 16,
                        color: AppTheme.white,
                      ),
                      label: const Text(
                        'Complete Trip',
                        style: TextStyle(
                          color: AppTheme.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.colorFF27AE60,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        elevation: 0,
                      ),
                    ),
                  ),
                ],

                // â”€â”€ Awaiting approval banner â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                if (isAwaiting) ...[
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.colorFF9B59B6.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: AppTheme.colorFF9B59B6.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.hourglass_top_rounded,
                          size: 16,
                          color: AppTheme.colorFF9B59B6,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Awaiting Admin Approval',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.colorFF9B59B6,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Your completion has been submitted. Waiting for admin to review and sign off.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isDark
                                      ? AppTheme.gray400
                                      : AppTheme.gray600,
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
          ),
        ],
      ),
    );
  }

  Widget _infoChip(bool isDark, IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 12,
          color: isDark ? AppTheme.gray500 : AppTheme.gray500,
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            fontSize: 12,
            color: isDark ? AppTheme.gray400 : AppTheme.gray600,
          ),
        ),
      ],
    );
  }
}
