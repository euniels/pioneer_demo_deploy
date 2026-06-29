import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../config/pioneer_runtime_config.dart';
import '../models/telemetry_view_data.dart';
import '../services/backend_api.dart';
import '../services/crud_permissions.dart';
import '../services/fleet_sync_service.dart';
import '../services/geotab_sync_status_service.dart';
import '../services/vehicles_store.dart';
import '../utils/display_format.dart';
import '../utils/form_validation.dart';
import '../widgets/admin_page_controls.dart';
import '../widgets/dashboard_layout.dart';
import '../widgets/geotab_push_preview.dart';
import '../widgets/geotab_sync_status_badge.dart';
import '../widgets/page_skeletons.dart';
import '../widgets/telemetry_widgets.dart';
import '../theme/app_theme.dart';

class MaintenancePage extends StatefulWidget {
  const MaintenancePage({super.key});

  @override
  State<MaintenancePage> createState() => _MaintenancePageState();
}

enum _MaintenanceHistoryAction { edit, voidRecord, pushToGeotab }

class _MaintenancePageState extends State<MaintenancePage> {
  late Future<Map<String, dynamic>> _future;
  String _section = 'alerts';
  String _searchQuery = '';
  String _vehicleFilter = 'All Vehicles';
  String _typeFilter = 'All Types';
  String _sortMode = 'Date Newest';
  DateTime? _dateFrom;
  DateTime? _dateTo;

  static const _maintenanceTypes = [
    'Preventive Maintenance Service',
    'Corrective Repair',
    'Oil Change',
    'Tire Replacement',
    'Battery',
    'Brake Service',
    'Air Filter',
    'Other',
  ];
  static const _fallbackSamplePlates = ['IAE 5512', 'LAM 9297', 'NDZ 6263'];

  @override
  void initState() {
    super.initState();
    geotabWriteBackEventNotifier.addListener(_onWriteBackEvent);
    _future = _load(forceRefresh: true);
  }

  @override
  void dispose() {
    geotabWriteBackEventNotifier.removeListener(_onWriteBackEvent);
    super.dispose();
  }

  void _onWriteBackEvent() {
    final event = geotabWriteBackEventNotifier.value;
    if (event == null || !mounted) {
      return;
    }
    if ((event['localType']?.toString() ?? '') == 'maintenance_history') {
      _reload();
    }
  }

  Future<Map<String, dynamic>> _load({bool forceRefresh = false}) async {
    Map<String, dynamic> summary = {};
    try {
      summary = await BackendApiService.loadWithWarmRetry<Map<String, dynamic>>(
        attempts: forceRefresh ? 2 : 4,
        request: (retryForceRefresh) {
          final effectiveForceRefresh = forceRefresh || retryForceRefresh;
          warmOperationalCachesSilently(forceRefresh: effectiveForceRefresh);
          return BackendApiService.getFleetSummaryMaintenance(
            forceRefresh: effectiveForceRefresh,
          );
        },
      );
    } catch (_) {
      summary =
          BackendApiService.peekCachedDataMap('/fleet/summary/maintenance') ??
          {};
    }

    List<Map<String, dynamic>> history = const [];
    try {
      history = await BackendApiService.getMaintenanceHistory(
        forceRefresh: forceRefresh,
      );
    } catch (_) {}

    var faults = _listOfMaps(summary['faults']);
    if (faults.isEmpty) {
      try {
        faults = await BackendApiService.getFleetMaintenanceFaults(
          forceRefresh: forceRefresh,
        );
      } catch (_) {}
    }

    List<Map<String, dynamic>> predictive = _listOfMaps(summary['predictive']);
    try {
      final predictionPayload =
          await BackendApiService.getMaintenancePredictions(
            forceRefresh: forceRefresh,
          );
      final vehicles = _listOfMaps(predictionPayload['vehicles']);
      if (vehicles.isNotEmpty) {
        predictive = vehicles;
      }
    } catch (_) {}

    return {
      ...summary,
      'history': history,
      'faults': faults,
      'predictive': predictive,
    };
  }

