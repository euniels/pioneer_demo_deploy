import 'package:flutter/material.dart';
import 'dart:async';

import '../config/pioneer_runtime_config.dart';
import '../models/telemetry_view_data.dart';
import '../widgets/dashboard_layout.dart';
import '../services/backend_api.dart';
import '../services/crud_permissions.dart';
import '../services/fleet_crud_policy.dart';
import '../services/fleet_sync_service.dart';
import '../services/page_cache_service.dart';
import '../services/demo_telemetry_fixtures.dart';
import '../services/vehicles_store.dart';
import '../utils/display_format.dart';
import '../utils/form_validation.dart';
import '../widgets/geotab_push_preview.dart';
import 'vehicle_details_modal.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';

class VehiclesPage extends StatefulWidget {
  const VehiclesPage({super.key});

  @override
  State<VehiclesPage> createState() => _VehiclesPageState();
}

class _VehiclesPageState extends State<VehiclesPage> {
  static const String _cacheKey = 'vehicles_page';

  String _searchQuery = '';
  bool _showGridView = true;
  String _statusFilter = 'All Status';
  String _typeFilter = 'All Types';
  String _fuelFilter = 'All Fuel';
  String _sortMode = 'Plate A-Z';

  @override
  void initState() {
    super.initState();
    vehiclesNotifier.addListener(_onVehiclesChanged);
    _primeVehicles();
  }

  void _onVehiclesChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _primeVehicles({bool forceRefresh = false}) async {
    await PageCacheService.getOrLoad<int>(
      key: _cacheKey,
      ttl: PageCacheService.vehiclesTtl,
      forceRefresh: forceRefresh,
      loader: () async {
        await refreshFleetBootstrap(forceRefresh: forceRefresh);
        await refreshFleetSnapshot(forceRefresh: forceRefresh);
        _prewarmVehicleDetails();
        return vehiclesNotifier.value.length;
      },
    ).catchError((_) {
      refreshFleetBootstrapSilently(forceRefresh: forceRefresh);
      return vehiclesNotifier.value.length;
    });
  }

  Future<void> _refreshVehicles() async {
    await _primeVehicles(forceRefresh: true);
    if (mounted) {
      setState(() {});
    }
  }

  void _prewarmVehicleDetails() {
    for (final vehicle in vehiclesNotifier.value.take(5)) {
      final geotabId = vehicle['geotabId']?.toString().trim() ?? '';
      if (geotabId.isEmpty) {
        continue;
      }

      unawaited(
        BackendApiService.getFleetTelemetryAsset(geotabId)
            .timeout(const Duration(seconds: 8))
            .catchError((_) => <String, dynamic>{}),
      );
    }
  }

  @override
  void dispose() {
    vehiclesNotifier.removeListener(_onVehiclesChanged);
    super.dispose();
  }

