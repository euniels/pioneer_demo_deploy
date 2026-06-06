import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../widgets/dashboard_layout.dart';
import '../services/auth.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';

class FinanceProfilePage extends StatefulWidget {
  const FinanceProfilePage({super.key});
  @override
  State<FinanceProfilePage> createState() => _FinanceProfilePageState();
}

class _FinanceProfilePageState extends State<FinanceProfilePage>
    with TickerProviderStateMixin {
  late AnimationController _cardAnimationController;
  late AnimationController _chartAnimationController;

  bool _isMobile(BuildContext context) =>
      MediaQuery.of(context).size.width < 600;
  bool _isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= 600 &&
      MediaQuery.of(context).size.width < 1024;

  // Finance accent â€” purple/violet
  static const Color _accent = AppTheme.colorFF8E2DE2;
  static const Color _accentDark = AppTheme.colorFF7A1FC7;

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
      currentRoute: '/finance-profile',
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
  //  HERO â€” purple gradient
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
                  'Finance Officer',
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
                      Icons.account_balance_rounded,
                      'Finance Dept.',
                      AppTheme.white,
                    ),
                    _heroBadge(
                      Icons.verified_user_rounded,
                      'CPA Certified',
                      AppTheme.white,
                    ),
                  ],
                ),
              ],
            ),
          ),
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
                        'PHP 2.4M',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          color: AppTheme.white,
                        ),
                      ),
                      Text(
                        'managed',
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
  //  KPI CARDS â€” finance-specific metrics
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildKpiCards(bool isDark, bool isMobile) {
    final sw = MediaQuery.of(context).size.width;
    final cards = [
      _statCard(
        title: 'TOTAL REVENUE',
        value: 'PHP 2.4M',
        subtitle: 'this month',
        icon: Icons.attach_money_rounded,
        color: AppTheme.colorFF27AE60,
        isDark: isDark,
      ),
      _statCard(
        title: 'OUTSTANDING',
        value: 'PHP 340K',
        subtitle: 'unpaid invoices',
        icon: Icons.receipt_long_rounded,
        color: AppTheme.colorFFF39C12,
        isDark: isDark,
      ),
      _statCard(
        title: 'TOTAL EXPENSES',
        value: 'PHP 890K',
        subtitle: 'this month',
        icon: Icons.trending_down_rounded,
        color: _accent,
        isDark: isDark,
      ),
      _statCard(
        title: 'NET PROFIT',
        value: 'PHP 137K',
        subtitle: '+8.3% vs last month',
        icon: Icons.savings_rounded,
        color: AppTheme.colorFF4B7BE5,
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
  //  CHARTS â€” monthly cashflow bar chart + expense breakdown
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildChartsSection(bool isDark, bool isMobile) {
    if (MediaQuery.of(context).size.width < 1024) {
      return Column(
        children: [
          _buildCashflowChart(isDark, isMobile),
          SizedBox(height: isMobile ? 16 : 20),
          _buildExpenseBreakdown(isDark, isMobile),
        ],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 6, child: _buildCashflowChart(isDark, false)),
          const SizedBox(width: 24),
          Expanded(flex: 4, child: _buildExpenseBreakdown(isDark, false)),
        ],
      ),
    );
  }

  Widget _buildCashflowChart(bool isDark, bool isMobile) {
    final incomeVals = [
      2100.0,
      2300.0,
      1900.0,
      2500.0,
      2800.0,
      2400.0,
      2600.0,
      2900.0,
      3100.0,
      2700.0,
      3300.0,
      3500.0,
    ];
    final expenseVals = [
      1200.0,
      1100.0,
      1300.0,
      1150.0,
      1400.0,
      1250.0,
      1350.0,
      1500.0,
      1600.0,
      1450.0,
      1700.0,
      1800.0,
    ];
    const months = ['J', 'F', 'M', 'A', 'M', 'J', 'J', 'A', 'S', 'O', 'N', 'D'];

    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: _card(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Monthly Cashflow',
            style: TextStyle(
              fontSize: isMobile ? 16 : 18,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Income vs Expenses - 2025',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: isMobile ? 200 : 280,
            child: BarChart(
              BarChartData(
                alignment: BarChartAlignment.spaceAround,
                maxY: 4000,
                barTouchData: BarTouchData(
                  enabled: true,
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
                      reservedSize: 28,
                      getTitlesWidget: (v, _) {
                        final i = v.toInt();
                        if (i < 0 || i >= months.length)
                          return const SizedBox();
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            months[i],
                            style: TextStyle(
                              fontSize: isMobile ? 9 : 10,
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
                      interval: 1000,
                      getTitlesWidget: (v, _) => Text(
                        'PHP ${(v / 1000).toStringAsFixed(0)}k',
                        style: TextStyle(
                          fontSize: isMobile ? 9 : 10,
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
                  horizontalInterval: 1000,
                  getDrawingHorizontalLine: (v) => FlLine(
                    color: isDark ? AppTheme.gray800 : AppTheme.gray200,
                    strokeWidth: 1,
                  ),
                ),
                borderData: FlBorderData(show: false),
                barGroups: List.generate(
                  12,
                  (i) => BarChartGroupData(
                    x: i,
                    barsSpace: 3,
                    barRods: [
                      BarChartRodData(
                        toY: incomeVals[i],
                        gradient: LinearGradient(
                          colors: [_accent, _accent.withValues(alpha: 0.5)],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                        width: isMobile ? 8 : 12,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(4),
                        ),
                      ),
                      BarChartRodData(
                        toY: expenseVals[i],
                        gradient: LinearGradient(
                          colors: [
                            AppTheme.colorFFF39C12,
                            AppTheme.colorFFF39C12.withValues(alpha: 0.5),
                          ],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                        width: isMobile ? 8 : 12,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(4),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _legendDot('Income', _accent),
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

  Widget _buildExpenseBreakdown(bool isDark, bool isMobile) {
    final expenses = [
      {
        'label': 'Fuel',
        'pct': 0.38,
        'amount': 'PHP 338K',
        'color': AppTheme.colorFFE74C3C,
      },
      {
        'label': 'Maintenance',
        'pct': 0.25,
        'amount': 'PHP 222K',
        'color': AppTheme.colorFFF39C12,
      },
      {
        'label': 'Salaries',
        'pct': 0.22,
        'amount': 'PHP 196K',
        'color': _accent,
      },
      {
        'label': 'Insurance',
        'pct': 0.10,
        'amount': 'PHP 89K',
        'color': AppTheme.colorFF4B7BE5,
      },
      {
        'label': 'Miscellaneous',
        'pct': 0.05,
        'amount': 'PHP 45K',
        'color': AppTheme.colorFF27AE60,
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
            'Expense Breakdown',
            style: TextStyle(
              fontSize: isMobile ? 16 : 18,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'This month\'s allocation',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
            ),
          ),
          const SizedBox(height: 24),
          ...expenses.map((e) {
            final color = e['color'] as Color;
            final pct = e['pct'] as double;
            return Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        e['label'] as String,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? AppTheme.gray300
                              : AppTheme.colorFF2C3E50,
                        ),
                      ),
                      Row(
                        children: [
                          Text(
                            '${(pct * 100).toInt()}%',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? AppTheme.gray400
                                  : AppTheme.gray600,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            e['amount'] as String,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: isDark
                                  ? AppTheme.white
                                  : AppTheme.colorFF2C3E50,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Stack(
                    children: [
                      Container(
                        height: 6,
                        decoration: BoxDecoration(
                          color: isDark ? AppTheme.gray800 : AppTheme.gray200,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      FractionallySizedBox(
                        widthFactor: pct,
                        child: Container(
                          height: 6,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [color, color.withValues(alpha: 0.6)],
                            ),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ],
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
  //  DETAILS â€” personal info + finance responsibilities
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
            'Finance Information',
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
            user.id ?? 'FIN-001',
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
            user.phone ?? '+63 917 000 0002',
            AppTheme.colorFF4B7BE5,
            isDark,
            isMobile,
          ),
          _infoRow(
            Icons.domain_rounded,
            'Department',
            'Finance & Accounting',
            AppTheme.colorFFF39C12,
            isDark,
            isMobile,
          ),
          _infoRow(
            Icons.manage_accounts_rounded,
            'Role',
            user.roleName ?? 'Finance Officer',
            _accent,
            isDark,
            isMobile,
          ),
          _infoRow(
            Icons.description_outlined,
            'Overview',
            user.roleDescription ?? 'Financial management and reporting',
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
        'icon': Icons.receipt_long_rounded,
        'color': _accent,
        'title': 'Invoice Management',
        'desc':
            'Process, track, and follow up on client invoices and outstanding receivables.',
      },
      {
        'icon': Icons.account_balance_rounded,
        'color': AppTheme.colorFF27AE60,
        'title': 'Budget Control',
        'desc':
            'Monitor departmental spending, prepare budgets, and flag cost overruns.',
      },
      {
        'icon': Icons.bar_chart_rounded,
        'color': AppTheme.colorFF4B7BE5,
        'title': 'Financial Reporting',
        'desc':
            'Prepare monthly P&L statements, balance sheets, and variance analysis reports.',
      },
      {
        'icon': Icons.local_gas_station_rounded,
        'color': AppTheme.colorFFF39C12,
        'title': 'Expense Tracking',
        'desc':
            'Record and categorize fuel, maintenance, and operational expenses accurately.',
      },
      {
        'icon': Icons.gavel_rounded,
        'color': _accent,
        'title': 'Tax & Compliance',
        'desc':
            'Ensure tax filings are accurate, timely, and aligned with BIR regulations.',
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
            'Key financial duties',
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
