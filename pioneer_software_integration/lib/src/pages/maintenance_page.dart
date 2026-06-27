import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../config/pioneer_runtime_config.dart';
import '../services/backend_api.dart';
import '../services/crud_permissions.dart';
import '../services/fleet_sync_service.dart';
import '../services/geotab_sync_status_service.dart';
import '../services/vehicles_store.dart';
import '../utils/display_format.dart';
import '../utils/form_validation.dart';
import '../widgets/dashboard_layout.dart';
import '../widgets/geotab_push_preview.dart';
import '../widgets/geotab_sync_status_badge.dart';
import '../widgets/page_skeletons.dart';
import '../theme/app_theme.dart';

class MaintenancePage extends StatefulWidget {
  const MaintenancePage({super.key});

  @override
  State<MaintenancePage> createState() => _MaintenancePageState();
}

enum _MaintenanceHistoryAction { edit, voidRecord, pushToGeotab }

class _MaintenancePageState extends State<MaintenancePage> {
  late Future<Map<String, dynamic>> _future;
  String _section = 'workOrders';
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
      actions: [
        IconButton(
          tooltip: 'Refresh maintenance',
          onPressed: _reload,
          icon: const Icon(Icons.refresh_rounded),
        ),
        if (CrudPermissions.canCreate(CrudEntity.maintenance))
          FilledButton.icon(
            onPressed: () => _openMaintenanceForm(),
            icon: const Icon(Icons.add_task_rounded, size: 18),
            label: const Text('Add Log'),
          ),
      ],
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
          final realWorkOrders = _listOfMaps(data['workOrders']);
          final realHistory = _listOfMaps(data['history']);
          final measurements = _listOfMaps(data['measurements']);
          final realPredictive = _listOfMaps(data['predictive']);
          final usingSampleMaintenance =
              PioneerRuntimeConfig.showMockData &&
              realAlerts.isEmpty &&
              realWorkOrders.isEmpty &&
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
          final workOrders = usingSampleMaintenance
              ? _sampleWorkOrderRows()
              : realWorkOrders;