  void _reload() {
    setState(() {
      _future = _load(forceRefresh: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      currentRoute: '/maintenance',
      title: 'Maintenance',
      subtitle: 'Service due, faults, DVIR, work orders, and live measurements',
      titleTextStyle: AppTheme.getDashboardPageTitleStyle(context),
      child: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        initialData: BackendApiService.peekCachedDataMap(
          '/fleet/summary/maintenance',
        ),
        builder: (context, snapshot) {
          final isDark = Theme.of(context).brightness == Brightness.dark;

          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const PioneerRouteSkeletonBody(routeName: '/maintenance');
          }

          if (snapshot.hasError) {
            return _MaintenanceEmptyState(
              isDark: isDark,
              title: 'Maintenance data is temporarily unavailable',
              message:
                  'The backend did not return maintenance intelligence right now.',
              actionLabel: 'Retry',
              onTap: _reload,
            );
          }

          final data = snapshot.data ?? const <String, dynamic>{};
          final overview = _mapOf(data['overview']);
          final realAlerts = _listOfMaps(data['alerts']);
          final faults = _listOfMaps(data['faults']);
          final dvir = _listOfMaps(data['dvir']);
          final workOrders = _listOfMaps(data['workOrders']);
          final realHistory = _listOfMaps(data['history']);
          final measurements = _listOfMaps(data['measurements']);
          final realPredictive = _listOfMaps(data['predictive']);
          final usingSampleMaintenance =
              PioneerRuntimeConfig.showMockData &&
              realAlerts.isEmpty &&
              realHistory.isEmpty &&
              realPredictive.isEmpty;
          final alerts = usingSampleMaintenance
              ? _sampleServiceDueRows()
              : realAlerts;
          final history = usingSampleMaintenance
              ? _sampleHistoryRows()
              : realHistory;
          final predictive = usingSampleMaintenance
              ? _samplePredictiveRows()
              : realPredictive;

          final serviceDueRows = alerts.isNotEmpty ? alerts : predictive;
          final sectionRows = switch (_section) {
            'faults' => faults,
            'dvir' => dvir,
            'workOrders' => workOrders,
            'history' => _filteredHistory(history),
            'measurements' => measurements,
            'predictive' => predictive,
            _ => serviceDueRows,
          }.where(_matchesMaintenanceSearch).toList();
          final cardSection =
              _section == 'alerts' &&
                  alerts.isEmpty &&
                  serviceDueRows.isNotEmpty
              ? 'predictive'
              : _section;
          final sectionHeading = switch (_section) {
            'alerts' => 'Service Due',
            'predictive' => 'Predictive Maintenance Risk',
            'faults' => 'Diagnostic Faults',
            'dvir' => 'Driver Vehicle Inspection Reports',
            'workOrders' => 'Work Orders',
            'history' => 'Maintenance History',
            'measurements' => 'Fleet Measurements',
            _ => 'Maintenance',
          };
          final sectionSubtitle = switch (_section) {
            'predictive' =>
              'Predicted due dates and odometer thresholds from local service history.',
            'history' =>
              'Complete local and GeoTab service record with proof and sync status.',
            'alerts' =>
              'Vehicles needing immediate service scheduling attention.',
            'faults' => 'Diagnostic events requiring inspection or repair.',
            _ => 'Operational maintenance records and follow-up actions.',
          };

          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: Column(
              children: [
                _buildMaintenanceToolbar(isDark, sectionRows.length),
                _buildSectionSwitcher(isDark),
                if (_section == 'history')
                  _buildHistoryFilters(isDark, history),
                Expanded(
                  child: Container(
                    color: isDark
                        ? AppTheme.colorFF0A0E1A
                        : AppTheme.colorFFF5F6F8,
                    child: ListView(
                      padding: const EdgeInsets.all(AppTheme.space24),
                      children: [
                        _buildOverview(isDark, overview),
                        const SizedBox(
                          height: AppTheme.dashboardSectionSpacing,
                        ),
                        _MaintenanceSectionHeading(
                          title: sectionHeading,
                          subtitle: sectionSubtitle,
                        ),
                        const SizedBox(height: AppTheme.space20),
                        if (usingSampleMaintenance &&
                            (_section == 'alerts' ||
                                _section == 'history' ||
                                _section == 'predictive')) ...[
                          const _MaintenanceSampleDataBanner(),
                          const SizedBox(height: AppTheme.space16),
                        ],
                        if (_section == 'predictive' && predictive.isNotEmpty)
                          _buildPredictiveRiskMatrix(isDark, predictive)
                        else if (_section == 'history' &&
                            sectionRows.isNotEmpty)
                          _buildHistoryTable(isDark, sectionRows)
                        else if (sectionRows.isEmpty)
                          _emptyStateForSection(isDark, history)
                        else
                          ...sectionRows.map(
                            (row) => _MaintenanceCard(
                              data: row,
                              section: cardSection,
                              isDark: isDark,
                              onTap: _section == 'faults'
                                  ? () => _showFaultDetails(row)
                                  : _section == 'workOrders'
                                  ? () => _showWorkOrderDetails(row)
                                  : null,
                              onEdit:
                                  CrudPermissions.canEdit(
                                        CrudEntity.maintenance,
                                      ) &&
                                      _section == 'history'
                                  ? () => _openMaintenanceForm(record: row)
                                  : null,
                              onVoid:
                                  CrudPermissions.canDelete(
                                        CrudEntity.maintenance,
                                      ) &&
                                      _section == 'history' &&
                                      (row['voided'] == true) == false
                                  ? () => _confirmVoid(row)
                                  : null,
                              onPush:
                                  _section == 'history' && canPushToGeotab(row)
                                  ? () => _pushMaintenanceToGeotab(row)
                                  : null,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _samplePlate(int index) {
    final currentPlates = vehiclesNotifier.value
        .map(
          (vehicle) =>
              (vehicle['plate'] ?? vehicle['plateNumber'])?.toString().trim() ??
              '',
        )
        .where((plate) => plate.isNotEmpty)
        .toList();
    if (index < currentPlates.length) {
      return currentPlates[index];
    }
    return _fallbackSamplePlates[index % _fallbackSamplePlates.length];
  }

  List<Map<String, dynamic>> _sampleServiceDueRows() => [
    {
      'isSample': true,
      'vehicle': _samplePlate(0),
      'type': 'Preventive Maintenance Service',
      'priority': 'High',
      'description': 'Service interval approaching at 86,200 km.',
    },
    {
      'isSample': true,
      'vehicle': _samplePlate(1),
      'type': 'Oil Change',
      'priority': 'Medium',
      'description': 'Oil service due within the next two weeks.',
    },
  ];

  List<Map<String, dynamic>> _sampleHistoryRows() => [
    {
      'id': 'sample-maintenance-1',
      'isSample': true,
      'source': 'sample',
      'vehiclePlate': _samplePlate(0),
      'vehicle': _samplePlate(0),
      'type': 'Preventive Maintenance Service',
      'recordedAt': '2026-03-18T09:30:00+08:00',
      'odometerKm': 81200,
      'costLabel': 'PHP 18,750.00',
      'provider': 'Pioneer Cabuyao Workshop',
      'notes': 'Full inspection, lubrication, and brake adjustment.',
      'hasProof': true,
    },
    {
      'id': 'sample-maintenance-2',
      'isSample': true,
      'source': 'sample',
      'vehiclePlate': _samplePlate(1),
      'vehicle': _samplePlate(1),
      'type': 'Oil Change',
      'recordedAt': '2026-04-11T14:15:00+08:00',
      'odometerKm': 57450,
      'costLabel': 'PHP 6,400.00',
      'provider': 'Pioneer Cabuyao Workshop',
      'notes': 'Engine oil and oil filter replaced.',
      'hasProof': false,
    },
    {
      'id': 'sample-maintenance-3',
      'isSample': true,
      'source': 'sample',
      'vehiclePlate': _samplePlate(2),
      'vehicle': _samplePlate(2),
      'type': 'Tire Replacement',
      'recordedAt': '2026-02-25T10:00:00+08:00',
      'odometerKm': 102800,
      'costLabel': 'PHP 32,000.00',
      'provider': 'Laguna Fleet Tire Center',
      'notes': 'Rear axle tires replaced after tread inspection.',
      'hasProof': true,
    },
  ];

  List<Map<String, dynamic>> _samplePredictiveRows() => [
    {
      'isSample': true,
      'plate': _samplePlate(0),
      'vehicle': _samplePlate(0),
      'lastServiceAt': '2026-03-18',
      'nextDueDate': '2026-05-20',
      'nextDueKm': 86200,
      'daysRemaining': -7,
      'state': 'overdue',
    },
    {
      'isSample': true,
      'plate': _samplePlate(1),
      'vehicle': _samplePlate(1),
      'lastServiceAt': '2026-04-11',
      'nextDueDate': '2026-06-06',
      'nextDueKm': 62450,
      'daysRemaining': 10,
      'state': 'due_soon',
    },
    {
      'isSample': true,
      'plate': _samplePlate(2),
      'vehicle': _samplePlate(2),
      'lastServiceAt': '2026-02-25',
      'nextDueDate': '2026-07-28',
      'nextDueKm': 112800,
      'daysRemaining': 62,
      'state': 'normal',
    },
  ];

  Future<void> _pushMaintenanceToGeotab(Map<String, dynamic> row) async {
    final historyId = row['id'].toString();
    final preview = await BackendApiService.pushMaintenanceHistoryToGeotab(
      historyId,
      previewOnly: true,
    );
    if (!mounted) return;
    if (!await guardGeotabPushPreview(context: context, preview: preview)) {
      return;
    }
    final confirmed = await showGeotabPushPreview(
      context: context,
      entityType: 'Maintenance Reminder',
      entityName: (row['vehiclePlate'] ?? row['vehicle'] ?? historyId)
          .toString(),
      payload: preview['preview'],
      snapshot: preview['geotabSnapshot'],
      previewPayload: preview['previewPayload'],
    );
    if (confirmed != true) return;

    await BackendApiService.pushMaintenanceHistoryToGeotab(historyId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('GeoTab push request staged for admin approval.'),
      ),
    );
    _reload();
  }

  Widget _emptyStateForSection(
    bool isDark,
    List<Map<String, dynamic>> history,
  ) {
    if (_section == 'alerts' || _section == 'predictive') {
      return _MaintenanceEmptyState(
        isDark: isDark,
        title: 'No service records found',
        message: 'Add maintenance history to enable predictions.',
        actionLabel: CrudPermissions.canCreate(CrudEntity.maintenance)
            ? 'Add Log'
            : null,
        onTap: CrudPermissions.canCreate(CrudEntity.maintenance)
            ? () => _openMaintenanceForm()
            : null,
      );
    }
    if (_section == 'history' && history.isNotEmpty) {
      return _MaintenanceEmptyState(
        isDark: isDark,
        title: 'No maintenance records match these filters',
        message: 'Clear the filters to view all local maintenance history.',
        actionLabel: 'Clear Filters',
        onTap: () => setState(() {
          _vehicleFilter = 'All Vehicles';
          _typeFilter = 'All Types';
          _sortMode = 'Date Newest';
          _dateFrom = null;
          _dateTo = null;
        }),
      );
    }
    if (_section == 'history') {
      return _MaintenanceEmptyState(
        isDark: isDark,
        title: 'No maintenance history yet',
        message: 'Add manual maintenance records to build service history.',
        actionLabel: CrudPermissions.canCreate(CrudEntity.maintenance)
            ? 'Add Log'
            : null,
        onTap: CrudPermissions.canCreate(CrudEntity.maintenance)
            ? () => _openMaintenanceForm()
            : null,
      );
    }
    if (_section == 'faults') {
      return _MaintenanceEmptyState(
        isDark: isDark,
        title: 'No fault details available',
        message:
            'Fault details appear here when GeoTab diagnostic data is available.',
      );
    }
    return _MaintenanceEmptyState(
      isDark: isDark,
      title: 'No rows found',
      message: 'This section has no records to show right now.',
    );
  }

  Future<void> _showFaultDetails(Map<String, dynamic> fault) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_faultCode(fault)),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FaultDetailRow(label: 'Vehicle', value: _faultVehicle(fault)),
              _FaultDetailRow(label: 'Severity', value: _faultSeverity(fault)),
              _FaultDetailRow(
                label: 'First detected',
                value: _faultTimestamp(fault),
              ),
              _FaultDetailRow(
                label: 'Description',
                value: _faultDescription(fault),
              ),
              if (_faultDescriptionNeedsGeotab(fault))
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Description requires GeoTab diagnostic data.',
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.warningOrange
                          : AppTheme.colorFFF59E0B,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildMaintenanceToolbar(bool isDark, int resultCount) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        border: Border(
          bottom: BorderSide(
            color: isDark
                ? AppTheme.white.withAlpha(18)
                : AppTheme.black.withAlpha(14),
          ),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 720;
          final search = _MaintenanceSearchField(
            value: _searchQuery,
            isDark: isDark,
            onChanged: (value) => setState(() => _searchQuery = value),
            onClear: () => setState(() => _searchQuery = ''),
          );
          final canAdd = CrudPermissions.canCreate(CrudEntity.maintenance);
          final addButton = _MaintenanceToolbarButton(
            label: compact
                ? 'Add'
                : (_section == 'workOrders' ? 'Create Work Order' : 'Add Log'),
            icon: _section == 'workOrders'
                ? Icons.handyman_rounded
                : Icons.add_task_rounded,
            color: AppTheme.successGreen,
            filled: true,
            onTap: () => _section == 'workOrders'
                ? _openWorkOrderForm()
                : _openMaintenanceForm(),
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                search,
                if (canAdd) ...[const SizedBox(height: 10), addButton],
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: AdminResultCount(count: resultCount, label: 'records'),
                ),
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: search),
                  if (canAdd) ...[const SizedBox(width: 14), addButton],
                ],
              ),
              const SizedBox(height: 12),
              AdminResultCount(count: resultCount, label: 'records'),
            ],
          );
        },
      ),
    );
  }

  Widget _buildOverview(bool isDark, Map<String, dynamic> overview) {
    final cards = [
      _OverviewCard(
        label: 'Alerts',
        value: '${overview['activeAlerts'] ?? 0}',
        subtitle: 'need scheduling',
        icon: Icons.warning_amber_rounded,
        accent: AppTheme.colorFFF59E0B,
        isDark: isDark,
      ),
      _OverviewCard(
        label: 'Faults',
        value: '${overview['faults'] ?? 0}',
        subtitle: 'diagnostic events',
        icon: Icons.report_problem_rounded,
        accent: AppTheme.colorFFEF4444,
        isDark: isDark,
      ),
      _OverviewCard(
        label: 'DVIR',
        value: '${overview['dvirReports'] ?? 0}',
        subtitle: 'inspection reports',
        icon: Icons.fact_check_rounded,
        accent: AppTheme.colorFF4B7BE5,
        isDark: isDark,
      ),
      _OverviewCard(
        label: 'Work Orders',
        value: '${overview['workOrders'] ?? 0}',
        subtitle: 'shop activity',
        icon: Icons.handyman_rounded,
        accent: AppTheme.colorFF10B981,
        isDark: isDark,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 920) {
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

        return Row(
          children: [
            Expanded(child: cards[0]),
            const SizedBox(width: 12),
            Expanded(child: cards[1]),
            const SizedBox(width: 12),
            Expanded(child: cards[2]),
            const SizedBox(width: 12),
            Expanded(child: cards[3]),
          ],
        );
      },
    );
  }

  Widget _buildSectionSwitcher(bool isDark) {
    final sections = const {
      'alerts': 'Service Due',
      'predictive': 'Predictive',
      'faults': 'Faults',
      'dvir': 'DVIR',
      'workOrders': 'Work Orders',
      'history': 'History',
      'measurements': 'Measurements',
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 12),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        border: Border(
          bottom: BorderSide(
            color: isDark
                ? AppTheme.white.withAlpha(18)
                : AppTheme.black.withAlpha(14),
          ),
        ),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: sections.entries.map((entry) {
              final selected = _section == entry.key;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InkWell(
                  onTap: () => setState(() => _section = entry.key),
                  borderRadius: BorderRadius.circular(10),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    height: 38,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: selected
                          ? AppTheme.successGreen.withValues(alpha: 0.14)
                          : AppTheme.white.withAlpha(8),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: selected
                            ? AppTheme.successGreen.withValues(alpha: 0.34)
                            : AppTheme.white.withAlpha(18),
                      ),
                    ),
                    child: Text(
                      entry.value,
                      style: AppTheme.getBodyStyle(context, fontSize: 12)
                          .copyWith(
                            fontWeight: FontWeight.w800,
                            color: selected
                                ? AppTheme.successGreen
                                : AppTheme.gray300,
                          ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildPredictiveRiskMatrix(
    bool isDark,
    List<Map<String, dynamic>> predictive,
  ) {
    final overdue = predictive
        .where((row) => _predictionState(row) == 'overdue')
        .toList();
    final dueSoon = predictive
        .where((row) => _predictionState(row) == 'due_soon')
        .toList();
    final healthy = predictive
        .where((row) => _predictionState(row) == 'normal')
        .toList();

    final columns = [
      _PredictionColumnData(
        title: 'Overdue',
        rows: overdue,
        color: AppTheme.errorRed,
        emptyMessage: 'No overdue services',
      ),
      _PredictionColumnData(
        title: 'Due Within 14 Days',
        rows: dueSoon,
        color: AppTheme.warningOrange,
        emptyMessage: 'No vehicles due soon',
      ),
      _PredictionColumnData(
        title: 'Healthy',
        rows: healthy,
        color: AppTheme.successGreen,
        emptyMessage: 'No healthy predictions yet',
      ),
    ];

    return Column(
      children: [
        _PredictionSummaryBar(
          total: predictive.length,
          overdue: overdue.length,
          dueSoon: dueSoon.length,
          healthy: healthy.length,
          isDark: isDark,
        ),
        const SizedBox(height: AppTheme.space20),
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 1080) {
              return Column(
                children: columns
                    .map(
                      (column) => Padding(
                        padding: const EdgeInsets.only(
                          bottom: AppTheme.space16,
                        ),
                        child: _PredictionRiskColumn(
                          data: column,
                          isDark: isDark,
                        ),
                      ),
                    )
                    .toList(),
              );
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var index = 0; index < columns.length; index++) ...[
                    if (index > 0) const SizedBox(width: AppTheme.space16),
                    Expanded(
                      child: _PredictionRiskColumn(
                        data: columns[index],
                        isDark: isDark,
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildHistoryTable(bool isDark, List<Map<String, dynamic>> history) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 940) {
          return Column(
            children: history.map((row) {
              final isSample = row['isSample'] == true;
              return _MaintenanceCard(
                data: row,
                section: 'history',
                isDark: isDark,
                onEdit:
                    !isSample && CrudPermissions.canEdit(CrudEntity.maintenance)
                    ? () => _openMaintenanceForm(record: row)
                    : null,
                onVoid:
                    !isSample &&
                        CrudPermissions.canDelete(CrudEntity.maintenance) &&
                        (row['voided'] == true) == false
                    ? () => _confirmVoid(row)
                    : null,
                onPush: !isSample && canPushToGeotab(row)
                    ? () => _pushMaintenanceToGeotab(row)
                    : null,
              );
            }).toList(),
          );
        }

        return Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: isDark ? AppTheme.colorFF141924 : AppTheme.white,
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            border: Border.all(color: AppTheme.getBorderColor(context)),
          ),
          child: Column(
            children: [
              _buildHistoryHeader(),
              for (var index = 0; index < history.length; index++)
                _buildHistoryRow(isDark, history[index], index),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHistoryHeader() {
    return Container(
      color: AppTheme.primaryBlue,
      constraints: const BoxConstraints(minHeight: 54),
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.space16),
      child: Row(
        children: [
          _historyColumn('DATE', 12, header: true),
          _historyColumn('VEHICLE', 12, header: true),
          _historyColumn('SERVICE / REMARKS', 24, header: true),
          _historyColumn('ODOMETER', 11, header: true),
          _historyColumn('PROVIDER / PROOF', 15, header: true),
          _historyColumn('COST', 9, header: true),
          _historyColumn('SOURCE', 10, header: true),
          _historyColumn('ACTIONS', 7, header: true),
        ],
      ),
    );
  }

  Widget _buildHistoryRow(bool isDark, Map<String, dynamic> row, int index) {
    final isSample = row['isSample'] == true;
    final isGeotab = _isGeotabHistory(row);
    final voided =
        row['voided'] == true ||
        row['status']?.toString().toLowerCase() == 'voided';
    final date =
        row['serviceDate'] ??
        row['displayDate'] ??
        row['recordedAt'] ??
        row['dateTime'];

    return Container(
      constraints: const BoxConstraints(minHeight: 68),
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space16,
        vertical: AppTheme.space10,
      ),
      decoration: BoxDecoration(
        color: isDark
            ? (index.isEven ? AppTheme.colorFF141924 : AppTheme.darkPanelAlt)
            : (index.isEven ? AppTheme.white : AppTheme.colorFFF8FBFF),
        border: Border(
          bottom: BorderSide(color: AppTheme.getBorderColor(context)),
        ),
      ),
      child: Row(
        children: [
          _historyColumn(formatValue(date), 12),
          _historyColumn(
            formatValue(row['vehiclePlate'] ?? row['vehicle']),
            12,
            strong: true,
          ),
          _historyColumn(
            formatValue(row['type']),
            24,
            secondary: formatValue(row['notes'] ?? row['description']),
          ),
          _historyColumn('${formatValue(row['odometerKm'])} km', 11),
          _historyColumn(
            formatValue(row['provider']),
            15,
            secondary: row['hasProof'] == true ? 'Proof attached' : 'No proof',
          ),
          _historyColumn(formatValue(row['costLabel'] ?? row['cost']), 9),
          Expanded(
            flex: 10,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _TinyBadge(
                label: isSample
                    ? 'Sample'
                    : voided
                    ? 'Voided'
                    : (isGeotab ? 'GeoTab' : 'Manual Entry'),
                color: isSample
                    ? AppTheme.warningOrange
                    : voided
                    ? AppTheme.errorRed
                    : (isGeotab ? AppTheme.successGreen : AppTheme.primaryBlue),
              ),
            ),
          ),
          Expanded(
            flex: 7,
            child: Align(
              alignment: Alignment.centerRight,
              child: isSample
                  ? Text(
                      'Preview',
                      style: AppTheme.getCaptionStyle(context).copyWith(
                        color: AppTheme.warningOrange,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  : PopupMenuButton<_MaintenanceHistoryAction>(
                      tooltip: 'Maintenance record actions',
                      onSelected: (action) {
                        switch (action) {
                          case _MaintenanceHistoryAction.edit:
                            _openMaintenanceForm(record: row);
                          case _MaintenanceHistoryAction.voidRecord:
                            _confirmVoid(row);
                          case _MaintenanceHistoryAction.pushToGeotab:
                            _pushMaintenanceToGeotab(row);
                        }
                      },
                      itemBuilder: (context) => [
                        if (CrudPermissions.canEdit(CrudEntity.maintenance))
                          const PopupMenuItem(
                            value: _MaintenanceHistoryAction.edit,
                            child: Text('Edit / Supplement'),
                          ),
                        if (CrudPermissions.canDelete(CrudEntity.maintenance) &&
                            !voided)
                          const PopupMenuItem(
                            value: _MaintenanceHistoryAction.voidRecord,
                            child: Text('Void Record'),
                          ),
                        if (canPushToGeotab(row))
                          const PopupMenuItem(
                            value: _MaintenanceHistoryAction.pushToGeotab,
                            child: Text('Push to GeoTab'),
                          ),
                      ],
                      icon: const Icon(Icons.more_vert_rounded),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _historyColumn(
    String value,
    int flex, {
    bool header = false,
    bool strong = false,
    String? secondary,
  }) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.only(right: AppTheme.space8),
        child: header
            ? Text(
                value,
                style: const TextStyle(
                  color: AppTheme.white,
                  fontSize: AppTheme.dashboardBodySize,
                  fontWeight: FontWeight.w700,
                ),
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        AppTheme.getBodyStyle(
                          context,
                          fontSize: AppTheme.dashboardBodySize,
                        ).copyWith(
                          fontWeight: strong
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                  ),
                  if (secondary != null) ...[
                    const SizedBox(height: AppTheme.space4),
                    Text(
                      secondary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.getCaptionStyle(context),
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  bool _isGeotabHistory(Map<String, dynamic> row) {
    return row['isReadOnly'] == true ||
        row['source']?.toString().toLowerCase() == 'geotab';
  }

  Widget _buildHistoryFilters(bool isDark, List<Map<String, dynamic>> history) {
    final vehicles = {
      'All Vehicles',
      ...history
          .map(
            (row) =>
                row['vehiclePlate']?.toString() ??
                row['vehicle']?.toString() ??
                '',
          )
          .where((value) => value.trim().isNotEmpty && value != 'N/A'),
    }.toList();
    final types = {'All Types', ..._maintenanceTypes}.toList();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        border: Border(
          bottom: BorderSide(
            color: isDark
                ? AppTheme.white.withAlpha(18)
                : AppTheme.black.withAlpha(14),
          ),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 720;
          final fieldWidth = narrow ? constraints.maxWidth : 220.0;
          final typeWidth = narrow ? constraints.maxWidth : 320.0;
          return Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: fieldWidth,
                child: AdminFilterChip(
                  label: 'Vehicle',
                  value: vehicles.contains(_vehicleFilter)
                      ? _vehicleFilter
                      : 'All Vehicles',
                  activeWhen: 'All Vehicles',
                  options: vehicles,
                  onSelected: (value) => setState(() {
                    _vehicleFilter = value;
                  }),
                  onClear: () => setState(() {
                    _vehicleFilter = 'All Vehicles';
                  }),
                ),
              ),
              SizedBox(
                width: typeWidth,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: types.contains(_typeFilter)
                      ? _typeFilter
                      : 'All Types',
                  items: types
                      .map(
                        (value) =>
                            DropdownMenuItem(value: value, child: Text(value)),
                      )
                      .toList(),
                  onChanged: (value) =>
                      setState(() => _typeFilter = value ?? 'All Types'),
                  decoration: const InputDecoration(
                    labelText: 'Maintenance type',
                  ),
                ),
              ),
              _DateFilterButton(
                label: 'From',
                value: _dateFrom,
                onTap: () => _pickFilterDate(true),
              ),
              _DateFilterButton(
                label: 'To',
                value: _dateTo,
                onTap: () => _pickFilterDate(false),
              ),
              SizedBox(
                width: fieldWidth,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _sortMode,
                  items: const [
                    DropdownMenuItem(
                      value: 'Date Newest',
                      child: Text('Date Newest'),
                    ),
                    DropdownMenuItem(
                      value: 'Date Oldest',
                      child: Text('Date Oldest'),
                    ),
                    DropdownMenuItem(
                      value: 'Vehicle A-Z',
                      child: Text('Vehicle A-Z'),
                    ),
                    DropdownMenuItem(
                      value: 'Vehicle Z-A',
                      child: Text('Vehicle Z-A'),
                    ),
                    DropdownMenuItem(
                      value: 'Type A-Z',
                      child: Text('Type A-Z'),
                    ),
                    DropdownMenuItem(
                      value: 'Type Z-A',
                      child: Text('Type Z-A'),
                    ),
                  ],
                  onChanged: (value) =>
                      setState(() => _sortMode = value ?? 'Date Newest'),
                  decoration: const InputDecoration(labelText: 'Sort'),
                ),
              ),
              TextButton.icon(
                onPressed: () => setState(() {
                  _vehicleFilter = 'All Vehicles';
                  _typeFilter = 'All Types';
                  _sortMode = 'Date Newest';
                  _dateFrom = null;
                  _dateTo = null;
                }),
                icon: const Icon(Icons.clear_rounded),
                label: const Text('Clear'),
              ),
            ],
          );
        },
      ),
    );
  }

  List<Map<String, dynamic>> _filteredHistory(List<Map<String, dynamic>> rows) {
    final filtered = rows.where((row) {
      final vehicle =
          row['vehiclePlate']?.toString() ?? row['vehicle']?.toString() ?? '';
      if (_vehicleFilter != 'All Vehicles' && vehicle != _vehicleFilter) {
        return false;
      }
      if (_typeFilter != 'All Types' &&
          row['type']?.toString() != _typeFilter) {
        return false;
      }
      final recordedAt = DateTime.tryParse(
        row['recordedAt']?.toString() ?? row['dateTime']?.toString() ?? '',
      );
      if (_dateFrom != null &&
          recordedAt != null &&
          recordedAt.isBefore(_dateFrom!)) {
        return false;
      }
      if (_dateTo != null &&
          recordedAt != null &&
          recordedAt.isAfter(
            DateTime(_dateTo!.year, _dateTo!.month, _dateTo!.day, 23, 59, 59),
          )) {
        return false;
      }
      return true;
    }).toList();
    filtered.sort((a, b) {
      return switch (_sortMode) {
        'Date Oldest' => _compareMaintenanceDates(a, b, newestFirst: false),
        'Vehicle A-Z' => _compareMaintenanceText(a, b, 'vehiclePlate'),
        'Vehicle Z-A' => _compareMaintenanceText(b, a, 'vehiclePlate'),
        'Type A-Z' => _compareMaintenanceText(a, b, 'type'),
        'Type Z-A' => _compareMaintenanceText(b, a, 'type'),
        _ => _compareMaintenanceDates(a, b, newestFirst: true),
      };
    });
    return filtered;
  }

  bool _matchesMaintenanceSearch(Map<String, dynamic> row) {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return true;
    }
    final searchable = [
      row['vehiclePlate'],
      row['vehicle'],
      row['plate'],
      row['type'],
      row['priority'],
      row['status'],
      row['description'],
      row['notes'],
      row['provider'],
      row['faultCode'],
      row['diagnosticName'],
      row['workOrderNumber'],
      row['source'],
    ].map((value) => value?.toString().toLowerCase() ?? '').join(' ');
    return searchable.contains(query);
  }

  int _compareMaintenanceDates(
    Map<String, dynamic> a,
    Map<String, dynamic> b, {
    required bool newestFirst,
  }) {
    final dateA = DateTime.tryParse(
      a['recordedAt']?.toString() ?? a['dateTime']?.toString() ?? '',
    );
    final dateB = DateTime.tryParse(
      b['recordedAt']?.toString() ?? b['dateTime']?.toString() ?? '',
    );
    if (dateA == null && dateB == null) return 0;
    if (dateA == null) return 1;
    if (dateB == null) return -1;
    return newestFirst ? dateB.compareTo(dateA) : dateA.compareTo(dateB);
  }

  int _compareMaintenanceText(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
    String field,
  ) {
    final valueA = field == 'vehiclePlate'
        ? (a['vehiclePlate'] ?? a['vehicle'])
        : a[field];
    final valueB = field == 'vehiclePlate'
        ? (b['vehiclePlate'] ?? b['vehicle'])
        : b[field];
    return (valueA?.toString().toLowerCase() ?? '').compareTo(
      valueB?.toString().toLowerCase() ?? '',
    );
  }

  Future<void> _pickFilterDate(bool from) async {
    final selected = await showDatePicker(
      context: context,
      initialDate: (from ? _dateFrom : _dateTo) ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 3650)),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
    );
    if (selected == null) return;
    setState(() {
      if (from) {
        _dateFrom = selected;
      } else {
        _dateTo = selected;
      }
    });
  }

  Future<void> _openMaintenanceForm({Map<String, dynamic>? record}) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _MaintenanceLogDialog(
        record: record,
        types: _maintenanceTypes,
        onSave: (payload) async {
          if (record == null) {
            await BackendApiService.createMaintenanceHistory(payload);
          } else {
            await BackendApiService.updateMaintenanceHistory(
              record['id'].toString(),
              payload,
            );
          }
          _reload();
        },
      ),
    );
  }

  Future<void> _openWorkOrderForm({Map<String, dynamic>? record}) async {
    final nativeRecord = record == null || _isNativeWorkOrder(record);
    if (!nativeRecord) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Create a native work order before editing evidence.'),
        ),
      );
      return;
    }
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _WorkOrderDialog(record: record),
    );
    if (result == null || !mounted) return;
    try {
      final id = _nativeWorkOrderId(record);
      if (id.isEmpty) {
        await BackendApiService.createMaintenanceWorkOrder(result);
      } else {
        await BackendApiService.updateMaintenanceWorkOrder(id, result);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Work order saved.')));
      _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            FormValidation.backendError(
              error,
              'Work order could not be saved.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _showWorkOrderDetails(Map<String, dynamic> record) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _WorkOrderDetailsDialog(
        record: record,
        onCreateFromEvidence: (payload) async {
          await BackendApiService.createMaintenanceWorkOrder(payload);
          _reload();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Native work order created from evidence.'),
            ),
          );
        },
        onStatus: (status) async {
          await _updateWorkOrderStatus(record, status);
        },
        onAttach: () async {
          await _attachWorkOrderProof(record);
        },
        onEdit: () async {
          Navigator.pop(context);
          await _openWorkOrderForm(record: record);
        },
      ),
    );
  }

  Future<void> _updateWorkOrderStatus(
    Map<String, dynamic> record,
    String status,
  ) async {
    final id = _nativeWorkOrderId(record);
    if (id.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Create a native work order before changing status.'),
        ),
      );
      return;
    }
    try {
      await BackendApiService.updateMaintenanceWorkOrder(id, {
        'status': status,
        'notes': 'Status changed to ${_workOrderStatusLabel(status)}.',
      });
      if (!mounted) return;
      Navigator.maybePop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Work order marked ${_workOrderStatusLabel(status)}.'),
        ),
      );
      _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            FormValidation.backendError(
              error,
              'Work order status could not be updated.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _attachWorkOrderProof(Map<String, dynamic> record) async {
    final id = _nativeWorkOrderId(record);
    if (id.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Create a native work order before attaching proof.'),
        ),
      );
      return;
    }
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'pdf'],
      withData: true,
    );
    final file = result?.files.single;
    if (file == null || file.bytes == null) return;
    final extension = (file.extension ?? '').toLowerCase();
    final mime = switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'pdf' => 'application/pdf',
      _ => 'application/octet-stream',
    };
    try {
      await BackendApiService.addMaintenanceWorkOrderAttachment(id, {
        'fileName': file.name,
        'fileType': mime,
        'dataUrl': 'data:$mime;base64,${base64Encode(file.bytes!)}',
        'kind': 'repair_proof',
      });
      if (!mounted) return;
      Navigator.maybePop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Work order proof attached.')),
      );
      _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            FormValidation.backendError(
              error,
              'Attachment could not be saved.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _confirmVoid(Map<String, dynamic> record) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Void maintenance record?'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Required void reason',
            hintText: 'Explain why this record was entered in error',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Void Record'),
          ),
        ],
      ),
    );
    controller.dispose();
    if ((reason ?? '').trim().isEmpty) return;
    try {
      await BackendApiService.voidMaintenanceHistory(
        record['id'].toString(),
        reason!.trim(),
      );
      _reload();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Maintenance record could not be voided.'),
        ),
      );
    }
  }
}

