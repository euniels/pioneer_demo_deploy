import 'package:flutter/material.dart';
import '../widgets/dashboard_layout.dart';
import '../services/auth.dart';
import '../services/api.dart';
import '../services/vehicles_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_state_widgets.dart';
import '../widgets/page_skeletons.dart';
import 'package:flutter_animate/flutter_animate.dart';

class DriverVehiclePage extends StatefulWidget {
  const DriverVehiclePage({super.key});
  @override
  State<DriverVehiclePage> createState() => _DriverVehiclePageState();
}

class _DriverVehiclePageState extends State<DriverVehiclePage>
    with TickerProviderStateMixin {
  Map<String, dynamic>? _vehicleData;
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
    // Refresh when admin updates vehicle assignments or status
    vehiclesNotifier.addListener(_onStoreChanged);
    _loadVehicle();
  }

  void _onStoreChanged() {
    if (mounted) _loadVehicle();
  }

  @override
  void dispose() {
    vehiclesNotifier.removeListener(_onStoreChanged);
    _cardAnimationController.dispose();
    _chartAnimationController.dispose();
    super.dispose();
  }

  Future<void> _loadVehicle() async {
    final user = AuthService.currentUserData;
    if (user == null) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
      return;
    }
    try {
      final data = await Api.getDriverVehicle();
      if (mounted) {
        setState(() {
          _vehicleData = data;
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
      currentRoute: '/driver-vehicle',
      title: 'My Vehicle',
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      return const PioneerRouteSkeletonBody(routeName: '/driver-vehicle');
    }
    // Unassigned / no vehicle in the store for this driver
    if (_vehicleData == null ||
        (_vehicleData!['status'] ?? '').toString().toLowerCase() ==
            'unassigned') {
      return Padding(
        padding: const EdgeInsets.all(AppTheme.space20),
        child: PioneerStateCard(
          icon: Icons.local_shipping_outlined,
          title: 'No vehicle assigned',
          message:
              'Your assigned truck and readiness details will appear here once dispatch assigns a vehicle.',
          tone: PioneerStateTone.empty,
          actionLabel: 'Refresh',
          onAction: _loadVehicle,
        ),
      );
    }
    if (_vehicleData?['error'] != null) return _buildNoVehicle();
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
          // â”€â”€ Vehicle hero card â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
          _buildVehicleHero(isDark, isMobile)
              .animate()
              .fadeIn(duration: 400.ms)
              .slideY(
                begin: 0.2,
                end: 0,
                duration: 400.ms,
                curve: Curves.easeOut,
              ),
          SizedBox(height: isMobile ? 20 : 32),
          // â”€â”€ Status grid (same as DashboardPage stat cards) â”€â”€â”€â”€â”€â”€â”€â”€
          _buildStatusCards(isDark, isMobile)
              .animate()
              .fadeIn(duration: 500.ms)
              .slideY(
                begin: 0.2,
                end: 0,
                duration: 500.ms,
                curve: Curves.easeOut,
              ),
          SizedBox(height: isMobile ? 20 : 32),
          // â”€â”€ Fuel gauge + documents â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
          _buildBottomSection(isDark, isMobile)
              .animate()
              .fadeIn(duration: 600.ms)
              .slideY(
                begin: 0.2,
                end: 0,
                duration: 600.ms,
                curve: Curves.easeOut,
              ),
        ],
      ),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  NO VEHICLE STATE
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildNoVehicle() {
    return Padding(
      padding: const EdgeInsets.all(AppTheme.space20),
      child: PioneerStateCard(
        icon: Icons.local_shipping_outlined,
        title: 'Vehicle details unavailable',
        message:
            'Your vehicle assignment could not be confirmed. Retry or contact dispatch if this continues.',
        tone: PioneerStateTone.warning,
        actionLabel: 'Retry',
        onAction: _loadVehicle,
      ),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  VEHICLE HERO â€” blue gradient like the DashboardPage green/orange cards
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildVehicleHero(bool isDark, bool isMobile) {
    final v = _vehicleData!;
    final statusText = (v['status'] ?? 'available').toString();
    final normalizedStatus = statusText.toLowerCase();
    final isActive =
        normalizedStatus == 'active' || normalizedStatus == 'on trip';
    final sw = MediaQuery.of(context).size.width;
    final isVerySmall = sw < 360;

    return Container(
      padding: EdgeInsets.all(isVerySmall ? 12 : (isMobile ? 16 : 24)),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppTheme.colorFF4B7BE5, AppTheme.colorFF3A66D4],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(isMobile ? 16 : 20),
        boxShadow: [
          BoxShadow(
            color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(isVerySmall ? 10 : (isMobile ? 16 : 20)),
            decoration: BoxDecoration(
              color: AppTheme.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              Icons.local_shipping_rounded,
              size: isVerySmall ? 28 : (isMobile ? 40 : 52),
              color: AppTheme.white,
            ),
          ),
          SizedBox(width: isVerySmall ? 10 : 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  v['plate'],
                  style: TextStyle(
                    fontSize: isVerySmall ? 18 : (isMobile ? 24 : 30),
                    fontWeight: FontWeight.w900,
                    color: AppTheme.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${v['model']} (${v['year']})',
                  style: TextStyle(
                    fontSize: isVerySmall ? 12 : (isMobile ? 14 : 16),
                    color: AppTheme.white.withValues(alpha: 0.85),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: isVerySmall ? 8 : 12,
                    vertical: isVerySmall ? 4 : 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isActive
                              ? AppTheme.greenAccent
                              : AppTheme.orangeAccent,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        statusText,
                        style: TextStyle(
                          fontSize: isVerySmall ? 11 : 13,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.white,
                        ),
                      ),
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

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  //  STATUS CARDS â€” exact same gradient pattern as DashboardPage stat cards
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildStatusCards(bool isDark, bool isMobile) {
    final v = _vehicleData!;
    final fuel = ((v['fuel'] as double) * 100).toInt();
    final fuelColor = fuel > 50
        ? AppTheme.colorFF27AE60
        : fuel > 25
        ? AppTheme.colorFFF39C12
        : AppTheme.colorFFE74C3C;

    final cards = [
      _buildStatCard(
        title: 'FUEL LEVEL',
        value: '$fuel%',
        subtitle: 'current level',
        icon: Icons.local_gas_station_rounded,
        color: fuelColor,
        isDark: isDark,
      ),
      _buildStatCard(
        title: 'MILEAGE',
        value: '${v['mileage']} km',
        subtitle: 'total driven',
        icon: Icons.speed_rounded,
        color: AppTheme.colorFF4B7BE5,
        isDark: isDark,
      ),
      _buildStatCard(
        title: 'LAST INSPECTION',
        value: v['lastInspection'],
        subtitle: 'inspection date',
        icon: Icons.checklist_rounded,
        color: AppTheme.colorFFF39C12,
        isDark: isDark,
      ),
      _buildStatCard(
        title: 'NEXT SERVICE',
        value: v['nextMaintenance'],
        subtitle: 'scheduled',
        icon: Icons.build_rounded,
        color: AppTheme.colorFFE74C3C,
        isDark: isDark,
      ),
    ];

    final sw = MediaQuery.of(context).size.width;
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

  Widget _buildStatCard({
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
        ? 18.0
        : sw < 600
        ? 20.0
        : 24.0;
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
                padding: EdgeInsets.all(8),
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
  //  BOTTOM SECTION â€” fuel bar + documents
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildBottomSection(bool isDark, bool isMobile) {
    if (MediaQuery.of(context).size.width < 900) {
      return Column(
        children: [
          _buildFuelGauge(isDark, isMobile),
          SizedBox(height: isMobile ? 16 : 20),
          _buildDocuments(isDark, isMobile),
        ],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 4, child: _buildFuelGauge(isDark, false)),
          const SizedBox(width: 24),
          Expanded(flex: 6, child: _buildDocuments(isDark, false)),
        ],
      ),
    );
  }

  Widget _buildFuelGauge(bool isDark, bool isMobile) {
    final v = _vehicleData!;
    final fuel = (v['fuel'] as double);
    final fuelPct = (fuel * 100).toInt();
    final fuelColor = fuelPct > 50
        ? AppTheme.colorFF27AE60
        : fuelPct > 25
        ? AppTheme.colorFFF39C12
        : AppTheme.colorFFE74C3C;

    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: _card(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Fuel Level',
            style: TextStyle(
              fontSize: isMobile ? 16 : 18,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Current tank status',
            style: TextStyle(
              fontSize: isMobile ? 12 : 13,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Column(
              children: [
                // Gauge arc visual
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 140,
                      height: 140,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: isDark
                            ? LinearGradient(
                                colors: [
                                  fuelColor.withValues(alpha: 0.3),
                                  fuelColor.withValues(alpha: 0.08),
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              )
                            : null,
                        color: isDark ? null : fuelColor.withValues(alpha: 0.1),
                        border: Border.all(
                          color: fuelColor.withValues(alpha: 0.4),
                          width: 2,
                        ),
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.local_gas_station_rounded,
                          color: fuelColor,
                          size: 32,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '$fuelPct%',
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w900,
                            color: isDark ? AppTheme.white : fuelColor,
                          ),
                        ),
                        Text(
                          'fuel',
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                // Progress bar
                Container(
                  height: 10,
                  decoration: BoxDecoration(
                    color: isDark ? AppTheme.gray800 : AppTheme.gray200,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: fuel,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [fuelColor, fuelColor.withValues(alpha: 0.7)],
                        ),
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Empty',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? AppTheme.gray500 : AppTheme.gray500,
                      ),
                    ),
                    Text(
                      'Full',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? AppTheme.gray500 : AppTheme.gray500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDocuments(bool isDark, bool isMobile) {
    final docs = _vehicleData!['documents'] as List<dynamic>;

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
                    'Vehicle Documents',
                    style: TextStyle(
                      fontSize: isMobile ? 16 : 18,
                      fontWeight: FontWeight.w700,
                      color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${docs.length} documents',
                    style: TextStyle(
                      fontSize: isMobile ? 12 : 13,
                      color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                    ),
                  ),
                ],
              ),
              // Valid/Expired count
              Row(
                children: [
                  _statusBadge(
                    'Valid',
                    docs.where((d) => (d as Map)['status'] == 'Valid').length,
                    AppTheme.colorFF27AE60,
                  ),
                  const SizedBox(width: 8),
                  _statusBadge(
                    'Expired',
                    docs.where((d) => (d as Map)['status'] != 'Valid').length,
                    AppTheme.colorFFE74C3C,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),
          ...docs.map(
            (doc) =>
                _buildDocRow(doc as Map<String, dynamic>, isDark, isMobile),
          ),
        ],
      ),
    );
  }

  Widget _statusBadge(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        '$count $label',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  Widget _buildDocRow(Map<String, dynamic> doc, bool isDark, bool isMobile) {
    final isValid = doc['status'] == 'Valid';
    final color = isValid ? AppTheme.colorFF27AE60 : AppTheme.colorFFE74C3C;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF8FAFD,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark
              ? color.withValues(alpha: 0.15)
              : color.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              isValid ? Icons.verified_rounded : Icons.warning_amber_rounded,
              color: color,
              size: 20,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  doc['type'],
                  style: TextStyle(
                    fontSize: isMobile ? 13 : 14,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(
                      Icons.calendar_today_rounded,
                      size: 11,
                      color: isDark ? AppTheme.gray500 : AppTheme.gray500,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Expires: ${doc['expiry']}',
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              doc['status'],
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
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