          final serviceDueRows = alerts.isNotEmpty ? alerts : predictive;
          final sectionRows = switch (_section) {
            'faults' => faults,
            'dvir' => dvir,
            'workOrders' => workOrders,
            'history' => _filteredHistory(history),
            'measurements' => measurements,
            'predictive' => predictive,
            _ => serviceDueRows,
          };
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
            child: ListView(
              padding: const EdgeInsets.all(AppTheme.space24),
              children: [
                const _MaintenanceSectionHeading(
                  title: 'Fleet Maintenance Readiness',
                  subtitle:
                      'Service risk, workshop activity, and compliance visibility.',
                ),
                const SizedBox(height: AppTheme.space20),
                _buildOverview(isDark, overview),
                const SizedBox(height: AppTheme.dashboardSectionSpacing),
                _buildSectionSwitcher(isDark),
                if (_section == 'history') ...[
                  const SizedBox(height: AppTheme.space20),
                  _buildHistoryFilters(isDark, history),
                ],
                const SizedBox(height: AppTheme.dashboardSectionSpacing),
                _MaintenanceSectionHeading(
                  title: sectionHeading,
                  subtitle: sectionSubtitle,
                ),
                if (_section == 'workOrders' &&
                    CrudPermissions.canCreate(CrudEntity.maintenance)) ...[
                  const SizedBox(height: AppTheme.space16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed: () => _openWorkOrderDialog(null),
                      icon: const Icon(Icons.assignment_add, size: 18),
                      label: const Text('Create Work Order'),
                    ),
                  ),
                ],
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
                else if (_section == 'history' && sectionRows.isNotEmpty)
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
                          ? () => _openWorkOrderDialog(row)
                          : null,
                      onEdit:
                          CrudPermissions.canEdit(CrudEntity.maintenance) &&
                              _section == 'history'
                          ? () => _openMaintenanceForm(record: row)
                          : null,
                      onVoid:
                          CrudPermissions.canDelete(CrudEntity.maintenance) &&
                              _section == 'history' &&
                              (row['voided'] == true) == false
                          ? () => _confirmVoid(row)
                          : null,
                      onPush: _section == 'history' && canPushToGeotab(row)
                          ? () => _pushMaintenanceToGeotab(row)
                          : null,
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

  List<Map<String, dynamic>> _sampleWorkOrderRows() => [
    {
      'id': 'sample-work-order-1',
      'workOrderId': 'WO-DEMO-001',
      'isSample': true,
      'isNativeWorkOrder': true,
      'vehicle': _samplePlate(0),
      'vehiclePlate': _samplePlate(0),
      'title': 'Inspect cooling system fault',
      'description':
          'GeoTab diagnostic evidence suggests a coolant temperature review is needed before the next dispatch.',
      'status': 'assigned',
      'statusLabel': 'Assigned',
      'priority': 'High',
      'priorityKey': 'high',
      'sourceType': 'geotab_fault',
      'sourceLabel': 'From GeoTab Fault',
      'sourceSummary': 'Demo GeoTab FaultData evidence.',
      'assignedTo': 'Maintenance Staff',
      'scheduledDate': '2026-06-18',
      'estimatedCostLabel': '₱8,500.00',
      'actualCostLabel': 'N/A',
      'attachmentCount': 1,
    },
    {
      'id': 'sample-work-order-2',
      'workOrderId': 'WO-DEMO-002',
      'isSample': true,
      'isNativeWorkOrder': true,
      'vehicle': _samplePlate(1),
      'vehiclePlate': _samplePlate(1),
      'title': 'Preventive service threshold',
      'description':
          'Service interval is close based on odometer and maintenance history.',
      'status': 'open',
      'statusLabel': 'Open',
      'priority': 'Medium',
      'priorityKey': 'medium',
      'sourceType': 'service_threshold',
      'sourceLabel': 'Service Threshold',
      'sourceSummary': 'Demo service threshold evidence.',
      'assignedTo': 'Unassigned',
      'scheduledDate': '2026-06-21',
      'estimatedCostLabel': '₱6,000.00',
      'actualCostLabel': 'N/A',
      'attachmentCount': 0,
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

  Future<void> _openWorkOrderDialog(Map<String, dynamic>? order) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _WorkOrderDialog(
        order: order,
        vehicles: vehiclesNotifier.value,
        onSave: (payload) async {
          final id = order?['id']?.toString() ?? '';
          final nativeExisting =
              id.isNotEmpty &&
              order?['isNativeWorkOrder'] == true &&
              order?['isSample'] != true;
          if (nativeExisting) {
            await BackendApiService.updateMaintenanceWorkOrder(id, payload);
          } else {
            await BackendApiService.createMaintenanceWorkOrder(payload);
          }
        },
        onStatusChange: (status, {String? reason}) async {
          final id = order?['id']?.toString() ?? '';
          if (id.isEmpty ||
              order?['isNativeWorkOrder'] != true ||
              order?['isSample'] == true) {
            return;
          }
          await BackendApiService.updateMaintenanceWorkOrder(id, {
            'status': status,
            if (reason != null && reason.trim().isNotEmpty)
              'voidReason': reason.trim(),
          });
        },
        onAttach: (payload) async {
          final id = order?['id']?.toString() ?? '';
          if (id.isEmpty ||
              order?['isNativeWorkOrder'] != true ||
              order?['isSample'] == true) {
            return;
          }
          await BackendApiService.addMaintenanceWorkOrderAttachment(
            id,
            payload,
          );
        },
      ),
    );
    if (saved == true) {
      _reload();
    }
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
    if (_section == 'workOrders') {
      return _MaintenanceEmptyState(
        isDark: isDark,
        title: 'No maintenance work orders yet',
        message:
            'Create a manual work order or convert GeoTab fault, DVIR, or device evidence into a repair workflow.',
        actionLabel: CrudPermissions.canCreate(CrudEntity.maintenance)
            ? 'Create Work Order'
            : null,
        onTap: CrudPermissions.canCreate(CrudEntity.maintenance)
            ? () => _openWorkOrderDialog(null)
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

  Widget _buildOverview(bool isDark, Map<String, dynamic> overview) {
    final cards = [
      _OverviewCard(
        label: 'Alerts',
        value: '${overview['activeAlerts'] ?? 0}',
        accent: AppTheme.colorFFF59E0B,
        isDark: isDark,
      ),
      _OverviewCard(
        label: 'Faults',
        value: '${overview['faults'] ?? 0}',
        accent: AppTheme.colorFFEF4444,
        isDark: isDark,
      ),
      _OverviewCard(
        label: 'DVIR',
        value: '${overview['dvirReports'] ?? 0}',
        accent: AppTheme.colorFF4B7BE5,
        isDark: isDark,
      ),
      _OverviewCard(
        label: 'Work Orders',
        value: '${overview['workOrders'] ?? 0}',
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
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF141924 : AppTheme.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.getBorderColor(context)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: sections.entries.map((entry) {
            final selected = _section == entry.key;
            return InkWell(
              onTap: () => setState(() => _section = entry.key),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTheme.space20,
                  vertical: AppTheme.space16,
                ),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: selected
                          ? AppTheme.primaryBlue
                          : AppTheme.transparent,
                      width: 3,
                    ),
                  ),
                ),
                child: Text(
                  entry.value,
                  style:
                      AppTheme.getBodyStyle(
                        context,
                        fontSize: AppTheme.dashboardBodySize,
                      ).copyWith(
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: selected
                            ? AppTheme.primaryBlue
                            : AppTheme.getSubtleTextColor(context),
                      ),
                ),
              ),
            );
          }).toList(),
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 720;
        final fieldWidth = narrow ? constraints.maxWidth : 220.0;
        final typeWidth = narrow ? constraints.maxWidth : 340.0;
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.colorFF141924 : AppTheme.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark
                  ? AppTheme.white.withValues(alpha: 0.06)
                  : AppTheme.black.withValues(alpha: 0.06),
            ),
          ),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: fieldWidth,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: vehicles.contains(_vehicleFilter)
                      ? _vehicleFilter
                      : 'All Vehicles',
                  items: vehicles
                      .map(
                        (value) =>
                            DropdownMenuItem(value: value, child: Text(value)),
                      )
                      .toList(),
                  onChanged: (value) =>
                      setState(() => _vehicleFilter = value ?? 'All Vehicles'),
                  decoration: const InputDecoration(labelText: 'Vehicle'),
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
          ),
        );
      },
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