class _MaintenanceSectionHeading extends StatelessWidget {
  const _MaintenanceSectionHeading({
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 4,
          height: 46,
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
                style: AppTheme.getBodyStyle(
                  context,
                  fontSize: AppTheme.dashboardBodySize,
                ).copyWith(color: AppTheme.getSubtleTextColor(context)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _WorkOrderDialog extends StatefulWidget {
  const _WorkOrderDialog({this.record});

  final Map<String, dynamic>? record;

  @override
  State<_WorkOrderDialog> createState() => _WorkOrderDialogState();
}

class _WorkOrderDialogState extends State<_WorkOrderDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _vehicleController;
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _assignedController;
  late final TextEditingController _estimatedCostController;
  late final TextEditingController _notesController;
  String _priority = 'medium';
  String _sourceType = 'manual';

  @override
  void initState() {
    super.initState();
    final record = widget.record ?? const <String, dynamic>{};
    _vehicleController = TextEditingController(
      text: formatValue(
        record['vehiclePlate'] ?? record['vehicle'],
      ).replaceAll('N/A', ''),
    );
    _titleController = TextEditingController(
      text: formatValue(record['title']).replaceAll('N/A', ''),
    );
    _descriptionController = TextEditingController(
      text: formatValue(record['description']).replaceAll('N/A', ''),
    );
    _assignedController = TextEditingController(
      text: formatValue(record['assignedTo']).replaceAll('N/A', ''),
    );
    _estimatedCostController = TextEditingController(
      text: formatValue(record['estimatedCost']).replaceAll('N/A', ''),
    );
    _notesController = TextEditingController(
      text: formatValue(record['notes']).replaceAll('N/A', ''),
    );
    _priority = _normalizeWorkOrderPriority(
      record['priorityKey'] ?? record['priority'],
    );
    _sourceType = _normalizeWorkOrderSource(record['sourceType']);
  }

  @override
  void dispose() {
    _vehicleController.dispose();
    _titleController.dispose();
    _descriptionController.dispose();
    _assignedController.dispose();
    _estimatedCostController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 720;
    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: isMobile ? 12 : 32,
        vertical: 24,
      ),
      backgroundColor: AppTheme.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Material(
            color: AppTheme.getCardBg(context),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _DialogHeader(
                  icon: Icons.handyman_rounded,
                  title: widget.record == null
                      ? 'Create Work Order'
                      : 'Edit Work Order',
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(22),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        children: [
                          _field(
                            _vehicleController,
                            'Vehicle plate',
                            required: true,
                          ),
                          const SizedBox(height: 12),
                          _field(_titleController, 'Title', required: true),
                          const SizedBox(height: 12),
                          _field(
                            _descriptionController,
                            'Description',
                            required: true,
                            maxLines: 3,
                          ),
                          const SizedBox(height: 12),
                          _row(isMobile, [
                            DropdownButtonFormField<String>(
                              initialValue: _priority,
                              decoration: const InputDecoration(
                                labelText: 'Priority',
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'low',
                                  child: Text('Low'),
                                ),
                                DropdownMenuItem(
                                  value: 'medium',
                                  child: Text('Medium'),
                                ),
                                DropdownMenuItem(
                                  value: 'high',
                                  child: Text('High'),
                                ),
                                DropdownMenuItem(
                                  value: 'critical',
                                  child: Text('Critical'),
                                ),
                              ],
                              onChanged: (value) =>
                                  setState(() => _priority = value ?? 'medium'),
                            ),
                            DropdownButtonFormField<String>(
                              initialValue: _sourceType,
                              decoration: const InputDecoration(
                                labelText: 'Source',
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'manual',
                                  child: Text('Manual'),
                                ),
                                DropdownMenuItem(
                                  value: 'geotab_fault',
                                  child: Text('From GeoTab Fault'),
                                ),
                                DropdownMenuItem(
                                  value: 'geotab_dvir',
                                  child: Text('From DVIR'),
                                ),
                                DropdownMenuItem(
                                  value: 'geotab_status',
                                  child: Text('From Device Status'),
                                ),
                                DropdownMenuItem(
                                  value: 'service_threshold',
                                  child: Text('Service Threshold'),
                                ),
                              ],
                              onChanged: (value) => setState(
                                () => _sourceType = value ?? 'manual',
                              ),
                            ),
                          ]),
                          const SizedBox(height: 12),
                          _row(isMobile, [
                            _field(_assignedController, 'Assigned to'),
                            _field(
                              _estimatedCostController,
                              'Estimated cost',
                              keyboardType: TextInputType.number,
                            ),
                          ]),
                          const SizedBox(height: 12),
                          _field(_notesController, 'Notes', maxLines: 2),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: _submit,
                          child: const Text('Save Work Order'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool required = false,
    TextInputType? keyboardType,
    int maxLines = 1,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      validator: keyboardType == TextInputType.number
          ? (value) => FormValidation.nonNegativeNumber(
              label,
              value,
              required: required,
            )
          : required
          ? (value) => FormValidation.requiredField(label, value)
          : null,
      decoration: InputDecoration(labelText: required ? '$label *' : label),
    );
  }

  Widget _row(bool mobile, List<Widget> children) {
    if (mobile) {
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

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(context, {
      'vehiclePlate': _vehicleController.text.trim(),
      'title': _titleController.text.trim(),
      'description': _descriptionController.text.trim(),
      'priority': _priority,
      'sourceType': _sourceType,
      'assignedTo': _assignedController.text.trim(),
      'estimatedCost': double.tryParse(_estimatedCostController.text.trim()),
      'notes': _notesController.text.trim(),
    });
  }
}

class _WorkOrderDetailsDialog extends StatelessWidget {
  const _WorkOrderDetailsDialog({
    required this.record,
    required this.onCreateFromEvidence,
    required this.onStatus,
    required this.onAttach,
    required this.onEdit,
  });

  final Map<String, dynamic> record;
  final Future<void> Function(Map<String, dynamic> payload)
  onCreateFromEvidence;
  final Future<void> Function(String status) onStatus;
  final Future<void> Function() onAttach;
  final Future<void> Function() onEdit;

  @override
  Widget build(BuildContext context) {
    final id = record['id']?.toString() ?? '';
    final isNative = _isNativeWorkOrder(record);
    final status = _normalizeWorkOrderStatus(
      record['statusKey'] ?? record['status'],
    );
    final source = formatValue(record['sourceLabel'] ?? record['sourceType']);
    final attachments = _listOfMaps(record['attachments']);
    final terminal = {'completed', 'verified', 'voided'}.contains(status);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      backgroundColor: AppTheme.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Material(
            color: AppTheme.getCardBg(context),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _DialogHeader(
                  icon: Icons.handyman_rounded,
                  title: 'Work Order Details',
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                formatValue(record['title'] ?? 'Work Order'),
                                style: AppTheme.getHeadingStyle(
                                  context,
                                  fontSize: 22,
                                ),
                              ),
                            ),
                            _TinyBadge(
                              label: _workOrderStatusLabel(status),
                              color: _workOrderStatusColor(status),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _TinyBadge(
                              label: source,
                              color: AppTheme.primaryBlue,
                            ),
                            _TinyBadge(
                              label: isNative
                                  ? 'Native Work Order'
                                  : 'GeoTab Evidence',
                              color: isNative
                                  ? AppTheme.successGreen
                                  : AppTheme.warningOrange,
                            ),
                            _TinyBadge(
                              label: formatValue(
                                record['priority'] ?? 'Medium',
                              ),
                              color: AppTheme.warningOrange,
                            ),
                            _TinyBadge(
                              label:
                                  '${attachments.length} attachment${attachments.length == 1 ? '' : 's'}',
                              color: AppTheme.successGreen,
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          formatValue(record['description']),
                          style: AppTheme.getBodyStyle(context).copyWith(
                            color: AppTheme.getSubtleTextColor(context),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            _MetricPill(
                              label: 'Vehicle',
                              value: formatValue(
                                record['vehiclePlate'] ?? record['vehicle'],
                              ),
                            ),
                            _MetricPill(
                              label: 'Assigned',
                              value: formatValue(record['assignedTo']),
                            ),
                            _MetricPill(
                              label: 'Estimated',
                              value: formatValue(record['estimatedCostLabel']),
                            ),
                            _MetricPill(
                              label: 'Actual',
                              value: formatValue(record['actualCostLabel']),
                            ),
                          ],
                        ),
                        if (formatValue(record['sourceSummary']) != 'N/A') ...[
                          const SizedBox(height: 16),
                          Text(
                            'Source evidence',
                            style: AppTheme.getBodyStyle(
                              context,
                            ).copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            formatValue(record['sourceSummary']),
                            style: AppTheme.settingsSubtitleStyle(context),
                          ),
                        ],
                        if (!isNative) ...[
                          const SizedBox(height: 16),
                          _EvidenceNotice(id: id),
                        ],
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    alignment: WrapAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                      if (!isNative)
                        FilledButton.icon(
                          onPressed: () async {
                            await onCreateFromEvidence(
                              _payloadFromEvidence(record),
                            );
                            if (context.mounted) Navigator.pop(context);
                          },
                          icon: const Icon(Icons.add_task_rounded),
                          label: const Text('Create Native Work Order'),
                        ),
                      if (isNative) ...[
                        OutlinedButton.icon(
                          onPressed: onAttach,
                          icon: const Icon(Icons.attach_file_rounded),
                          label: const Text('Attach Proof'),
                        ),
                        OutlinedButton.icon(
                          onPressed: onEdit,
                          icon: const Icon(Icons.edit_note_rounded),
                          label: const Text('Edit'),
                        ),
                        if (!terminal)
                          FilledButton.icon(
                            onPressed: () async =>
                                onStatus(_nextWorkOrderStatus(status)),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: Text(_nextWorkOrderAction(status)),
                          ),
                        if (!terminal)
                          TextButton.icon(
                            onPressed: () async => onStatus('voided'),
                            icon: const Icon(Icons.block_rounded),
                            label: const Text('Void'),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DialogHeader extends StatelessWidget {
  const _DialogHeader({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
      color: AppTheme.colorFF4B7BE5,
      child: Row(
        children: [
          Icon(icon, color: AppTheme.white),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: AppTheme.getHeadingStyle(
                context,
                fontSize: 20,
              ).copyWith(color: AppTheme.white),
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
}

class _MetricPill extends StatelessWidget {
  const _MetricPill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 140),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.getSecondaryBg(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.getBorderColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: AppTheme.settingsSubtitleStyle(context, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            value == 'N/A' ? 'Not set' : value,
            style: AppTheme.getBodyStyle(
              context,
            ).copyWith(fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

class _EvidenceNotice extends StatelessWidget {
  const _EvidenceNotice({required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.warningOrange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppTheme.warningOrange.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            color: AppTheme.warningOrange,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'This row is source evidence${id.isEmpty ? '' : ' ($id)'}. '
              'Create a native work order before editing, changing status, or attaching proof.',
              style: AppTheme.settingsSubtitleStyle(context),
            ),
          ),
        ],
      ),
    );
  }
}

bool _isNativeWorkOrder(Map<String, dynamic>? record) {
  return record?['isNativeWorkOrder'] == true;
}

String _nativeWorkOrderId(Map<String, dynamic>? record) {
  if (!_isNativeWorkOrder(record)) return '';
  return record?['id']?.toString() ?? '';
}

String _normalizeWorkOrderPriority(Object? value) {
  final normalized = value
      ?.toString()
      .trim()
      .toLowerCase()
      .replaceAll('-', '_')
      .replaceAll(' ', '_');
  return switch (normalized) {
    'low' => 'low',
    'medium' || 'normal' => 'medium',
    'high' => 'high',
    'critical' || 'urgent' => 'critical',
    _ => 'medium',
  };
}

String _normalizeWorkOrderSource(Object? value) {
  final normalized = value
      ?.toString()
      .trim()
      .toLowerCase()
      .replaceAll('-', '_')
      .replaceAll(' ', '_');
  if (normalized == null || normalized.isEmpty) return 'manual';
  if (normalized.contains('fault')) return 'geotab_fault';
  if (normalized.contains('dvir')) return 'geotab_dvir';
  if (normalized.contains('status') || normalized.contains('offline')) {
    return 'geotab_status';
  }
  if (normalized.contains('threshold') || normalized.contains('service')) {
    return 'service_threshold';
  }
  return switch (normalized) {
    'manual' => 'manual',
    'geotab_fault' => 'geotab_fault',
    'geotab_dvir' => 'geotab_dvir',
    'geotab_status' => 'geotab_status',
    'service_threshold' => 'service_threshold',
    _ => 'manual',
  };
}

String _normalizeWorkOrderStatus(Object? value) {
  final normalized = value
      ?.toString()
      .trim()
      .toLowerCase()
      .replaceAll('-', '_')
      .replaceAll(' ', '_');
  return switch (normalized) {
    'assigned' => 'assigned',
    'in_progress' || 'started' || 'active' => 'in_progress',
    'waiting_parts' || 'waiting' || 'on_hold' => 'waiting_parts',
    'completed' || 'complete' || 'done' => 'completed',
    'verified' => 'verified',
    'voided' || 'void' || 'cancelled' || 'canceled' => 'voided',
    _ => 'open',
  };
}

Map<String, dynamic> _payloadFromEvidence(Map<String, dynamic> record) {
  final sourceType = _normalizeWorkOrderSource(record['sourceType']);
  return {
    'vehiclePlate': formatValue(record['vehiclePlate'] ?? record['vehicle']),
    'title': formatValue(record['title'] ?? 'Maintenance Work Order'),
    'description': formatValue(
      record['description'] ?? record['sourceSummary'],
    ),
    'priority': _normalizeWorkOrderPriority(
      record['priorityKey'] ?? record['priority'],
    ),
    'sourceType': sourceType,
    'sourceRecordId': record['sourceRecordId']?.toString(),
    'sourceSummary': formatValue(record['sourceSummary']),
    'status': 'open',
  };
}

String _workOrderStatusLabel(String status) {
  return switch (status.toLowerCase().replaceAll(' ', '_')) {
    'assigned' => 'Assigned',
    'in_progress' => 'In progress',
    'waiting_parts' => 'Waiting parts',
    'completed' => 'Completed',
    'verified' => 'Verified',
    'voided' => 'Voided',
    _ => 'Open',
  };
}

String _nextWorkOrderStatus(String status) {
  return switch (status.toLowerCase().replaceAll(' ', '_')) {
    'open' => 'assigned',
    'assigned' => 'in_progress',
    'in_progress' => 'completed',
    'waiting_parts' => 'in_progress',
    'completed' => 'verified',
    _ => 'in_progress',
  };
}

String _nextWorkOrderAction(String status) {
  return switch (status.toLowerCase().replaceAll(' ', '_')) {
    'open' => 'Assign',
    'assigned' => 'Start Work',
    'in_progress' => 'Complete',
    'waiting_parts' => 'Resume Work',
    'completed' => 'Verify',
    _ => 'Advance',
  };
}

Color _workOrderStatusColor(String status) {
  return switch (status.toLowerCase().replaceAll(' ', '_')) {
    'completed' || 'verified' => AppTheme.successGreen,
    'voided' => AppTheme.errorRed,
    'waiting_parts' => AppTheme.warningOrange,
    'in_progress' => AppTheme.primaryBlue,
    _ => AppTheme.colorFF8B5CF6,
  };
}

class _OverviewCard extends StatelessWidget {
  final String label;
  final String value;
  final String subtitle;
  final IconData icon;
  final Color accent;
  final bool isDark;

  const _OverviewCard({
    required this.label,
    required this.value,
    required this.subtitle,
    required this.icon,
    required this.accent,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 112),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF171B23 : AppTheme.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: accent.withValues(alpha: isDark ? 0.34 : 0.2),
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: isDark ? 0.14 : 0.08),
            blurRadius: 22,
            spreadRadius: -14,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: accent, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: isDark ? AppTheme.gray300 : AppTheme.gray700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: isDark ? AppTheme.white : AppTheme.colorFF233244,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
    );
  }
}

class _MaintenanceToolbarButton extends StatelessWidget {
  const _MaintenanceToolbarButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
    this.filled = false,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          constraints: const BoxConstraints(minWidth: 144),
          decoration: BoxDecoration(
            color: filled ? color : color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: color.withValues(alpha: filled ? 0 : 0.28),
            ),
            boxShadow: filled
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.22),
                      blurRadius: 16,
                      spreadRadius: -10,
                      offset: const Offset(0, 10),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: filled ? AppTheme.white : color, size: 18),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: filled ? AppTheme.white : color,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MaintenanceSearchField extends StatelessWidget {
  const _MaintenanceSearchField({
    required this.value,
    required this.isDark,
    required this.onChanged,
    required this.onClear,
  });

  final String value;
  final bool isDark;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return TextField(
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText:
            'Search by vehicle, service type, fault, provider, or notes...',
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: value.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                onPressed: onClear,
                icon: const Icon(Icons.close_rounded),
              ),
        filled: true,
        fillColor: isDark ? AppTheme.colorFF1A1D23 : AppTheme.colorFFF8FAFD,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
            color: isDark
                ? AppTheme.white.withAlpha(18)
                : AppTheme.black.withAlpha(12),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
            color: isDark
                ? AppTheme.white.withAlpha(18)
                : AppTheme.black.withAlpha(12),
          ),
        ),
      ),
      style: TextStyle(
        fontSize: 14,
        color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
      ),
    );
  }
}

class _PredictionColumnData {
  const _PredictionColumnData({
    required this.title,
    required this.rows,
    required this.color,
    required this.emptyMessage,
  });

  final String title;
  final List<Map<String, dynamic>> rows;
  final Color color;
  final String emptyMessage;
}

class _PredictionSummaryBar extends StatelessWidget {
  const _PredictionSummaryBar({
    required this.total,
    required this.overdue,
    required this.dueSoon,
    required this.healthy,
    required this.isDark,
  });

  final int total;
  final int overdue;
  final int dueSoon;
  final int healthy;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppTheme.space20),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF141924 : AppTheme.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.getBorderColor(context)),
      ),
      child: Wrap(
        spacing: AppTheme.space24,
        runSpacing: AppTheme.space12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '$total vehicles evaluated',
            style: AppTheme.getHeadingStyle(
              context,
              fontSize: AppTheme.dashboardSectionHeaderSize,
            ),
          ),
          _PredictionCountBadge(
            label: 'Overdue',
            count: overdue,
            color: AppTheme.errorRed,
          ),
          _PredictionCountBadge(
            label: 'Due soon',
            count: dueSoon,
            color: AppTheme.warningOrange,
          ),
          _PredictionCountBadge(
            label: 'Healthy',
            count: healthy,
            color: AppTheme.successGreen,
          ),
        ],
      ),
    );
  }
}

