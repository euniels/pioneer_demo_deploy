import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../widgets/dashboard_layout.dart';
import '../widgets/page_skeletons.dart';
import '../services/backend_api.dart';
import '../services/fleet_sync_service.dart';
import '../services/local_fleet_mirror_service.dart';
import '../services/trips_store.dart';
import '../services/vehicles_store.dart';
import '../services/billing_store.dart';
import '../services/notification_service.dart';
import '../theme/app_theme.dart';
import '../utils/display_format.dart';
import 'package:flutter_animate/flutter_animate.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({Key? key}) : super(key: key);

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with TickerProviderStateMixin {
  late AnimationController _cardAnimationController;
  late AnimationController _chartAnimationController;
  late final DateTime _openedAt;
  Map<String, dynamic> _dashboardSummary = {};

  @override
  void initState() {
    super.initState();
    _openedAt = DateTime.now();
    _cardAnimationController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _chartAnimationController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _cardAnimationController.forward();
    _chartAnimationController.forward();
    tripsNotifier.addListener(_onDataChanged);
    vehiclesNotifier.addListener(_onDataChanged);
    billingsNotifier.addListener(_onDataChanged);
    NotificationService.instance.notifications.addListener(_onDataChanged);

    final cachedSummary = BackendApiService.peekCachedDataMap(
      '/fleet/dashboard/summary',
    );
    if (cachedSummary != null && cachedSummary.isNotEmpty) {
      _dashboardSummary = cachedSummary;
    }

    unawaited(_loadDashboardSummaryFromMirror());
    _loadDashboardSummary();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      refreshFleetBootstrapSilently();
      refreshFleetSnapshotSilently();
      Future<void>.delayed(const Duration(seconds: 1), () {
        warmOperationalCachesSilently();
      });
    });
  }

  Future<void> _loadDashboardSummary({bool forceRefresh = false}) async {
    try {
      final summary = await BackendApiService.getFleetDashboardSummary(
        forceRefresh: forceRefresh,
      );
      if (!mounted) {
        return;
      }
      if (_shouldKeepCurrentDashboardSummary(summary)) {
        return;
      }
      setState(() => _dashboardSummary = summary);
    } catch (_) {
      // Keep the dashboard driven by the existing stores if the summary endpoint is unavailable.
    }
  }

  bool _shouldKeepCurrentDashboardSummary(Map<String, dynamic> next) {
    if (_dashboardSummary.isEmpty) {
      return false;
    }

    final degraded =
        next['stale'] == true ||
        next['refreshing'] == true ||
        next['geotabAvailable'] == false ||
        next['geotab_available'] == false ||
        next['geotabReason'] == 'snapshot_unavailable' ||
        next['geotab_reason'] == 'snapshot_unavailable';

    return degraded &&
        !_dashboardSummaryHasOperationalData(next) &&
        _dashboardSummaryHasOperationalData(_dashboardSummary);
  }

  Future<void> _loadDashboardSummaryFromMirror() async {
    if (_dashboardSummary.isNotEmpty) {
      return;
    }

    try {
      final state = await LocalFleetMirrorService.loadState();
      final summary = state.dashboardSummary;
      if (!mounted || summary == null || summary.isEmpty) {
        return;
      }
      setState(() => _dashboardSummary = summary);
    } catch (_) {
      // The existing notifier-driven fallback still keeps the page usable.
    }
  }

  void _onDataChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    tripsNotifier.removeListener(_onDataChanged);
    vehiclesNotifier.removeListener(_onDataChanged);
    billingsNotifier.removeListener(_onDataChanged);
    NotificationService.instance.notifications.removeListener(_onDataChanged);
    _cardAnimationController.dispose();
    _chartAnimationController.dispose();
    super.dispose();
  }

  bool _isMobile(BuildContext context) =>
      MediaQuery.of(context).size.width < 600;

  bool _isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= 600 &&
      MediaQuery.of(context).size.width < 1024;

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      currentRoute: '/dashboard',
      title: 'Dashboard',
      titleTextStyle: AppTheme.getDashboardPageTitleStyle(context),
      child: _buildPageContent(),
    );
  }

  Widget _buildPageContent() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isMobile = _isMobile(context);
    final isTablet = _isTablet(context);
    final hasAnyFleetData =
        vehiclesNotifier.value.isNotEmpty ||
        tripsNotifier.value.isNotEmpty ||
        billingsNotifier.value.isNotEmpty ||
        _dashboardSummary.isNotEmpty;
    final syncElapsed = DateTime.now().difference(_openedAt);

    if (!hasAnyFleetData) {
      return _buildSyncingState(isDark, syncElapsed);
    }

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
          _buildTopStatsCards(isDark, isMobile, isTablet)
              .animate()
              .fadeIn(duration: 500.ms)
              .slideY(
                begin: 0.2,
                end: 0,
                duration: 500.ms,
                curve: Curves.easeOut,
              ),
          const SizedBox(height: AppTheme.dashboardSectionSpacing),
          _buildPredictiveIntelligenceSection(isDark)
              .animate()
              .fadeIn(duration: 550.ms)
              .slideY(
                begin: 0.16,
                end: 0,
                duration: 550.ms,
                curve: Curves.easeOut,
              ),
          const SizedBox(height: AppTheme.dashboardSectionSpacing),
          _buildChartsSection(isDark, isMobile, isTablet)
              .animate()
              .fadeIn(duration: 600.ms)
              .slideY(
                begin: 0.2,
                end: 0,
                duration: 600.ms,
                curve: Curves.easeOut,
              ),
          const SizedBox(height: AppTheme.dashboardSectionSpacing),
          _buildBusinessSummaryPanels(isDark, isMobile)
              .animate()
              .fadeIn(duration: 650.ms)
              .slideY(
                begin: 0.2,
                end: 0,
                duration: 650.ms,
                curve: Curves.easeOut,
              ),
          const SizedBox(height: AppTheme.dashboardSectionSpacing),
          _buildBottomSection(isDark, isMobile, isTablet)
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

  Widget _buildPredictiveIntelligenceSection(bool isDark) {
    final summary = _dashboardSummary.isNotEmpty
        ? _dashboardSummary
        : _localDashboardSummaryFallback();
    final predictions = _dashboardList(
      summary['predictiveMaintenance'],
    ).take(3).toList();
    final idleAlerts = _dashboardList(summary['idleTimeAlerts']);
    final fuelTrend = _dashboardList(summary['fuelCostTrend']);
    final recentFuelCost = fuelTrend.isNotEmpty
        ? _parseMoney(fuelTrend.last['cost'] ?? fuelTrend.last['costLabel'])
        : 0.0;
    final priorFuelCost = fuelTrend.length > 1
        ? _parseMoney(
            fuelTrend[fuelTrend.length - 2]['cost'] ??
                fuelTrend[fuelTrend.length - 2]['costLabel'],
          )
        : 0.0;
    final fuelDeltaPercent = priorFuelCost <= 0
        ? null
        : ((recentFuelCost - priorFuelCost) / priorFuelCost) * 100;
    final fuelTrendUp = fuelDeltaPercent != null && fuelDeltaPercent > 0;
    final fuelTrendColor = fuelDeltaPercent == null
        ? AppTheme.neutralGray
        : fuelTrendUp
        ? AppTheme.errorRed
        : AppTheme.successGreen;

    final panels = [
      _dashboardSignalPanel(
        isDark,
        icon: Icons.build_circle_outlined,
        title: 'Predictive Maintenance',
        subtitle: 'Assets closest to their next service window',
        child: predictions.isEmpty
            ? _signalConfirmation(
                'No maintenance predictions yet',
                'Add service history to generate due-date forecasts.',
              )
            : Column(
                children: predictions
                    .map((row) => _maintenancePredictionRow(isDark, row))
                    .toList(),
              ),
      ),
      _dashboardSignalPanel(
        isDark,
        icon: Icons.timer_outlined,
        title: 'Idle time alerts',
        subtitle: 'Engine-on idling beyond 30 minutes today',
        child: idleAlerts.isEmpty
            ? _signalConfirmation(
                'No excessive idling detected',
                'No vehicle has exceeded the alert threshold today.',
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${idleAlerts.length}',
                    style: AppTheme.getDashboardKpiValueStyle(
                      context,
                    ).copyWith(color: AppTheme.errorRed),
                  ),
                  Text(
                    'Vehicles need operations review',
                    style: AppTheme.getDashboardKpiLabelStyle(context),
                  ),
                  const SizedBox(height: AppTheme.space12),
                  ...idleAlerts
                      .take(3)
                      .map(
                        (row) => _dashboardAlertRow(
                          formatValue(row['vehicle']),
                          formatValue(row['label']),
                          AppTheme.errorRed,
                        ),
                      ),
                ],
              ),
      ),
      _dashboardSignalPanel(
        isDark,
        icon: Icons.local_gas_station_outlined,
        title: 'Fuel trend',
        subtitle: 'Current week against the previous period',
        child: fuelTrend.isEmpty
            ? _signalConfirmation(
                'No fuel cost records yet',
                'Fuel comparisons appear after transactions are recorded.',
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _moneyShort(recentFuelCost),
                    style: AppTheme.getDashboardKpiValueStyle(context),
                  ),
                  Text(
                    'Fuel cost this week',
                    style: AppTheme.getDashboardKpiLabelStyle(context),
                  ),
                  const SizedBox(height: AppTheme.space12),
                  Row(
                    children: [
                      Icon(
                        fuelDeltaPercent == null
                            ? Icons.horizontal_rule_rounded
                            : fuelTrendUp
                            ? Icons.trending_up_rounded
                            : Icons.trending_down_rounded,
                        color: fuelTrendColor,
                        size: AppTheme.dashboardKpiIconSize,
                      ),
                      const SizedBox(width: AppTheme.space8),
                      Expanded(
                        child: Text(
                          fuelDeltaPercent == null
                              ? 'Awaiting previous-period comparison'
                              : '${fuelDeltaPercent.abs().toStringAsFixed(1)}% ${fuelTrendUp ? 'increase' : 'reduction'} week over week',
                          style: AppTheme.getDashboardBodyStyle(context)
                              .copyWith(
                                color: fuelTrendColor,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _dashboardSectionHeading(
          'Predictive Intelligence',
          'Service urgency, avoidable idle cost, and fuel movement surfaced before operational charts.',
        ),
        const SizedBox(height: AppTheme.space16),
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 1050) {
              return Column(
                children: [
                  for (var index = 0; index < panels.length; index++) ...[
                    panels[index],
                    if (index != panels.length - 1)
                      const SizedBox(height: AppTheme.space16),
                  ],
                ],
              );
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var index = 0; index < panels.length; index++) ...[
                    Expanded(child: panels[index]),
                    if (index != panels.length - 1)
                      const SizedBox(width: AppTheme.space16),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _dashboardSectionHeading(String title, String subtitle) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: AppTheme.space4,
          height: 52,
          decoration: BoxDecoration(
            color: AppTheme.pioneerRed,
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          ),
        ),
        const SizedBox(width: AppTheme.space12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: AppTheme.getDashboardSectionHeaderStyle(context),
              ),
              const SizedBox(height: AppTheme.space4),
              Text(
                subtitle,
                style: AppTheme.getDashboardBodyStyle(
                  context,
                ).copyWith(color: AppTheme.getSubtleTextColor(context)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _dashboardSignalPanel(
    bool isDark, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(AppTheme.dashboardKpiPadding),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCardBg : AppTheme.lightCardBg,
        borderRadius: AppTheme.getCardRadius(),
        border: Border.all(color: AppTheme.getBorderColor(context)),
        boxShadow: AppTheme.getCardShadow(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppTheme.primaryBlue, size: 28),
              const SizedBox(width: AppTheme.space8),
              Expanded(
                child: Text(
                  title,
                  style: AppTheme.getHeadingStyle(context, fontSize: 17),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.space6),
          Text(subtitle, style: AppTheme.getDashboardSecondaryStyle(context)),
          const SizedBox(height: AppTheme.space16),
          child,
        ],
      ),
    );
  }

  Widget _maintenancePredictionRow(bool isDark, Map<String, dynamic> row) {
    final days = _dashboardInt(row['daysRemaining'] ?? row['daysUntilDue']);
    final state = '${row['state']}'.toLowerCase();
    final overdue = days < 0 || state == 'overdue';
    final dueSoon = !overdue && (days <= 14 || state == 'due_soon');
    final urgencyColor = overdue
        ? AppTheme.errorRed
        : dueSoon
        ? AppTheme.warningOrange
        : AppTheme.successGreen;
    final daysLabel = overdue ? '${days.abs()} overdue' : '$days days';

    return Container(
      margin: const EdgeInsets.only(bottom: AppTheme.space8),
      padding: const EdgeInsets.all(AppTheme.space12),
      decoration: BoxDecoration(
        color: urgencyColor.withValues(alpha: isDark ? 0.12 : 0.08),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(color: urgencyColor.withValues(alpha: 0.32)),
      ),
      child: Row(
        children: [
          Container(
            width: AppTheme.space4,
            height: 40,
            decoration: BoxDecoration(
              color: urgencyColor,
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            ),
          ),
          const SizedBox(width: AppTheme.space10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  formatValue(row['plate'] ?? row['vehicle']),
                  style: AppTheme.getDashboardBodyStyle(
                    context,
                  ).copyWith(fontWeight: FontWeight.w700),
                ),
                Text(
                  'Last: ${formatValue(row['lastServiceAt'])}  |  Next: ${formatValue(row['predictedNextDueAt'])}',
                  style: AppTheme.getDashboardSecondaryStyle(context),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppTheme.space8),
          Text(
            daysLabel,
            style: AppTheme.getHeadingStyle(
              context,
              fontSize: 16,
            ).copyWith(color: urgencyColor),
          ),
        ],
      ),
    );
  }

  Widget _dashboardAlertRow(String title, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.space8),
      child: Row(
        children: [
          Icon(Icons.circle, size: AppTheme.space8, color: color),
          const SizedBox(width: AppTheme.space8),
          Expanded(
            child: Text(title, style: AppTheme.getDashboardBodyStyle(context)),
          ),
          Text(
            value,
            style: AppTheme.getDashboardBodyStyle(
              context,
            ).copyWith(fontWeight: FontWeight.w700, color: color),
          ),
        ],
      ),
    );
  }

  Widget _signalConfirmation(String title, String detail) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.check_circle_outline_rounded,
          color: AppTheme.successGreen,
          size: 28,
        ),
        const SizedBox(width: AppTheme.space10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: AppTheme.getDashboardBodyStyle(
                  context,
                ).copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppTheme.space4),
              Text(detail, style: AppTheme.getDashboardSecondaryStyle(context)),
            ],
          ),
        ),
      ],
    );
  }

  // Retained as an optional action-focused dashboard composition while the
  // predictive-first executive view is the active dashboard presentation.
  // ignore: unused_element
  Widget _buildLegacyExecutiveCommandDeck(bool isDark, bool isMobile) {
    final summary = _dashboardSummary.isNotEmpty
        ? _dashboardSummary
        : _localDashboardSummaryFallback();
    final predictiveMaintenance = _dashboardList(
      summary['predictiveMaintenance'],
    );
    final tripForecast = _dashboardList(summary['tripVolumeForecast']);
    final fuelTrend = _dashboardList(summary['fuelCostTrend']);
    final staleVehicles = vehiclesNotifier.value.where((vehicle) {
      final stale = vehicle['stale'] == true || vehicle['isStale'] == true;
      final lastSeen =
          vehicle['lastSeen']?.toString() ??
          vehicle['lastGeotabAt']?.toString() ??
          vehicle['updatedAt']?.toString() ??
          '';
      return stale || lastSeen.toLowerCase().contains('minute');
    }).length;
    final pendingTrips = tripsNotifier.value
        .where((trip) => '${trip['status']}'.toLowerCase() == 'pending')
        .length;
    final activeTrips = tripsNotifier.value.where((trip) {
      final status = '${trip['status']}'.toLowerCase();
      return status.contains('transit') ||
          status.contains('dispatch') ||
          status.contains('progress');
    }).length;
    final readyVehicles = vehiclesNotifier.value.where((vehicle) {
      final status = '${vehicle['status']}'.toLowerCase();
      return status == 'available' || status == 'active';
    }).length;
    final urgentMaintenance = predictiveMaintenance.where((row) {
      final state = '${row['state']}'.toLowerCase();
      final days = int.tryParse('${row['daysRemaining'] ?? ''}');
      return state.contains('overdue') ||
          state.contains('due') ||
          (days != null && days <= 14);
    }).length;
    final nextForecast = tripForecast.isNotEmpty
        ? '${formatValue(tripForecast.first['forecastTrips'])} trips'
        : 'Builds after trip history';
    final fuelSignal = fuelTrend.isNotEmpty
        ? formatValue(
            fuelTrend.last['costLabel'] ??
                fuelTrend.last['rollingAverageLabel'] ??
                fuelTrend.last['label'],
          )
        : 'Awaiting fuel data';

    final metrics = [
      _commandMetric(
        isDark,
        icon: Icons.route_rounded,
        label: 'Route execution',
        value: '$activeTrips active',
        detail: '$pendingTrips waiting for dispatch',
        color: AppTheme.primaryBlue,
      ),
      _commandMetric(
        isDark,
        icon: Icons.local_shipping_rounded,
        label: 'Fleet readiness',
        value: '$readyVehicles ready',
        detail: '${vehiclesNotifier.value.length} total assets',
        color: AppTheme.successGreen,
      ),
      _commandMetric(
        isDark,
        icon: Icons.psychology_alt_rounded,
        label: 'Tomorrow signal',
        value: nextForecast,
        detail: 'Predictive trip volume',
        color: AppTheme.colorFF8E2DE2,
      ),
      _commandMetric(
        isDark,
        icon: Icons.local_gas_station_rounded,
        label: 'Fuel pressure',
        value: fuelSignal,
        detail: 'Latest rolling trend',
        color: AppTheme.warningOrange,
      ),
    ];

    final actions = [
      _commandAction(
        isDark,
        title: pendingTrips == 0
            ? 'Dispatch queue clear'
            : 'Dispatch pending trips',
        message: pendingTrips == 0
            ? 'No route is waiting for assignment right now.'
            : '$pendingTrips trip${pendingTrips == 1 ? '' : 's'} need dispatcher action.',
        icon: Icons.send_rounded,
        color: pendingTrips == 0
            ? AppTheme.successGreen
            : AppTheme.warningOrange,
        routeName: '/dispatch',
      ),
      _commandAction(
        isDark,
        title: urgentMaintenance == 0
            ? 'Maintenance risk controlled'
            : 'Maintenance needs review',
        message: urgentMaintenance == 0
            ? 'No urgent predictive maintenance item is currently flagged.'
            : '$urgentMaintenance asset${urgentMaintenance == 1 ? '' : 's'} are due soon or overdue.',
        icon: Icons.build_circle_rounded,
        color: urgentMaintenance == 0
            ? AppTheme.successGreen
            : AppTheme.errorRed,
        routeName: '/maintenance',
      ),
      _commandAction(
        isDark,
        title: staleVehicles == 0
            ? 'Telematics feed healthy'
            : 'Check stale vehicles',
        message: staleVehicles == 0
            ? 'Live tracking has no stale/offline asset warning.'
            : '$staleVehicles vehicle${staleVehicles == 1 ? '' : 's'} have stale tracking data.',
        icon: Icons.satellite_alt_rounded,
        color: staleVehicles == 0
            ? AppTheme.successGreen
            : AppTheme.warningOrange,
        routeName: '/live-tracking',
      ),
    ];

    return Container(
      padding: EdgeInsets.all(isMobile ? 14 : 18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? const [AppTheme.colorFF101827, AppTheme.colorFF14213A]
              : const [AppTheme.white, AppTheme.colorFFF0F6FF],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppTheme.primaryBlue.withValues(alpha: 0.22)),
        boxShadow: AppTheme.getElevatedShadow(context),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 980;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryBlue.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.auto_awesome_rounded,
                      color: AppTheme.primaryBlue,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Executive Command Center',
                          style: AppTheme.getHeadingStyle(
                            context,
                            fontSize: isMobile ? 18 : 22,
                          ),
                        ),
                        Text(
                          'Cache-first operating picture with predictive maintenance, route pressure, and live telemetry quality.',
                          style: AppTheme.getSubtitleStyle(context),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (narrow) ...[
                ...metrics.map(
                  (metric) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: metric,
                  ),
                ),
                const SizedBox(height: 4),
                ...actions.map(
                  (action) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: action,
                  ),
                ),
              ] else ...[
                Row(
                  children: [
                    for (var index = 0; index < metrics.length; index++) ...[
                      Expanded(child: metrics[index]),
                      if (index != metrics.length - 1)
                        const SizedBox(width: 12),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    for (var index = 0; index < actions.length; index++) ...[
                      Expanded(child: actions[index]),
                      if (index != actions.length - 1)
                        const SizedBox(width: 12),
                    ],
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _commandMetric(
    bool isDark, {
    required IconData icon,
    required String label,
    required String value,
    required String detail,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark
            ? AppTheme.white.withValues(alpha: 0.035)
            : AppTheme.white.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.getHeadingStyle(context, fontSize: 17),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.getCaptionStyle(context),
                ),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.getSubtitleStyle(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _commandAction(
    bool isDark, {
    required String title,
    required String message,
    required IconData icon,
    required Color color,
    required String routeName,
  }) {
    return InkWell(
      onTap: () => Navigator.pushNamed(context, routeName),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: isDark ? 0.11 : 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.24)),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.getHeadingStyle(context, fontSize: 14),
                  ),
                  Text(
                    message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.getSubtitleStyle(context),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.arrow_forward_rounded, color: color, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _buildSyncingState(bool isDark, Duration syncElapsed) {
    return const PioneerRouteSkeletonBody(routeName: '/dashboard');
  }

  Widget _buildTopStatsCards(bool isDark, bool isMobile, bool isTablet) {
    final screenWidth = MediaQuery.of(context).size.width;

    // â”€â”€ Dynamic values from live stores â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    final allTrips = tripsNotifier.value;
    final allVehicles = vehiclesNotifier.value;
    final allBillings = billingsNotifier.value;
    final summary = _dashboardSummary.isNotEmpty
        ? _dashboardSummary
        : _localDashboardSummaryFallback();
    final utilization = _dashboardMap(summary['fleetUtilization']);
    final revenue = _dashboardMap(summary['recentRevenueSummary']);
    final month = _dashboardMap(summary['monthAtGlance']);
    final tripsThisWeek = _dashboardList(summary['tripsThisWeek']);

    final int activeTrucks = allVehicles.isNotEmpty
        ? allVehicles.where((v) => v['status'] != 'maintenance').length
        : _dashboardInt(utilization['activeVehiclesToday']);
    final int totalTrucks = allVehicles.isNotEmpty
        ? allVehicles.length
        : _dashboardInt(utilization['totalVehicles']);

    final int summaryTripCount = tripsThisWeek.fold<int>(
      _dashboardInt(month['tripsCompleted']),
      (sum, item) => sum + _dashboardInt(item['count']),
    );
    final int totalTrips = allTrips.isNotEmpty
        ? allTrips.length
        : summaryTripCount;
    final int pendingTrips = allTrips
        .where((t) => t['status'] == 'pending')
        .length;
    final int delayedTrips = allTrips
        .where((t) => t['hasDelay'] == true)
        .length;
    final correctedTotalRevenue = allBillings.fold<double>(
      0,
      (sum, billing) => sum + _parseMoney(billing['amount']),
    );
    final displayRevenueLabel =
        allBillings.isEmpty &&
            (revenue['thisWeekLabel']?.toString().trim().isNotEmpty ?? false)
        ? revenue['thisWeekLabel'].toString()
        : correctedTotalRevenue >= 1000000
        ? 'PHP ${(correctedTotalRevenue / 1000000).toStringAsFixed(1)}M'
        : correctedTotalRevenue >= 1000
        ? 'PHP ${(correctedTotalRevenue / 1000).toStringAsFixed(0)}K'
        : 'PHP ${correctedTotalRevenue.toStringAsFixed(0)}';
    final correctedNetProfit =
        (allBillings.isEmpty
            ? _parseMoney(revenue['thisWeekLabel'])
            : correctedTotalRevenue) *
        0.60;
    final displayProfitLabel = correctedNetProfit >= 1000000
        ? 'PHP ${(correctedNetProfit / 1000000).toStringAsFixed(1)}M'
        : correctedNetProfit >= 1000
        ? 'PHP ${(correctedNetProfit / 1000).toStringAsFixed(0)}K'
        : 'PHP ${correctedNetProfit.toStringAsFixed(0)}';
    final revenueTrend = '${revenue['trend']}'.toLowerCase();
    final revenueTrendLabel = revenueTrend == 'up'
        ? 'Higher than the previous week'
        : revenueTrend == 'down'
        ? 'Lower than the previous week'
        : 'No week-over-week change';
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

    final cards = [
      _buildTopStatCard(
        title: 'Total revenue',
        value: displayRevenueLabel,
        subtitle: 'From ${allBillings.length} invoice(s)',
        icon: Icons.attach_money_rounded,
        color: AppTheme.colorFF27AE60,
        trend: revenueTrend,
        trendLabel: revenueTrendLabel,
        isDark: isDark,
      ),
      _buildTopStatCard(
        title: 'Estimated net profit',
        value: displayProfitLabel,
        subtitle: '~60% of revenue',
        icon: Icons.trending_up_rounded,
        color: AppTheme.colorFF4B7BE5,
        trend: revenueTrend,
        trendLabel: revenueTrendLabel,
        isDark: isDark,
      ),
      _buildTopStatCard(
        title: 'Active trucks',
        value: '$activeTrucks',
        subtitle: 'of $totalTrucks fleet assets',
        icon: Icons.local_shipping_rounded,
        color: AppTheme.colorFF4B7BE5,
        isDark: isDark,
      ),
      _buildTopStatCard(
        title: 'Trips total',
        value: '$totalTrips',
        subtitle:
            '${allTrips.where((t) => t['status'] == 'completed').length} completed',
        icon: Icons.airport_shuttle_rounded,
        color: AppTheme.colorFFF39C12,
        isDark: isDark,
      ),
      _buildTopStatCard(
        title: 'Delayed trips',
        value: '$delayedTrips',
        subtitle: 'need attention',
        icon: Icons.warning_rounded,
        color: AppTheme.colorFFE74C3C,
        isDark: isDark,
      ),
      _buildTopStatCard(
        title: 'Dispatch queue',
        value: '$pendingTrips',
        subtitle: 'pending',
        icon: Icons.send_rounded,
        color: AppTheme.colorFF8E2DE2,
        isDark: isDark,
      ),
    ];

    final columns = screenWidth > 1200
        ? 4
        : screenWidth >= 900
        ? 3
        : 2;
    return _buildKpiGrid(cards, columns);
  }

  Widget _buildKpiGrid(List<Widget> cards, int columns) {
    final rows = <Widget>[];
    for (var index = 0; index < cards.length; index += columns) {
      final rowCards = cards.skip(index).take(columns).toList();
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (
                var cardIndex = 0;
                cardIndex < rowCards.length;
                cardIndex++
              ) ...[
                Expanded(child: rowCards[cardIndex]),
                if (cardIndex != rowCards.length - 1)
                  const SizedBox(width: AppTheme.space16),
              ],
            ],
          ),
        ),
      );
      if (index + columns < cards.length) {
        rows.add(const SizedBox(height: AppTheme.space16));
      }
    }
    return Column(children: rows);
  }

  Widget _buildTopStatCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
    required bool isDark,
    String? trend,
    String? trendLabel,
  }) {
    final trendColor = trend == 'up'
        ? AppTheme.successGreen
        : trend == 'down'
        ? AppTheme.errorRed
        : AppTheme.neutralGray;

    return Container(
      padding: const EdgeInsets.all(AppTheme.dashboardKpiPadding),
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
        borderRadius: AppTheme.getCardRadius(),
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    style: AppTheme.getDashboardKpiValueStyle(context),
                  ),
                ),
              ),
              const SizedBox(width: AppTheme.space12),
              Container(
                padding: const EdgeInsets.all(AppTheme.space10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
                child: Icon(
                  icon,
                  color: color,
                  size: AppTheme.dashboardKpiIconSize,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.space10),
          Text(
            title,
            style: AppTheme.getDashboardKpiLabelStyle(
              context,
            ).copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppTheme.space4),
          Text(subtitle, style: AppTheme.getDashboardSecondaryStyle(context)),
          if (trendLabel != null) ...[
            const SizedBox(height: AppTheme.space10),
            Row(
              children: [
                Icon(
                  trend == 'up'
                      ? Icons.trending_up_rounded
                      : trend == 'down'
                      ? Icons.trending_down_rounded
                      : Icons.trending_flat_rounded,
                  size: 20,
                  color: trendColor,
                ),
                const SizedBox(width: AppTheme.space6),
                Expanded(
                  child: Text(
                    trendLabel,
                    style: AppTheme.getDashboardSecondaryStyle(
                      context,
                    ).copyWith(color: trendColor, fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChartsSection(bool isDark, bool isMobile, bool isTablet) {
    final screenWidth = MediaQuery.of(context).size.width;

    if (screenWidth < 1250) {
      return Column(
        children: [
          _buildRevenueVsExpensesChart(isDark, isMobile),
          SizedBox(height: isMobile ? 16 : 20),
          _buildFleetStatusChart(isDark, isMobile),
        ],
      );
    }

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 6, child: _buildRevenueVsExpensesChart(isDark, false)),
          const SizedBox(width: 24),
          Expanded(flex: 4, child: _buildFleetStatusChart(isDark, false)),
        ],
      ),
    );
  }

  Widget _buildRevenueVsExpensesChart(bool isDark, bool isMobile) {
    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        borderRadius: BorderRadius.circular(isMobile ? 16 : 20),
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
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Revenue vs Expenses',
            style: AppTheme.getDashboardSectionHeaderStyle(context),
          ),
          const SizedBox(height: 4),
          Text(
            'Monthly trend - 2025',
            style: AppTheme.getDashboardSecondaryStyle(context),
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
                  getDrawingHorizontalLine: (value) => FlLine(
                    color: isDark ? AppTheme.gray800 : AppTheme.gray300,
                    strokeWidth: 1,
                  ),
                ),
                titlesData: FlTitlesData(
                  show: true,
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 30,
                      interval: 1,
                      getTitlesWidget: (value, meta) {
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
                        if (value.toInt() >= 0 &&
                            value.toInt() < months.length) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              months[value.toInt()],
                              style: TextStyle(
                                fontSize: AppTheme.dashboardSecondarySize,
                                color: isDark
                                    ? AppTheme.gray400
                                    : AppTheme.gray600,
                              ),
                            ),
                          );
                        }
                        return const Text('');
                      },
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: 25,
                      reservedSize: isMobile ? 40 : 50,
                      getTitlesWidget: (value, meta) => Text(
                        'PHP ${value.toInt()}M',
                        style: TextStyle(
                          fontSize: AppTheme.dashboardSecondarySize,
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
                    spots: const [
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
                    ],
                    isCurved: true,
                    color: AppTheme.colorFF27AE60,
                    barWidth: 3,
                    isStrokeCapRound: true,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        colors: [
                          AppTheme.colorFF27AE60.withValues(alpha: 0.3),
                          AppTheme.colorFF27AE60.withValues(alpha: 0.0),
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
        ],
      ),
    );
  }

  Widget _buildFleetStatusChart(bool isDark, bool isMobile) {
    final screenWidth = MediaQuery.of(context).size.width;
    final allVehicles = vehiclesNotifier.value;

    // Count by status
    int available = 0, onTrip = 0, maintenance = 0;
    for (final v in allVehicles) {
      switch ((v['status'] as String? ?? '').toLowerCase()) {
        case 'available':
          available++;
          break;
        case 'on trip':
          onTrip++;
          break;
        case 'dispatched':
          onTrip++;
          break;
        case 'maintenance':
          maintenance++;
          break;
      }
    }
    final total = allVehicles.length;

    double pieRadius;
    double centerRadius;

    if (screenWidth < 380) {
      pieRadius = 38.0;
      centerRadius = 32.0;
    } else if (isMobile) {
      pieRadius = 44.0;
      centerRadius = 42.0;
    } else if (screenWidth < 900) {
      pieRadius = 55.0;
      centerRadius = 46.0;
    } else if (screenWidth < 1200) {
      pieRadius = 55.0;
      centerRadius = 46.0;
    } else {
      pieRadius = 50.0;
      centerRadius = 41.0;
    }

    final sections = <PieChartSectionData>[
      if (available > 0)
        PieChartSectionData(
          value: available.toDouble(),
          color: AppTheme.colorFF27AE60,
          title: '',
          radius: pieRadius,
        ),
      if (onTrip > 0)
        PieChartSectionData(
          value: onTrip.toDouble(),
          color: AppTheme.colorFF4B7BE5,
          title: '',
          radius: pieRadius,
        ),
      if (maintenance > 0)
        PieChartSectionData(
          value: maintenance.toDouble(),
          color: AppTheme.colorFFF39C12,
          title: '',
          radius: pieRadius,
        ),
      // Fallback if all zero
      if (available == 0 && onTrip == 0 && maintenance == 0)
        PieChartSectionData(
          value: 1,
          color: AppTheme.colorFF6B7280,
          title: '',
          radius: pieRadius,
        ),
    ];

    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        borderRadius: BorderRadius.circular(isMobile ? 16 : 20),
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
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Fleet Status',
            style: AppTheme.getDashboardSectionHeaderStyle(context),
          ),
          const SizedBox(height: 4),
          Text(
            '$total total vehicle${total == 1 ? '' : 's'}',
            style: AppTheme.getDashboardSecondaryStyle(context),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: isMobile ? 200 : 280,
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: PieChart(
                    PieChartData(
                      centerSpaceRadius: centerRadius,
                      sectionsSpace: 2,
                      sections: sections,
                    ),
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  flex: 4,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildFleetLegendItem(
                        'Available',
                        '$available',
                        AppTheme.colorFF27AE60,
                        isDark,
                        isMobile,
                      ),
                      SizedBox(height: isMobile ? 16 : 20),
                      _buildFleetLegendItem(
                        'In Transit',
                        '$onTrip',
                        AppTheme.colorFF4B7BE5,
                        isDark,
                        isMobile,
                      ),
                      SizedBox(height: isMobile ? 16 : 20),
                      _buildFleetLegendItem(
                        'Maintenance',
                        '$maintenance',
                        AppTheme.colorFFF39C12,
                        isDark,
                        isMobile,
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

  Widget _buildFleetLegendItem(
    String label,
    String count,
    Color color,
    bool isDark,
    bool isMobile,
  ) {
    return Row(
      children: [
        Container(
          width: isMobile ? 10 : 12,
          height: isMobile ? 10 : 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        SizedBox(width: isMobile ? 8 : 12),
        Expanded(
          child: Text(
            label,
            style: AppTheme.getDashboardBodyStyle(context).copyWith(
              color: isDark ? AppTheme.gray300 : AppTheme.colorFF2C3E50,
            ),
          ),
        ),
        Text(count, style: AppTheme.getHeadingStyle(context, fontSize: 16)),
      ],
    );
  }

  Widget _buildBusinessSummaryPanels(bool isDark, bool isMobile) {
    final summary = _dashboardSummary.isNotEmpty
        ? _dashboardSummary
        : _localDashboardSummaryFallback();
    final tripsThisWeek = _dashboardList(summary['tripsThisWeek']);
    final utilization = _dashboardMap(summary['fleetUtilization']);
    final topVehicles = _dashboardList(summary['topActiveVehicles']);
    final revenue = _dashboardMap(summary['recentRevenueSummary']);
    final humidity = _dashboardMap(summary['humidityAlertCount']);
    final month = _dashboardMap(summary['monthAtGlance']);
    final utilizationRate = _dashboardDouble(
      utilization['rate'],
    ).clamp(0.0, 1.0).toDouble();
    final humidityCount = _dashboardInt(humidity['count']);

    final panels = [
      _dashboardPanel(
        isDark,
        title: 'This Month at a Glance',
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _businessMetric(
                    isDark,
                    'Completed',
                    formatValue(month['tripsCompleted']),
                    Icons.task_alt_rounded,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _businessMetric(
                    isDark,
                    'Distance',
                    formatValue(month['kmDrivenLabel']),
                    Icons.route_rounded,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _businessMetric(
                    isDark,
                    'On-time',
                    formatValue(month['onTimeDeliveryLabel']),
                    Icons.schedule_rounded,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _businessMetric(
                    isDark,
                    'Invoiced',
                    formatValue(month['totalInvoicedLabel']),
                    Icons.receipt_long_rounded,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      _dashboardPanel(
        isDark,
        title: 'Trips This Week',
        child: _tripsThisWeekChart(isDark, tripsThisWeek),
      ),
      _dashboardPanel(
        isDark,
        title: 'Fleet Utilization Rate',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              formatValue(utilization['percentageLabel']),
              style: TextStyle(
                fontSize: isMobile ? 24 : 30,
                fontWeight: FontWeight.w900,
                color: AppTheme.colorFF1A3A6B,
              ),
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: utilizationRate,
              minHeight: 10,
              backgroundColor: isDark
                  ? AppTheme.white10
                  : AppTheme.colorFFE5E7EB,
              color: AppTheme.colorFF1A3A6B,
            ),
            const SizedBox(height: 8),
            Text(
              formatValue(utilization['activeLabel']),
              style: TextStyle(
                fontSize: 12,
                color: isDark ? AppTheme.gray400 : AppTheme.gray600,
              ),
            ),
          ],
        ),
      ),
      _dashboardPanel(
        isDark,
        title: 'Top 5 Active Vehicles',
        child: topVehicles.isEmpty
            ? _emptyPanelText(isDark, 'No active vehicles today')
            : Column(
                children: topVehicles
                    .map(
                      (vehicle) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_dashboardInt(vehicle['rank'])}.',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                color: AppTheme.colorFF1A3A6B,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    formatValue(vehicle['plateNumber']),
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: isDark
                                          ? AppTheme.white
                                          : AppTheme.colorFF1F2937,
                                    ),
                                  ),
                                  Text(
                                    formatValue(vehicle['driverFullName']),
                                    style: TextStyle(
                                      fontSize: AppTheme.dashboardSecondarySize,
                                      color: isDark
                                          ? AppTheme.gray400
                                          : AppTheme.gray600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  formatValue(vehicle['distanceLabel']),
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: isDark
                                        ? AppTheme.white
                                        : AppTheme.colorFF1F2937,
                                  ),
                                ),
                                Text(
                                  formatValue(vehicle['status']),
                                  style: TextStyle(
                                    fontSize: AppTheme.dashboardSecondarySize,
                                    color: isDark
                                        ? AppTheme.gray400
                                        : AppTheme.gray600,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
      ),
      _dashboardPanel(
        isDark,
        title: 'Recent Revenue Summary',
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _businessMetric(
                    isDark,
                    'This week',
                    formatValue(revenue['thisWeekLabel']),
                    revenue['trend'] == 'down'
                        ? Icons.trending_down_rounded
                        : revenue['trend'] == 'flat'
                        ? Icons.trending_flat_rounded
                        : Icons.trending_up_rounded,
                    color: revenue['trend'] == 'down'
                        ? AppTheme.colorFFE74C3C
                        : revenue['trend'] == 'flat'
                        ? AppTheme.colorFF6B7280
                        : AppTheme.colorFF27AE60,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _businessMetric(
                    isDark,
                    'Last week',
                    formatValue(revenue['lastWeekLabel']),
                    Icons.history_rounded,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                formatValue(revenue['trendLabel']),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: revenue['trend'] == 'down'
                      ? AppTheme.colorFFE74C3C
                      : revenue['trend'] == 'flat'
                      ? AppTheme.colorFF6B7280
                      : AppTheme.colorFF27AE60,
                ),
              ),
            ),
          ],
        ),
      ),
      _dashboardPanel(
        isDark,
        title: 'Humidity Alert Count',
        child: humidityCount == 0
            ? Text(
                'No alerts this week',
                style: TextStyle(
                  color: AppTheme.colorFF27AE60,
                  fontWeight: FontWeight.w800,
                  fontSize: isMobile ? 14 : 16,
                ),
              )
            : _businessMetric(
                isDark,
                'humidity alerts this week',
                '$humidityCount',
                Icons.water_drop_rounded,
                color: AppTheme.colorFFE74C3C,
              ),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _dashboardSection(
          isDark,
          title: 'Executive Snapshot',
          subtitle:
              'Month-to-date performance, utilization, cash flow, and alerts.',
          child: _responsivePanelGrid(
            panels: [panels[0], panels[2], panels[4], panels[5]],
            maxColumns: isMobile ? 1 : 4,
          ),
        ),
        const SizedBox(height: AppTheme.dashboardSectionSpacing),
        _dashboardSection(
          isDark,
          title: 'Operations Today',
          subtitle:
              'Trip volume and active vehicle ranking from local fleet data.',
          child: _responsivePanelGrid(
            panels: [panels[1], panels[3]],
            maxColumns: isMobile ? 1 : 2,
          ),
        ),
      ],
    );
  }

  Widget _dashboardSection(
    bool isDark, {
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF111827 : AppTheme.colorFFF8FAFC,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.06)
              : AppTheme.black.withValues(alpha: 0.04),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _dashboardSectionHeading(title, subtitle),
          const SizedBox(height: AppTheme.space16),
          child,
        ],
      ),
    );
  }

  Widget _responsivePanelGrid({
    required List<Widget> panels,
    required int maxColumns,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width < 680 ? 1 : maxColumns.clamp(1, panels.length);
        final rows = <Widget>[];

        for (var index = 0; index < panels.length; index += columns) {
          final rowPanels = panels.skip(index).take(columns).toList();
          rows.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (
                    var rowIndex = 0;
                    rowIndex < rowPanels.length;
                    rowIndex++
                  ) ...[
                    Expanded(child: rowPanels[rowIndex]),
                    if (rowIndex != rowPanels.length - 1)
                      const SizedBox(width: 12),
                  ],
                  for (
                    var spacer = rowPanels.length;
                    spacer < columns;
                    spacer++
                  )
                    const Expanded(child: SizedBox.shrink()),
                ],
              ),
            ),
          );
          if (index + columns < panels.length) {
            rows.add(const SizedBox(height: 12));
          }
        }

        return Column(children: rows);
      },
    );
  }

  Widget _tripsThisWeekChart(
    bool isDark,
    List<Map<String, dynamic>> tripsThisWeek,
  ) {
    final maxCount = tripsThisWeek.fold<int>(
      0,
      (max, item) => _dashboardInt(item['count']) > max
          ? _dashboardInt(item['count'])
          : max,
    );

    return SizedBox(
      height: 150,
      child: BarChart(
        BarChartData(
          maxY: (maxCount <= 0 ? 1 : maxCount).toDouble(),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (value) => FlLine(
              color: isDark ? AppTheme.white10 : AppTheme.colorFFE5E7EB,
              strokeWidth: 1,
            ),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: true, reservedSize: 28),
            ),
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                getTitlesWidget: (value, meta) {
                  final index = value.toInt();
                  if (index < 0 || index >= tripsThisWeek.length) {
                    return const SizedBox.shrink();
                  }

                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      formatValue(tripsThisWeek[index]['label']),
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          barGroups: [
            for (var index = 0; index < tripsThisWeek.length; index++)
              BarChartGroupData(
                x: index,
                barRods: [
                  BarChartRodData(
                    toY: _dashboardInt(
                      tripsThisWeek[index]['count'],
                    ).toDouble(),
                    color: AppTheme.colorFF1A3A6B,
                    width: 14,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(4),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Map<String, dynamic> _localDashboardSummaryFallback() {
    final today = DateTime.now();
    final startToday = DateTime(today.year, today.month, today.day);
    final tripsByDay = <Map<String, dynamic>>[];
    for (var offset = 6; offset >= 0; offset--) {
      final day = startToday.subtract(Duration(days: offset));
      tripsByDay.add({
        'label': _weekdayLabel(day),
        'count': tripsNotifier.value
            .where((trip) => _isSameDay(_dateOf(trip), day))
            .length,
      });
    }

    final activeVehicles = tripsNotifier.value
        .where((trip) => !_dateOf(trip).isBefore(startToday))
        .map((trip) => trip['vehicle']?.toString().trim() ?? '')
        .where((vehicle) => vehicle.isNotEmpty)
        .toSet();
    final totalVehicles = vehiclesNotifier.value.length;
    final rate = totalVehicles == 0
        ? 0.0
        : activeVehicles.length / totalVehicles;

    return {
      'monthAtGlance': {
        'tripsCompleted': tripsNotifier.value
            .where((trip) => '${trip['status']}'.toLowerCase() == 'completed')
            .length,
        'kmDrivenLabel': '0 km',
        'onTimeDeliveryLabel': 'N/A',
        'totalInvoicedLabel': _moneyShort(
          billingsNotifier.value.fold<double>(
            0,
            (sum, billing) => sum + _parseMoney(billing['amount']),
          ),
        ),
      },
      'tripsThisWeek': tripsByDay,
      'fleetUtilization': {
        'activeVehiclesToday': activeVehicles.length,
        'totalVehicles': totalVehicles,
        'rate': rate,
        'percentageLabel': '${(rate * 100).toStringAsFixed(0)}%',
        'activeLabel':
            '${activeVehicles.length} of $totalVehicles vehicles active today',
      },
      'topActiveVehicles': vehiclesNotifier.value.take(5).map((vehicle) {
        final index = vehiclesNotifier.value.indexOf(vehicle);
        return {
          'rank': index + 1,
          'plateNumber': vehicle['plate'],
          'driverFullName': vehicle['driver'] ?? 'Unassigned',
          'distanceLabel': '${formatValue(vehicle['distanceKmToday'])} km',
          'status': vehicle['status'] ?? 'available',
        };
      }).toList(),
      'recentRevenueSummary': {
        'thisWeekLabel': _moneyShort(
          billingsNotifier.value.fold<double>(
            0,
            (sum, billing) => sum + _parseMoney(billing['amount']),
          ),
        ),
        'lastWeekLabel': 'PHP 0',
        'trend': 'flat',
        'trendLabel': 'No change',
      },
      'humidityAlertCount': {
        'count': NotificationService.instance.notifications.value
            .where(
              (item) =>
                  item.message.toLowerCase().contains('humidity') ||
                  item.title.toLowerCase().contains('humidity'),
            )
            .length,
      },
      'predictiveMaintenance': const [],
      'fuelCostTrend': const [],
      'tripVolumeForecast': const [],
      'idleTimeAlerts': const [],
    };
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _weekdayLabel(DateTime date) {
    const labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return labels[date.weekday - 1];
  }

  Widget _emptyPanelText(bool isDark, String text) {
    return Text(
      text,
      style: AppTheme.getDashboardBodyStyle(
        context,
      ).copyWith(color: isDark ? AppTheme.gray400 : AppTheme.gray600),
    );
  }

  Widget _dashboardPanel(
    bool isDark, {
    required String title,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.08)
              : AppTheme.black.withValues(alpha: 0.05),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTheme.getHeadingStyle(context, fontSize: 16)),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _businessMetric(
    bool isDark,
    String label,
    String value,
    IconData icon, {
    Color color = AppTheme.colorFF1A3A6B,
  }) {
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: isDark ? AppTheme.white : AppTheme.colorFF1F2937,
                ),
              ),
              Text(
                label,
                style: TextStyle(
                  fontSize: AppTheme.dashboardKpiLabelSize,
                  color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  DateTime _dateOf(Map<String, dynamic> row) {
    return DateTime.tryParse(
          row['startedAt']?.toString() ??
              row['endedAt']?.toString() ??
              row['date']?.toString() ??
              '',
        ) ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  String _moneyShort(double value) {
    if (value >= 1000000) {
      return 'PHP ${(value / 1000000).toStringAsFixed(1)}M';
    }
    if (value >= 1000) {
      return 'PHP ${(value / 1000).toStringAsFixed(0)}K';
    }
    return 'PHP ${value.toStringAsFixed(0)}';
  }

  Widget _buildBottomSection(bool isDark, bool isMobile, bool isTablet) {
    final screenWidth = MediaQuery.of(context).size.width;

    if (screenWidth < 900) {
      return Column(
        children: [
          _buildRecentTripsTable(isDark, isMobile),
          SizedBox(height: isMobile ? 16 : 20),
          _buildNotificationsPanel(isDark, isMobile),
        ],
      );
    }

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 6, child: _buildRecentTripsTable(isDark, false)),
          const SizedBox(width: 24),
          Expanded(flex: 4, child: _buildNotificationsPanel(isDark, false)),
        ],
      ),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // REPLACED: now reads live from tripsNotifier instead of hardcoded rows
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildRecentTripsTable(bool isDark, bool isMobile) {
    final summaryTrips = _dashboardList(_dashboardSummary['recentTrips']);
    final trips = summaryTrips.isNotEmpty
        ? summaryTrips
        : tripsNotifier.value.take(6).toList();

    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        borderRadius: BorderRadius.circular(isMobile ? 16 : 20),
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
      ),
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
                    'Recent Trips',
                    style: TextStyle(
                      fontSize: isMobile ? 16 : 18,
                      fontWeight: FontWeight.w700,
                      color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${tripsNotifier.value.length} total trips',
                    style: TextStyle(
                      fontSize: isMobile ? 12 : 13,
                      color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                    ),
                  ),
                ],
              ),
              TextButton.icon(
                onPressed: () => Navigator.pushNamed(context, '/trips'),
                icon: const Icon(Icons.arrow_forward, size: 16),
                label: const Text('View All'),
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.colorFFF39C12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.vertical,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowColor: WidgetStateProperty.all(
                    isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF8FAFD,
                  ),
                  columnSpacing: isMobile ? 12 : 20,
                  horizontalMargin: isMobile ? 12 : 20,
                  dataRowMinHeight: 56,
                  dataRowMaxHeight: 64,
                  columns: [
                    DataColumn(
                      label: SizedBox(
                        width: isMobile ? 80 : 100,
                        child: Text(
                          'TRIP #',
                          style: TextStyle(
                            fontSize: isMobile ? 10 : 11,
                            fontWeight: FontWeight.w600,
                            color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                          ),
                        ),
                      ),
                    ),
                    DataColumn(
                      label: SizedBox(
                        width: isMobile ? 120 : 150,
                        child: Text(
                          'CLIENT',
                          style: TextStyle(
                            fontSize: isMobile ? 10 : 11,
                            fontWeight: FontWeight.w600,
                            color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                          ),
                        ),
                      ),
                    ),
                    DataColumn(
                      label: SizedBox(
                        width: isMobile ? 180 : 220,
                        child: Text(
                          'ROUTE',
                          style: TextStyle(
                            fontSize: isMobile ? 10 : 11,
                            fontWeight: FontWeight.w600,
                            color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                          ),
                        ),
                      ),
                    ),
                    DataColumn(
                      label: SizedBox(
                        width: isMobile ? 100 : 120,
                        child: Text(
                          'DRIVER',
                          style: TextStyle(
                            fontSize: isMobile ? 10 : 11,
                            fontWeight: FontWeight.w600,
                            color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                          ),
                        ),
                      ),
                    ),
                    DataColumn(
                      label: SizedBox(
                        width: isMobile ? 90 : 110,
                        child: Text(
                          'STATUS',
                          style: TextStyle(
                            fontSize: isMobile ? 10 : 11,
                            fontWeight: FontWeight.w600,
                            color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                          ),
                        ),
                      ),
                    ),
                    DataColumn(
                      label: SizedBox(
                        width: isMobile ? 70 : 90,
                        child: Text(
                          'AMOUNT',
                          style: TextStyle(
                            fontSize: isMobile ? 10 : 11,
                            fontWeight: FontWeight.w600,
                            color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                          ),
                        ),
                      ),
                    ),
                  ],
                  rows: trips
                      .map((trip) => _buildTripRow(trip, isDark, isMobile))
                      .toList(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  DataRow _buildTripRow(Map<String, dynamic> trip, bool isDark, bool isMobile) {
    final status = formatValue(trip['status']);
    final statusColor = dashboardTripStatusColor(trip);
    final String statusLabel;
    switch (status.toLowerCase()) {
      case 'completed':
        statusLabel = 'Completed';
        break;
      case 'in progress':
      case 'inprogress':
      case 'in_transit':
      case 'in transit':
        statusLabel = 'In Progress';
        break;
      case 'dispatched':
        statusLabel = 'Dispatched';
        break;
      default:
        statusLabel = status;
    }
    final route = cleanDashboardRouteTextForDisplay(trip);

    return DataRow(
      cells: [
        DataCell(
          SizedBox(
            width: isMobile ? 80 : 100,
            child: Text(
              formatValue(trip['tripId'] ?? trip['id']),
              style: TextStyle(
                fontSize: isMobile ? 11 : 12,
                color: AppTheme.colorFF4B7BE5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        DataCell(
          SizedBox(
            width: isMobile ? 120 : 150,
            child: Text(
              formatValue(trip['customer'] ?? trip['client']),
              style: TextStyle(
                fontSize: isMobile ? 11 : 12,
                color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        DataCell(
          SizedBox(
            width: isMobile ? 180 : 220,
            child: Text(
              route,
              style: TextStyle(
                fontSize: isMobile ? 11 : 12,
                color: isDark ? AppTheme.gray400 : AppTheme.gray700,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        DataCell(
          SizedBox(
            width: isMobile ? 100 : 120,
            child: Text(
              formatValue(trip['driver']),
              style: TextStyle(
                fontSize: isMobile ? 11 : 12,
                color: isDark ? AppTheme.gray300 : AppTheme.gray800,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        DataCell(
          SizedBox(
            width: isMobile ? 90 : 110,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      statusLabel,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: statusColor,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        DataCell(
          SizedBox(
            width: isMobile ? 70 : 90,
            child: Text(
              formatValue(trip['amount'] ?? trip['revenue']),
              style: TextStyle(
                fontSize: isMobile ? 11 : 12,
                fontWeight: FontWeight.w700,
                color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Notifications panel reads from NotificationService (live data)
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildNotificationsPanel(bool isDark, bool isMobile) {
    final notifs = NotificationService.instance.notifications.value
        .take(6)
        .toList();
    final unread = NotificationService.instance.unreadCount;

    return Container(
      padding: EdgeInsets.all(isMobile ? 16 : 24),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        borderRadius: BorderRadius.circular(isMobile ? 16 : 20),
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
      ),
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
                    'Notifications',
                    style: TextStyle(
                      fontSize: isMobile ? 16 : 18,
                      fontWeight: FontWeight.w700,
                      color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    unread > 0 ? '$unread unread' : 'All caught up',
                    style: TextStyle(
                      fontSize: isMobile ? 12 : 13,
                      color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                    ),
                  ),
                ],
              ),
              TextButton.icon(
                onPressed: () => Navigator.pushNamed(context, '/notifications'),
                icon: const Icon(Icons.arrow_forward, size: 16),
                label: const Text('View All'),
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.colorFFF39C12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (notifs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  'No notifications yet',
                  style: TextStyle(
                    color: isDark ? AppTheme.gray500 : AppTheme.gray600,
                    fontSize: 13,
                  ),
                ),
              ),
            )
          else
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (int i = 0; i < notifs.length; i++) ...[
                      _buildNotificationItem(
                        icon: _categoryIcon(notifs[i].category),
                        iconColor: _categoryColor(notifs[i].category),
                        title: notifs[i].title,
                        subtitle: notifs[i].message,
                        time: notifs[i].time,
                        isUnread: !notifs[i].isRead,
                        isDark: isDark,
                        isMobile: isMobile,
                      ),
                      if (i < notifs.length - 1) const SizedBox(height: 16),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  IconData _categoryIcon(NotificationCategory cat) {
    switch (cat) {
      case NotificationCategory.maintenance:
        return Icons.build_rounded;
      case NotificationCategory.trip:
        return Icons.local_shipping_rounded;
      case NotificationCategory.fuel:
        return Icons.local_gas_station_rounded;
      case NotificationCategory.driver:
        return Icons.person_add_rounded;
      case NotificationCategory.billing:
        return Icons.payment_rounded;
      case NotificationCategory.alert:
        return Icons.warning_rounded;
      case NotificationCategory.system:
        return Icons.settings_rounded;
    }
  }

  Color _categoryColor(NotificationCategory cat) {
    switch (cat) {
      case NotificationCategory.maintenance:
        return AppTheme.colorFFF39C12;
      case NotificationCategory.trip:
        return AppTheme.colorFF27AE60;
      case NotificationCategory.fuel:
        return AppTheme.colorFFE74C3C;
      case NotificationCategory.driver:
        return AppTheme.colorFF4B7BE5;
      case NotificationCategory.billing:
        return AppTheme.colorFF8B5CF6;
      case NotificationCategory.alert:
        return AppTheme.colorFFE74C3C;
      case NotificationCategory.system:
        return AppTheme.colorFF14B8A6;
    }
  }

  Widget _buildNotificationItem({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    String? time,
    bool isUnread = false,
    required bool isDark,
    required bool isMobile,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: isMobile ? 16 : 18),
            ),
            if (isUnread)
              Positioned(
                right: 0,
                top: 0,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: AppTheme.colorFFE74C3C,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: isMobile ? 12 : 13,
                        fontWeight: isUnread
                            ? FontWeight.w700
                            : FontWeight.w600,
                        color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                      ),
                    ),
                  ),
                  if (time != null)
                    Text(
                      time,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? AppTheme.gray500 : AppTheme.gray500,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: isMobile ? 11 : 12,
                  color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                  height: 1.4,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

double _parseMoney(dynamic value) {
  final raw = value?.toString() ?? '';
  final normalized = raw
      .split('')
      .where((char) => '0123456789.-'.contains(char))
      .join();
  return double.tryParse(normalized) ?? 0;
}

Map<String, dynamic> _dashboardMap(dynamic value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return <String, dynamic>{};
}

List<Map<String, dynamic>> _dashboardList(dynamic value) {
  if (value is! List) {
    return <Map<String, dynamic>>[];
  }

  return value
      .whereType<Map>()
      .map((item) => item.map((key, value) => MapEntry(key.toString(), value)))
      .cast<Map<String, dynamic>>()
      .toList();
}

int _dashboardInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _dashboardDouble(dynamic value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

bool _dashboardSummaryHasOperationalData(Map<String, dynamic> summary) {
  final month = _dashboardMap(summary['monthAtGlance']);
  final utilization = _dashboardMap(summary['fleetUtilization']);
  final revenue = _dashboardMap(summary['recentRevenueSummary']);
  final humidity = _dashboardMap(summary['humidityAlertCount']);

  if (_dashboardDouble(utilization['totalVehicles']) > 0 ||
      _dashboardDouble(utilization['activeVehiclesToday']) > 0 ||
      _dashboardDouble(month['completed']) > 0 ||
      _dashboardDouble(month['distanceKm']) > 0 ||
      _dashboardDouble(month['invoiced']) > 0 ||
      _dashboardDouble(revenue['thisWeek']) > 0 ||
      _dashboardDouble(revenue['lastWeek']) > 0 ||
      _dashboardDouble(humidity['count']) > 0) {
    return true;
  }

  if (_dashboardList(summary['topActiveVehicles']).isNotEmpty ||
      _dashboardList(summary['recentTrips']).isNotEmpty ||
      _dashboardList(summary['predictiveMaintenance']).isNotEmpty) {
    return true;
  }

  return _dashboardList(summary['tripsThisWeek']).any(
    (bucket) =>
        _dashboardDouble(bucket['count']) > 0 ||
        _dashboardDouble(bucket['trips']) > 0,
  );
}

Color dashboardTripStatusColor(Map<String, dynamic> trip) {
  final explicitColor = trip['statusColor'];
  if (explicitColor is Color) {
    return explicitColor;
  }

  final status = formatValue(trip['status']).toLowerCase();
  if (status.contains('complete') || status.contains('deliver')) {
    return AppTheme.successGreen;
  }
  if (status.contains('progress') ||
      status.contains('transit') ||
      status.contains('active') ||
      status.contains('dispatch')) {
    return AppTheme.primaryBlue;
  }
  if (status.contains('delay') ||
      status.contains('pending') ||
      status.contains('hold')) {
    return AppTheme.warningOrange;
  }
  if (status.contains('cancel') ||
      status.contains('fail') ||
      status.contains('error')) {
    return AppTheme.errorRed;
  }

  return AppTheme.colorFF6B7280;
}

String cleanDashboardRouteTextForDisplay(Map<String, dynamic> trip) {
  final fallback = formatValue(trip['routeFallback']);
  final routeText = formatValue(
    trip['routeText'] ??
        '${formatValue(trip['origin'])} -> ${formatValue(trip['destination'])}',
  );
  final hasControl = routeText.runes.any(
    (codePoint) => codePoint < 0x20 && codePoint != 0x09 && codePoint != 0x0A,
  );

  if (hasControl) {
    return fallback == 'N/A' ? 'Route coordinates unavailable' : fallback;
  }

  return routeText;
}