class _OverviewCard extends StatelessWidget {
  final String label;
  final String value;
  final Color accent;
  final bool isDark;

  const _OverviewCard({
    required this.label,
    required this.value,
    required this.accent,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppTheme.dashboardKpiPadding),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF141924 : AppTheme.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusXl),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: AppTheme.dashboardKpiLabelSize,
              fontWeight: FontWeight.w800,
              color: accent,
            ),
          ),
          const SizedBox(height: AppTheme.space8),
          Text(value, style: AppTheme.getDashboardKpiValueStyle(context)),
        ],
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

    final card = Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF141924 : AppTheme.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.06)
              : AppTheme.black.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: AppTheme.dashboardSectionHeaderSize,
              fontWeight: FontWeight.w900,
              color: isDark ? AppTheme.white : AppTheme.colorFF18212F,
            ),
          ),
          if (section == 'workOrders') ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _TinyBadge(
                  label: isSample
                      ? 'Sample'
                      : (data['isNativeWorkOrder'] == true
                            ? 'PioneerPath Work Order'
                            : 'GeoTab Suggestion'),
                  color: isSample
                      ? AppTheme.warningOrange
                      : (data['isNativeWorkOrder'] == true
                            ? AppTheme.successGreen
                            : AppTheme.primaryBlue),
                ),
                _TinyBadge(
                  label: formatValue(data['sourceLabel'] ?? 'Manual'),
                  color: data['isGeotabBacked'] == true
                      ? AppTheme.primaryBlue
                      : AppTheme.colorFF64748B,
                ),
                _TinyBadge(
                  label: formatValue(data['statusLabel'] ?? data['status']),
                  color: _workOrderStatusColor(data['status']),
                ),
                if ((data['attachmentCount'] ?? 0) != 0)
                  _TinyBadge(
                    label: '${data['attachmentCount']} proof file(s)',
                    color: AppTheme.successGreen,
                  ),
              ],
            ),
          ],
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