class _PredictionCountBadge extends StatelessWidget {
  const _PredictionCountBadge({
    required this.label,
    required this.count,
    required this.color,
  });

  final String label;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space12,
        vertical: AppTheme.space8,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Text(
        label.isEmpty ? '$count' : '$count $label',
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _PredictionRiskColumn extends StatelessWidget {
  const _PredictionRiskColumn({required this.data, required this.isDark});

  final _PredictionColumnData data;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppTheme.space20),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF141924 : AppTheme.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: data.color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: AppTheme.space8,
                height: AppTheme.space20,
                decoration: BoxDecoration(
                  color: data.color,
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                ),
              ),
              const SizedBox(width: AppTheme.space10),
              Expanded(
                child: Text(
                  data.title,
                  style: AppTheme.getHeadingStyle(
                    context,
                    fontSize: AppTheme.dashboardSectionHeaderSize,
                  ),
                ),
              ),
              _PredictionCountBadge(
                label: '',
                count: data.rows.length,
                color: data.color,
              ),
            ],
          ),
          const SizedBox(height: AppTheme.space16),
          if (data.rows.isEmpty)
            Text(
              data.emptyMessage,
              style: AppTheme.getBodyStyle(
                context,
                fontSize: AppTheme.dashboardBodySize,
              ).copyWith(color: AppTheme.getSubtleTextColor(context)),
            )
          else
            ...data.rows.map(
              (row) => Padding(
                padding: const EdgeInsets.only(bottom: AppTheme.space12),
                child: _PredictionVehicleRow(
                  row: row,
                  color: data.color,
                  isDark: isDark,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PredictionVehicleRow extends StatelessWidget {
  const _PredictionVehicleRow({
    required this.row,
    required this.color,
    required this.isDark,
  });

  final Map<String, dynamic> row;
  final Color color;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final days = _predictionDays(row);
    final recommendation = days < 0
        ? 'Overdue - service immediately'
        : 'Schedule service within $days days';
    return Container(
      padding: const EdgeInsets.all(AppTheme.space12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.1 : 0.06),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  formatValue(row['plate'] ?? row['vehicle']),
                  style: AppTheme.getBodyStyle(
                    context,
                    fontSize: AppTheme.dashboardBodySize,
                  ).copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                days < 0 ? '${days.abs()}d overdue' : '${days}d',
                style: TextStyle(
                  fontSize: AppTheme.dashboardKpiValueSize,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.space8),
          Text(
            'Last service: ${formatValue(row['lastServiceAt'])}',
            style: AppTheme.getCaptionStyle(context),
          ),
          Text(
            'Next due: ${formatValue(row['nextDueDate'])} | ${formatValue(row['nextDueKm'])} km',
            style: AppTheme.getCaptionStyle(context),
          ),
          const SizedBox(height: AppTheme.space8),
          Text(
            recommendation,
            style: TextStyle(
              color: color,
              fontSize: AppTheme.dashboardBodySize,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _MaintenanceCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final String section;
  final bool isDark;
  final VoidCallback? onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onVoid;
  final VoidCallback? onPush;

  const _MaintenanceCard({
    required this.data,
    required this.section,
    required this.isDark,
    this.onTap,
    this.onEdit,
    this.onVoid,
    this.onPush,
  });

  @override
  Widget build(BuildContext context) {
    final isSample = data['isSample'] == true;
    final title = switch (section) {
      'faults' => _faultCode(data),
      'dvir' => 'DVIR ${(data['vehicle'] ?? 'Vehicle').toString()}',
      'workOrders' => (data['title'] ?? 'Work Order').toString(),
      'history' => (data['type'] ?? 'Maintenance History').toString(),
      'measurements' => (data['vehicle'] ?? 'Vehicle').toString(),
      'predictive' =>
        (data['vehicle'] ?? data['plate'] ?? 'Vehicle').toString(),
      _ => (data['type'] ?? 'Maintenance').toString(),
    };

    final subtitle = switch (section) {
      'faults' =>
        "${data['vehicle'] ?? 'Unknown'} • ${data['severity'] ?? 'Unknown severity'}",
      'dvir' =>
        "${data['driver'] ?? 'Unknown driver'} • ${(data['displayDate'] ?? 'N/A').toString()}",
      'workOrders' =>
        "${data['vehicle'] ?? 'Unknown'} • ${(data['scheduledDate'] ?? 'N/A').toString()}",
      'history' =>
        "${data['vehicle'] ?? 'Unknown'} • ${(data['serviceDate'] ?? data['displayDate'] ?? 'N/A').toString()}",
      'measurements' =>
        "Odometer ${(data['odometerKm'] ?? 0)} km • Engine ${(data['engineHours'] ?? 0)} h",
      'predictive' =>
        "${data['vehicle'] ?? data['plate'] ?? 'Vehicle'} • ${(data['label'] ?? 'Prediction pending').toString()}",
      _ =>
        "${data['vehicle'] ?? 'Unknown'} • ${(data['priority'] ?? 'Low').toString()} priority",
    };

    final description = switch (section) {
      'faults' =>
        "${data['failureMode'] ?? 'Fault recorded'} • ${data['state'] ?? 'Unknown state'}",
      'dvir' => (data['driverRemark'] ?? 'No driver remark').toString(),
      'workOrders' => (data['description'] ?? 'No description').toString(),
      'history' =>
        (data['notes'] ?? data['description'] ?? 'No maintenance history notes')
            .toString(),
      'measurements' =>
        "Fuel ${(data['fuelLevelRatio'] ?? 0)} • Next ${(data['nextMaintenance'] ?? 'N/A')}",
      'predictive' =>
        "Predicted next due: ${(data['predictedNextDueAt'] ?? 'N/A').toString()}",
      _ => (data['description'] ?? 'No description').toString(),
    };

    final voided =
        data['voided'] == true ||
        data['status']?.toString().toLowerCase() == 'voided';
    final readOnly = data['isReadOnly'] == true;
    final severityText = _faultSeverity(data).toLowerCase();
    final faultSeverity =
        severityText.contains('critical') || severityText.contains('high')
        ? TelemetrySeverity.critical
        : severityText.contains('medium') || severityText.contains('warning')
        ? TelemetrySeverity.warning
        : TelemetrySeverity.normal;
    final faultColor = telemetrySeverityColor(
      faultSeverity,
      TelemetryAvailability.live,
    );

    final card = Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF141924 : AppTheme.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: section == 'faults'
              ? faultColor.withValues(alpha: 0.4)
              : isDark
              ? AppTheme.white.withValues(alpha: 0.06)
              : AppTheme.black.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: AppTheme.dashboardSectionHeaderSize,
                    fontWeight: FontWeight.w900,
                    color: isDark ? AppTheme.white : AppTheme.colorFF18212F,
                  ),
                ),
              ),
              if (section == 'faults') ...[
                _TinyBadge(label: _faultSeverity(data), color: faultColor),
                const SizedBox(width: 7),
                _TinyBadge(
                  label: data['acknowledged'] == true
                      ? 'Acknowledged'
                      : 'Needs review',
                  color: data['acknowledged'] == true
                      ? AppTheme.successGreen
                      : AppTheme.warningOrange,
                ),
              ],
              if (section == 'dvir')
                _TinyBadge(
                  label: data['repaired'] == true
                      ? 'Repaired'
                      : data['hasDefects'] == true
                      ? 'Defect found'
                      : 'Passed',
                  color: data['repaired'] == true || data['hasDefects'] != true
                      ? AppTheme.successGreen
                      : AppTheme.warningOrange,
                ),
            ],
          ),
          if (section == 'history') ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _TinyBadge(
                  label: isSample
                      ? 'Sample'
                      : voided
                      ? 'Voided'
                      : (readOnly ? 'GeoTab' : 'Manual Entry'),
                  color: isSample
                      ? AppTheme.warningOrange
                      : voided
                      ? AppTheme.errorRed
                      : (readOnly
                            ? AppTheme.successGreen
                            : AppTheme.primaryBlue),
                ),
                if (data['hasProof'] == true)
                  _TinyBadge(
                    label: isSample ? 'Sample proof' : 'Proof attached',
                    color: isSample
                        ? AppTheme.warningOrange
                        : AppTheme.primaryBlue,
                  ),
                if (!isSample)
                  GeoTabSyncStatusBadge.fromEntity(data, compact: true),
              ],
            ),
          ],
          if (section == 'workOrders') ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _TinyBadge(
                  label: _workOrderStatusLabel(
                    (data['statusKey'] ?? data['status'] ?? 'open').toString(),
                  ),
                  color: _workOrderStatusColor(
                    (data['statusKey'] ?? data['status'] ?? 'open').toString(),
                  ),
                ),
                _TinyBadge(
                  label: formatValue(data['sourceLabel'] ?? data['sourceType']),
                  color: AppTheme.primaryBlue,
                ),
                if (_listOfMaps(data['attachments']).isNotEmpty)
                  _TinyBadge(
                    label:
                        '${_listOfMaps(data['attachments']).length} proof file${_listOfMaps(data['attachments']).length == 1 ? '' : 's'}',
                    color: AppTheme.successGreen,
                  ),
              ],
            ),
          ],
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              color: isDark ? AppTheme.white70 : AppTheme.colorFF475569,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            description,
            style: TextStyle(
              height: 1.4,
              color: isDark ? AppTheme.white60 : AppTheme.colorFF64748B,
            ),
          ),
          if (section == 'faults') ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _TinyBadge(
                  label:
                      'First ${formatValue(data['firstDetectedAt'] ?? data['dateTime'])}',
                  color: AppTheme.primaryBlue,
                ),
                _TinyBadge(
                  label:
                      'Last ${formatValue(data['lastDetectedAt'] ?? data['recordedAt'] ?? data['dateTime'])}',
                  color: AppTheme.primaryBlue,
                ),
                _TinyBadge(
                  label:
                      '${data['occurrenceCount'] ?? 1} occurrence${(data['occurrenceCount'] ?? 1) == 1 ? '' : 's'}',
                  color: faultColor,
                ),
              ],
            ),
          ],
          if (section == 'history') ...[
            const SizedBox(height: 10),
            Text(
              'Odometer ${formatValue(data['odometerKm'])} km | Cost ${formatValue(data['costLabel'])} | Performed by ${formatValue(data['provider'])}',
              style: TextStyle(
                color: isDark ? AppTheme.white60 : AppTheme.colorFF64748B,
                fontSize: AppTheme.dashboardSecondarySize,
              ),
            ),
            if (voided && (data['voidReason']?.toString().isNotEmpty ?? false))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Void reason: ${formatValue(data['voidReason'])}',
                  style: const TextStyle(
                    color: AppTheme.errorRed,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (onEdit != null)
                  OutlinedButton.icon(
                    onPressed: onEdit,
                    icon: Icon(
                      readOnly
                          ? Icons.note_add_rounded
                          : Icons.edit_note_rounded,
                      size: 18,
                    ),
                    label: Text(readOnly ? 'Add Remarks/Proof' : 'Edit'),
                  ),
                if (onEdit != null && onVoid != null) const SizedBox(width: 8),
                if (onVoid != null)
                  TextButton.icon(
                    onPressed: onVoid,
                    icon: const Icon(Icons.block_rounded, size: 18),
                    label: const Text('Void'),
                  ),
                if (onPush != null) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: onPush,
                    icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                    label: const Text('Push to GeoTab'),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );

    if (onTap == null) {
      return card;
    }
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: onTap,
      child: card,
    );
  }
}

