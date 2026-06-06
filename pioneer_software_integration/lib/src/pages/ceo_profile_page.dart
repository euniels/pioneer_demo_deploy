import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../widgets/dashboard_layout.dart';
import '../services/auth.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';

class CeoProfilePage extends StatefulWidget {
  const CeoProfilePage({super.key});
  @override
  State<CeoProfilePage> createState() => _CeoProfilePageState();
}

class _CeoProfilePageState extends State<CeoProfilePage>
    with TickerProviderStateMixin {
  late AnimationController _cardAnimationController;
  late AnimationController _chartAnimationController;

  bool _isMobile(BuildContext context) =>
      MediaQuery.of(context).size.width < 600;
  bool _isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= 600 &&
      MediaQuery.of(context).size.width < 1024;

  // CEO accent color
  static const Color _accent = AppTheme.colorFFE74C3C;
  static const Color _accentDark = AppTheme.colorFFC0392B;

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
    _cardAnimationController.forward();
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _chartAnimationController.forward();
    });
  }

  @override
  void dispose() {
    _cardAnimationController.dispose();
    _chartAnimationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      currentRoute: '/ceo-profile',
      title: 'My Profile',
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMobile = _isMobile(context);
    final isTablet = _isTablet(context);
    final user = AuthService.currentUserData;
    if (user == null) return const Center(child: Text('No user data'));

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
          _buildProfileHero(user, isDark, isMobile)
              .animate()
              .fadeIn(duration: 400.ms)
              .slideY(
                begin: 0.2,
                end: 0,
                duration: 400.ms,
                curve: Curves.easeOut,
              ),
          SizedBox(height: isMobile ? 20 : 32),
          _buildKpiCards(isDark, isMobile)
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
          _buildDetailsSection(user, isDark, isMobile)
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
  //  HERO â€” red/executive gradient
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildProfileHero(dynamic user, bool isDark, bool isMobile) {
    return Container(
      padding: EdgeInsets.all(isMobile ? 20 : 28),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [_accent, _accentDark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(isMobile ? 16 : 20),
        boxShadow: [
          BoxShadow(
            color: _accent.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: isMobile ? 72 : 88,
            height: isMobile ? 72 : 88,
            decoration: BoxDecoration(
              color: AppTheme.white,
              shape: BoxShape.circle,
              border: Border.all(color: AppTheme.white, width: 3),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.black.withValues(alpha: 0.15),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Center(
              child: Text(
                user.fullName[0].toUpperCase(),
                style: TextStyle(
                  fontSize: isMobile ? 30 : 36,
                  fontWeight: FontWeight.w900,
                  color: _accent,
                ),
              ),
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.fullName,
                  style: TextStyle(
                    fontSize: isMobile ? 20 : 24,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Chief Executive Officer',
                  style: TextStyle(
                    fontSize: isMobile ? 13 : 14,
                    color: AppTheme.white.withValues(alpha: 0.85),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _heroBadge(
                      Icons.verified_rounded,
                      'C-Suite',
                      AppTheme.white,
                    ),
                    _heroBadge(
                      Icons.domain_rounded,
                      'PioneerPath',
                      AppTheme.white,
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Right: approval rating (hidden on mobile to prevent overflow)
          if (!isMobile)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      const Text(
                        '98%',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: AppTheme.white,
                        ),
                      ),
                      Text(
                        'approval',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.white.withValues(alpha: 0.8),
                        ),
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

  Widget _heroBadge(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppTheme.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 13),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  KPI CARDS â€” CEO-specific metrics
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildKpiCards(bool isDark, bool isMobile) {
    final sw = MediaQuery.of(context).size.width;
    final cards = [
      _statCard(
        title: 'TOTAL REVENUE',
        value: 'PHP 2.4M',
        subtitle: '+12.5% this month',
        icon: Icons.trending_up_rounded,
        color: _accent,
        isDark: isDark,
      ),
      _statCard(
        title: 'NET PROFIT',
        value: 'PHP 890K',
        subtitle: '+8.3% this month',
        icon: Icons.attach_money_rounded,
        color: AppTheme.colorFF27AE60,
        isDark: isDark,
      ),
      _statCard(
        title: 'ACTIVE FLEET',
        value: '10',
        subtitle: '7 in transit',
        icon: Icons.local_shipping_rounded,
        color: AppTheme.colorFF4B7BE5,
        isDark: isDark,
      ),
      _statCard(
        title: 'FLEET UPTIME',
        value: '96.4%',
        subtitle: 'operational rate',
        icon: Icons.speed_rounded,
        color: AppTheme.colorFFF39C12,
        isDark: isDark,
      ),
    ];

    if (sw >= 1000) {
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

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  CHARTS â€” revenue trend + fleet performance
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildChartsSection(bool isDark, bool isMobile) {
    if (MediaQuery.of(context).size.width < 1024) {
      return Column(
        children: [
          _buildRevenueChart(isDark, isMobile),
          SizedBox(height: isMobile ? 16 : 20),
          _buildFleetPieCard(isDark, isMobile),
        ],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 6, child: _buildRevenueChart(isDark, false)),
          const SizedBox(width: 24),
          Expanded(flex: 4, child: _buildFleetPieCard(isDark, false)),
        ],
      ),
    );
  }

  Widget _buildRevenueChart(bool isDark, bool isMobile) {
    const spots = [
      FlSpot(0, 50),
      FlSpot(1, 52),
      FlSpot(2, 48),
      FlSpot(3, 54),
      FlSpot(4, 58),
      FlSpot(5, 56),
      FlSpot(6, 62),
      FlSpot(7, 65),
      FlSpot(8, 68),
      FlSpot(9, 72),
      FlSpot(10, 78),
      FlSpot(11, 85),
    ];
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

    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: _card(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Revenue vs Expenses',
            style: TextStyle(
              fontSize: isMobile ? 16 : 18,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Monthly trend - 2025',
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
                  horizontalInterval: 25,
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
                      interval: 1,
                      getTitlesWidget: (v, _) {
                        final i = v.toInt();
                        if (i < 0 || i >= months.length)
                          return const SizedBox();
                        return Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            months[i],
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
                      reservedSize: isMobile ? 40 : 50,
                      interval: 25,
                      getTitlesWidget: (v, _) => Text(
                        'PHP ${v.toInt()}M',
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
                maxX: 11,
                minY: 0,
                maxY: 100,
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    color: _accent,
                    barWidth: 3,
                    isStrokeCapRound: true,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        colors: [
                          _accent.withValues(alpha: 0.3),
                          _accent.withValues(alpha: 0.0),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                  LineChartBarData(
                    spots: const [
                      FlSpot(0, 25),
                      FlSpot(1, 26),
                      FlSpot(2, 24),
                      FlSpot(3, 28),
                      FlSpot(4, 30),
                      FlSpot(5, 32),
                      FlSpot(6, 35),
                      FlSpot(7, 38),
                      FlSpot(8, 40),
                      FlSpot(9, 42),
                      FlSpot(10, 45),
                      FlSpot(11, 48),
                    ],
                    isCurved: true,
                    color: AppTheme.colorFFF39C12,
                    barWidth: 3,
                    isStrokeCapRound: true,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        colors: [
                          AppTheme.colorFFF39C12.withValues(alpha: 0.3),
                          AppTheme.colorFFF39C12.withValues(alpha: 0.0),
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
          const SizedBox(height: 16),
          Row(
            children: [
              _legendDot('Revenue', _accent),
              const SizedBox(width: 20),
              _legendDot('Expenses', AppTheme.colorFFF39C12),
            ],
          ),
        ],
      ),
    );
  }

  Widget _legendDot(String label, Color color) => Row(
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    ],
  );

  Widget _buildFleetPieCard(bool isDark, bool isMobile) {
    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: _card(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Fleet Status Overview',
            style: TextStyle(
              fontSize: isMobile ? 16 : 18,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '10 total vehicles',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: isMobile ? 200 : 260,
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: PieChart(
                    PieChartData(
                      centerSpaceRadius: isMobile ? 40 : 48,
                      sectionsSpace: 3,
                      sections: [
                        PieChartSectionData(
                          value: 20,
                          color: AppTheme.colorFF27AE60,
                          title: '',
                          radius: isMobile ? 44 : 52,
                        ),
                        PieChartSectionData(
                          value: 50,
                          color: AppTheme.colorFF4B7BE5,
                          title: '',
                          radius: isMobile ? 44 : 52,
                        ),
                        PieChartSectionData(
                          value: 20,
                          color: _accent,
                          title: '',
                          radius: isMobile ? 44 : 52,
                        ),
                        PieChartSectionData(
                          value: 10,
                          color: AppTheme.colorFF6B7280,
                          title: '',
                          radius: isMobile ? 44 : 52,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 4,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _pieLegend('Active', '2', AppTheme.colorFF27AE60, isDark),
                      const SizedBox(height: 14),
                      _pieLegend(
                        'In Transit',
                        '5',
                        AppTheme.colorFF4B7BE5,
                        isDark,
                      ),
                      const SizedBox(height: 14),
                      _pieLegend('Maintenance', '2', _accent, isDark),
                      const SizedBox(height: 14),
                      _pieLegend('Idle', '1', AppTheme.colorFF6B7280, isDark),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pieLegend(String label, String count, Color color, bool isDark) =>
      Row(
        children: [
          Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: isDark ? AppTheme.gray300 : AppTheme.colorFF2C3E50,
              ),
            ),
          ),
          Text(
            count,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
          ),
        ],
      );

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  DETAILS â€” personal info + access & responsibilities
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildDetailsSection(dynamic user, bool isDark, bool isMobile) {
    if (MediaQuery.of(context).size.width < 900) {
      return Column(
        children: [
          _buildPersonalInfo(user, isDark, isMobile),
          SizedBox(height: isMobile ? 16 : 20),
          _buildResponsibilities(isDark, isMobile),
        ],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 5, child: _buildPersonalInfo(user, isDark, false)),
          const SizedBox(width: 24),
          Expanded(flex: 5, child: _buildResponsibilities(isDark, false)),
        ],
      ),
    );
  }

  Widget _buildPersonalInfo(dynamic user, bool isDark, bool isMobile) {
    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: _card(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Executive Information',
            style: TextStyle(
              fontSize: isMobile ? 16 : 18,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Account & contact details',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
            ),
          ),
          const SizedBox(height: 20),
          _infoRow(
            Icons.badge_rounded,
            'Employee ID',
            user.id ?? 'CEO-001',
            _accent,
            isDark,
            isMobile,
          ),
          _infoRow(
            Icons.email_rounded,
            'Email',
            user.email,
            AppTheme.colorFF27AE60,
            isDark,
            isMobile,
          ),
          _infoRow(
            Icons.phone_rounded,
            'Phone',
            user.phone ?? '+63 917 000 0001',
            AppTheme.colorFF4B7BE5,
            isDark,
            isMobile,
          ),
          _infoRow(
            Icons.domain_rounded,
            'Organization',
            'Pioneer Truck Corporation',
            AppTheme.colorFFF39C12,
            isDark,
            isMobile,
          ),
          _infoRow(
            Icons.manage_accounts_rounded,
            'Role',
            user.roleName ?? 'Chief Executive Officer',
            _accent,
            isDark,
            isMobile,
          ),
          _infoRow(
            Icons.description_outlined,
            'Overview',
            user.roleDescription ?? 'Full executive access',
            _accent,
            isDark,
            isMobile,
            isLast: true,
          ),
        ],
      ),
    );
  }

  Widget _infoRow(
    IconData icon,
    String label,
    String value,
    Color color,
    bool isDark,
    bool isMobile, {
    bool isLast = false,
  }) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, color: color, size: isMobile ? 17 : 19),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: isMobile ? 11 : 12,
                        color: isDark ? AppTheme.gray500 : AppTheme.gray500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      value,
                      style: TextStyle(
                        fontSize: isMobile ? 13 : 14,
                        fontWeight: FontWeight.w600,
                        color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (!isLast)
          Divider(
            height: 1,
            color: isDark
                ? AppTheme.white.withValues(alpha: 0.06)
                : AppTheme.black.withValues(alpha: 0.05),
          ),
      ],
    );
  }

  Widget _buildResponsibilities(bool isDark, bool isMobile) {
    final items = [
      {
        'icon': Icons.trending_up_rounded,
        'color': _accent,
        'title': 'Strategic Direction',
        'desc':
            'Define company vision, long-term goals, and growth strategy for the fleet business.',
      },
      {
        'icon': Icons.account_balance_rounded,
        'color': AppTheme.colorFF27AE60,
        'title': 'Financial Oversight',
        'desc':
            'Approve budgets, review P&L statements, and ensure profitability targets are met.',
      },
      {
        'icon': Icons.groups_rounded,
        'color': AppTheme.colorFF4B7BE5,
        'title': 'Executive Leadership',
        'desc':
            'Lead the management team and coordinate between departments and operations.',
      },
      {
        'icon': Icons.handshake_rounded,
        'color': AppTheme.colorFFF39C12,
        'title': 'Client Relations',
        'desc':
            'Manage key accounts, partnerships, and high-value client contracts.',
      },
      {
        'icon': Icons.policy_rounded,
        'color': _accent,
        'title': 'Compliance & Governance',
        'desc':
            'Ensure regulatory compliance, risk management, and corporate governance standards.',
      },
    ];

    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: _card(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Responsibilities',
            style: TextStyle(
              fontSize: isMobile ? 16 : 18,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Key areas of oversight',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
            ),
          ),
          const SizedBox(height: 20),
          ...items.map((item) {
            final color = item['color'] as Color;
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                gradient: isDark
                    ? LinearGradient(
                        colors: [
                          color.withValues(alpha: 0.18),
                          color.withValues(alpha: 0.04),
                        ],
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                      )
                    : null,
                color: isDark ? null : color.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDark
                      ? color.withValues(alpha: 0.22)
                      : color.withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      item['icon'] as IconData,
                      color: color,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item['title'] as String,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: isDark
                                ? AppTheme.white
                                : AppTheme.colorFF2C3E50,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          item['desc'] as String,
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
          }),
        ],
      ),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  SHARED HELPERS
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _statCard({
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
        ? 20.0
        : sw < 600
        ? 24.0
        : 30.0;
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
              SizedBox(width: spSm),
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
