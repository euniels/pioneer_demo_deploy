import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../widgets/dashboard_layout.dart';
import '../services/auth.dart';
import '../services/api.dart';
import '../services/trips_store.dart';
import '../services/vehicles_store.dart';
import '../services/driver_data_service.dart';
import '../widgets/app_state_widgets.dart';
import '../widgets/page_skeletons.dart';
import '../widgets/trip_completion_modal.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';

class DriverDashboardPage extends StatefulWidget {
  const DriverDashboardPage({super.key});
  @override
  State<DriverDashboardPage> createState() => _DriverDashboardPageState();
}

class _DriverDashboardPageState extends State<DriverDashboardPage>
    with TickerProviderStateMixin {
  Map<String, dynamic>? _dashboardData;
  bool _isLoading = true;
  late AnimationController _cardAnimationController;
  late AnimationController _chartAnimationController;

  @override
  void initState() {
    super.initState();
    _cardAnimationController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _chartAnimationController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    // Listen to real stores â€” auto-refresh when admin dispatches or updates
    tripsNotifier.addListener(_onStoreChanged);
    vehiclesNotifier.addListener(_onStoreChanged);
    _loadDashboard();
  }

  void _onStoreChanged() {
    if (mounted) _loadDashboard();
  }

  @override
  void dispose() {
    tripsNotifier.removeListener(_onStoreChanged);
    vehiclesNotifier.removeListener(_onStoreChanged);
    _cardAnimationController.dispose();
    _chartAnimationController.dispose();
    super.dispose();
  }

  Future<void> _loadDashboard() async {
    final user = AuthService.currentUserData;
    if (user == null) return;
    try {
      final data = await Api.getDashboard();
      if (mounted) {
        setState(() {
          _dashboardData = data;
          _isLoading = false;
        });
        _cardAnimationController.forward();
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) _chartAnimationController.forward();
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  bool _isMobile(BuildContext context) =>
      MediaQuery.of(context).size.width < 600;
  bool _isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= 600 &&
      MediaQuery.of(context).size.width < 1024;

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      currentRoute: '/driver-dashboard',
      title: 'Dashboard',
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      return const PioneerRouteSkeletonBody(routeName: '/driver-dashboard');
    }
    if (_dashboardData == null) {
      return PioneerStateCard(
        icon: Icons.dashboard_customize_rounded,
        title: 'Dashboard could not be loaded',
        message:
            'Your local workspace is still available. Retry when the connection is stable.',
        actionLabel: 'Retry',
        tone: PioneerStateTone.error,
        onAction: _loadDashboard,
      );
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMobile = _isMobile(context);
    final isTablet = _isTablet(context);

    return SingleChildScrollView(
      padding: EdgeInsets.all(
        isMobile
            ? 16
            : isTablet
            ? 24
            : 32,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildGreetingBanner(isDark, isMobile)
              .animate()
              .fadeIn(duration: 400.ms)
              .slideY(
                begin: 0.2,
                end: 0,
                duration: 400.ms,
                curve: Curves.easeOut,
              ),
          SizedBox(height: isMobile ? 20 : 32),
          _buildTopStatsCards(isDark, isMobile)
              .animate()
              .fadeIn(duration: 500.ms)
              .slideY(
                begin: 0.2,
                end: 0,
                duration: 500.ms,
                curve: Curves.easeOut,
              ),
          SizedBox(height: isMobile ? 20 : 32),
          _buildChartsSection(isDark, isMobile)
              .animate()
              .fadeIn(duration: 600.ms)
              .slideY(
                begin: 0.2,
                end: 0,
                duration: 600.ms,
                curve: Curves.easeOut,
              ),
          SizedBox(height: isMobile ? 20 : 32),
          _buildBottomSection(isDark, isMobile)
              .animate()
              .fadeIn(duration: 700.ms)
              .slideY(
                begin: 0.2,
                end: 0,
                duration: 700.ms,
                curve: Curves.easeOut,
              ),
        ],
      ),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  GREETING BANNER
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildGreetingBanner(bool isDark, bool isMobile) {
    final user = AuthService.currentUserData!;
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Good Morning'
        : hour < 17
        ? 'Good Afternoon'
        : 'Good Evening';

    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppTheme.colorFF27AE60, AppTheme.colorFF1A8A4A],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(isMobile ? 16 : 20),
        boxShadow: [
          BoxShadow(
            color: AppTheme.colorFF27AE60.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: isMobile ? 52 : 64,
            height: isMobile ? 52 : 64,
            decoration: BoxDecoration(
              color: AppTheme.white.withValues(alpha: 0.2),
              shape: BoxShape.circle,
              border: Border.all(
                color: AppTheme.white.withValues(alpha: 0.4),
                width: 2,
              ),
            ),
            child: Center(
              child: Text(
                user.fullName[0].toUpperCase(),
                style: TextStyle(
                  fontSize: isMobile ? 24 : 28,
                  fontWeight: FontWeight.w900,
                  color: AppTheme.white,
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  greeting,
                  style: TextStyle(
                    fontSize: isMobile ? 13 : 14,
                    color: AppTheme.white.withValues(alpha: 0.8),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  user.fullName,
                  style: TextStyle(
                    fontSize: isMobile ? 18 : 22,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.white,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: AppTheme.white,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      'Active',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.white,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _assignedVehicleLabel(),
                style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.white.withValues(alpha: 0.8),
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
  //  STAT CARDS â€” identical style to DashboardPage._buildTopStatCard
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildTopStatsCards(bool isDark, bool isMobile) {
    final stats = _dashboardData!['todayStats'] as Map<String, dynamic>;
    final screenWidth = MediaQuery.of(context).size.width;
    final cards = [
      _buildTopStatCard(
        title: 'TRIPS TODAY',
        value: '${stats['tripsCompleted']}/${stats['tripsAssigned']}',
        subtitle: 'completed',
        icon: Icons.check_circle_rounded,
        color: AppTheme.colorFF27AE60,
        isDark: isDark,
      ),
      _buildTopStatCard(
        title: 'EARNINGS',
        value: stats['earnings'],
        subtitle: 'today',
        icon: Icons.payments_rounded,
        color: AppTheme.colorFF4B7BE5,
        isDark: isDark,
      ),
      _buildTopStatCard(
        title: 'DISTANCE',
        value: stats['distance'],
        subtitle: 'driven today',
        icon: Icons.route_rounded,
        color: AppTheme.colorFFF39C12,
        isDark: isDark,
      ),
      _buildTopStatCard(
        title: 'HOURS WORKED',
        value: stats['hoursWorked'],
        subtitle: 'today',
        icon: Icons.access_time_rounded,
        color: AppTheme.colorFFE74C3C,
        isDark: isDark,
      ),
    ];

    if (screenWidth >= 1000) {
      return Row(
        children: cards
            .asMap()
            .entries
            .map(
              (e) => Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    right: e.key < cards.length - 1 ? 20 : 0,
                  ),
                  child: e.value,
                ),
              ),
            )
            .toList(),
      );
    }
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: cards[0]),
            const SizedBox(width: 12),
            Expanded(child: cards[1]),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: cards[2]),
            const SizedBox(width: 12),
            Expanded(child: cards[3]),
          ],
        ),
      ],
    );
  }

  Widget _buildTopStatCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
    required bool isDark,
  }) {
    final sw = MediaQuery.of(context).size.width;
    final cardPadding = sw < 360
        ? 12.0
        : sw < 600
        ? 16.0
        : 20.0;
    final br = sw < 360
        ? 10.0
        : sw < 600
        ? 12.0
        : 16.0;
    final titleSz = sw < 360
        ? 9.0
        : sw < 600
        ? 10.0
        : 11.0;
    final valueSz = sw < 360
        ? 20.0
        : sw < 600
        ? 24.0
        : 32.0;
    final subSz = sw < 360
        ? 9.0
        : sw < 600
        ? 10.0
        : 11.0;
    final iconSz = sw < 360
        ? 16.0
        : sw < 600
        ? 18.0
        : 20.0;
    final iconPad = sw < 360 ? 6.0 : 8.0;
    final spSm = sw < 360
        ? 4.0
        : sw < 600
        ? 6.0
        : 8.0;
    final spMd = sw < 360
        ? 6.0
        : sw < 600
        ? 8.0
        : 12.0;

    return Container(
      padding: EdgeInsets.all(cardPadding),
      decoration: BoxDecoration(
        gradient: isDark
            ? LinearGradient(
                colors: [
                  color.withValues(alpha: 0.3),
                  color.withValues(alpha: 0.1),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: isDark ? null : color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(br),
        border: Border.all(
          color: isDark
              ? color.withValues(alpha: 0.3)
              : color.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: titleSz,
                    fontWeight: FontWeight.w600,
                    color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                    letterSpacing: 0.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(width: spSm),
              Container(
                padding: EdgeInsets.all(iconPad),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: iconSz),
              ),
            ],
          ),
          SizedBox(height: spMd),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                fontSize: valueSz,
                fontWeight: FontWeight.w700,
                color: isDark ? AppTheme.white : color,
              ),
            ),
          ),
          SizedBox(height: spSm),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: subSz,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  CHARTS SECTION
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildChartsSection(bool isDark, bool isMobile) {
    if (MediaQuery.of(context).size.width < 1024) {
      return Column(
        children: [
          _buildCurrentTrip(isDark, isMobile),
          SizedBox(height: isMobile ? 16 : 20),
          _buildWeeklyEarningsChart(isDark, isMobile),
        ],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 5, child: _buildCurrentTrip(isDark, false)),
          const SizedBox(width: 24),
          Expanded(flex: 5, child: _buildWeeklyEarningsChart(isDark, false)),
        ],
      ),
    );
  }

  Widget _buildCurrentTrip(bool isDark, bool isMobile) {
    final raw = _dashboardData!['currentTrip'];
    final trip = raw is Map<String, dynamic> ? raw : null;
    if (trip == null) {
      return Container(
        padding: const EdgeInsets.all(32),
        decoration: _card(isDark),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.check_circle_outline_rounded,
              size: 64,
              color: isDark ? AppTheme.gray700 : AppTheme.gray300,
            ),
            const SizedBox(height: 16),
            Text(
              'No Active Trip',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: isDark ? AppTheme.gray500 : AppTheme.gray400,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              "You're all caught up!",
              style: TextStyle(
                fontSize: 13,
                color: isDark ? AppTheme.gray600 : AppTheme.gray500,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppTheme.colorFF27AE60, AppTheme.colorFF1A8A4A],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(isMobile ? 16 : 20),
        boxShadow: [
          BoxShadow(
            color: AppTheme.colorFF27AE60.withValues(alpha: 0.3),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.local_shipping_rounded,
                color: AppTheme.white,
                size: 24,
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Current Trip',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.white,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  trip['status'],
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.white,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _tripRow(Icons.location_on_rounded, 'Pickup', trip['pickup']),
          const SizedBox(height: 10),
          _tripRow(Icons.flag_rounded, 'Dropoff', trip['dropoff']),
          const SizedBox(height: 10),
          _tripRow(Icons.business_rounded, 'Customer', trip['customer']),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _tripChip(
                  Icons.access_time_rounded,
                  (trip['estimatedArrival'] ?? '-').toString(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _tripChip(
                  Icons.route_rounded,
                  (trip['distance'] ?? '-').toString(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _tripChip(
                  Icons.inventory_2_rounded,
                  (trip['cargo'] ?? '-').toString(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () async {
              final tripId = trip['tripId']?.toString() ?? '';
              if (tripId.isEmpty) return;
              final realId = DriverDataService.findRealTripId(tripId);
              if (realId == null) return;

              // Find the full trip data from the store
              final tripData = tripsNotifier.value.firstWhere(
                (t) => t['tripId'] == realId,
                orElse: () => <String, dynamic>{},
              );

              // Show driver signature capture modal
              final submitted = await showTripCompletionModal(
                context,
                tripId: realId,
                tripData: tripData,
              );

              if (submitted == true && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text(
                      'Trip submitted for approval! Awaiting admin sign-off.',
                    ),
                    backgroundColor: AppTheme.colorFF9B59B6,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    margin: const EdgeInsets.all(16),
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.white,
              foregroundColor: AppTheme.colorFF27AE60,
              minimumSize: const Size(double.infinity, 48),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              'Complete Trip',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
          ).animate().fadeIn(duration: 300.ms),
          // â”€â”€ Navigate to Trips page to mark complete â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        ],
      ),
    );
  }

  Widget _tripRow(IconData icon, String label, String value) => Row(
    children: [
      Icon(icon, color: AppTheme.white.withValues(alpha: 0.8), size: 18),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.white.withValues(alpha: 0.7),
              ),
            ),
            Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.white,
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _tripChip(IconData icon, String value) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: AppTheme.white.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      children: [
        Icon(icon, color: AppTheme.white, size: 18),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppTheme.white,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );

  Widget _buildWeeklyEarningsChart(bool isDark, bool isMobile) {
    const green = AppTheme.colorFF27AE60;
    final rows = _weeklyEarningsChartRows();
    final spots = [
      for (var index = 0; index < rows.length; index++)
        FlSpot(index.toDouble(), rows[index]['amount'] as double),
    ];
    final days = rows
        .map((row) => row['label']?.toString() ?? '-')
        .toList(growable: false);
    final maxAmount = rows.fold<double>(
      0,
      (peak, row) =>
          (row['amount'] as double) > peak ? row['amount'] as double : peak,
    );
    final maxY = maxAmount <= 0
        ? 1000.0
        : (((maxAmount * 1.25) / 500).ceil() * 500).toDouble();
    final interval = (maxY / 4).ceil().toDouble();

    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: _card(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Weekly Earnings',
            style: TextStyle(
              fontSize: isMobile ? 16 : 18,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Last 7 days - PHP',
            style: TextStyle(
              fontSize: isMobile ? 12 : 13,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: isMobile ? 200 : 280,
            child: LineChart(
              LineChartData(
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: interval,
                  getDrawingHorizontalLine: (v) => FlLine(
                    color: isDark ? AppTheme.gray800 : AppTheme.gray300,
                    strokeWidth: 1,
                  ),
                ),
                titlesData: FlTitlesData(
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 30,
                      getTitlesWidget: (v, _) {
                        final i = v.toInt();
                        if (i < 0 || i >= days.length) return const SizedBox();
                        return Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            days[i],
                            style: TextStyle(
                              fontSize: isMobile ? 9 : 11,
                              color: isDark
                                  ? AppTheme.gray400
                                  : AppTheme.gray600,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: isMobile ? 52 : 62,
                      interval: interval,
                      getTitlesWidget: (v, _) => Text(
                        'PHP ${(v / 1000).toStringAsFixed(1)}k',
                        style: TextStyle(
                          fontSize: isMobile ? 9 : 11,
                          color: isDark ? AppTheme.gray500 : AppTheme.gray600,
                        ),
                      ),
                    ),
                  ),
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                ),
                borderData: FlBorderData(show: false),
                minX: 0,
                maxX: (rows.length - 1).toDouble(),
                minY: 0,
                maxY: maxY,
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    color: green,
                    barWidth: 3,
                    isStrokeCapRound: true,
                    dotData: FlDotData(
                      show: true,
                      getDotPainter: (s, _, __, ___) => FlDotCirclePainter(
                        radius: 4,
                        color: green,
                        strokeWidth: 2,
                        strokeColor: isDark
                            ? AppTheme.colorFF1A1D23
                            : AppTheme.white,
                      ),
                    ),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        colors: [
                          green.withValues(alpha: 0.3),
                          green.withValues(alpha: 0.0),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  BOTTOM SECTION
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildBottomSection(bool isDark, bool isMobile) {
    if (MediaQuery.of(context).size.width < 900) {
      return Column(
        children: [
          _buildUpcomingTrips(isDark, isMobile),
          SizedBox(height: isMobile ? 16 : 20),
          _buildWeekSummary(isDark, isMobile),
        ],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 6, child: _buildUpcomingTrips(isDark, false)),
          const SizedBox(width: 24),
          Expanded(flex: 4, child: _buildWeekSummary(isDark, false)),
        ],
      ),
    );
  }

  Widget _buildUpcomingTrips(bool isDark, bool isMobile) {
    final trips = _dashboardData!['upcomingTrips'] as List<dynamic>? ?? [];

    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: _card(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Upcoming Trips',
                    style: TextStyle(
                      fontSize: isMobile ? 16 : 18,
                      fontWeight: FontWeight.w700,
                      color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${trips.length} scheduled',
                    style: TextStyle(
                      fontSize: isMobile ? 12 : 13,
                      color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                    ),
                  ),
                ],
              ),
              TextButton.icon(
                onPressed: () =>
                    Navigator.pushReplacementNamed(context, '/driver-trips'),
                icon: const Icon(Icons.arrow_forward, size: 16),
                label: const Text('View All'),
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.colorFF27AE60,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (trips.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No upcoming trips',
                  style: TextStyle(
                    color: isDark ? AppTheme.gray600 : AppTheme.gray400,
                  ),
                ),
              ),
            )
          else
            ...trips.map(
              (t) => _upcomingRow(t as Map<String, dynamic>, isDark, isMobile),
            ),
        ],
      ),
    );
  }

  Widget _upcomingRow(Map<String, dynamic> trip, bool isDark, bool isMobile) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF8FAFD,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.06)
              : AppTheme.black.withValues(alpha: 0.05),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.route_rounded,
              color: AppTheme.colorFF4B7BE5,
              size: 20,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${trip['pickup']}  ->  ${trip['dropoff']}',
                  style: TextStyle(
                    fontSize: isMobile ? 12 : 13,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Icon(
                      Icons.access_time_rounded,
                      size: 12,
                      color: isDark ? AppTheme.gray500 : AppTheme.gray500,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      trip['time'],
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Text(
            trip['payment'],
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w900,
              color: AppTheme.colorFF27AE60,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWeekSummary(bool isDark, bool isMobile) {
    final w =
        (_dashboardData!['weekSummary'] as Map<String, dynamic>?) ??
        {
          'totalTrips': 0,
          'totalEarnings': 'PHP 0',
          'avgRating': '0.0',
          'onTimeRate': 0,
          'totalDistance': '0 km',
        };
    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: _card(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Week Summary',
            style: TextStyle(
              fontSize: isMobile ? 16 : 18,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "This week's performance",
            style: TextStyle(
              fontSize: isMobile ? 12 : 13,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
            ),
          ),
          const SizedBox(height: 20),
          _weekRow(
            'Total Trips',
            '${w['totalTrips']}',
            Icons.route_rounded,
            AppTheme.colorFF4B7BE5,
            isDark,
          ),
          const SizedBox(height: 10),
          _weekRow(
            'Earnings',
            w['totalEarnings'],
            Icons.payments_rounded,
            AppTheme.colorFF27AE60,
            isDark,
          ),
          const SizedBox(height: 10),
          _weekRow(
            'Avg Rating',
            '${w['avgRating']}/5.0',
            Icons.star_rounded,
            AppTheme.colorFFF39C12,
            isDark,
          ),
          const SizedBox(height: 10),
          _weekRow(
            'On-Time',
            '${w['onTimeRate']}%',
            Icons.check_circle_rounded,
            AppTheme.colorFF27AE60,
            isDark,
          ),
        ],
      ),
    );
  }

  Widget _weekRow(
    String label,
    String value,
    IconData icon,
    Color color,
    bool isDark,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF8FAFD,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.06)
              : AppTheme.black.withValues(alpha: 0.05),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 16),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
          ),
        ],
      ),
    );
  }

  String _assignedVehicleLabel() {
    final driverVehicle = DriverDataService.getDriverVehicle();
    final plate = driverVehicle?['plate']?.toString().trim() ?? '';
    if (plate.isNotEmpty && plate.toLowerCase() != 'unassigned') {
      return plate;
    }

    final currentTrip = _dashboardData?['currentTrip'] as Map<String, dynamic>?;
    final vehicle = currentTrip?['vehicle']?.toString().trim() ?? '';
    if (vehicle.isNotEmpty && vehicle.toLowerCase() != 'n/a') {
      return vehicle;
    }

    return 'Awaiting assignment';
  }

  List<Map<String, dynamic>> _weeklyEarningsChartRows() {
    final earnings = DriverDataService.getEarningsData();
    final rawRows =
        (earnings['breakdown'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        const <Map<String, dynamic>>[];

    if (rawRows.isEmpty) {
      return List.generate(7, (index) {
        final day = DateTime.now().subtract(Duration(days: 6 - index));
        return {'label': _weekdayLabel(day.weekday), 'amount': 0.0};
      });
    }

    final recentRows = rawRows.length > 7
        ? rawRows.sublist(rawRows.length - 7)
        : rawRows;

    return recentRows
        .map((row) {
          return {
            'label': _compactChartLabel(row['date']),
            'amount': _moneyToDouble(row['amount']),
          };
        })
        .toList(growable: false);
  }

  String _compactChartLabel(dynamic raw) {
    final value = raw?.toString().trim() ?? '';
    if (value.isEmpty) {
      return '-';
    }

    final parsed = DateTime.tryParse(value);
    if (parsed != null) {
      return _weekdayLabel(parsed.weekday);
    }

    final parts = value.split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      final day = parts[1].replaceAll(RegExp(r'[^0-9]'), '');
      final prefix = parts.first.length >= 3
          ? parts.first.substring(0, 3)
          : parts.first;
      return day.isEmpty ? prefix : '$prefix $day';
    }

    return value.length > 6 ? value.substring(0, 6) : value;
  }

  String _weekdayLabel(int weekday) {
    const labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final safeWeekday = weekday < 1 ? 1 : (weekday > 7 ? 7 : weekday);
    return labels[safeWeekday - 1];
  }

  double _moneyToDouble(dynamic value) {
    final raw = value?.toString().replaceAll(RegExp(r'[^0-9.-]'), '') ?? '';
    return double.tryParse(raw) ?? 0.0;
  }

  BoxDecoration _card(bool isDark) => BoxDecoration(
    color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
    borderRadius: BorderRadius.circular(20),
    border: Border.all(
      color: isDark
          ? AppTheme.white.withValues(alpha: 0.08)
          : AppTheme.black.withValues(alpha: 0.05),
    ),
    boxShadow: [
      BoxShadow(
        color: AppTheme.black.withValues(alpha: isDark ? 0.2 : 0.02),
        blurRadius: 10,
        offset: const Offset(0, 4),
      ),
    ],
  );
}