  List<Map<String, dynamic>> get _filteredVehicles {
    var list = vehiclesNotifier.value;
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list
          .where(
            (v) =>
                v['plate'].toString().toLowerCase().contains(q) ||
                v['truckType'].toString().toLowerCase().contains(q) ||
                (v['makeModel'] ?? '').toString().toLowerCase().contains(q) ||
                v['driver'].toString().toLowerCase().contains(q),
          )
          .toList();
    }
    if (_statusFilter != 'All Status') {
      list = list.where((v) {
        final vStatus = v['status'].toString().toLowerCase();
        final fStatus = _statusFilter.toLowerCase();
        // 'On Trip' filter matches 'on trip' stored value
        return vStatus == fStatus ||
            vStatus.replaceAll(' ', '') == fStatus.replaceAll(' ', '');
      }).toList();
    }
    if (_typeFilter != 'All Types') {
      list = list.where((v) {
        final type = (v['vehicleType'] ?? v['truckType'] ?? '')
            .toString()
            .toLowerCase();
        return type == _typeFilter.toLowerCase();
      }).toList();
    }
    if (_fuelFilter != 'All Fuel') {
      list = list.where((v) {
        final fuel = (v['fuelType'] ?? '').toString().toLowerCase();
        return fuel == _fuelFilter.toLowerCase();
      }).toList();
    }
    final sorted = List<Map<String, dynamic>>.from(list);
    sorted.sort((a, b) {
      return switch (_sortMode) {
        'Plate Z-A' => _compareText(b['plate'], a['plate']),
        'Status A-Z' => _compareText(a['status'], b['status']),
        'Status Z-A' => _compareText(b['status'], a['status']),
        'Type A-Z' => _compareText(
          a['vehicleType'] ?? a['truckType'],
          b['vehicleType'] ?? b['truckType'],
        ),
        'Type Z-A' => _compareText(
          b['vehicleType'] ?? b['truckType'],
          a['vehicleType'] ?? a['truckType'],
        ),
        _ => _compareText(a['plate'], b['plate']),
      };
    });
    return sorted;
  }

  int get _movingCount => vehiclesNotifier.value
      .where(
        (vehicle) =>
            ((vehicle['speed'] as num?)?.toInt() ?? 0) > 0 ||
            vehicle['isDriving'] == true,
      )
      .length;

  int get _reportingCount => vehiclesNotifier.value
      .where(
        (vehicle) =>
            ((vehicle['latitude'] as num?)?.toDouble() ?? 0.0) != 0.0 ||
            ((vehicle['longitude'] as num?)?.toDouble() ?? 0.0) != 0.0,
      )
      .length;

  int get _maintenanceCount => vehiclesNotifier.value
      .where(
        (vehicle) =>
            vehicle['status']?.toString().trim().toLowerCase() == 'maintenance',
      )
      .length;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DashboardLayout(
      currentRoute: '/vehicles',
      title: 'Vehicles',
      child: _buildPageContent(isDark),
    );
  }

  Widget _buildPageContent(bool isDark) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 850;

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
          child: _buildHeader(isDark, screenWidth),
        ),
        Expanded(
          child: Container(
            color: isDark ? AppTheme.colorFF0A0E1A : AppTheme.colorFFF5F6F8,
            child: RefreshIndicator(
              onRefresh: _refreshVehicles,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.all(isMobile ? 16 : 24),
                children: [
                  _buildFleetSummaryCards(isDark, isMobile),
                  SizedBox(height: isMobile ? 14 : 20),
                  if (_filteredVehicles.isEmpty)
                    SizedBox(height: 360, child: _buildEmptyState(isDark))
                  else
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final gap = isMobile ? 12.0 : 20.0;
                        final width = constraints.maxWidth;
                        final columns = !_showGridView
                            ? 1
                            : width >= 1040
                            ? 3
                            : width >= 680
                            ? 2
                            : 1;
                        final cardWidth =
                            (width - (gap * (columns - 1))) / columns;

                        return Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          children: List.generate(_filteredVehicles.length, (
                            index,
                          ) {
                            return SizedBox(
                              width: cardWidth,
                              child:
                                  _buildVehicleCard(
                                        _filteredVehicles[index],
                                        isDark,
                                      )
                                      .animate()
                                      .fadeIn(duration: 500.ms)
                                      .slideY(
                                        begin: 0.2,
                                        end: 0,
                                        duration: 500.ms,
                                        curve: Curves.easeOut,
                                      ),
                            );
                          }),
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬ HEADER Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬

  Widget _buildHeader(bool isDark, double screenWidth) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        final addButton = _addButton(label: compact ? 'Add' : 'Add Vehicle');
        final controls = Row(
          mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
          children: [
            _VehicleViewToggle(
              gridActive: _showGridView,
              onGrid: () => setState(() => _showGridView = true),
              onList: () => setState(() => _showGridView = false),
            ),
            const SizedBox(width: 12),
            if (compact) Expanded(child: addButton) else addButton,
          ],
        );
        final filterRow = Align(
          alignment: Alignment.centerLeft,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _VehicleResultCount(count: _filteredVehicles.length),
                const SizedBox(width: 10),
                _VehicleFilterChip(
                  label: 'Status',
                  value: _statusFilter,
                  activeWhen: 'All Status',
                  options: const [
                    'All Status',
                    'Available',
                    'On Trip',
                    'Maintenance',
                    'Inactive',
                  ],
                  onSelected: (value) => setState(() => _statusFilter = value),
                  onClear: () => setState(() => _statusFilter = 'All Status'),
                ),
                const SizedBox(width: 8),
                _VehicleFilterChip(
                  label: 'Type',
                  value: _typeFilter,
                  activeWhen: 'All Types',
                  options: const [
                    'All Types',
                    'Light Commercial Vehicle',
                    'Drop-side Truck',
                    'Refrigerated Truck',
                    'Tanker',
                    'Other',
                  ],
                  onSelected: (value) => setState(() => _typeFilter = value),
                  onClear: () => setState(() => _typeFilter = 'All Types'),
                ),
                const SizedBox(width: 8),
                _VehicleFilterChip(
                  label: 'Fuel',
                  value: _fuelFilter,
                  activeWhen: 'All Fuel',
                  options: const ['All Fuel', 'Diesel', 'Gasoline', 'Electric'],
                  onSelected: (value) => setState(() => _fuelFilter = value),
                  onClear: () => setState(() => _fuelFilter = 'All Fuel'),
                ),
                const SizedBox(width: 8),
                _VehicleFilterChip(
                  label: 'Sort',
                  value: _sortMode,
                  activeWhen: 'Plate A-Z',
                  options: const [
                    'Plate A-Z',
                    'Plate Z-A',
                    'Status A-Z',
                    'Status Z-A',
                    'Type A-Z',
                    'Type Z-A',
                  ],
                  onSelected: (value) => setState(() => _sortMode = value),
                  onClear: () => setState(() => _sortMode = 'Plate A-Z'),
                ),
              ],
            ),
          ),
        );

        if (compact) {
          return Column(
            children: [
              _searchField(isDark),
              const SizedBox(height: 12),
              controls,
              const SizedBox(height: 12),
              filterRow,
            ],
          );
        }

        return Column(
          children: [
            Row(
              children: [
                Expanded(child: _searchField(isDark)),
                const SizedBox(width: 14),
                controls,
              ],
            ),
            const SizedBox(height: 12),
            filterRow,
          ],
        );
      },
    );
  }

  Widget _searchField(bool isDark) {
    return TextField(
      onChanged: (v) => setState(() => _searchQuery = v),
      style: TextStyle(
        fontSize: 14,
        color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
      ),
      decoration: InputDecoration(
        hintText: 'Search by plate, type, driver, or model...',
        prefixIcon: const Icon(Icons.search_rounded),
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
    );
  }

  Widget _addButton({required String label}) {
    if (!CrudPermissions.canCreate(CrudEntity.vehicles)) {
      return const SizedBox.shrink();
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _showAddVehicleModal,
        child: Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          constraints: const BoxConstraints(minWidth: 172),
          decoration: BoxDecoration(
            color: AppTheme.successGreen,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: AppTheme.successGreen.withValues(alpha: 0.22),
                blurRadius: 16,
                spreadRadius: -10,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.add_rounded, color: AppTheme.white, size: 18),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  color: AppTheme.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    ); // MouseRegion
  }

  // Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬ ADD VEHICLE MODAL Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬

  Widget _buildFleetSummaryCards(bool isDark, bool isMobile) {
    final cards = [
      _VehicleSummaryData(
        title: 'Fleet',
        value: '${vehiclesNotifier.value.length}',
        subtitle: 'registered vehicles',
        icon: Icons.local_shipping_rounded,
        color: AppTheme.colorFF4B7BE5,
      ),
      _VehicleSummaryData(
        title: 'Reporting',
        value: '$_reportingCount',
        subtitle: 'live telemetry',
        icon: Icons.gps_fixed_rounded,
        color: AppTheme.colorFF14B8A6,
      ),
      _VehicleSummaryData(
        title: 'Moving',
        value: '$_movingCount',
        subtitle: 'currently active',
        icon: Icons.route_rounded,
        color: AppTheme.successGreen,
      ),
      _VehicleSummaryData(
        title: 'Maintenance',
        value: '$_maintenanceCount',
        subtitle: 'need attention',
        icon: Icons.build_circle_rounded,
        color: AppTheme.warningOrange,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = isMobile ? 12.0 : 16.0;
        final columns = constraints.maxWidth < 720 ? 2 : 4;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final card in cards)
              SizedBox(
                width: width,
                child: _VehicleSummaryCard(data: card, isDark: isDark),
              ),
          ],
        );
      },
    );
  }

  void _showAddVehicleModal() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _VehicleEditorDialog(
        existingPlates: vehiclesNotifier.value
            .map((vehicle) => vehicle['plate']?.toString() ?? '')
            .where((plate) => plate.trim().isNotEmpty)
            .toSet(),
        onSave: (payload) async {
          await createVehicleInBackend(payload);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Changes saved locally.')),
            );
          }
        },
      ),
    );
  }

  void _showEditVehicleModal(Map<String, dynamic> vehicle) {
    final policy = FleetCrudPolicy.vehicle(vehicle);
    if (!policy.canEdit) {
      _showVehicleActionMessage(policy.editDisabledReason);
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _VehicleEditorDialog(
        vehicle: vehicle,
        existingPlates: vehiclesNotifier.value
            .where((item) => item['plate'] != vehicle['plate'])
            .map((item) => item['plate']?.toString() ?? '')
            .where((plate) => plate.trim().isNotEmpty)
            .toSet(),
        onSave: (payload) async {
          final id =
              vehicle['localId']?.toString() ??
              vehicle['id']?.toString().replaceFirst('manual-vehicle-', '') ??
              '';
          if (id.isEmpty) {
            throw const BackendApiException(
              'Only managed PioneerPath vehicles can be edited.',
            );
          }
          await updateVehicleInBackend(id, payload);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Changes saved locally.')),
            );
          }
        },
      ),
    );
  }

  Future<void> _confirmDeactivateVehicle(Map<String, dynamic> vehicle) async {
    final policy = FleetCrudPolicy.vehicle(vehicle);
    if (!policy.canDeactivate) {
      _showVehicleActionMessage(policy.deactivateDisabledReason);
      return;
    }

    final id =
        vehicle['localId']?.toString() ??
        vehicle['id']?.toString().replaceFirst('manual-vehicle-', '') ??
        '';
    if (id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Only managed PioneerPath vehicles can be deactivated.',
          ),
        ),
      );
      return;
    }

    final reasonCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Deactivate vehicle?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${vehicle['plate']} will be removed from assignment dropdowns.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              decoration: const InputDecoration(
                labelText: 'Reason',
                hintText: 'Optional operations note',
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Deactivate'),
          ),
        ],
      ),
    );
    final reason = reasonCtrl.text.trim();
    reasonCtrl.dispose();

    if (confirmed != true) return;

    try {
      await deactivateVehicleInBackend(
        id,
        reason: reason.isEmpty ? 'Deactivated from Vehicles page.' : reason,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Changes saved locally.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _confirmDeleteVehicle(Map<String, dynamic> vehicle) async {
    final policy = FleetCrudPolicy.vehicle(vehicle);
    if (!policy.canDelete) {
      _showVehicleActionMessage(policy.deleteDisabledReason);
      return;
    }

    final plate = _displayValue(vehicle['plate']);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $plate?'),
        content: const Text(
          'This cannot be undone. Vehicles with trip history cannot be deleted; use Deactivate instead to preserve records.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.colorFFE74C3C,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await deleteVehicleInBackend(vehicle);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vehicle deleted successfully.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _pushVehicleToGeotab(Map<String, dynamic> vehicle) async {
    final policy = FleetCrudPolicy.vehicle(vehicle);
    if (!policy.canPushToGeotab) {
      _showVehicleActionMessage(policy.pushDisabledReason);
      return;
    }

    final preview = await pushVehicleToGeotab(vehicle, previewOnly: true);
    if (!mounted) return;
    if (!await guardGeotabPushPreview(context: context, preview: preview)) {
      return;
    }
    final confirmed = await showGeotabPushPreview(
      context: context,
      entityType: 'Vehicle',
      entityName: (vehicle['plate'] ?? vehicle['plateNumber'] ?? '').toString(),
      payload: preview['preview'],
      snapshot: preview['geotabSnapshot'],
      previewPayload: preview['previewPayload'],
    );
    if (confirmed != true) return;

    try {
      await pushVehicleToGeotab(vehicle);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('GeoTab push request staged for admin approval.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  void _showVehicleActionMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(behavior: SnackBarBehavior.floating, content: Text(message)),
    );
  }

  // Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬ VEHICLE CARD Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬

  Widget _buildVehicleCard(Map<String, dynamic> vehicle, bool isDark) {
    final statusColor = vehicle['statusColor'] is Color
        ? vehicle['statusColor'] as Color
        : _statusColorForVehicle(vehicle);

    String statusLabel;
    switch ((vehicle['status']?.toString() ?? '').toLowerCase()) {
      case 'available':
      case 'active':
        statusLabel = 'Available';
        break;
      case 'on trip':
      case 'ontrip':
        statusLabel = 'On Trip';
        break;
      case 'maintenance':
      case 'under maintenance':
        statusLabel = 'Maintenance';
        break;
      case 'inactive':
        statusLabel = 'Inactive';
        break;
      default:
        statusLabel = vehicle['status']?.toString() ?? 'Available';
    }
    final telemetryReadings = DemoTelemetryFixtures.readingsForVehicle(vehicle);
    final telemetryIssues = telemetryReadings.where(
      (reading) =>
          reading.hasReading &&
          reading.severity != TelemetrySeverity.normal,
    ).length;
    final telemetryReporting = telemetryReadings.any(
      (reading) => reading.hasReading,
    );
    final telemetryOffline = vehicle['isCommunicating'] == false ||
        vehicle['offline'] == true;
    final telemetryLabel = telemetryOffline
        ? 'Telemetry stale'
        : telemetryIssues > 0
        ? 'Telemetry needs review'
        : telemetryReporting
        ? 'Telemetry reporting'
        : 'Telemetry not reported';
    final telemetryColor = telemetryOffline
        ? AppTheme.neutralGray
        : telemetryIssues > 0
        ? AppTheme.warningOrange
        : telemetryReporting
        ? AppTheme.successGreen
        : AppTheme.infoBlue;

    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = (constraints.maxWidth / 350).clamp(0.84, 1.08);
        final p = 14.0 * scale;
        final locationLabel =
            vehicle['currentLocationLabel']?.toString().trim() ?? '';
        final importedOnly = _isGeotabOnlyVehicle(vehicle);
        final crudPolicy = FleetCrudPolicy.vehicle(vehicle);
        final samples = _sampleVehicleSpecifications(vehicle);
        final makeModelSample =
            PioneerRuntimeConfig.showMockData &&
            importedOnly &&
            !_hasDisplayValue(vehicle['makeModel']);
        final makeModel = _hasDisplayValue(vehicle['makeModel'])
            ? _displayValue(vehicle['makeModel'])
            : (makeModelSample ? samples['makeModel']! : '');
        final fuelCapacitySample =
            PioneerRuntimeConfig.showMockData &&
            importedOnly &&
            !_hasDisplayValue(vehicle['fuelCapacity']);
        final fuelCapacity = _hasDisplayValue(vehicle['fuelCapacity'])
            ? '${_displayValue(vehicle['fuelCapacity'])} L cap.'
            : (fuelCapacitySample ? '${samples['fuelCapacity']} L cap.' : '');
        final yearSample =
            PioneerRuntimeConfig.showMockData &&
            importedOnly &&
            !_hasDisplayValue(vehicle['year']);
        final year = _hasDisplayValue(vehicle['year'])
            ? _displayValue(vehicle['year'])
            : (yearSample ? samples['year']! : '');
        final cargoSample =
            PioneerRuntimeConfig.showMockData &&
            importedOnly &&
            !_hasDisplayValue(vehicle['cargoCapacityKg']);
        final cargoCapacity = _hasDisplayValue(vehicle['cargoCapacityKg'])
            ? '${_displayValue(vehicle['cargoCapacityKg'])} kg cargo'
            : (cargoSample ? '${samples['cargoCapacity']} kg cargo' : '');
        final infoItems = <Widget>[
          if (fuelCapacity.isNotEmpty)
            _infoItem(
              Icons.local_gas_station_rounded,
              fuelCapacity,
              isDark,
              scale,
              isSample: fuelCapacitySample,
            ),
          if (_hasDisplayValue(vehicle['mileage']))
            _infoItem(
              Icons.speed_rounded,
              _displayValue(vehicle['mileage']),
              isDark,
              scale,
            ),
          if (year.isNotEmpty)
            _infoItem(
              Icons.calendar_today_rounded,
              year,
              isDark,
              scale,
              isSample: yearSample,
            ),
          if (cargoCapacity.isNotEmpty)
            _infoItem(
              Icons.inventory_2_rounded,
              cargoCapacity,
              isDark,
              scale,
              isSample: cargoSample,
            ),
          _infoItem(
            Icons.route_rounded,
            '${vehicle['numTrips'] ?? 0} trips',
            isDark,
            scale,
          ),
        ];

        return _VehicleHoverLift(
          child: InkWell(
            onTap: () {
              showDialog(
                context: context,
                barrierDismissible: true,
                builder: (_) {
                  final screenWidth = MediaQuery.of(context).size.width;
                  final inset = screenWidth < 640 ? 16.0 : 48.0;
                  return Dialog(
                    backgroundColor: AppTheme.transparent,
                    insetPadding: EdgeInsets.symmetric(
                      horizontal: inset,
                      vertical: 24,
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: 1040,
                        maxHeight: MediaQuery.of(context).size.height * 0.92,
                      ),
                      child: VehicleDetailsModal(
                        vehicle: vehicle,
                        centeredDialog: true,
                      ),
                    ),
                  );
                },
              );
            },
            borderRadius: BorderRadius.circular(12),
            child: Container(
              decoration: BoxDecoration(
                color: isDark ? AppTheme.colorFF171B23 : AppTheme.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: statusColor.withAlpha(isDark ? 62 : 52),
                ),
                boxShadow: [
                  BoxShadow(
                    color: statusColor.withValues(alpha: isDark ? 0.13 : 0.08),
                    blurRadius: 20,
                    spreadRadius: -12,
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
              child: Padding(
                padding: EdgeInsets.all(p),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 44 * scale,
                          height: 44 * scale,
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.18),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: statusColor.withValues(alpha: 0.38),
                            ),
                          ),
                          child: Icon(
                            Icons.local_shipping_rounded,
                            color: statusColor,
                            size: 22 * scale,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _displayValue(vehicle['plate']),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 17 * scale,
                                  fontWeight: FontWeight.w800,
                                  color: isDark
                                      ? AppTheme.white
                                      : AppTheme.colorFF233244,
                                ),
                              ),
                              if (_hasDisplayValue(vehicle['truckType']) ||
                                  makeModel.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Wrap(
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 5,
                                  runSpacing: 3,
                                  children: [
                                    if (_hasDisplayValue(vehicle['truckType']))
                                      Text(
                                        _displayValue(vehicle['truckType']),
                                        style: TextStyle(
                                          fontSize: 12 * scale,
                                          color: isDark
                                              ? AppTheme.gray400
                                              : AppTheme.gray600,
                                        ),
                                      ),
                                    if (makeModel.isNotEmpty)
                                      Text(
                                        '${_hasDisplayValue(vehicle['truckType']) ? '- ' : ''}$makeModel',
                                        style: TextStyle(
                                          fontSize: 12 * scale,
                                          fontStyle: makeModelSample
                                              ? FontStyle.italic
                                              : FontStyle.normal,
                                          color: isDark
                                              ? AppTheme.gray400
                                              : AppTheme.gray600,
                                        ),
                                      ),
                                    if (makeModelSample) _sampleChip(scale),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                        _VehicleStatusBadge(
                          label: statusLabel,
                          color: statusColor,
                        ),
                        PopupMenuButton<String>(
                          tooltip: 'Vehicle actions',
                          color: isDark
                              ? AppTheme.colorFF1A1D23
                              : AppTheme.white,
                          icon: Icon(
                            Icons.more_vert_rounded,
                            color: isDark ? AppTheme.gray300 : AppTheme.gray600,
                          ),
                          onSelected: (action) {
                            if (action == 'edit') {
                              _showEditVehicleModal(vehicle);
                            } else if (action == 'deactivate') {
                              unawaited(_confirmDeactivateVehicle(vehicle));
                            } else if (action == 'delete') {
                              unawaited(_confirmDeleteVehicle(vehicle));
                            } else if (action == 'push_geotab') {
                              unawaited(_pushVehicleToGeotab(vehicle));
                            }
                          },
                          itemBuilder: (context) => [
                            if (CrudPermissions.canEdit(CrudEntity.vehicles))
                              PopupMenuItem(
                                value: 'edit',
                                enabled: crudPolicy.canEdit,
                                child: Text(
                                  crudPolicy.canEdit
                                      ? 'Edit vehicle'
                                      : 'Edit vehicle - GeoTab read-only',
                                ),
                              ),
                            PopupMenuItem(
                              value: 'push_geotab',
                              enabled: crudPolicy.canPushToGeotab,
                              child: Text(
                                crudPolicy.canPushToGeotab
                                    ? 'Push to GeoTab'
                                    : 'Push to GeoTab - no local changes',
                              ),
                            ),
                            if (CrudPermissions.canDelete(CrudEntity.vehicles))
                              PopupMenuItem(
                                value: 'deactivate',
                                enabled: crudPolicy.canDeactivate,
                                child: Text(
                                  crudPolicy.canDeactivate
                                      ? 'Deactivate'
                                      : 'Deactivate - unavailable',
                                ),
                              ),
                            if (CrudPermissions.canDelete(
                                  CrudEntity.vehicles,
                                ) &&
                                crudPolicy.isManagedLocally)
                              PopupMenuItem(
                                value: 'delete',
                                enabled: crudPolicy.canDelete,
                                child: const Text('Delete'),
                              ),
                          ],
                        ),
                      ],
                    ),
                    SizedBox(height: 10 * scale),
                    _vehicleInfoWrap(infoItems, scale),
                    SizedBox(height: 10 * scale),
                    Container(
                      width: double.infinity,
                      padding: EdgeInsets.all(12 * scale),
                      decoration: BoxDecoration(
                        color: isDark
                            ? AppTheme.colorFF11161F
                            : AppTheme.colorFFF7F9FC,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          Text(
                            'Driver:',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? AppTheme.gray500
                                  : AppTheme.gray600,
                            ),
                          ),
                          SizedBox(width: 6 * scale),
                          Expanded(
                            child: Text(
                              _displayValue(vehicle['driver']),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5 * scale,
                                fontWeight: FontWeight.w700,
                                color: isDark
                                    ? AppTheme.white
                                    : AppTheme.colorFF233244,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 10 * scale),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _vehicleMetaChip(
                          label: _currencyLabel(vehicle['totalRevenue']),
                          color: AppTheme.colorFFD4AF37,
                          isDark: isDark,
                        ),
                        _vehicleMetaChip(
                          label: _registrationLabel(vehicle),
                          color: _registrationColorForVehicle(vehicle),
                          isDark: isDark,
                        ),
                        _vehicleMetaChip(
                          label: _healthLabel(vehicle),
                          color: _healthColorForVehicle(vehicle),
                          isDark: isDark,
                        ),
                        _vehicleMetaChip(
                          label: telemetryLabel,
                          color: telemetryColor,
                          isDark: isDark,
                        ),
                        _fleetCrudScopeChip(crudPolicy, isDark, scale),
                        if (_routeSummary(vehicle).isNotEmpty)
                          _vehicleMetaChip(
                            label: _routeSummary(vehicle),
                            color: AppTheme.colorFF4B7BE5,
                            isDark: isDark,
                          ),
                      ],
                    ),
                    if (locationLabel.isNotEmpty) ...[
                      SizedBox(height: 10 * scale),
                      Container(
                        width: double.infinity,
                        padding: EdgeInsets.symmetric(
                          horizontal: 12 * scale,
                          vertical: 8 * scale,
                        ),
                        decoration: BoxDecoration(
                          color: isDark
                              ? AppTheme.colorFF131A24
                              : AppTheme.colorFFF7F9FC,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isDark
                                ? AppTheme.white.withValues(alpha: 0.05)
                                : AppTheme.black.withValues(alpha: 0.05),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.place_rounded,
                              size: 14 * scale,
                              color: AppTheme.colorFF4B7BE5,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                locationLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isDark
                                      ? AppTheme.gray300
                                      : AppTheme.colorFF425466,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _vehicleInfoWrap(List<Widget> items, double scale) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = 8 * scale;
        final itemWidth = constraints.maxWidth < 260
            ? constraints.maxWidth
            : (constraints.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: items
              .map((item) => SizedBox(width: itemWidth, child: item))
              .toList(),
        );
      },
    );
  }

  Widget _fleetCrudScopeChip(
    FleetCrudPolicy policy,
    bool isDark,
    double scale,
  ) {
    return Tooltip(
      message: policy.scopeDetail,
      child: Container(
        constraints: BoxConstraints(maxWidth: 190 * scale),
        padding: EdgeInsets.symmetric(
          horizontal: 10 * scale,
          vertical: 6 * scale,
        ),
        decoration: BoxDecoration(
          color: policy.scopeColor.withValues(alpha: isDark ? 0.18 : 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: policy.scopeColor.withValues(alpha: isDark ? 0.34 : 0.24),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(policy.scopeIcon, size: 13 * scale, color: policy.scopeColor),
            SizedBox(width: 5 * scale),
            Flexible(
              child: Text(
                policy.scopeLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11 * scale,
                  fontWeight: FontWeight.w800,
                  color: policy.scopeColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoItem(
    IconData icon,
    String label,
    bool isDark,
    double scale, {
    bool isSample = false,
  }) {
    final displayLabel = _displayValue(label).replaceAll('₱', 'PHP ');
    return Row(
      children: [
        Icon(
          icon,
          size: 14 * scale,
          color: isDark ? AppTheme.gray500 : AppTheme.gray600,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            displayLabel,
            style: TextStyle(
              fontSize: 13 * scale,
              fontStyle: isSample ? FontStyle.italic : FontStyle.normal,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (isSample) ...[const SizedBox(width: 4), _sampleChip(scale)],
      ],
    );
  }

  Widget _sampleChip(double scale) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 5 * scale, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.colorFFF39C12.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: AppTheme.colorFFF39C12.withValues(alpha: 0.42),
        ),
      ),
      child: Text(
        'Sample',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AppTheme.colorFFF39C12,
        ),
      ),
    );
  }

  Widget _vehicleMetaChip({
    required String label,
    required Color color,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.18 : 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  Color _healthColorForVehicle(Map<String, dynamic> vehicle) {
    switch ((vehicle['healthStatus']?.toString().trim().toLowerCase() ?? '')) {
      case 'offline':
        return AppTheme.colorFFE74C3C;
      case 'critical':
        return AppTheme.colorFFE67E22;
      case 'warning':
        return AppTheme.colorFFF39C12;
      default:
        return AppTheme.colorFF27AE60;
    }
  }

  Color _statusColorForVehicle(Map<String, dynamic> vehicle) {
    switch ((vehicle['status']?.toString().trim().toLowerCase() ?? '')) {
      case 'on trip':
      case 'ontrip':
      case 'in transit':
        return AppTheme.colorFF4B7BE5;
      case 'maintenance':
      case 'under maintenance':
        return AppTheme.colorFFF39C12;
      case 'inactive':
      case 'deactivated':
        return AppTheme.gray500;
      default:
        return AppTheme.colorFF27AE60;
    }
  }

  String _registrationLabel(Map<String, dynamic> vehicle) {
    final days = int.tryParse(
      vehicle['registrationDaysRemaining']?.toString() ?? '',
    );
    if (days == null) {
      return 'Reg N/A';
    }
    if (days < 0) {
      return 'Reg expired';
    }
    return 'Reg ${days}d';
  }

  Color _registrationColorForVehicle(Map<String, dynamic> vehicle) {
    final days = int.tryParse(
      vehicle['registrationDaysRemaining']?.toString() ?? '',
    );
    if (days != null && days <= 30) {
      return AppTheme.colorFFE74C3C;
    }
    return AppTheme.colorFF14B8A6;
  }

  String _healthLabel(Map<String, dynamic> vehicle) {
    final status =
        vehicle['healthStatus']?.toString().trim().toLowerCase() ?? 'healthy';
    final score = vehicle['healthScore']?.toString().trim() ?? '100';
    final title = status.isEmpty
        ? 'Healthy'
        : status[0].toUpperCase() + status.substring(1);
    return '$title $score';
  }

  String _routeSummary(Map<String, dynamic> vehicle) {
    final currentZone = vehicle['currentZone']?.toString().trim() ?? '';
    final destinationZone = vehicle['destinationZone']?.toString().trim() ?? '';
    final assignedRoute = vehicle['assignedRoute']?.toString().trim() ?? '';

    if (currentZone.isNotEmpty && destinationZone.isNotEmpty) {
      return '$currentZone -> $destinationZone';
    }

    if (assignedRoute.isNotEmpty) {
      return assignedRoute;
    }

    return '';
  }

  String _currencyLabel(dynamic value) {
    final amount = int.tryParse(value?.toString() ?? '') ?? 0;
    final formatted = amount.toString().replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
      (match) => '${match[1]},',
    );
    return 'PHP $formatted';
  }

  String _displayValue(dynamic value) {
    return formatValue(value);
  }

  bool _hasDisplayValue(dynamic value) {
    final text = _displayValue(value).trim();
    if (text.isEmpty) {
      return false;
    }
    final normalized = text.toLowerCase();
    return normalized != 'n/a' &&
        normalized != 'na' &&
        normalized != 'null' &&
        normalized != 'unavailable' &&
        normalized != '--';
  }

  bool _isGeotabOnlyVehicle(Map<String, dynamic> vehicle) {
    return vehicle['managedLocally'] != true &&
        (vehicle['geotabId']?.toString().trim().isNotEmpty ?? false);
  }

  Map<String, String> _sampleVehicleSpecifications(
    Map<String, dynamic> vehicle,
  ) {
    final plate = (vehicle['plate'] ?? vehicle['geotabId'] ?? '').toString();
    final seed = plate.codeUnits.fold<int>(0, (sum, value) => sum + value);
    const specs = [
      {
        'makeModel': 'Isuzu N-Series NPR',
        'year': '2022',
        'fuelCapacity': '75',
        'cargoCapacity': '3000',
      },
      {
        'makeModel': 'Fuso Canter FE',
        'year': '2021',
        'fuelCapacity': '70',
        'cargoCapacity': '2500',
      },
      {
        'makeModel': 'Isuzu Forward FTR',
        'year': '2020',
        'fuelCapacity': '100',
        'cargoCapacity': '5000',
      },
      {
        'makeModel': 'Fuso Fighter FK',
        'year': '2023',
        'fuelCapacity': '90',
        'cargoCapacity': '4000',
      },
    ];
    return specs[seed % specs.length];
  }

  int _compareText(dynamic a, dynamic b) {
    return _displayValue(
      a,
    ).toLowerCase().compareTo(_displayValue(b).toLowerCase());
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.local_shipping_rounded,
            size: 80,
            color: isDark ? AppTheme.gray700 : AppTheme.gray300,
          ),
          const SizedBox(height: 24),
          Text(
            'No vehicles found',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.gray600 : AppTheme.gray400,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Try adjusting your search or filter',
            style: TextStyle(
              fontSize: 14,
              color: isDark ? AppTheme.gray500 : AppTheme.gray500,
            ),
          ),
        ],
      ),
    );
  }
}

// Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
// ADD VEHICLE DIALOG
// Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬

class _AddVehicleDialog extends StatefulWidget {
  final void Function(Map<String, dynamic>) onAdd;
  const _AddVehicleDialog({required this.onAdd});

  @override
  State<_AddVehicleDialog> createState() => _AddVehicleDialogState();
}

class _AddVehicleDialogState extends State<_AddVehicleDialog> {
  final _formKey = GlobalKey<FormState>();
  final _plateCtrl = TextEditingController();
  final _fuelCtrl = TextEditingController();
  final _yearCtrl = TextEditingController();

  String _truckType = '6 Wheeler';
  bool _saving = false;

  static const _truckTypes = [
    '4 Wheeler',
    '6 Wheeler',
    '8 Wheeler',
    '10 Wheeler',
    '12 Wheeler',
  ];

  @override
  void dispose() {
    _plateCtrl.dispose();
    _fuelCtrl.dispose();
    _yearCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final newVehicle = {
      'plate': _plateCtrl.text.trim().toUpperCase(),
      'truckType': _truckType,
      'fuelCapacity': _fuelCtrl.text.trim(),
      'year': _yearCtrl.text.trim(),
      'status': 'available',
      'statusColor': AppTheme.colorFF27AE60,
      'mileage': '0 km',
      'numTrips': 0,
      'totalRevenue': 0,
      'driver': 'Unassigned',
    };

    widget.onAdd(newVehicle);
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
              maxWidth: isVerySmall ? sw - 16 : 480,
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
                  // Ã¢â€â‚¬Ã¢â€â‚¬ Dialog header Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
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
                            Icons.local_shipping_rounded,
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
                                'Add New Vehicle',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.white,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Fill in the vehicle details below',
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

                  // Ã¢â€â‚¬Ã¢â€â‚¬ Form Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬Ã¢â€â‚¬
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        children: [
                          // Plate number
                          _formField(
                            controller: _plateCtrl,
                            label: 'Plate Number',
                            hint: 'e.g. ABC 1234',
                            icon: Icons.pin_rounded,
                            isDark: isDark,
                            validator: (v) {
                              if (v == null || v.trim().isEmpty)
                                return 'Plate number is required';
                              final existing = vehiclesNotifier.value.any(
                                (veh) =>
                                    veh['plate'].toString().toLowerCase() ==
                                    v.trim().toLowerCase(),
                              );
                              if (existing)
                                return 'A vehicle with this plate already exists';
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),

                          // Truck type dropdown
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Truck Type',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: isDark
                                      ? AppTheme.gray300
                                      : AppTheme.colorFF2C3E50,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                height: 52,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? AppTheme.colorFF0F1117
                                      : AppTheme.colorFFF5F6F8,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isDark
                                        ? AppTheme.white.withValues(alpha: 0.1)
                                        : AppTheme.black.withValues(alpha: 0.1),
                                  ),
                                ),
                                child: DropdownButton<String>(
                                  value: _truckType,
                                  underline: const SizedBox(),
                                  isExpanded: true,
                                  icon: Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                    color: isDark
                                        ? AppTheme.gray400
                                        : AppTheme.gray600,
                                  ),
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: isDark
                                        ? AppTheme.white
                                        : AppTheme.colorFF2C3E50,
                                  ),
                                  dropdownColor: isDark
                                      ? AppTheme.colorFF1A1D23
                                      : AppTheme.white,
                                  items: _truckTypes
                                      .map(
                                        (t) => DropdownMenuItem(
                                          value: t,
                                          child: Text(t),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (v) =>
                                      setState(() => _truckType = v!),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),

                          // Fuel capacity
                          _formField(
                            controller: _fuelCtrl,
                            label: 'Fuel Capacity (Liters)',
                            hint: 'e.g. 300',
                            icon: Icons.local_gas_station_rounded,
                            isDark: isDark,
                            keyboardType: TextInputType.number,
                            validator: (v) {
                              if (v == null || v.trim().isEmpty)
                                return 'Fuel capacity is required';
                              if (int.tryParse(v.trim()) == null)
                                return 'Enter a valid number';
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),

                          // Year
                          _formField(
                            controller: _yearCtrl,
                            label: 'Year',
                            hint: 'e.g. 2023',
                            icon: Icons.calendar_today_rounded,
                            isDark: isDark,
                            keyboardType: TextInputType.number,
                            validator: (v) {
                              if (v == null || v.trim().isEmpty)
                                return 'Year is required';
                              final yr = int.tryParse(v.trim());
                              if (yr == null || yr < 1990 || yr > 2030)
                                return 'Enter a valid year (1990-2030)';
                              return null;
                            },
                          ),
                          const SizedBox(height: 28),

                          // Action buttons
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
                                          color: const Color(
                                            0xFF4B7BE5,
                                          ).withValues(alpha: 0.4),
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
                                              child: CircularProgressIndicator(
                                                color: AppTheme.white,
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Text(
                                              'Add Vehicle',
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
          ),
        ),
      ],
    );
  }
}

class _VehicleResultCount extends StatelessWidget {
  const _VehicleResultCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppTheme.infoBlue.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.infoBlue.withValues(alpha: 0.22)),
      ),
      child: Text(
        '$count vehicles shown',
        style: const TextStyle(
          color: AppTheme.infoBlue,
          fontWeight: FontWeight.w900,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _VehicleSummaryData {
  const _VehicleSummaryData({
    required this.title,
    required this.value,
    required this.subtitle,
    required this.icon,
    required this.color,
  });

  final String title;
  final String value;
  final String subtitle;
  final IconData icon;
  final Color color;
}

class _VehicleSummaryCard extends StatelessWidget {
  const _VehicleSummaryCard({required this.data, required this.isDark});

  final _VehicleSummaryData data;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 112),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF171B23 : AppTheme.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: data.color.withValues(alpha: isDark ? 0.34 : 0.2),
        ),
        boxShadow: [
          BoxShadow(
            color: data.color.withValues(alpha: isDark ? 0.14 : 0.08),
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
              color: data.color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(data.icon, color: data.color, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data.title,
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
                  data.value,
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
                  data.subtitle,
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

class _VehicleViewToggle extends StatelessWidget {
  const _VehicleViewToggle({
    required this.gridActive,
    required this.onGrid,
    required this.onList,
  });

  final bool gridActive;
  final VoidCallback onGrid;
  final VoidCallback onList;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 50,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppTheme.colorFF1A1D23,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.white.withAlpha(18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _VehicleViewToggleButton(
            icon: Icons.grid_view_rounded,
            active: gridActive,
            tooltip: 'Grid view',
            onTap: onGrid,
          ),
          _VehicleViewToggleButton(
            icon: Icons.view_list_rounded,
            active: !gridActive,
            tooltip: 'List view',
            onTap: onList,
          ),
        ],
      ),
    );
  }
}

class _VehicleViewToggleButton extends StatelessWidget {
  const _VehicleViewToggleButton({
    required this.icon,
    required this.active,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active
                ? AppTheme.successGreen.withValues(alpha: 0.22)
                : AppTheme.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(
            icon,
            color: active ? AppTheme.successGreen : AppTheme.gray400,
            size: 20,
          ),
        ),
      ),
    );
  }
}

class _VehicleFilterChip extends StatelessWidget {
  const _VehicleFilterChip({
    required this.label,
    required this.value,
    required this.activeWhen,
    required this.options,
    required this.onSelected,
    required this.onClear,
  });

  final String label;
  final String value;
  final String activeWhen;
  final List<String> options;
  final ValueChanged<String> onSelected;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final active = value != activeWhen;
    return PopupMenuButton<String>(
      initialValue: value,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final option in options)
          PopupMenuItem(value: option, child: Text(option)),
      ],
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: active
              ? AppTheme.successGreen.withValues(alpha: 0.13)
              : AppTheme.white.withAlpha(8),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active
                ? AppTheme.successGreen.withValues(alpha: 0.34)
                : AppTheme.white.withAlpha(18),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              active ? '$label: $value' : label,
              style: TextStyle(
                color: active ? AppTheme.successGreen : AppTheme.gray300,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 16,
              color: active ? AppTheme.successGreen : AppTheme.gray400,
            ),
            if (active) ...[
              const SizedBox(width: 4),
              InkWell(
                onTap: onClear,
                borderRadius: BorderRadius.circular(999),
                child: const Icon(Icons.close_rounded, size: 15),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _VehicleStatusBadge extends StatelessWidget {
  const _VehicleStatusBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 118),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        label.toUpperCase(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w900,
          color: color,
        ),
      ),
    );
  }
}

class _VehicleHoverLift extends StatefulWidget {
  const _VehicleHoverLift({required this.child});

  final Widget child;

  @override
  State<_VehicleHoverLift> createState() => _VehicleHoverLiftState();
}

class _VehicleHoverLiftState extends State<_VehicleHoverLift> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedScale(
        scale: _hovering ? 1.005 : 1,
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          curve: Curves.easeOut,
          transform: Matrix4.translationValues(0, _hovering ? -2 : 0, 0),
          child: widget.child,
        ),
      ),
    );
  }
}

