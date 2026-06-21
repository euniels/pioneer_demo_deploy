import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;

import '../services/backend_api.dart';
import '../services/crud_permissions.dart';
import '../services/geotab_sync_status_service.dart';
import '../services/vehicles_store.dart';
import '../theme/app_theme.dart';
import '../utils/form_validation.dart';
import '../widgets/app_state_widgets.dart';
import '../widgets/dashboard_layout.dart';
import '../widgets/page_skeletons.dart';
import '../widgets/pioneer_google_map.dart';
import '../widgets/geotab_push_preview.dart';
import '../widgets/geotab_sync_status_badge.dart';

class RoutesPage extends StatefulWidget {
  const RoutesPage({super.key});

  @override
  State<RoutesPage> createState() => _RoutesPageState();
}

class _RoutesPageState extends State<RoutesPage> {
  List<Map<String, dynamic>> _routes = const [];
  String _searchQuery = '';
  bool _showGridView = true;
  String _sourceFilter = 'All Sources';
  String _statusFilter = 'All Status';
  String _sortMode = 'Name A-Z';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    geotabWriteBackEventNotifier.addListener(_onWriteBackEvent);
    _loadRoutes();
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
    final localType = event['localType']?.toString() ?? '';
    final operations = ((event['operations'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => item['localType']?.toString() ?? '')
        .toSet();
    if (localType == 'fleet_route' || operations.contains('fleet_route')) {
      _loadRoutes(forceRefresh: true);
    }
  }

  Future<void> _loadRoutes({bool forceRefresh = false}) async {
    setState(() {
      _loading = _routes.isEmpty;
      _error = null;
    });
    try {
      final routes = await BackendApiService.getFleetRoutes(
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      setState(() {
        _routes = routes
            .where((route) => route['status']?.toString() != 'deleted')
            .toList();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Routes could not be refreshed.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      currentRoute: '/routes',
      title: 'Routes',
      subtitle: 'Reusable delivery templates and GeoTab route plans',
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final routes = _sortedRoutes;
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 850;
    if (_loading) {
      return const PioneerRouteSkeletonBody(routeName: '/routes');
    }

    return Column(
      children: [
        _buildRoutesToolbar(isDark, isMobile),
        _buildRouteFilterBar(isDark, isMobile),
        Expanded(
          child: Container(
            color: isDark ? AppTheme.colorFF0A0E1A : AppTheme.colorFFF5F6F8,
            child: RefreshIndicator(
              onRefresh: () => _loadRoutes(forceRefresh: true),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.all(isMobile ? 16 : 24),
                children: [
                  if (_error != null) ...[
                    PioneerStateCard(
                      icon: Icons.cloud_off_rounded,
                      title: 'Route refresh paused',
                      message: _error!,
                      actionLabel: 'Retry',
                      onAction: () => _loadRoutes(forceRefresh: true),
                      tone: PioneerStateTone.warning,
                    ),
                    const SizedBox(height: 12),
                  ],
                  _buildRouteSummaryCards(isDark, isMobile),
                  SizedBox(height: isMobile ? 14 : 20),
                  if (routes.isEmpty)
                    PioneerStateCard(
                      icon: Icons.alt_route_rounded,
                      title: _routes.isEmpty ? 'No routes yet' : 'No routes found',
                      message: _routes.isEmpty
                          ? 'Create a route template with ordered stops, then assign it to a vehicle when ready.'
                          : 'Try clearing the active search and filters to show all routes.',
                      actionLabel: _routes.isEmpty
                          ? 'Create route'
                          : 'Clear filters',
                      onAction: _routes.isEmpty
                          ? _openCreateRoute
                          : _clearRouteFilters,
                    )
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
                          children: [
                            for (final route in routes)
                              SizedBox(
                                width: cardWidth,
                                child: _RouteCard(
                                  route: route,
                                  onView: () => _openRouteDetails(route),
                                  onEdit:
                                      CrudPermissions.canEdit(
                                            CrudEntity.routes,
                                          ) &&
                                          _canEdit(route)
                                      ? () => _openEditRoute(route)
                                      : null,
                                  onDelete:
                                      CrudPermissions.canDelete(
                                            CrudEntity.routes,
                                          ) &&
                                          _canEdit(route) &&
                                          route['managedLocally'] == true
                                      ? () => _confirmDeleteRoute(route)
                                      : null,
                                  onPush: canPushToGeotab(route)
                                      ? () => _pushRouteToGeotab(route)
                                      : null,
                                  editBlockedReason: _routeEditBlockedReason(
                                    route,
                                  ),
                                  deleteBlockedReason: _routeDeleteBlockedReason(
                                    route,
                                  ),
                                  pushBlockedReason: canPushToGeotab(route)
                                      ? null
                                      : _routePushBlockedReason(route),
                                ),
                              ),
                          ],
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

  List<Map<String, dynamic>> get _sortedRoutes {
    var routes = _routes;
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      routes = routes.where((route) {
        final name = (route['name'] ?? route['routeName'] ?? '')
            .toString()
            .toLowerCase();
        final assigned =
            (route['assignedVehicle'] ?? route['assignedVehiclePlate'] ?? '')
                .toString()
                .toLowerCase();
        final description = (route['description'] ?? '')
            .toString()
            .toLowerCase();
        return name.contains(query) ||
            assigned.contains(query) ||
            description.contains(query);
      }).toList();
    }

    if (_sourceFilter != 'All Sources') {
      routes = routes.where((route) {
        final managed = route['managedLocally'] == true;
        return _sourceFilter == 'PioneerPath'
            ? managed
            : _sourceFilter == 'GeoTab'
            ? !managed
            : true;
      }).toList();
    }

    if (_statusFilter != 'All Status') {
      routes = routes.where((route) {
        final status =
            (route['syncStatus'] ?? route['status'] ?? 'synced')
                .toString()
                .toLowerCase();
        final inUse = route['inUseByActiveTrip'] == true;
        return switch (_statusFilter) {
          'In use' => inUse,
          'Writable' => _canEdit(route),
          'Pending approval' => status == 'pending_approval',
          'Synced' => status == 'synced',
          _ => true,
        };
      }).toList();
    }

    final sorted = List<Map<String, dynamic>>.from(routes);
    sorted.sort((a, b) {
      return switch (_sortMode) {
        'Name Z-A' => _compareRouteText(b, a, 'name'),
        'Usage High-Low' => _routeUsage(b).compareTo(_routeUsage(a)),
        'Usage Low-High' => _routeUsage(a).compareTo(_routeUsage(b)),
        'Stops High-Low' => _routeStopCount(b).compareTo(_routeStopCount(a)),
        'Stops Low-High' => _routeStopCount(a).compareTo(_routeStopCount(b)),
        _ => _compareRouteText(a, b, 'name'),
      };
    });
    return sorted;
  }

  Widget _buildRoutesToolbar(bool isDark, bool isMobile) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        isMobile ? 16 : 24,
        16,
        isMobile ? 16 : 24,
        12,
      ),
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
          final addButton = _routeAddButton(label: compact ? 'Add' : 'Add Route');
          final controls = Row(
            mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
            children: [
              _RouteViewToggle(
                gridActive: _showGridView,
                onGrid: () => setState(() => _showGridView = true),
                onList: () => setState(() => _showGridView = false),
              ),
              const SizedBox(width: 12),
              if (compact) Expanded(child: addButton) else addButton,
            ],
          );

          final search = _RouteSearchField(
            value: _searchQuery,
            onChanged: (value) => setState(() => _searchQuery = value.trim()),
            onClear: () => setState(() => _searchQuery = ''),
            isDark: isDark,
          );

          if (compact) {
            return Column(
              children: [
                search,
                const SizedBox(height: 12),
                controls,
              ],
            );
          }

          return Row(
            children: [
              Expanded(child: search),
              const SizedBox(width: 14),
              controls,
            ],
          );
        },
      ),
    );
  }

  Widget _routeAddButton({required String label}) {
    if (!CrudPermissions.canCreate(CrudEntity.routes)) {
      return const SizedBox.shrink();
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _openCreateRoute,
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
              const Icon(Icons.add_road_rounded, color: AppTheme.white, size: 18),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  color: AppTheme.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRouteFilterBar(bool isDark, bool isMobile) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        isMobile ? 16 : 24,
        10,
        isMobile ? 16 : 24,
        12,
      ),
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
            children: [
              _RouteResultCount(count: _sortedRoutes.length),
              const SizedBox(width: 10),
              _RouteFilterChip(
                label: 'Source',
                value: _sourceFilter,
                activeWhen: 'All Sources',
                options: const ['All Sources', 'PioneerPath', 'GeoTab'],
                onSelected: (value) => setState(() => _sourceFilter = value),
                onClear: () => setState(() => _sourceFilter = 'All Sources'),
              ),
              const SizedBox(width: 8),
              _RouteFilterChip(
                label: 'Status',
                value: _statusFilter,
                activeWhen: 'All Status',
                options: const [
                  'All Status',
                  'Writable',
                  'In use',
                  'Pending approval',
                  'Synced',
                ],
                onSelected: (value) => setState(() => _statusFilter = value),
                onClear: () => setState(() => _statusFilter = 'All Status'),
              ),
              const SizedBox(width: 8),
              _RouteFilterChip(
                label: 'Sort',
                value: _sortMode,
                activeWhen: 'Name A-Z',
                options: const [
                  'Name A-Z',
                  'Name Z-A',
                  'Usage High-Low',
                  'Usage Low-High',
                  'Stops High-Low',
                  'Stops Low-High',
                ],
                onSelected: (value) => setState(() => _sortMode = value),
                onClear: () => setState(() => _sortMode = 'Name A-Z'),
              ),
              if (_hasActiveRouteFilters) ...[
                const SizedBox(width: 10),
                TextButton.icon(
                  onPressed: _clearRouteFilters,
                  icon: const Icon(Icons.filter_alt_off_rounded, size: 16),
                  label: const Text('Clear'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  bool get _hasActiveRouteFilters =>
      _searchQuery.isNotEmpty ||
      _sourceFilter != 'All Sources' ||
      _statusFilter != 'All Status' ||
      _sortMode != 'Name A-Z';

  void _clearRouteFilters() {
    setState(() {
      _searchQuery = '';
      _sourceFilter = 'All Sources';
      _statusFilter = 'All Status';
      _sortMode = 'Name A-Z';
    });
  }

  int _compareRouteText(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
    String field,
  ) {
    final valueA = a[field] ?? a['routeName'];
    final valueB = b[field] ?? b['routeName'];
    return (valueA?.toString().toLowerCase() ?? '').compareTo(
      valueB?.toString().toLowerCase() ?? '',
    );
  }

  int _routeUsage(Map<String, dynamic> route) {
    final value =
        route['usageCount'] ?? route['tripCount'] ?? route['usedCount'];
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  int _routeStopCount(Map<String, dynamic> route) {
    final value = route['stopCount'] ?? route['routedPlaces']?.length;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Widget _buildRouteSummaryCards(bool isDark, bool isMobile) {
    final localCount = _routes
        .where((route) => route['managedLocally'] == true)
        .length;
    final geotabCount = _routes.length - localCount;
    final stopTotal = _routes.fold<int>(
      0,
      (sum, route) => sum + _routeStopCount(route),
    );
    final cards = [
      _RouteSummaryData(
        title: 'Route library',
        value: '${_routes.length}',
        subtitle: 'total templates and plans',
        icon: Icons.alt_route_rounded,
        color: AppTheme.colorFF4B7BE5,
      ),
      _RouteSummaryData(
        title: 'PioneerPath',
        value: '$localCount',
        subtitle: 'managed local routes',
        icon: Icons.route_rounded,
        color: AppTheme.successGreen,
      ),
      _RouteSummaryData(
        title: 'GeoTab plans',
        value: '$geotabCount',
        subtitle: 'read-only imported routes',
        icon: Icons.cloud_done_rounded,
        color: AppTheme.colorFF00A8E8,
      ),
      _RouteSummaryData(
        title: 'Stops mapped',
        value: '$stopTotal',
        subtitle: 'route stop points',
        icon: Icons.pin_drop_rounded,
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
                child: _RouteSummaryCard(data: card, isDark: isDark),
              ),
          ],
        );
      },
    );
  }

  bool _canEdit(Map<String, dynamic> route) {
    return route['managedLocally'] == true &&
        route['inUseByActiveTrip'] != true &&
        route['status']?.toString() != 'deleted';
  }

  String? _routeEditBlockedReason(Map<String, dynamic> route) {
    if (route['managedLocally'] != true) {
      return 'Imported GeoTab route plans are read-only. Clone/create a local managed route before editing.';
    }
    if (route['inUseByActiveTrip'] == true) {
      return 'This route is in use by an active trip. It can be edited after the trip completes.';
    }
    if (route['status']?.toString() == 'deleted') {
      return 'Deleted routes are retained for history and cannot be edited.';
    }
    return null;
  }

  String? _routeDeleteBlockedReason(Map<String, dynamic> route) {
    if (route['managedLocally'] != true) {
      return 'Imported GeoTab route plans cannot be deleted from PioneerPath.';
    }
    if (route['inUseByActiveTrip'] == true) {
      return 'Routes used by active trips cannot be deleted.';
    }
    if (route['status']?.toString() == 'deleted') {
      return 'This route is already soft-deleted.';
    }
    return null;
  }

  String _routePushBlockedReason(Map<String, dynamic> route) {
    final syncStatus = route['syncStatus']?.toString() ?? '';
    if (syncStatus == 'pending_approval') {
      return 'A GeoTab push for this route is already waiting for approval.';
    }
    if (syncStatus == 'synced') {
      return 'GeoTab is already up to date.';
    }
    if (route['assignedVehicleGeotabId']?.toString().trim().isEmpty ?? true) {
      return 'Assign a vehicle with a GeoTab Device ID before pushing.';
    }
    if ((route['stopCount'] as num?)?.toInt() == 0) {
      return 'Add at least one stop before pushing to GeoTab.';
    }
    return 'Save local route changes before pushing to GeoTab.';
  }

  Future<void> _openCreateRoute() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => const _RouteEditorDialog(),
    );
    if (created == true) {
      await _loadRoutes(forceRefresh: true);
    }
  }

  Future<void> _openEditRoute(Map<String, dynamic> route) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _RouteEditorDialog(route: route),
    );
    if (saved == true) {
      await _loadRoutes(forceRefresh: true);
    }
  }

  void _openRouteDetails(Map<String, dynamic> route) {
    showDialog(
      context: context,
      builder: (_) => _RouteDetailsDialog(route: route),
    );
  }

  Future<void> _confirmDeleteRoute(Map<String, dynamic> route) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete route?'),
        content: Text(
          '${route['name']} will be hidden from route lists but preserved for trip history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep route'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Soft delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await BackendApiService.deleteFleetRoute(route['id'].toString());
    await _loadRoutes(forceRefresh: true);
  }

  Future<void> _pushRouteToGeotab(Map<String, dynamic> route) async {
    final routeId = route['id'].toString();
    final preview = await BackendApiService.pushFleetRouteToGeotab(
      routeId,
      previewOnly: true,
    );
    if (!mounted) return;
    if (!await guardGeotabPushPreview(context: context, preview: preview)) {
      return;
    }
    final confirmed = await showGeotabPushPreview(
      context: context,
      entityType: 'Route',
      entityName: (route['name'] ?? route['routeName'] ?? routeId).toString(),
      payload: preview['preview'],
      snapshot: preview['geotabSnapshot'],
      previewPayload: preview['previewPayload'],
    );
    if (confirmed != true) return;

    await BackendApiService.pushFleetRouteToGeotab(routeId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('GeoTab push request staged for admin approval.'),
      ),
    );
    await _loadRoutes(forceRefresh: true);
  }
}

class _RouteSearchField extends StatelessWidget {
  const _RouteSearchField({
    required this.value,
    required this.onChanged,
    required this.onClear,
    required this.isDark,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return TextField(
      onChanged: onChanged,
      style: TextStyle(
        fontSize: 14,
        color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
      ),
      decoration: InputDecoration(
        hintText: 'Search by route name, vehicle, or description...',
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
    );
  }
}

class _RouteViewToggle extends StatelessWidget {
  const _RouteViewToggle({
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
          _RouteViewToggleButton(
            icon: Icons.grid_view_rounded,
            active: gridActive,
            tooltip: 'Grid view',
            onTap: onGrid,
          ),
          _RouteViewToggleButton(
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

class _RouteViewToggleButton extends StatelessWidget {
  const _RouteViewToggleButton({
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

class _RouteResultCount extends StatelessWidget {
  const _RouteResultCount({required this.count});

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
        '$count routes shown',
        style: const TextStyle(
          color: AppTheme.infoBlue,
          fontWeight: FontWeight.w900,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _RouteFilterChip extends StatelessWidget {
  const _RouteFilterChip({
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

class _RouteCard extends StatelessWidget {
  const _RouteCard({
    required this.route,
    required this.onView,
    this.onEdit,
    this.onDelete,
    this.onPush,
    this.editBlockedReason,
    this.deleteBlockedReason,
    this.pushBlockedReason,
  });

  final Map<String, dynamic> route;
  final VoidCallback onView;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onPush;
  final String? editBlockedReason;
  final String? deleteBlockedReason;
  final String? pushBlockedReason;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final stopCount = route['stopCount'] ?? route['routedPlaces']?.length ?? 0;
    final status =
        route['syncStatus']?.toString() ??
        route['status']?.toString() ??
        'synced';
    final assigned =
        route['assignedVehicle']?.toString() ??
        route['assignedVehiclePlate']?.toString() ??
        'Unassigned';
    final managed = route['managedLocally'] == true;
    final accent = managed ? AppTheme.successGreen : AppTheme.colorFF00A8E8;

    return Container(
      constraints: const BoxConstraints(minHeight: 190),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF171B23 : AppTheme.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: isDark ? 0.34 : 0.22)),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: isDark ? 0.12 : 0.07),
            blurRadius: 20,
            spreadRadius: -14,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.alt_route_rounded, color: accent, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      route['name']?.toString() ??
                          route['routeName']?.toString() ??
                          'Untitled route',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: isDark ? AppTheme.white : AppTheme.colorFF233244,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      managed ? 'PioneerPath managed' : 'GeoTab route plan',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                      ),
                    ),
                  ],
                ),
              ),
              GeoTabSyncStatusBadge.fromEntity({
                ...route,
                'syncStatus': status,
              }, compact: true),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _RouteFactPill(Icons.pin_drop_rounded, '$stopCount stops'),
              _RouteFactPill(Icons.local_shipping_rounded, assigned),
              _RouteFactPill(
                Icons.timeline_rounded,
                '${route['usageCount'] ?? route['tripCount'] ?? 0} uses',
              ),
              _RouteFactPill(
                Icons.event_available_rounded,
                route['lastUsedAt']?.toString().isNotEmpty == true
                    ? route['lastUsedAt'].toString()
                    : 'Not used yet',
              ),
            ],
          ),
          if (route['inUseByActiveTrip'] == true) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.warningOrange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppTheme.warningOrange.withValues(alpha: 0.22),
                ),
              ),
              child: Text(
                'Read-only while assigned to an active trip.',
                style: TextStyle(
                  color: AppTheme.warningOrange,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              _RouteActionButton(
                tooltip: 'View route',
                icon: Icons.visibility_rounded,
                onPressed: onView,
              ),
              _RouteActionButton(
                tooltip: onEdit == null
                    ? (editBlockedReason ?? 'Route cannot be edited.')
                    : 'Edit local route',
                icon: Icons.edit_rounded,
                onPressed: onEdit,
              ),
              _RouteActionButton(
                tooltip: onPush == null
                    ? (pushBlockedReason ?? 'GeoTab is already up to date.')
                    : 'Push to GeoTab',
                icon: Icons.cloud_upload_outlined,
                onPressed: onPush,
              ),
              _RouteActionButton(
                tooltip: onDelete == null
                    ? (deleteBlockedReason ?? 'Route cannot be deleted.')
                    : 'Soft delete local route',
                icon: Icons.delete_outline_rounded,
                onPressed: onDelete,
                danger: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RouteFactPill extends StatelessWidget {
  const _RouteFactPill(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF11161F : AppTheme.colorFFF7F9FC,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.06)
              : AppTheme.black.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppTheme.getMutedTextColor(context)),
          const SizedBox(width: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isDark ? AppTheme.gray300 : AppTheme.gray700,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _RouteActionButton extends StatelessWidget {
  const _RouteActionButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.danger = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppTheme.colorFFE74C3C : AppTheme.colorFF4B7BE5;
    return Tooltip(
      message: tooltip,
      child: IconButton.filledTonal(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        style: IconButton.styleFrom(
          foregroundColor: onPressed == null ? AppTheme.gray500 : color,
          backgroundColor: color.withValues(alpha: 0.12),
          disabledBackgroundColor: AppTheme.gray500.withValues(alpha: 0.08),
          minimumSize: const Size(38, 38),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}

class _RouteSummaryData {
  const _RouteSummaryData({
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

class _RouteSummaryCard extends StatelessWidget {
  const _RouteSummaryCard({required this.data, required this.isDark});

  final _RouteSummaryData data;
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
          color: data.color.withValues(alpha: isDark ? 0.34 : 0.20),
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

class _RouteEditorDialog extends StatefulWidget {
  const _RouteEditorDialog({this.route});

  final Map<String, dynamic>? route;

  @override
  State<_RouteEditorDialog> createState() => _RouteEditorDialogState();
}

class _RouteEditorDialogState extends State<_RouteEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _comment;
  late final TextEditingController _scheduledStart;
  late final TextEditingController _scheduledEnd;
  String? _vehiclePlate;
  String? _vehicleGeotabId;
  String _routeType = 'planned';
  late List<_EditableStop> _stops;
  bool _saving = false;

  bool get _editing => widget.route != null;

  @override
  void initState() {
    super.initState();
    final route = widget.route ?? const <String, dynamic>{};
    _name = TextEditingController(text: route['name']?.toString() ?? '');
    _description = TextEditingController(
      text: route['description']?.toString() ?? '',
    );
    _comment = TextEditingController(text: route['comment']?.toString() ?? '');
    _scheduledStart = TextEditingController(
      text: route['scheduledStartAt']?.toString() ?? '',
    );
    _scheduledEnd = TextEditingController(
      text: route['scheduledEndAt']?.toString() ?? '',
    );
    _routeType =
        (route['routeType']?.toString().toLowerCase() ?? 'planned') ==
            'unplanned'
        ? 'unplanned'
        : 'planned';
    _vehiclePlate = _emptyToNull(route['assignedVehiclePlate']);
    _vehicleGeotabId = _emptyToNull(route['assignedVehicleGeotabId']);
    final rawStops =
        ((route['stops'] ?? route['routedPlaces']) as List?) ?? const [];
    _stops = rawStops
        .whereType<Map>()
        .map((stop) => _EditableStop.fromMap(Map<String, dynamic>.from(stop)))
        .toList();
    if (_stops.isEmpty) {
      _stops = [_EditableStop.empty(1), _EditableStop.empty(2)];
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _comment.dispose();
    _scheduledStart.dispose();
    _scheduledEnd.dispose();
    for (final stop in _stops) {
      stop.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 700;

    return Dialog(
      backgroundColor: AppTheme.transparent,
      insetPadding: EdgeInsets.symmetric(
        horizontal: isMobile ? 10 : 48,
        vertical: 20,
      ),
      child: Container(
        constraints: BoxConstraints(maxWidth: isMobile ? width - 20 : 920),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.colorFF111827 : AppTheme.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.getBorderColor(context)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dialogHeader(),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(18),
                child: Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _name,
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? 'Route name is required'
                            : null,
                        decoration: const InputDecoration(
                          labelText: 'Route name',
                          prefixIcon: Icon(Icons.route_rounded),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _description,
                        minLines: 2,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Description',
                          prefixIcon: Icon(Icons.notes_rounded),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _comment,
                        minLines: 2,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'GeoTab comment',
                          hintText:
                              'Visible route note for dispatcher review in MyGeotab',
                          prefixIcon: Icon(Icons.comment_rounded),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _routeTypeAndScheduleFields(),
                      const SizedBox(height: 12),
                      _vehicleDropdown(),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Ordered stops',
                              style: AppTheme.getHeadingStyle(
                                context,
                                fontSize: 16,
                              ),
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: _addStop,
                            icon: const Icon(Icons.add_location_alt_rounded),
                            label: const Text('Add stop'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ..._stops.asMap().entries.map(
                        (entry) => _stopEditor(entry.key, entry.value),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving ? null : () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check_rounded),
                      label: Text(_editing ? 'Save route' : 'Create route'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dialogHeader() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [AppTheme.primaryBlue, AppTheme.colorFF4B7BE5],
        ),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Row(
        children: [
          Icon(
            _editing ? Icons.edit_road_rounded : Icons.add_road_rounded,
            color: AppTheme.white,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _editing ? 'Edit Route' : 'Create Route',
              style: const TextStyle(
                color: AppTheme.white,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
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

  Widget _vehicleDropdown() {
    final vehicles = vehiclesNotifier.value
        .where(
          (vehicle) => vehicle['plate']?.toString().trim().isNotEmpty == true,
        )
        .toList();
    final options = <DropdownMenuItem<String?>>[
      const DropdownMenuItem(value: null, child: Text('Unassigned template')),
      ...vehicles.map((vehicle) {
        final plate = vehicle['plate']?.toString() ?? '';
        final geotabId = vehicle['geotabId']?.toString() ?? '';
        return DropdownMenuItem<String?>(
          value: '$plate|$geotabId',
          child: Text(geotabId.isEmpty ? plate : '$plate - $geotabId'),
        );
      }),
    ];
    final current = _vehiclePlate == null
        ? null
        : '$_vehiclePlate|${_vehicleGeotabId ?? ''}';

    return DropdownButtonFormField<String?>(
      initialValue: options.any((item) => item.value == current)
          ? current
          : null,
      items: options,
      onChanged: (value) {
        final parts = (value ?? '').split('|');
        setState(() {
          _vehiclePlate = parts.isNotEmpty && parts.first.isNotEmpty
              ? parts.first
              : null;
          _vehicleGeotabId = parts.length > 1 && parts[1].isNotEmpty
              ? parts[1]
              : null;
        });
      },
      decoration: const InputDecoration(
        labelText: 'Assigned vehicle',
        prefixIcon: Icon(Icons.local_shipping_rounded),
      ),
    );
  }

  Widget _routeTypeAndScheduleFields() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        final children = [
          DropdownButtonFormField<String>(
            initialValue: _routeType,
            decoration: const InputDecoration(
              labelText: 'Route type',
              prefixIcon: Icon(Icons.route_rounded),
            ),
            items: const [
              DropdownMenuItem(value: 'planned', child: Text('Planned')),
              DropdownMenuItem(value: 'unplanned', child: Text('Unplanned')),
            ],
            onChanged: (value) =>
                setState(() => _routeType = value ?? 'planned'),
          ),
          TextFormField(
            controller: _scheduledStart,
            decoration: const InputDecoration(
              labelText: 'Scheduled start',
              hintText: 'Optional ISO date/time',
              prefixIcon: Icon(Icons.play_circle_outline_rounded),
            ),
          ),
          TextFormField(
            controller: _scheduledEnd,
            decoration: const InputDecoration(
              labelText: 'Scheduled end',
              hintText: 'Optional ISO date/time',
              prefixIcon: Icon(Icons.flag_circle_rounded),
            ),
          ),
        ];

        if (compact) {
          return Column(
            children: [
              for (var index = 0; index < children.length; index++) ...[
                children[index],
                if (index != children.length - 1) const SizedBox(height: 10),
              ],
            ],
          );
        }

        return Row(
          children: [
            for (var index = 0; index < children.length; index++) ...[
              Expanded(child: children[index]),
              if (index != children.length - 1) const SizedBox(width: 10),
            ],
          ],
        );
      },
    );
  }

  Widget _stopEditor(int index, _EditableStop stop) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.getBorderColor(context)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 15,
                backgroundColor: AppTheme.primaryBlue,
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(color: AppTheme.white),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Stop sequence ${index + 1}',
                  style: AppTheme.getHeadingStyle(context, fontSize: 13),
                ),
              ),
              IconButton(
                tooltip: 'Move up',
                onPressed: index == 0 ? null : () => _moveStop(index, -1),
                icon: const Icon(Icons.arrow_upward_rounded),
              ),
              IconButton(
                tooltip: 'Move down',
                onPressed: index == _stops.length - 1
                    ? null
                    : () => _moveStop(index, 1),
                icon: const Icon(Icons.arrow_downward_rounded),
              ),
              IconButton(
                tooltip: 'Remove stop',
                onPressed: _stops.length <= 1 ? null : () => _removeStop(index),
                icon: const Icon(Icons.remove_circle_outline_rounded),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: stop.name,
            validator: (value) => value == null || value.trim().isEmpty
                ? 'Stop name required'
                : null,
            decoration: const InputDecoration(labelText: 'Stop name'),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: stop.zoneId,
                  decoration: const InputDecoration(
                    labelText: 'GeoTab Zone ID',
                    hintText: 'Optional',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextFormField(
                  controller: stop.duration,
                  keyboardType: TextInputType.number,
                  validator: (value) => FormValidation.nonNegativeNumber(
                    'Duration minutes',
                    value,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Duration minutes',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: stop.latitude,
                  keyboardType: TextInputType.number,
                  validator: _latitudeValidator,
                  decoration: const InputDecoration(labelText: 'Latitude'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextFormField(
                  controller: stop.longitude,
                  keyboardType: TextInputType.number,
                  validator: _longitudeValidator,
                  decoration: const InputDecoration(labelText: 'Longitude'),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: () => _pickStopOnMap(stop),
                icon: const Icon(Icons.map_rounded),
                label: const Text('Pick on map'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _addStop() {
    setState(() => _stops.add(_EditableStop.empty(_stops.length + 1)));
  }

  void _removeStop(int index) {
    final stop = _stops.removeAt(index);
    stop.dispose();
    setState(() {});
  }

  void _moveStop(int index, int delta) {
    final target = index + delta;
    final item = _stops.removeAt(index);
    _stops.insert(target, item);
    setState(() {});
  }

  Future<void> _pickStopOnMap(_EditableStop stop) async {
    final initial = gmaps.LatLng(
      double.tryParse(stop.latitude.text) ?? 14.2788,
      double.tryParse(stop.longitude.text) ?? 121.1248,
    );
    final picked = await showDialog<gmaps.LatLng>(
      context: context,
      builder: (_) => _CoordinatePickerDialog(initial: initial),
    );
    if (picked == null) return;
    setState(() {
      stop.latitude.text = picked.latitude.toStringAsFixed(7);
      stop.longitude.text = picked.longitude.toStringAsFixed(7);
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final payload = {
      'name': _name.text.trim(),
      'description': _description.text.trim(),
      'comment': _comment.text.trim(),
      'routeType': _routeType,
      if (_scheduledStart.text.trim().isNotEmpty)
        'scheduledStartAt': _scheduledStart.text.trim(),
      if (_scheduledEnd.text.trim().isNotEmpty)
        'scheduledEndAt': _scheduledEnd.text.trim(),
      if (_vehicleGeotabId?.isNotEmpty == true)
        'assignedVehicleGeotabId': _vehicleGeotabId,
      if (_vehiclePlate?.isNotEmpty == true)
        'assignedVehiclePlate': _vehiclePlate,
      'stops': _stops.asMap().entries.map((entry) {
        final stop = entry.value;
        return {
          'name': stop.name.text.trim(),
          if (stop.zoneId.text.trim().isNotEmpty)
            'zoneId': stop.zoneId.text.trim(),
          'latitude': double.parse(stop.latitude.text.trim()),
          'longitude': double.parse(stop.longitude.text.trim()),
          if (stop.duration.text.trim().isNotEmpty)
            'estimatedStopDurationMinutes':
                int.tryParse(stop.duration.text.trim()) ?? 0,
        };
      }).toList(),
    };

    try {
      if (_editing) {
        await BackendApiService.updateFleetRoute(
          widget.route!['id'].toString(),
          payload,
        );
      } else {
        await BackendApiService.createFleetRoute(payload);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Changes saved locally.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            FormValidation.backendError(error, 'Route could not be saved.'),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _latitudeValidator(String? value) {
    final parsed = double.tryParse(value ?? '');
    if (parsed == null || parsed < -90 || parsed > 90) {
      return 'Valid latitude required';
    }
    return null;
  }

  String? _longitudeValidator(String? value) {
    final parsed = double.tryParse(value ?? '');
    if (parsed == null || parsed < -180 || parsed > 180) {
      return 'Valid longitude required';
    }
    return null;
  }

  String? _emptyToNull(dynamic value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty || text == 'Unassigned' ? null : text;
  }
}

class _EditableStop {
  _EditableStop({
    required this.name,
    required this.zoneId,
    required this.latitude,
    required this.longitude,
    required this.duration,
  });

  factory _EditableStop.empty(int sequence) {
    return _EditableStop(
      name: TextEditingController(text: 'Stop $sequence'),
      zoneId: TextEditingController(),
      latitude: TextEditingController(),
      longitude: TextEditingController(),
      duration: TextEditingController(),
    );
  }

  factory _EditableStop.fromMap(Map<String, dynamic> map) {
    return _EditableStop(
      name: TextEditingController(text: map['name']?.toString() ?? ''),
      zoneId: TextEditingController(text: map['zoneId']?.toString() ?? ''),
      latitude: TextEditingController(text: map['latitude']?.toString() ?? ''),
      longitude: TextEditingController(
        text: map['longitude']?.toString() ?? '',
      ),
      duration: TextEditingController(
        text: map['estimatedStopDurationMinutes']?.toString() ?? '',
      ),
    );
  }

  final TextEditingController name;
  final TextEditingController zoneId;
  final TextEditingController latitude;
  final TextEditingController longitude;
  final TextEditingController duration;

  void dispose() {
    name.dispose();
    zoneId.dispose();
    latitude.dispose();
    longitude.dispose();
    duration.dispose();
  }
}

class _CoordinatePickerDialog extends StatefulWidget {
  const _CoordinatePickerDialog({required this.initial});

  final gmaps.LatLng initial;

  @override
  State<_CoordinatePickerDialog> createState() =>
      _CoordinatePickerDialogState();
}

class _CoordinatePickerDialogState extends State<_CoordinatePickerDialog> {
  late gmaps.LatLng _selected = widget.initial;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 720,
        height: 520,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Pick stop coordinates',
                      style: AppTheme.getHeadingStyle(context, fontSize: 16),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, _selected),
                    child: const Text('Use point'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PioneerGoogleMap(
                initialCenter: widget.initial,
                initialZoom: 14,
                markers: {
                  gmaps.Marker(
                    markerId: const gmaps.MarkerId('selected-stop'),
                    position: _selected,
                  ),
                },
                onTap: (position) => setState(() => _selected = position),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RouteDetailsDialog extends StatelessWidget {
  const _RouteDetailsDialog({required this.route});

  final Map<String, dynamic> route;

  @override
  Widget build(BuildContext context) {
    final stops =
        (((route['stops'] ?? route['routedPlaces']) as List?) ?? const [])
            .whereType<Map>()
            .map((stop) => Map<String, dynamic>.from(stop))
            .toList();
    final points = stops
        .map((stop) {
          final lat =
              (stop['latitude'] as num?)?.toDouble() ??
              double.tryParse(stop['latitude']?.toString() ?? '');
          final lng =
              (stop['longitude'] as num?)?.toDouble() ??
              double.tryParse(stop['longitude']?.toString() ?? '');
          if (lat == null || lng == null) return null;
          return gmaps.LatLng(lat, lng);
        })
        .whereType<gmaps.LatLng>()
        .toList();
    final center = points.isNotEmpty
        ? points.first
        : const gmaps.LatLng(14.2788, 121.1248);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenSize = MediaQuery.sizeOf(context);
    final isCompact = screenSize.width < 760;
    final dialogHeight = (screenSize.height * 0.84).clamp(520.0, 720.0);

    final mapPanel = PioneerGoogleMap(
      initialCenter: center,
      initialZoom: 13,
      markers: points.indexed
          .map(
            (entry) => gmaps.Marker(
              markerId: gmaps.MarkerId('route-stop-${entry.$1}'),
              position: entry.$2,
              infoWindow: gmaps.InfoWindow(
                title: '${entry.$1 + 1}. ${stops[entry.$1]['name'] ?? 'Stop'}',
              ),
            ),
          )
          .toSet(),
      polylines: points.length >= 2
          ? {
              gmaps.Polyline(
                polylineId: const gmaps.PolylineId('route-path'),
                points: points,
                color: AppTheme.primaryBlue,
                width: 5,
                startCap: gmaps.Cap.roundCap,
                endCap: gmaps.Cap.roundCap,
                jointType: gmaps.JointType.round,
              ),
            }
          : const <gmaps.Polyline>{},
    );

    final detailsPanel = Container(
      color: isDark ? AppTheme.colorFF111827 : AppTheme.white,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: stops.length + 1,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, index) {
          if (index == 0) {
            return _RouteMetadataSummary(route: route);
          }
          final stop = stops[index - 1];
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isDark
                  ? AppTheme.colorFF1A1D23
                  : AppTheme.colorFFF7F9FC,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.getBorderColor(context)),
            ),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: CircleAvatar(
                radius: 17,
                backgroundColor: AppTheme.primaryBlue,
                child: Text(
                  '$index',
                  style: const TextStyle(
                    color: AppTheme.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              title: SelectableText(
                stop['name']?.toString() ?? 'Stop',
                style: AppTheme.getHeadingStyle(context, fontSize: 13),
              ),
              subtitle: SelectableText(
                'Zone: ${stop['zoneId'] ?? 'Not linked'}\n'
                '${stop['latitude']}, ${stop['longitude']}',
                style: AppTheme.getSubtitleStyle(context),
              ),
            ),
          );
        },
      ),
    );

    return Dialog(
      backgroundColor: AppTheme.transparent,
      insetPadding: EdgeInsets.symmetric(
        horizontal: isCompact ? 10 : 48,
        vertical: 20,
      ),
      child: Container(
        width: isCompact ? screenSize.width - 20 : 980,
        height: dialogHeight,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: isDark ? AppTheme.colorFF111827 : AppTheme.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.getBorderColor(context)),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppTheme.primaryBlue, AppTheme.colorFF4B7BE5],
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.route_rounded, color: AppTheme.white),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          route['name']?.toString() ??
                              route['routeName']?.toString() ??
                              'Route details',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          'Route overview and ordered stops',
                          style: TextStyle(
                            color: AppTheme.white70,
                            fontSize: 12,
                          ),
                        ),
                      ],
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
              child: isCompact
                  ? Column(
                      children: [
                        Expanded(flex: 3, child: mapPanel),
                        Divider(
                          height: 1,
                          color: AppTheme.getBorderColor(context),
                        ),
                        Expanded(flex: 2, child: detailsPanel),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(flex: 3, child: mapPanel),
                        VerticalDivider(
                          width: 1,
                          color: AppTheme.getBorderColor(context),
                        ),
                        SizedBox(width: 320, child: detailsPanel),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RouteMetadataSummary extends StatelessWidget {
  const _RouteMetadataSummary({required this.route});

  final Map<String, dynamic> route;

  @override
  Widget build(BuildContext context) {
    final type = route['routeType']?.toString() == 'unplanned'
        ? 'Unplanned'
        : 'Planned';
    final comment = route['comment']?.toString().trim() ?? '';
    final schedule = [
      route['scheduledStartAt']?.toString().trim() ?? '',
      route['scheduledEndAt']?.toString().trim() ?? '',
    ].where((value) => value.isNotEmpty).join(' - ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('GeoTab route entry', style: AppTheme.getHeadingStyle(context)),
        const SizedBox(height: 10),
        _routeFact(context, 'Type', type),
        _routeFact(
          context,
          'Assigned asset',
          route['assignedVehicle']?.toString() ?? 'Unassigned',
        ),
        if (schedule.isNotEmpty) _routeFact(context, 'Schedule', schedule),
        if (comment.isNotEmpty) _routeFact(context, 'Comment', comment),
        _routeFact(
          context,
          'GeoTab route ID',
          route['geotabRouteId']?.toString().trim().isNotEmpty == true
              ? route['geotabRouteId'].toString()
              : 'Not synced yet',
        ),
      ],
    );
  }

  Widget _routeFact(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTheme.getCaptionStyle(context)),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: AppTheme.getSubtitleStyle(
              context,
            ).copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
