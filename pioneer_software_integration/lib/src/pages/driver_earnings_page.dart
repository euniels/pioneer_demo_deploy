import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../widgets/dashboard_layout.dart';
import '../services/auth.dart';
import '../services/api.dart';
import '../services/trips_store.dart';
import '../widgets/app_state_widgets.dart';
import '../widgets/page_skeletons.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';

class DriverEarningsPage extends StatefulWidget {
  const DriverEarningsPage({super.key});
  @override
  State<DriverEarningsPage> createState() => _DriverEarningsPageState();
}

class _DriverEarningsPageState extends State<DriverEarningsPage>
    with TickerProviderStateMixin {
  Map<String, dynamic>? _earningsData;
  bool _isLoading = true;
  late AnimationController _cardAnimationController;
  late AnimationController _chartAnimationController;

  bool _isMobile(BuildContext context) =>
      MediaQuery.of(context).size.width < 600;
  bool _isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= 600 &&
      MediaQuery.of(context).size.width < 1024;

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
    // Refresh earnings when trips are completed
    tripsNotifier.addListener(_onStoreChanged);
    _loadEarnings();
  }

  void _onStoreChanged() {
    if (mounted) _loadEarnings();
  }

  @override
  void dispose() {
    tripsNotifier.removeListener(_onStoreChanged);
    _cardAnimationController.dispose();
    _chartAnimationController.dispose();
    super.dispose();
  }

  Future<void> _loadEarnings() async {
    final user = AuthService.currentUserData;
    if (user == null) return;
    try {
      final data = await Api.getDriverEarnings();
      if (mounted) {
        setState(() {
          _earningsData = data;
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

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      currentRoute: '/driver-earnings',
      title: 'My Earnings',
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      return const PioneerRouteSkeletonBody(routeName: '/driver-earnings');
    }
    if (_earningsData == null) {
      return PioneerStateCard(
        icon: Icons.payments_rounded,
        title: 'Earnings could not be loaded',
        message:
            'We could not refresh your earnings right now. Retry without leaving this page.',
        actionLabel: 'Retry',
        tone: PioneerStateTone.error,
        onAction: _loadEarnings,
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
          // â”€â”€ Summary cards â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
          _buildSummaryCards(isDark, isMobile)
              .animate()
              .fadeIn(duration: 500.ms)
              .slideY(
                begin: 0.2,
                end: 0,
                duration: 500.ms,
                curve: Curves.easeOut,
              ),
          SizedBox(height: isMobile ? 20 : 32),
          // â”€â”€ Charts section â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
          // â”€â”€ Earnings breakdown â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
          _buildBreakdownTable(isDark, isMobile)
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
  //  SUMMARY CARDS â€” same gradient+border style as stat cards in DashboardPage
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildSummaryCards(bool isDark, bool isMobile) {
    final today = _earningsData!['today'] as Map<String, dynamic>;
    final week = _earningsData!['thisWeek'] as Map<String, dynamic>;
    final month = _earningsData!['thisMonth'] as Map<String, dynamic>;
    final sw = MediaQuery.of(context).size.width;

    final cards = [
      _earningStatCard(
        title: 'TODAY',
        value: today['amount'],
        subtitle: '${today['trips']} trips Â· ${today['hours']} hrs',
        icon: Icons.today_rounded,
        color: AppTheme.colorFF27AE60,
        isDark: isDark,
      ),
      _earningStatCard(
        title: 'THIS WEEK',
        value: week['amount'],
        subtitle: '${week['trips']} trips Â· ${week['hours']} hrs',
        icon: Icons.date_range_rounded,
        color: AppTheme.colorFF4B7BE5,
        isDark: isDark,
      ),
      _earningStatCard(
        title: 'THIS MONTH',
        value: month['amount'],
        subtitle: '${month['trips']} trips Â· ${month['hours']} hrs',
        icon: Icons.calendar_month_rounded,
        color: AppTheme.colorFFF39C12,
        isDark: isDark,
      ),
    ];

    if (sw >= 900) {
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
      children: cards
          .map(
            (c) =>
                Padding(padding: const EdgeInsets.only(bottom: 12), child: c),
          )
          .toList(),
    );
  }

  /// Uses same exact gradient/border pattern as DashboardPage _buildTopStatCard
  Widget _earningStatCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
    required bool isDark,
  }) {
    final sw = MediaQuery.of(context).size.width;
    final pad = sw < 360
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
        ? 22.0
        : sw < 600
        ? 26.0
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

    return Container(
      padding: EdgeInsets.all(pad),
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
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: iconSz),
              ),
            ],
          ),
          const SizedBox(height: 12),
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
          const SizedBox(height: 4),
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
  //  CHARTS SECTION â€” bar chart + pending card
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildChartsSection(bool isDark, bool isMobile) {
    if (MediaQuery.of(context).size.width < 1024) {
      return Column(
        children: [
          _buildBarChart(isDark, isMobile),
          SizedBox(height: isMobile ? 16 : 20),
          _buildPendingCard(isDark, isMobile),
        ],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 6, child: _buildBarChart(isDark, false)),
          const SizedBox(width: 24),
          Expanded(flex: 4, child: _buildPendingCard(isDark, false)),
        ],
      ),
    );
  }

  Widget _buildBarChart(bool isDark, bool isMobile) {
    const green = AppTheme.colorFF27AE60;
    final rows = _barChartRows();
    final days = rows
        .map((row) => row['label']?.toString() ?? '-')
        .toList(growable: false);
    final values = rows
        .map((row) => row['amount'] as double)
        .toList(growable: false);
    final maxAmount = values.fold<double>(
      0,
      (peak, value) => value > peak ? value : peak,
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
            'Earnings This Week',
            style: TextStyle(
              fontSize: isMobile ? 16 : 18,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Daily breakdown - PHP',
            style: TextStyle(
              fontSize: isMobile ? 12 : 13,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: isMobile ? 200 : 280,
            child: BarChart(
              BarChartData(
                alignment: BarChartAlignment.spaceAround,
                maxY: maxY,
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    tooltipBgColor: isDark
                        ? AppTheme.colorFF252930
                        : AppTheme.white,
                    getTooltipItem: (g, gi, r, ri) => BarTooltipItem(
                      'PHP ${r.toY.toInt()}',
                      TextStyle(
                        color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
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
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: interval,
                  getDrawingHorizontalLine: (v) => FlLine(
                    color: isDark ? AppTheme.gray800 : AppTheme.gray300,
                    strokeWidth: 1,
                  ),
                ),
                borderData: FlBorderData(show: false),
                barGroups: List.generate(
                  values.length,
                  (i) => BarChartGroupData(
                    x: i,
                    barRods: [
                      BarChartRodData(
                        toY: values[i],
                        gradient: LinearGradient(
                          colors: [green, green.withValues(alpha: 0.5)],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                        width: isMobile ? 24 : 32,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(6),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingCard(bool isDark, bool isMobile) {
    final pending = _earningsData!['pendingPayments'];
    final nextPayout = _earningsData!['nextPayoutDate'];
    final today = (_earningsData!['today'] as Map<String, dynamic>)['amount'];
    final week = (_earningsData!['thisWeek'] as Map<String, dynamic>)['amount'];

    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: _card(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Pending Payment',
            style: TextStyle(
              fontSize: isMobile ? 16 : 18,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Awaiting payout',
            style: TextStyle(
              fontSize: isMobile ? 12 : 13,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
            ),
          ),
          const SizedBox(height: 24),
          // Pending amount card (orange gradient, matches current trip card style)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppTheme.colorFFF39C12, AppTheme.colorFFE67E22],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.colorFFF39C12.withValues(alpha: 0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.access_time_rounded,
                  color: AppTheme.white,
                  size: 28,
                ),
                const SizedBox(height: 12),
                Text(
                  pending,
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Next payout: $nextPayout',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.white.withValues(alpha: 0.85),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          // Quick stats reusing inner-row style
          _innerRow('Today', today, AppTheme.colorFF27AE60, isDark),
          const SizedBox(height: 10),
          _innerRow('This Week', week, AppTheme.colorFF4B7BE5, isDark),
        ],
      ),
    );
  }

  Widget _innerRow(String label, String value, Color color, bool isDark) {
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
            child: Icon(Icons.payments_rounded, color: color, size: 16),
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

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  BREAKDOWN TABLE â€” matches _buildRecentTripsTable style
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildBreakdownTable(bool isDark, bool isMobile) {
    final breakdown = _earningsData!['breakdown'] as List<dynamic>;

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
                    'Daily Earnings',
                    style: TextStyle(
                      fontSize: isMobile ? 16 : 18,
                      fontWeight: FontWeight.w700,
                      color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Recent breakdown',
                    style: TextStyle(
                      fontSize: isMobile ? 12 : 13,
                      color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.colorFF27AE60.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: AppTheme.colorFF27AE60.withValues(alpha: 0.3),
                  ),
                ),
                child: Text(
                  '${breakdown.length} days',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.colorFF27AE60,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Table header (matches DashboardPage DataTable header style)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF8FAFD,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'DATE',
                    style: TextStyle(
                      fontSize: isMobile ? 10 : 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                      color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                    ),
                  ),
                ),
                SizedBox(
                  width: 50,
                  child: Text(
                    'TRIPS',
                    style: TextStyle(
                      fontSize: isMobile ? 10 : 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                      color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                    ),
                  ),
                ),
                SizedBox(
                  width: 50,
                  child: Text(
                    'HOURS',
                    style: TextStyle(
                      fontSize: isMobile ? 10 : 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                      color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                    ),
                  ),
                ),
                SizedBox(
                  width: 80,
                  child: Text(
                    'AMOUNT',
                    style: TextStyle(
                      fontSize: isMobile ? 10 : 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                      color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // Rows
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: breakdown.length,
            itemBuilder: (ctx, i) {
              final day = breakdown[i] as Map<String, dynamic>;
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? AppTheme.colorFF0F1117
                      : AppTheme.colorFFF8FAFD,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isDark
                        ? AppTheme.white.withValues(alpha: 0.06)
                        : AppTheme.black.withValues(alpha: 0.05),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFF27AE60,
                              ).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(
                              Icons.calendar_today_rounded,
                              color: AppTheme.colorFF27AE60,
                              size: 16,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              day['date'],
                              style: TextStyle(
                                fontSize: isMobile ? 12 : 13,
                                fontWeight: FontWeight.w600,
                                color: isDark
                                    ? AppTheme.white
                                    : AppTheme.colorFF2C3E50,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 50,
                      child: Text(
                        '${day['trips']}',
                        style: TextStyle(
                          fontSize: isMobile ? 12 : 13,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? AppTheme.gray300
                              : AppTheme.colorFF2C3E50,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 50,
                      child: Text(
                        '${day['hours']}h',
                        style: TextStyle(
                          fontSize: isMobile ? 12 : 13,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? AppTheme.gray300
                              : AppTheme.colorFF2C3E50,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 80,
                      child: Text(
                        day['amount'],
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                          color: AppTheme.colorFF27AE60,
                        ),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  List<Map<String, dynamic>> _barChartRows() {
    final rawRows = _earningsBreakdownRows();
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

  List<Map<String, dynamic>> _earningsBreakdownRows() {
    return (_earningsData?['breakdown'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        const <Map<String, dynamic>>[];
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