class _TinyBadge extends StatelessWidget {
  const _TinyBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: AppTheme.dashboardSecondarySize,
        ),
      ),
    );
  }
}

class _FaultDetailRow extends StatelessWidget {
  const _FaultDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: AppTheme.dashboardSecondarySize,
                fontWeight: FontWeight.w800,
                color: AppTheme.colorFF64748B,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _DateFilterButton extends StatelessWidget {
  const _DateFilterButton({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final DateTime? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.event_rounded, size: 18),
      label: Text(
        value == null
            ? label
            : '$label ${value!.year}-${value!.month.toString().padLeft(2, '0')}-${value!.day.toString().padLeft(2, '0')}',
      ),
    );
  }
}

class _MaintenanceLogDialog extends StatefulWidget {
  const _MaintenanceLogDialog({
    required this.types,
    required this.onSave,
    this.record,
  });

  final Map<String, dynamic>? record;
  final List<String> types;
  final Future<void> Function(Map<String, dynamic> payload) onSave;

  @override
  State<_MaintenanceLogDialog> createState() => _MaintenanceLogDialogState();
}

class _MaintenanceLogDialogState extends State<_MaintenanceLogDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _vehicleController;
  late final TextEditingController _geotabIdController;
  late final TextEditingController _odometerController;
  late final TextEditingController _providerController;
  late final TextEditingController _costController;
  late final TextEditingController _remarksController;
  String _type = 'Preventive Maintenance Service';
  DateTime _date = DateTime.now();
  DateTime? _nextDue;
  String? _proofFileName;
  String? _proofFileType;
  String? _proofDataUrl;
  bool _saving = false;
  bool _saved = false;

  bool get _editing => widget.record != null;
  bool get _readOnlySource => widget.record?['isReadOnly'] == true;

  @override
  void initState() {
    super.initState();
    final record = widget.record ?? const <String, dynamic>{};
    _vehicleController = TextEditingController(
      text: (record['vehiclePlate'] ?? record['vehicle'] ?? '').toString(),
    );
    _geotabIdController = TextEditingController(
      text: record['vehicleGeotabId']?.toString() ?? '',
    );
    _odometerController = TextEditingController(
      text: record['odometerKm']?.toString() ?? '',
    );
    _providerController = TextEditingController(
      text: _clean(record['provider']),
    );
    _costController = TextEditingController(
      text: record['cost']?.toString() ?? '',
    );
    _remarksController = TextEditingController(
      text: _clean(
        record['notes'] == 'N/A' ? record['description'] : record['notes'],
      ),
    );
    final existingType = record['type']?.toString();
    _type = widget.types.contains(existingType)
        ? existingType!
        : widget.types.first;
    _date =
        DateTime.tryParse(
          record['recordedAt']?.toString() ??
              record['dateTime']?.toString() ??
              '',
        ) ??
        DateTime.now();
    _nextDue = DateTime.tryParse(record['nextDueAt']?.toString() ?? '');
    _proofFileName = record['proofFileName']?.toString();
    _proofFileType = record['proofFileType']?.toString();
  }

  @override
  void dispose() {
    _vehicleController.dispose();
    _geotabIdController.dispose();
    _odometerController.dispose();
    _providerController.dispose();
    _costController.dispose();
    _remarksController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final mobile = width < 720;
    final vehicleOptions =
        vehiclesNotifier.value
            .map((vehicle) => vehicle['plate']?.toString().trim() ?? '')
            .where((plate) => plate.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    if (_vehicleController.text.trim().isNotEmpty &&
        !vehicleOptions.contains(_vehicleController.text.trim())) {
      vehicleOptions.add(_vehicleController.text.trim());
    }

    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: mobile ? width - 24 : 760),
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? AppTheme.colorFF111827
                : AppTheme.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.getBorderColor(context)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppTheme.primaryBlue, AppTheme.colorFF4B7BE5],
                  ),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.build_circle_rounded,
                      color: AppTheme.white,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _editing
                            ? (_readOnlySource
                                  ? 'Supplement GeoTab Maintenance'
                                  : 'Edit Maintenance Log')
                            : 'Add Maintenance Log',
                        style: const TextStyle(
                          color: AppTheme.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: AppTheme.white,
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _readOnlySource
                              ? 'GeoTab-sourced fields are read-only; add local remarks or proof only.'
                              : 'Manual C3-04/C3-05 service record for compliance and prediction.',
                          style: const TextStyle(
                            color: AppTheme.colorFF64748B,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 16),
                        _row(mobile, [
                          DropdownButtonFormField<String>(
                            initialValue:
                                vehicleOptions.contains(_vehicleController.text)
                                ? _vehicleController.text
                                : null,
                            items: vehicleOptions
                                .map(
                                  (plate) => DropdownMenuItem(
                                    value: plate,
                                    child: Text(plate),
                                  ),
                                )
                                .toList(),
                            onChanged: _readOnlySource
                                ? null
                                : (value) {
                                    if (value != null) {
                                      _vehicleController.text = value;
                                      final match = vehiclesNotifier.value
                                          .firstWhere(
                                            (vehicle) =>
                                                vehicle['plate']?.toString() ==
                                                value,
                                            orElse: () =>
                                                const <String, dynamic>{},
                                          );
                                      _geotabIdController.text =
                                          match['geotabId']?.toString() ?? '';
                                    }
                                  },
                            validator: (value) =>
                                FormValidation.requiredSelection(
                                  'vehicle',
                                  value ?? _vehicleController.text,
                                ),
                            decoration: const InputDecoration(
                              labelText: 'Vehicle *',
                            ),
                          ),
                          _dateTile(
                            label: 'Maintenance date',
                            value: _date,
                            enabled: !_readOnlySource,
                            onTap: () => _pickDate(true),
                          ),
                        ]),
                        const SizedBox(height: 12),
                        _row(mobile, [
                          _field(
                            _odometerController,
                            'Odometer reading at service in km',
                            required: true,
                            enabled: !_readOnlySource,
                            keyboardType: TextInputType.number,
                          ),
                          DropdownButtonFormField<String>(
                            initialValue: _type,
                            items: widget.types
                                .map(
                                  (type) => DropdownMenuItem(
                                    value: type,
                                    child: Text(type),
                                  ),
                                )
                                .toList(),
                            onChanged: _readOnlySource
                                ? null
                                : (value) =>
                                      setState(() => _type = value ?? _type),
                            validator: (value) =>
                                FormValidation.requiredSelection(
                                  'maintenance type',
                                  value,
                                ),
                            decoration: const InputDecoration(
                              labelText: 'Maintenance type',
                            ),
                          ),
                        ]),
                        const SizedBox(height: 12),
                        _row(mobile, [
                          _field(
                            _providerController,
                            'Service provider',
                            enabled: !_readOnlySource,
                          ),
                          _field(
                            _costController,
                            'Cost in PHP',
                            enabled: !_readOnlySource,
                            keyboardType: TextInputType.number,
                          ),
                          _dateTile(
                            label: 'Next due',
                            value: _nextDue,
                            enabled: !_readOnlySource,
                            onTap: () => _pickDate(false),
                          ),
                        ]),
                        const SizedBox(height: 12),
                        _field(
                          _remarksController,
                          'Remarks and findings',
                          required: true,
                          maxLines: 4,
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _pickProof,
                          icon: const Icon(Icons.attach_file_rounded, size: 18),
                          label: Text(
                            _proofFileName == null || _proofFileName!.isEmpty
                                ? 'Attach JPG, PNG, or PDF proof'
                                : 'Attached: $_proofFileName',
                          ),
                        ),
                        const SizedBox(height: 18),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _saving
                                    ? null
                                    : () => Navigator.pop(context),
                                child: const Text('Cancel'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton(
                                onPressed: _saving ? null : _submit,
                                child: _saving
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: AppTheme.white,
                                        ),
                                      )
                                    : Text(_saved ? 'Saved' : 'Save Log'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(bool mobile, List<Widget> children) {
    if (mobile) {
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

  Widget _field(
    TextEditingController controller,
    String label, {
    bool required = false,
    bool enabled = true,
    TextInputType? keyboardType,
    int maxLines = 1,
  }) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      keyboardType: keyboardType,
      maxLines: maxLines,
      validator: keyboardType == TextInputType.number
          ? (value) => FormValidation.nonNegativeNumber(
              label,
              value,
              required: required,
            )
          : required
          ? (value) => FormValidation.requiredField(label, value)
          : null,
      decoration: InputDecoration(labelText: required ? '$label *' : label),
    );
  }

  Widget _dateTile({
    required String label,
    required DateTime? value,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return InkWell(
      onTap: enabled ? onTap : null,
      child: InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: Text(value == null ? 'Not set' : _dateLabel(value)),
      ),
    );
  }

  Future<void> _pickDate(bool recorded) async {
    final selected = await showDatePicker(
      context: context,
      initialDate: recorded ? _date : (_nextDue ?? DateTime.now()),
      firstDate: DateTime.now().subtract(const Duration(days: 3650)),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
    );
    if (selected == null) return;
    setState(() {
      if (recorded) {
        _date = selected;
      } else {
        _nextDue = selected;
      }
    });
  }

  Future<void> _pickProof() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'pdf'],
      withData: true,
    );
    final file = result?.files.single;
    if (file == null || file.bytes == null) return;
    final extension = (file.extension ?? '').toLowerCase();
    final mime = switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'pdf' => 'application/pdf',
      _ => 'application/octet-stream',
    };
    setState(() {
      _proofFileName = file.name;
      _proofFileType = mime;
      _proofDataUrl = 'data:$mime;base64,${base64Encode(file.bytes!)}';
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _saved = false;
    });
    final payload = <String, dynamic>{
      if (!_readOnlySource) ...{
        'vehiclePlate': _vehicleController.text.trim(),
        'vehicleGeotabId': _geotabIdController.text.trim(),
        'type': _type,
        'description': _remarksController.text.trim(),
        'recordedAt': _date.toIso8601String(),
        'nextDueAt': _nextDue?.toIso8601String(),
        'odometerKm': double.tryParse(_odometerController.text.trim()) ?? 0,
        'cost': double.tryParse(_costController.text.trim()),
        'provider': _providerController.text.trim(),
        'source': 'manual',
      },
      'notes': _remarksController.text.trim(),
      'proofFileName': _proofFileName,
      'proofFileType': _proofFileType,
      'proofDataUrl': _proofDataUrl,
    };
    try {
      await widget.onSave(payload);
      if (!mounted) return;
      setState(() => _saved = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Changes saved locally.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            FormValidation.backendError(
              error,
              'Maintenance log could not be saved.',
            ),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _MaintenanceEmptyState extends StatelessWidget {
  final bool isDark;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onTap;

  const _MaintenanceEmptyState({
    required this.isDark,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.build_circle_outlined,
              size: 56,
              color: isDark ? AppTheme.white24 : AppTheme.black26,
            ),
            const SizedBox(height: 14),
            Text(
              title,
              style: TextStyle(
                fontSize: AppTheme.dashboardSectionHeaderSize,
                fontWeight: FontWeight.w900,
                color: isDark ? AppTheme.white : AppTheme.colorFF18212F,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark ? AppTheme.white60 : AppTheme.colorFF64748B,
              ),
            ),
            if (actionLabel != null && onTap != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onTap, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class _MaintenanceSampleDataBanner extends StatelessWidget {
  const _MaintenanceSampleDataBanner();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: const _MaintenanceDashedBorderPainter(
        color: AppTheme.warningOrange,
      ),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.space12,
          vertical: AppTheme.space10,
        ),
        decoration: BoxDecoration(
          color: AppTheme.warningOrange.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.science_outlined,
              color: AppTheme.warningOrange,
              size: 20,
            ),
            const SizedBox(width: AppTheme.space8),
            Expanded(
              child: Text(
                'Sample data - GeoTab did not return maintenance data. '
                'This shows what the section looks like with real records.',
                style:
                    AppTheme.getBodyStyle(
                      context,
                      fontSize: AppTheme.dashboardBodySize,
                    ).copyWith(
                      color: AppTheme.warningOrange,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MaintenanceDashedBorderPainter extends CustomPainter {
  const _MaintenanceDashedBorderPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          const Radius.circular(AppTheme.radiusMd),
        ),
      );

    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(
          metric.extractPath(
            distance,
            (distance + 6).clamp(0, metric.length).toDouble(),
          ),
          paint,
        );
        distance += 10;
      }
    }
  }

  @override
  bool shouldRepaint(_MaintenanceDashedBorderPainter oldDelegate) =>
      oldDelegate.color != color;
}

Map<String, dynamic> _mapOf(dynamic raw) {
  if (raw is! Map) return {};
  return raw.map((key, value) => MapEntry(key.toString(), value));
}

List<Map<String, dynamic>> _listOfMaps(dynamic raw) {
  if (raw is! List) return [];
  return raw
      .whereType<Map>()
      .map((item) => item.map((key, value) => MapEntry(key.toString(), value)))
      .toList();
}

String _dateLabel(DateTime value) {
  return '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
}

String _clean(dynamic value) {
  final text = value?.toString().trim() ?? '';
  return text == 'N/A' ? '' : text;
}

String _faultCode(Map<String, dynamic> fault) {
  final candidates = [
    fault['faultCode'],
    fault['code'],
    fault['diagnosticCode'],
    fault['name'],
    fault['id'],
  ];
  for (final value in candidates) {
    final text = value?.toString().trim() ?? '';
    if (text.isNotEmpty && text != 'N/A') {
      return text;
    }
  }
  return 'Fault code unavailable';
}

String _faultDescription(Map<String, dynamic> fault) {
  final candidates = [
    fault['description'],
    fault['diagnosticDescription'],
    fault['failureMode'],
    fault['state'],
  ];
  for (final value in candidates) {
    final text = value?.toString().trim() ?? '';
    if (text.isNotEmpty && text != 'N/A' && text.toLowerCase() != 'unknown') {
      return text;
    }
  }
  return 'Raw fault code shown. Description requires GeoTab diagnostic data.';
}

bool _faultDescriptionNeedsGeotab(Map<String, dynamic> fault) {
  return _faultDescription(
    fault,
  ).contains('Description requires GeoTab diagnostic data');
}

String _faultVehicle(Map<String, dynamic> fault) {
  final value = fault['vehicle'] ?? fault['plate'] ?? fault['vehiclePlate'];
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? 'Unknown vehicle' : text;
}

String _faultSeverity(Map<String, dynamic> fault) {
  final value = fault['severity'] ?? fault['severityCode'];
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? 'Unknown severity' : text;
}

String _faultTimestamp(Map<String, dynamic> fault) {
  final value =
      fault['firstDetectedAt'] ??
      fault['dateTime'] ??
      fault['recordedAt'] ??
      fault['displayDate'];
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? 'Timestamp unavailable' : text;
}

String _predictionState(Map<String, dynamic> row) {
  final state = row['state']?.toString().toLowerCase() ?? '';
  if (state == 'overdue' || state == 'due_soon' || state == 'normal') {
    return state;
  }
  final days = _predictionDays(row);
  if (days < 0) return 'overdue';
  if (days <= 14) return 'due_soon';
  return 'normal';
}

int _predictionDays(Map<String, dynamic> row) {
  final value = row['daysRemaining'];
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