Color _workOrderStatusColor(Object? value) {
  return switch (value?.toString().toLowerCase().replaceAll(' ', '_')) {
    'completed' || 'verified' => AppTheme.successGreen,
    'in_progress' || 'assigned' => AppTheme.primaryBlue,
    'waiting_parts' => AppTheme.warningOrange,
    'voided' => AppTheme.errorRed,
    _ => AppTheme.colorFF64748B,
  };
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

class _WorkOrderDialog extends StatefulWidget {
  const _WorkOrderDialog({
    required this.vehicles,
    required this.onSave,
    required this.onStatusChange,
    required this.onAttach,
    this.order,
  });

  final Map<String, dynamic>? order;
  final List<Map<String, dynamic>> vehicles;
  final Future<void> Function(Map<String, dynamic> payload) onSave;
  final Future<void> Function(String status, {String? reason}) onStatusChange;
  final Future<void> Function(Map<String, dynamic> payload) onAttach;

  @override
  State<_WorkOrderDialog> createState() => _WorkOrderDialogState();
}

class _WorkOrderDialogState extends State<_WorkOrderDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _vehicleController;
  late final TextEditingController _geotabIdController;
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _assignedController;
  late final TextEditingController _estimatedCostController;
  late final TextEditingController _actualCostController;
  late final TextEditingController _notesController;
  String _priority = 'medium';
  DateTime? _scheduledAt;
  bool _saving = false;
  bool _attaching = false;

  Map<String, dynamic> get _order => widget.order ?? const {};
  bool get _editing => widget.order != null && _order['isNativeWorkOrder'] == true;
  bool get _sample => _order['isSample'] == true;
  bool get _derived => _order['isDerivedWorkOrder'] == true;
  bool get _canPersist => !_sample;
  String get _status => (_order['status'] ?? 'open').toString();

  @override
  void initState() {
    super.initState();
    _vehicleController = TextEditingController(
      text: (_order['vehiclePlate'] ?? _order['vehicle'] ?? '').toString(),
    );
    _geotabIdController = TextEditingController(
      text: _order['vehicleGeotabId']?.toString() ?? '',
    );
    _titleController = TextEditingController(
      text: (_order['title'] ?? '').toString(),
    );
    _descriptionController = TextEditingController(
      text: (_order['description'] ?? '').toString(),
    );
    _assignedController = TextEditingController(
      text: (_order['assignedTo'] ?? '').toString().replaceAll('Unassigned', ''),
    );
    _estimatedCostController = TextEditingController(
      text: _numberText(_order['estimatedCost']),
    );
    _actualCostController = TextEditingController(
      text: _numberText(_order['actualCost']),
    );
    _notesController = TextEditingController(text: (_order['notes'] ?? '').toString());
    _priority = _priorityKey(_order['priorityKey'] ?? _order['priority']);
    _scheduledAt = DateTime.tryParse(_order['scheduledAt']?.toString() ?? '');
  }

  @override
  void dispose() {
    _vehicleController.dispose();
    _geotabIdController.dispose();
    _titleController.dispose();
    _descriptionController.dispose();
    _assignedController.dispose();
    _estimatedCostController.dispose();
    _actualCostController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final mobile = width < 760;
    final vehicleOptions =
        widget.vehicles
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
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: mobile ? width - 24 : 820,
          maxHeight: MediaQuery.of(context).size.height - 48,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.space24,
                vertical: AppTheme.space20,
              ),
              color: AppTheme.primaryBlue,
              child: Row(
                children: [
                  const Icon(Icons.assignment_rounded, color: AppTheme.white),
                  const SizedBox(width: AppTheme.space12),
                  Expanded(
                    child: Text(
                      _editing
                          ? 'Work Order ${formatValue(_order['workOrderId'])}'
                          : (_derived ? 'Create From GeoTab Evidence' : 'Create Work Order'),
                      style: const TextStyle(
                        color: AppTheme.white,
                        fontSize: AppTheme.dashboardSectionHeaderSize,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _saving || _attaching ? null : () => Navigator.pop(context, false),
                    icon: const Icon(Icons.close_rounded, color: AppTheme.white),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppTheme.space24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: AppTheme.space8,
                        runSpacing: AppTheme.space8,
                        children: [
                          _TinyBadge(
                            label: formatValue(_order['sourceLabel'] ?? 'Manual'),
                            color: _sourceColor(_order['sourceType']),
                          ),
                          _TinyBadge(
                            label: formatValue(_order['statusLabel'] ?? _status),
                            color: _statusColor(_status),
                          ),
                          _TinyBadge(
                            label: '${formatValue(_order['attachmentCount'] ?? 0)} attachment(s)',
                            color: AppTheme.primaryBlue,
                          ),
                        ],
                      ),
                      const SizedBox(height: AppTheme.space16),
                      if ((_order['sourceSummary']?.toString().trim().isNotEmpty ?? false)) ...[
                        _EvidencePanel(summary: _order['sourceSummary'].toString()),
                        const SizedBox(height: AppTheme.space16),
                      ],
                      _row(mobile, [
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: vehicleOptions.contains(_vehicleController.text)
                              ? _vehicleController.text
                              : null,
                          items: vehicleOptions
                              .map((plate) => DropdownMenuItem(value: plate, child: Text(plate)))
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            _vehicleController.text = value;
                            final match = widget.vehicles.firstWhere(
                              (vehicle) => vehicle['plate']?.toString() == value,
                              orElse: () => const <String, dynamic>{},
                            );
                            _geotabIdController.text = match['geotabId']?.toString() ?? '';
                          },
                          validator: (value) => FormValidation.requiredSelection(
                            'vehicle',
                            value ?? _vehicleController.text,
                          ),
                          decoration: const InputDecoration(labelText: 'Vehicle *'),
                        ),
                        _field(_titleController, 'Title *', required: true),
                      ]),
                      const SizedBox(height: AppTheme.space12),
                      _field(
                        _descriptionController,
                        'Work description *',
                        required: true,
                        maxLines: 4,
                      ),
                      const SizedBox(height: AppTheme.space12),
                      _row(mobile, [
                        DropdownButtonFormField<String>(
                          initialValue: _priority,
                          items: const [
                            DropdownMenuItem(value: 'low', child: Text('Low')),
                            DropdownMenuItem(value: 'medium', child: Text('Medium')),
                            DropdownMenuItem(value: 'high', child: Text('High')),
                            DropdownMenuItem(value: 'critical', child: Text('Critical')),
                          ],
                          onChanged: (value) => setState(() => _priority = value ?? _priority),
                          decoration: const InputDecoration(labelText: 'Priority'),
                        ),
                        _field(_assignedController, 'Assigned staff / mechanic'),
                        _dateTile(),
                      ]),
                      const SizedBox(height: AppTheme.space12),
                      _row(mobile, [
                        _field(
                          _estimatedCostController,
                          'Estimated cost',
                          keyboardType: TextInputType.number,
                        ),
                        _field(
                          _actualCostController,
                          'Actual cost',
                          keyboardType: TextInputType.number,
                        ),
                      ]),
                      const SizedBox(height: AppTheme.space12),
                      _field(_notesController, 'Notes / verification remarks', maxLines: 3),
                      const SizedBox(height: AppTheme.space16),
                      _buildActionButtons(),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons() {
    final existingNative = _editing && _canPersist;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (existingNative)
          Wrap(
            spacing: AppTheme.space8,
            runSpacing: AppTheme.space8,
            children: [
              _statusButton('Assign', 'assigned'),
              _statusButton('Start Work', 'in_progress'),
              _statusButton('Waiting Parts', 'waiting_parts'),
              _statusButton('Complete', 'completed'),
              _statusButton('Verify', 'verified'),
              OutlinedButton.icon(
                onPressed: _attaching ? null : _pickAttachment,
                icon: const Icon(Icons.attach_file_rounded, size: 18),
                label: Text(_attaching ? 'Attaching...' : 'Attach Receipt/Photo'),
              ),
              TextButton.icon(
                onPressed: _saving ? null : _voidOrder,
                icon: const Icon(Icons.block_rounded, size: 18),
                label: const Text('Void'),
              ),
            ],
          ),
        if (existingNative) const SizedBox(height: AppTheme.space16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _saving || _attaching ? null : () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: AppTheme.space12),
            Expanded(
              child: FilledButton.icon(
                onPressed: _saving || _sample ? null : _submit,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppTheme.white,
                        ),
                      )
                    : const Icon(Icons.save_rounded, size: 18),
                label: Text(_editing ? 'Save Work Order' : 'Create Work Order'),
              ),
            ),
          ],
        ),
        if (_sample) ...[
          const SizedBox(height: AppTheme.space10),
          Text(
            'Sample work orders are preview-only. Use live/demo backend data to test saving.',
            style: AppTheme.getCaptionStyle(context).copyWith(color: AppTheme.warningOrange),
          ),
        ],
      ],
    );
  }

  Widget _statusButton(String label, String status) {
    return OutlinedButton(
      onPressed: _saving ? null : () => _changeStatus(status),
      child: Text(label),
    );
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onSave(_payload());
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _changeStatus(String status) async {
    setState(() => _saving = true);
    try {
      await widget.onStatusChange(status);
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _voidOrder() async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Void work order?'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Required void reason',
            hintText: 'Explain why this work order should be voided',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Void Work Order'),
          ),
        ],
      ),
    );
    controller.dispose();
    if ((reason ?? '').isEmpty) return;
    setState(() => _saving = true);
    try {
      await widget.onStatusChange('voided', reason: reason);
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickAttachment() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'pdf'],
      withData: true,
    );
    final file = result?.files.single;
    if (file == null || file.bytes == null) return;
    final ext = (file.extension ?? '').toLowerCase();
    final mime = switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'pdf' => 'application/pdf',
      _ => 'application/octet-stream',
    };
    setState(() => _attaching = true);
    try {
      await widget.onAttach({
        'fileName': file.name,
        'fileType': mime,
        'dataUrl': 'data:$mime;base64,${base64Encode(file.bytes!)}',
        'kind': 'repair_proof',
      });
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _attaching = false);
    }
  }

  Map<String, dynamic> _payload() {
    return {
      'vehiclePlate': _vehicleController.text.trim(),
      'vehicleGeotabId': _geotabIdController.text.trim(),
      'title': _titleController.text.trim(),
      'description': _descriptionController.text.trim(),
      'priority': _priority,
      'sourceType': (_order['sourceType'] ?? 'manual').toString(),
      'sourceRecordId': _order['sourceRecordId']?.toString(),
      'sourceSummary': _order['sourceSummary']?.toString(),
      'assignedTo': _assignedController.text.trim(),
      'scheduledAt': _scheduledAt?.toIso8601String(),
      'estimatedCost': _numOrNull(_estimatedCostController.text),
      'actualCost': _numOrNull(_actualCostController.text),
      'notes': _notesController.text.trim(),
    };
  }

  Widget _row(bool mobile, List<Widget> children) {
    if (mobile) {
      return Column(
        children: children
            .map((child) => Padding(
                  padding: const EdgeInsets.only(bottom: AppTheme.space12),
                  child: child,
                ))
            .toList(),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: AppTheme.space12),
          Expanded(child: children[i]),
        ],
      ],
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool required = false,
    int maxLines = 1,
    TextInputType? keyboardType,
  }) {
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      validator: required
          ? (value) => FormValidation.requiredField(label.replaceAll('*', '').trim(), value)
          : null,
      decoration: InputDecoration(labelText: label),
    );
  }

  Widget _dateTile() {
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: _scheduledAt ?? DateTime.now(),
          firstDate: DateTime.now().subtract(const Duration(days: 3650)),
          lastDate: DateTime.now().add(const Duration(days: 3650)),
        );
        if (picked != null) {
          setState(() => _scheduledAt = picked);
        }
      },
      child: InputDecorator(
        decoration: const InputDecoration(labelText: 'Scheduled date'),
        child: Text(
          _scheduledAt == null
              ? 'Not scheduled'
              : '${_scheduledAt!.year}-${_scheduledAt!.month.toString().padLeft(2, '0')}-${_scheduledAt!.day.toString().padLeft(2, '0')}',
        ),
      ),
    );
  }

  static String _priorityKey(Object? value) {
    final normalized = value?.toString().toLowerCase().trim() ?? '';
    if (['low', 'medium', 'high', 'critical'].contains(normalized)) {
      return normalized;
    }
    return 'medium';
  }

  static String _numberText(Object? value) {
    if (value == null) return '';
    final text = value.toString();
    return text == 'N/A' ? '' : text;
  }

  static num? _numOrNull(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return num.tryParse(trimmed.replaceAll(',', ''));
  }

  static Color _statusColor(String value) {
    return switch (value.toLowerCase().replaceAll(' ', '_')) {
      'completed' || 'verified' => AppTheme.successGreen,
      'in_progress' || 'assigned' => AppTheme.primaryBlue,
      'waiting_parts' => AppTheme.warningOrange,
      'voided' => AppTheme.errorRed,
      _ => AppTheme.colorFF64748B,
    };
  }

  static Color _sourceColor(Object? value) {
    return switch (value?.toString().toLowerCase()) {
      'geotab_fault' => AppTheme.errorRed,
      'geotab_dvir' => AppTheme.warningOrange,
      'geotab_status' => AppTheme.primaryBlue,
      'service_threshold' => AppTheme.successGreen,
      _ => AppTheme.colorFF64748B,
    };
  }
}