class _VehicleEditorDialog extends StatefulWidget {
  const _VehicleEditorDialog({
    required this.existingPlates,
    required this.onSave,
    this.vehicle,
  });

  final Map<String, dynamic>? vehicle;
  final Set<String> existingPlates;
  final Future<void> Function(Map<String, dynamic> payload) onSave;

  @override
  State<_VehicleEditorDialog> createState() => _VehicleEditorDialogState();
}

class _VehicleEditorDialogState extends State<_VehicleEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _plateCtrl;
  late final TextEditingController _makeModelCtrl;
  late final TextEditingController _yearCtrl;
  late final TextEditingController _chassisCtrl;
  late final TextEditingController _vinCtrl;
  late final TextEditingController _fuelCapacityCtrl;
  late final TextEditingController _cargoCapacityCtrl;
  late final TextEditingController _geotabDeviceCtrl;
  late final TextEditingController _registrationExpiryCtrl;
  late final TextEditingController _insuranceExpiryCtrl;

  String _vehicleType = 'Light Commercial Vehicle';
  String _fuelType = 'Diesel';
  String _status = 'Active';
  bool _saving = false;

  static const _vehicleTypes = [
    'Light Commercial Vehicle',
    'Drop-side Truck',
    'Refrigerated Truck',
    'Tanker',
    'Other',
  ];

  @override
  void initState() {
    super.initState();
    final vehicle = widget.vehicle ?? const {};
    _plateCtrl = TextEditingController(
      text: (vehicle['plate'] ?? vehicle['plateNumber'] ?? '').toString(),
    );
    _makeModelCtrl = TextEditingController(
      text: _optionalText(vehicle['makeModel']),
    );
    _yearCtrl = TextEditingController(text: _optionalText(vehicle['year']));
    _chassisCtrl = TextEditingController(
      text: _optionalText(vehicle['chassisNumber']),
    );
    _vinCtrl = TextEditingController(text: _optionalText(vehicle['vin']));
    _fuelCapacityCtrl = TextEditingController(
      text: _optionalText(
        vehicle['fuelCapacityLiters'] ?? vehicle['fuelCapacity'],
      ),
    );
    _cargoCapacityCtrl = TextEditingController(
      text: _optionalText(vehicle['cargoCapacityKg']),
    );
    _geotabDeviceCtrl = TextEditingController(
      text: _optionalText(vehicle['geotabDeviceId'] ?? vehicle['geotabId']),
    );
    _registrationExpiryCtrl = TextEditingController(
      text: _optionalText(vehicle['registrationExpiryDate']),
    );
    _insuranceExpiryCtrl = TextEditingController(
      text: _optionalText(vehicle['insuranceExpiryDate']),
    );
    _vehicleType = _firstAllowed(
      _optionalText(vehicle['vehicleType'] ?? vehicle['truckType']),
      _vehicleTypes,
      'Light Commercial Vehicle',
    );
    _fuelType = _firstAllowed(_optionalText(vehicle['fuelType']), const [
      'Diesel',
      'Gasoline',
      'Electric',
    ], 'Diesel');
    _status = switch ((vehicle['status']?.toString().toLowerCase() ?? '')) {
      'maintenance' || 'under maintenance' => 'Under Maintenance',
      'inactive' => 'Inactive',
      _ => 'Active',
    };
  }

  @override
  void dispose() {
    _plateCtrl.dispose();
    _makeModelCtrl.dispose();
    _yearCtrl.dispose();
    _chassisCtrl.dispose();
    _vinCtrl.dispose();
    _fuelCapacityCtrl.dispose();
    _cargoCapacityCtrl.dispose();
    _geotabDeviceCtrl.dispose();
    _registrationExpiryCtrl.dispose();
    _insuranceExpiryCtrl.dispose();
    super.dispose();
  }

  static String _optionalText(dynamic value) {
    final text = value?.toString().trim() ?? '';
    return text == 'N/A' || text == 'null' ? '' : text;
  }

  static String _firstAllowed(
    String value,
    List<String> options,
    String fallback,
  ) {
    for (final option in options) {
      if (option.toLowerCase() == value.toLowerCase()) return option;
    }
    return fallback;
  }

  Future<void> _pickDate(TextEditingController controller) async {
    final now = DateTime.now();
    final initial = DateTime.tryParse(controller.text) ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(now) ? now : initial,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 15),
    );
    if (picked != null) {
      controller.text = picked.toIso8601String().substring(0, 10);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await widget.onSave({
        'plateNumber': _plateCtrl.text.trim().toUpperCase(),
        'vehicleType': _vehicleType,
        'makeModel': _emptyToNull(_makeModelCtrl.text),
        'year': int.tryParse(_yearCtrl.text.trim()),
        'chassisNumber': _emptyToNull(_chassisCtrl.text),
        'vin': _emptyToNull(_vinCtrl.text),
        'fuelType': _fuelType,
        'fuelCapacityLiters': double.tryParse(_fuelCapacityCtrl.text.trim()),
        'cargoCapacityKg': double.tryParse(_cargoCapacityCtrl.text.trim()),
        'geotabDeviceId': _emptyToNull(_geotabDeviceCtrl.text),
        'registrationExpiryDate': _registrationExpiryCtrl.text.trim(),
        'insuranceExpiryDate': _emptyToNull(_insuranceExpiryCtrl.text),
        'status': _status,
      });
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Object? _emptyToNull(String value) {
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final width = MediaQuery.of(context).size.width;
    final isEditing = widget.vehicle != null;

    return Dialog(
      backgroundColor: AppTheme.transparent,
      insetPadding: EdgeInsets.symmetric(
        horizontal: width < 640 ? 16 : 48,
        vertical: 24,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 820),
        child: Container(
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
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppTheme.colorFF1B2A4A, AppTheme.colorFF4B7BE5],
                  ),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.local_shipping_rounded,
                      color: AppTheme.white,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        isEditing ? 'Edit Vehicle' : 'Add Vehicle',
                        style: const TextStyle(
                          color: AppTheme.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
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
              Expanded(
                child: Form(
                  key: _formKey,
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      _sectionLabel('Identity', isDark),
                      _responsiveRow(width, [
                        _field(
                          _plateCtrl,
                          'Plate number',
                          isDark,
                          required: true,
                          validator: (value) {
                            final plate = value?.trim().toUpperCase() ?? '';
                            if (plate.isEmpty)
                              return 'Plate number is required';
                            final exists = widget.existingPlates.any(
                              (item) => item.trim().toUpperCase() == plate,
                            );
                            if (exists) return 'Plate number must be unique';
                            return null;
                          },
                        ),
                        _dropdown(
                          'Vehicle type',
                          _vehicleType,
                          _vehicleTypes,
                          isDark,
                          (value) => setState(() => _vehicleType = value),
                        ),
                      ]),
                      _responsiveRow(width, [
                        _field(_makeModelCtrl, 'Make and model', isDark),
                        _field(
                          _yearCtrl,
                          'Year',
                          isDark,
                          keyboardType: TextInputType.number,
                        ),
                      ]),
                      _responsiveRow(width, [
                        _field(_chassisCtrl, 'Chassis number', isDark),
                        _field(_vinCtrl, 'VIN', isDark),
                      ]),
                      const SizedBox(height: 14),
                      _sectionLabel('Capacity And Fuel', isDark),
                      _responsiveRow(width, [
                        _dropdown(
                          'Fuel type',
                          _fuelType,
                          const ['Diesel', 'Gasoline', 'Electric'],
                          isDark,
                          (value) => setState(() => _fuelType = value),
                        ),
                        _field(
                          _fuelCapacityCtrl,
                          'Fuel capacity in liters',
                          isDark,
                          keyboardType: TextInputType.number,
                        ),
                      ]),
                      _field(
                        _cargoCapacityCtrl,
                        'Cargo capacity in kg',
                        isDark,
                        required: true,
                        keyboardType: TextInputType.number,
                      ),
                      const SizedBox(height: 14),
                      _sectionLabel('Compliance And GeoTab', isDark),
                      _field(_geotabDeviceCtrl, 'GeoTab Device ID', isDark),
                      _responsiveRow(width, [
                        _dateField(
                          _registrationExpiryCtrl,
                          'Registration expiry date',
                          isDark,
                          required: true,
                        ),
                        _dateField(
                          _insuranceExpiryCtrl,
                          'Insurance expiry date',
                          isDark,
                        ),
                      ]),
                      _dropdown(
                        'Status',
                        _status,
                        const ['Active', 'Under Maintenance', 'Inactive'],
                        isDark,
                        (value) => setState(() => _status = value),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Row(
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
                      child: FilledButton.icon(
                        onPressed: _saving ? null : _submit,
                        icon: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppTheme.white,
                                ),
                              )
                            : const Icon(Icons.save_rounded),
                        label: Text(isEditing ? 'Save Changes' : 'Add Vehicle'),
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

  Widget _responsiveRow(double width, List<Widget> children) {
    if (width < 720) {
      return Column(children: children);
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

  Widget _sectionLabel(String label, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        label,
        style: TextStyle(
          color: isDark ? AppTheme.gray300 : AppTheme.colorFF233244,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    bool isDark, {
    bool required = false,
    TextInputType keyboardType = TextInputType.text,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        validator:
            validator ??
            (value) {
              if (required && (value?.trim().isEmpty ?? true)) {
                return '$label is required';
              }
              if (keyboardType == TextInputType.number &&
                  (value?.trim().isNotEmpty ?? false) &&
                  double.tryParse(value!.trim()) == null) {
                return 'Enter a valid number';
              }
              if (keyboardType == TextInputType.number &&
                  (value?.trim().isNotEmpty ?? false) &&
                  (double.tryParse(value!.trim()) ?? 0) < 0) {
                return '$label cannot be negative';
              }
              return null;
            },
        decoration: InputDecoration(labelText: label),
        style: TextStyle(
          color: isDark ? AppTheme.white : AppTheme.colorFF233244,
        ),
      ),
    );
  }

  Widget _dateField(
    TextEditingController controller,
    String label,
    bool isDark, {
    bool required = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        readOnly: true,
        onTap: () => _pickDate(controller),
        validator: (value) {
          if (required && (value?.trim().isEmpty ?? true)) {
            return '$label is required';
          }
          return FormValidation.futureOrTodayDateText(
            label,
            value,
            required: required,
          );
        },
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: const Icon(Icons.calendar_today_rounded),
        ),
        style: TextStyle(
          color: isDark ? AppTheme.white : AppTheme.colorFF233244,
        ),
      ),
    );
  }

  Widget _dropdown(
    String label,
    String value,
    List<String> values,
    bool isDark,
    ValueChanged<String> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        initialValue: values.contains(value) ? value : null,
        hint: const Text('Select...'),
        decoration: InputDecoration(labelText: label),
        dropdownColor: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        style: TextStyle(
          color: isDark ? AppTheme.white : AppTheme.colorFF233244,
        ),
        items: values
            .map((item) => DropdownMenuItem(value: item, child: Text(item)))
            .toList(),
        onChanged: (next) {
          if (next != null) onChanged(next);
        },
        validator: (value) =>
            FormValidation.requiredSelection(label.toLowerCase(), value),
      ),
    );
  }
}