class _EvidencePanel extends StatelessWidget {
  const _EvidencePanel({required this.summary});

  final String summary;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppTheme.space16),
      decoration: BoxDecoration(
        color: AppTheme.warningOrange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppTheme.warningOrange.withValues(alpha: 0.24)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.manage_search_rounded, color: AppTheme.warningOrange),
          const SizedBox(width: AppTheme.space10),
          Expanded(
            child: Text(
              summary,
              style: AppTheme.getBodyStyle(
                context,
                fontSize: AppTheme.dashboardBodySize,
              ),
            ),
          ),
        ],
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _editing
                      ? (_readOnlySource
                            ? 'Supplement GeoTab Maintenance'
                            : 'Edit Maintenance Log')
                      : 'Add Maintenance Log',
                  style: const TextStyle(
                    fontSize: AppTheme.dashboardSectionHeaderSize,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _readOnlySource
                      ? 'GeoTab-sourced fields are read-only; add local remarks or proof only.'
                      : 'Manual C3-04/C3-05 service record for compliance and prediction.',
                  style: const TextStyle(color: AppTheme.colorFF64748B),
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
                              final match = vehiclesNotifier.value.firstWhere(
                                (vehicle) =>
                                    vehicle['plate']?.toString() == value,
                                orElse: () => const <String, dynamic>{},
                              );
                              _geotabIdController.text =
                                  match['geotabId']?.toString() ?? '';
                            }
                          },
                    validator: (value) => FormValidation.requiredSelection(
                      'vehicle',
                      value ?? _vehicleController.text,
                    ),
                    decoration: const InputDecoration(labelText: 'Vehicle *'),
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
                          (type) =>
                              DropdownMenuItem(value: type, child: Text(type)),
                        )
                        .toList(),
                    onChanged: _readOnlySource
                        ? null
                        : (value) => setState(() => _type = value ?? _type),
                    validator: (value) => FormValidation.requiredSelection(
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
