import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;

import '../services/backend_api.dart';
import '../services/crud_permissions.dart';
import '../services/geotab_sync_status_service.dart';
import '../theme/app_theme.dart';
import '../utils/form_validation.dart';
import '../widgets/app_state_widgets.dart';
import '../widgets/dashboard_layout.dart';
import '../widgets/page_skeletons.dart';
import '../widgets/pioneer_google_map.dart';
import '../widgets/geotab_push_preview.dart';
import '../widgets/geotab_sync_status_badge.dart';

const Map<String, String> _geotabZoneTypeLabels = {
  'ZoneTypeCustomerId': 'Customer Site',
  'ZoneTypeHomeId': 'Home Base',
  'ZoneTypeOfficeId': 'Office',
  'ZoneTypeServiceId': 'Service Center',
};

const List<String> _zoneTypeOptions = [
  'Customer Site',
  'Home Base',
  'Office',
  'Service Center',
  'Depot',
  'Restricted Area',
  'Rest Stop',
  'Custom Zone',
];

String readableZoneType(dynamic raw) {
  final value = raw?.toString().trim() ?? '';
  if (value.isEmpty) {
    return 'Custom Zone';
  }
  final mapped = _geotabZoneTypeLabels[value];
  if (mapped != null) {
    return mapped;
  }
  return _zoneTypeOptions.contains(value) ? value : 'Custom Zone';
}

String zoneNotes(dynamic zone) {
  if (zone is! Map) {
    return '';
  }
  final direct = zone['notes']?.toString().trim() ?? '';
  if (direct.isNotEmpty) {
    return direct;
  }
  final meta = zone['meta'];
  if (meta is Map) {
    return meta['notes']?.toString().trim() ?? '';
  }
  return '';
}

class ZonesPage extends StatefulWidget {
  const ZonesPage({super.key});

  @override
  State<ZonesPage> createState() => _ZonesPageState();
}

class _ZonesPageState extends State<ZonesPage> {
  List<Map<String, dynamic>> _zones = const [];
  String _searchQuery = '';
  bool _showGridView = true;
  String _typeFilter = 'All Types';
  String _sourceFilter = 'All Sources';
  String _statusFilter = 'All Status';
  String _sortMode = 'Name A-Z';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    geotabWriteBackEventNotifier.addListener(_onWriteBackEvent);
    _loadZones();
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
    if (localType == 'fleet_zone') {
      _loadZones(forceRefresh: true);
    }
  }

  Future<void> _loadZones({bool forceRefresh = false}) async {
    setState(() {
      _loading = _zones.isEmpty;
      _error = null;
    });
    try {
      final zones = await BackendApiService.getFleetZones(
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      setState(() {
        _zones = zones.where((zone) => zone['status'] != 'deleted').toList();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Zones could not be refreshed.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      currentRoute: '/zones',
      title: 'Zones & Geofences',
      subtitle: 'Customer sites, depots, restricted areas, and route overlays',
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 850;
    final zones = _filteredZones;
    if (_loading) {
      return const PioneerRouteSkeletonBody(routeName: '/zones');
    }

    return Column(
      children: [
        _buildZonesToolbar(isDark, isMobile),
        _buildZoneFilterBar(isDark, isMobile),
        Expanded(
          child: Container(
            color: isDark ? AppTheme.colorFF0A0E1A : AppTheme.colorFFF5F6F8,
            child: RefreshIndicator(
              onRefresh: () => _loadZones(forceRefresh: true),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.all(isMobile ? 16 : 24),
                children: [
                  if (_error != null) ...[
                    PioneerStateCard(
                      icon: Icons.cloud_off_rounded,
                      title: 'Zone refresh paused',
                      message: _error!,
                      actionLabel: 'Retry',
                      onAction: () => _loadZones(forceRefresh: true),
                      tone: PioneerStateTone.warning,
                    ),
                    const SizedBox(height: 12),
                  ],
                  _buildZoneSummaryCards(isDark, isMobile),
                  SizedBox(height: isMobile ? 14 : 20),
                  if (zones.isEmpty)
                    PioneerStateCard(
                      icon: Icons.hexagon_rounded,
                      title: _zones.isEmpty
                          ? 'No managed zones yet'
                          : 'No zones found',
                      message: _zones.isEmpty
                          ? 'Draw customer sites, depots, rest stops, or restricted areas so dispatch and live tracking can show delivery geofences.'
                          : 'Try clearing the active search and filters to show all zones.',
                      actionLabel: _zones.isEmpty
                          ? (CrudPermissions.canCreate(CrudEntity.zones)
                                ? 'Create zone'
                                : null)
                          : 'Clear filters',
                      onAction: _zones.isEmpty
                          ? (CrudPermissions.canCreate(CrudEntity.zones)
                                ? () => _openZoneEditor()
                                : null)
                          : _clearZoneFilters,
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
                            for (final zone in zones)
                              SizedBox(
                                width: cardWidth,
                                child: _ZoneCard(
                                  zone: zone,
                                  onEdit:
                                      CrudPermissions.canEdit(
                                            CrudEntity.zones,
                                          ) &&
                                          zone['managedLocally'] == true
                                      ? () => _openZoneEditor(zone: zone)
                                      : null,
                                  onDelete:
                                      CrudPermissions.canDelete(
                                            CrudEntity.zones,
                                          ) &&
                                          zone['managedLocally'] == true
                                      ? () => _confirmDelete(zone)
                                      : null,
                                  onPush: canPushToGeotab(zone)
                                      ? () => _pushZoneToGeotab(zone)
                                      : null,
                                  onView: () => _showZoneMap(zone),
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

  List<Map<String, dynamic>> get _filteredZones {
    var zones = _zones;
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      zones = zones.where((zone) {
        final name = (zone['name'] ?? '').toString().toLowerCase();
        final client = (zone['clientName'] ?? '').toString().toLowerCase();
        final notes = zoneNotes(zone).toLowerCase();
        return name.contains(query) ||
            client.contains(query) ||
            notes.contains(query);
      }).toList();
    }
    if (_typeFilter != 'All Types') {
      zones = zones.where((zone) {
        final type = readableZoneType(zone['zoneType'] ?? zone['type']);
        return type.toLowerCase() == _typeFilter.toLowerCase();
      }).toList();
    }
    if (_sourceFilter != 'All Sources') {
      zones = zones.where((zone) {
        final managed = zone['managedLocally'] == true;
        return _sourceFilter == 'PioneerPath'
            ? managed
            : _sourceFilter == 'GeoTab'
            ? !managed
            : true;
      }).toList();
    }
    if (_statusFilter != 'All Status') {
      zones = zones.where((zone) {
        final syncStatus = (zone['syncStatus'] ?? 'not_staged').toString();
        return switch (_statusFilter) {
          'Writable' => zone['managedLocally'] == true,
          'Pending approval' => syncStatus == 'pending_approval',
          'Synced' => syncStatus == 'synced',
          'Not staged' => syncStatus == 'not_staged',
          _ => true,
        };
      }).toList();
    }
    final sorted = List<Map<String, dynamic>>.from(zones);
    sorted.sort((a, b) {
      return switch (_sortMode) {
        'Name Z-A' => _compareZoneText(b, a, 'name'),
        'Type A-Z' => _compareZoneText(a, b, 'zoneType'),
        'Type Z-A' => _compareZoneText(b, a, 'zoneType'),
        'Client A-Z' => _compareZoneText(a, b, 'clientName'),
        'Client Z-A' => _compareZoneText(b, a, 'clientName'),
        _ => _compareZoneText(a, b, 'name'),
      };
    });
    return sorted;
  }

  Widget _buildZonesToolbar(bool isDark, bool isMobile) {
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
          final addButton = _zoneAddButton(label: compact ? 'Add' : 'New Zone');
          final controls = Row(
            mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
            children: [
              _ZoneViewToggle(
                gridActive: _showGridView,
                onGrid: () => setState(() => _showGridView = true),
                onList: () => setState(() => _showGridView = false),
              ),
              const SizedBox(width: 12),
              if (compact) Expanded(child: addButton) else addButton,
            ],
          );
          final search = _ZoneSearchField(
            value: _searchQuery,
            isDark: isDark,
            onChanged: (value) => setState(() => _searchQuery = value.trim()),
            onClear: () => setState(() => _searchQuery = ''),
          );

          if (compact) {
            return Column(
              children: [search, const SizedBox(height: 12), controls],
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

  Widget _zoneAddButton({required String label}) {
    if (!CrudPermissions.canCreate(CrudEntity.zones)) {
      return const SizedBox.shrink();
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _openZoneEditor(),
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
              const Icon(
                Icons.add_location_alt_rounded,
                color: AppTheme.white,
                size: 18,
              ),
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

  Widget _buildZoneFilterBar(bool isDark, bool isMobile) {
    final types = {
      'All Types',
      ..._zones.map(
        (zone) => readableZoneType(zone['zoneType'] ?? zone['type']),
      ),
    }.where((value) => value.trim().isNotEmpty).toList()..sort();
    final safeTypeFilter = types.contains(_typeFilter)
        ? _typeFilter
        : 'All Types';
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
              _ZoneResultCount(count: _filteredZones.length),
              const SizedBox(width: 10),
              _ZoneFilterChip(
                label: 'Type',
                value: safeTypeFilter,
                activeWhen: 'All Types',
                options: types,
                onSelected: (value) => setState(() => _typeFilter = value),
                onClear: () => setState(() => _typeFilter = 'All Types'),
              ),
              const SizedBox(width: 8),
              _ZoneFilterChip(
                label: 'Source',
                value: _sourceFilter,
                activeWhen: 'All Sources',
                options: const ['All Sources', 'PioneerPath', 'GeoTab'],
                onSelected: (value) => setState(() => _sourceFilter = value),
                onClear: () => setState(() => _sourceFilter = 'All Sources'),
              ),
              const SizedBox(width: 8),
              _ZoneFilterChip(
                label: 'Status',
                value: _statusFilter,
                activeWhen: 'All Status',
                options: const [
                  'All Status',
                  'Writable',
                  'Pending approval',
                  'Synced',
                  'Not staged',
                ],
                onSelected: (value) => setState(() => _statusFilter = value),
                onClear: () => setState(() => _statusFilter = 'All Status'),
              ),
              const SizedBox(width: 8),
              _ZoneFilterChip(
                label: 'Sort',
                value: _sortMode,
                activeWhen: 'Name A-Z',
                options: const [
                  'Name A-Z',
                  'Name Z-A',
                  'Type A-Z',
                  'Type Z-A',
                  'Client A-Z',
                  'Client Z-A',
                ],
                onSelected: (value) => setState(() => _sortMode = value),
                onClear: () => setState(() => _sortMode = 'Name A-Z'),
              ),
              if (_hasActiveZoneFilters) ...[
                const SizedBox(width: 10),
                TextButton.icon(
                  onPressed: _clearZoneFilters,
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

  bool get _hasActiveZoneFilters =>
      _searchQuery.isNotEmpty ||
      _typeFilter != 'All Types' ||
      _sourceFilter != 'All Sources' ||
      _statusFilter != 'All Status' ||
      _sortMode != 'Name A-Z';

  void _clearZoneFilters() {
    setState(() {
      _searchQuery = '';
      _typeFilter = 'All Types';
      _sourceFilter = 'All Sources';
      _statusFilter = 'All Status';
      _sortMode = 'Name A-Z';
    });
  }

  int _compareZoneText(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
    String field,
  ) {
    final valueA = field == 'zoneType'
        ? readableZoneType(a['zoneType'] ?? a['type'])
        : a[field];
    final valueB = field == 'zoneType'
        ? readableZoneType(b['zoneType'] ?? b['type'])
        : b[field];
    return (valueA?.toString().toLowerCase() ?? '').compareTo(
      valueB?.toString().toLowerCase() ?? '',
    );
  }

  Future<void> _openZoneEditor({Map<String, dynamic>? zone}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ZoneEditorDialog(zone: zone),
    );
    if (saved == true) {
      _loadZones(forceRefresh: true);
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> zone) async {
    final zoneName = (zone['name'] ?? 'This zone').toString();
    final hasGeoTabSync = _hasGeotabSync(zone);
    if (!hasGeoTabSync && zone['pendingWriteJobId'] != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            'This zone has a GeoTab push awaiting review. Cancel or reject the push before deleting it.',
          ),
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(hasGeoTabSync ? 'Remove synced zone?' : 'Delete zone?'),
        content: Text(
          hasGeoTabSync
              ? '$zoneName is synced with GeoTab. Review the removal payload next; after confirmation, removal will be staged for administrator approval.'
              : 'Delete $zoneName? This local-only zone has never been pushed to GeoTab and will be permanently removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(hasGeoTabSync ? 'Review Removal' : 'Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final zoneId = (zone['id'] ?? '').toString();
    if (zoneId.isEmpty) return;

    if (hasGeoTabSync) {
      try {
        final preview = await BackendApiService.deleteFleetZone(
          zoneId,
          previewOnly: true,
        );
        if (!mounted) return;
        final approved = await showGeotabPushPreview(
          context: context,
          entityType: 'Zone Removal',
          entityName: zoneName,
          payload: preview['preview'],
          snapshot: preview['geotabSnapshot'],
          previewPayload: preview['previewPayload'],
        );
        if (approved != true) return;
      } catch (error) {
        if (!mounted) return;
        _showDeleteError(error);
        return;
      }
    }

    final previousZones = List<Map<String, dynamic>>.from(_zones);
    setState(() {
      _zones = _zones.where((entry) => entry['id'] != zoneId).toList();
    });
    try {
      await BackendApiService.deleteFleetZone(
        zoneId,
        confirmedPreview: hasGeoTabSync,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            hasGeoTabSync
                ? 'Zone removal staged for GeoTab approval.'
                : 'Local zone deleted.',
          ),
        ),
      );
      _loadZones(forceRefresh: true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _zones = previousZones);
      _showDeleteError(error);
    }
  }

  bool _hasGeotabSync(Map<String, dynamic> zone) {
    final geotabId = zone['geotabZoneId']?.toString().trim() ?? '';
    return geotabId.isNotEmpty || zone['geotabSnapshot'] != null;
  }

  void _showDeleteError(Object error) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          FormValidation.backendError(error, 'Zone could not be deleted.'),
        ),
      ),
    );
  }

  Future<void> _pushZoneToGeotab(Map<String, dynamic> zone) async {
    final zoneId = (zone['id'] ?? '').toString();
    final preview = await BackendApiService.pushFleetZoneToGeotab(
      zoneId,
      previewOnly: true,
    );
    if (!mounted) return;
    if (!await guardGeotabPushPreview(context: context, preview: preview)) {
      return;
    }
    final confirmed = await showGeotabPushPreview(
      context: context,
      entityType: 'Zone',
      entityName: (zone['name'] ?? zoneId).toString(),
      payload: preview['preview'],
      snapshot: preview['geotabSnapshot'],
      previewPayload: preview['previewPayload'],
    );
    if (confirmed != true) return;

    await BackendApiService.pushFleetZoneToGeotab(zoneId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('GeoTab push request staged for admin approval.'),
      ),
    );
    _loadZones(forceRefresh: true);
  }

  Future<void> _showZoneMap(Map<String, dynamic> zone) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: SizedBox(
          width: 720,
          height: 520,
          child: _ZoneMapPreview(zone: zone),
        ),
      ),
    );
  }

  Widget _buildZoneSummaryCards(bool isDark, bool isMobile) {
    final synced = _zones.where((zone) => zone['syncStatus'] == 'synced').length;
    final pending = _zones
        .where((zone) => zone['syncStatus'] == 'pending_approval')
        .length;
    final local = _zones.where((zone) => zone['managedLocally'] == true).length;
    final pointTotal = _zones.fold<int>(
      0,
      (sum, zone) => sum + (((zone['points'] as List?) ?? const []).length),
    );
    final cards = [
      _ZoneSummaryData(
        title: 'Managed zones',
        value: '${_zones.length}',
        subtitle: 'delivery geofences',
        icon: Icons.hexagon_rounded,
        color: AppTheme.colorFF4B7BE5,
      ),
      _ZoneSummaryData(
        title: 'PioneerPath',
        value: '$local',
        subtitle: 'editable local zones',
        icon: Icons.edit_location_alt_rounded,
        color: AppTheme.successGreen,
      ),
      _ZoneSummaryData(
        title: 'GeoTab synced',
        value: '$synced',
        subtitle: '$pending pending approval',
        icon: Icons.cloud_done_rounded,
        color: AppTheme.colorFF00A8E8,
      ),
      _ZoneSummaryData(
        title: 'Points mapped',
        value: '$pointTotal',
        subtitle: 'boundary points',
        icon: Icons.polyline_rounded,
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
                child: _ZoneSummaryCard(data: card, isDark: isDark),
              ),
          ],
        );
      },
    );
  }
}

class _ZoneSearchField extends StatelessWidget {
  const _ZoneSearchField({
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
      style: TextStyle(
        fontSize: 14,
        color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
      ),
      decoration: InputDecoration(
        hintText: 'Search by zone name, client, or notes...',
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

class _ZoneViewToggle extends StatelessWidget {
  const _ZoneViewToggle({
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
          _ZoneViewToggleButton(
            icon: Icons.grid_view_rounded,
            active: gridActive,
            tooltip: 'Grid view',
            onTap: onGrid,
          ),
          _ZoneViewToggleButton(
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

class _ZoneViewToggleButton extends StatelessWidget {
  const _ZoneViewToggleButton({
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

class _ZoneResultCount extends StatelessWidget {
  const _ZoneResultCount({required this.count});

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
        '$count zones shown',
        style: const TextStyle(
          color: AppTheme.infoBlue,
          fontWeight: FontWeight.w900,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _ZoneFilterChip extends StatelessWidget {
  const _ZoneFilterChip({
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

class _ZoneSummaryData {
  const _ZoneSummaryData({
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

class _ZoneSummaryCard extends StatelessWidget {
  const _ZoneSummaryCard({required this.data, required this.isDark});

  final _ZoneSummaryData data;
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

class _ZoneCard extends StatelessWidget {
  const _ZoneCard({
    required this.zone,
    required this.onView,
    this.onEdit,
    this.onDelete,
    this.onPush,
  });

  final Map<String, dynamic> zone;
  final VoidCallback onView;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onPush;

  @override
  Widget build(BuildContext context) {
    final syncStatus = (zone['syncStatus'] ?? 'not_staged').toString();
    final pointCount = ((zone['points'] as List?) ?? const []).length;
    final zoneType = readableZoneType(zone['zoneType'] ?? zone['type']);
    final notes = zoneNotes(zone);
    final isMockZone =
        zone['meta'] is Map && zone['meta']['isMockZone'] == true;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final managed = zone['managedLocally'] == true;
    final accent = managed ? AppTheme.successGreen : AppTheme.colorFF00A8E8;
    return Container(
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
                child: Icon(Icons.hexagon_rounded, color: accent, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (zone['name'] ?? 'Unnamed zone').toString(),
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
                      managed ? 'PioneerPath managed' : 'GeoTab geofence',
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
                ...zone,
                'syncStatus': syncStatus,
              }, compact: true),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _ZoneFactPill(Icons.category_rounded, zoneType),
              _ZoneFactPill(
                Icons.business_rounded,
                (zone['clientName'] ?? 'No client').toString(),
              ),
              _ZoneFactPill(Icons.polyline_rounded, '$pointCount points'),
            ],
          ),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              notes,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: isDark ? AppTheme.gray400 : AppTheme.gray600,
              ),
            ),
          ],
          if (isMockZone) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              decoration: BoxDecoration(
                color: AppTheme.warningOrange.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: AppTheme.warningOrange.withValues(alpha: 0.32),
                ),
              ),
              child: const Text(
                'MOCK ZONE - UPDATE WITH ACTUAL BOUNDARY',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.warningOrange,
                ),
              ),
            ),
          ],
          if ((zone['syncError'] ?? '').toString().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              (zone['syncError'] ?? '').toString(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppTheme.errorRed, fontSize: 12),
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _ZoneActionButton(
                tooltip: 'View map',
                icon: Icons.map_rounded,
                onPressed: onView,
              ),
              _ZoneActionButton(
                tooltip: onEdit == null
                    ? 'Only PioneerPath-managed zones can be edited.'
                    : 'Edit zone',
                icon: Icons.edit_rounded,
                onPressed: onEdit,
              ),
              _ZoneActionButton(
                tooltip: onPush == null
                    ? 'GeoTab is already up to date.'
                    : 'Push to GeoTab',
                icon: Icons.cloud_upload_outlined,
                onPressed: onPush,
              ),
              _ZoneActionButton(
                tooltip: onDelete == null
                    ? 'Only local zones can be deleted.'
                    : 'Soft delete zone',
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

class _ZoneFactPill extends StatelessWidget {
  const _ZoneFactPill(this.icon, this.label);

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

class _ZoneActionButton extends StatelessWidget {
  const _ZoneActionButton({
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


class _ZoneEditorDialog extends StatefulWidget {
  const _ZoneEditorDialog({this.zone});

  final Map<String, dynamic>? zone;

  @override
  State<_ZoneEditorDialog> createState() => _ZoneEditorDialogState();
}

class _ZoneEditorDialogState extends State<_ZoneEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _clientName;
  late final TextEditingController _notes;
  late String _zoneType;
  late List<gmaps.LatLng> _points;
  bool _polygonClosed = false;
  bool _saving = false;

  bool get _editing => widget.zone != null;

  @override
  void initState() {
    super.initState();
    final zone = widget.zone ?? const <String, dynamic>{};
    _name = TextEditingController(text: zone['name']?.toString() ?? '');
    _clientName = TextEditingController(
      text: zone['clientName']?.toString() ?? '',
    );
    _notes = TextEditingController(text: zoneNotes(zone));
    _zoneType = readableZoneType(zone['zoneType'] ?? zone['type']);
    if (!_zoneTypeOptions.contains(_zoneType)) {
      _zoneType = 'Custom Zone';
    }
    _points = _pointsFrom(zone);
    _polygonClosed = _points.length >= 3;
  }

  @override
  void dispose() {
    _name.dispose();
    _clientName.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920, maxHeight: 760),
        child: Container(
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
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.hexagon_rounded, color: AppTheme.white),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _editing ? 'Edit Zone' : 'New Zone',
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
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _name,
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? 'Zone name required'
                            : null,
                        decoration: const InputDecoration(
                          labelText: 'Zone name',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _zoneType,
                        hint: const Text('Select...'),
                        decoration: const InputDecoration(
                          labelText: 'Zone type',
                        ),
                        items: _zoneTypeOptions
                            .map(
                              (type) => DropdownMenuItem(
                                value: type,
                                child: Text(type),
                              ),
                            )
                            .toList(),
                        onChanged: (value) =>
                            setState(() => _zoneType = value ?? 'Custom Zone'),
                        validator: (value) => FormValidation.requiredSelection(
                          'zone type',
                          value,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _clientName,
                  decoration: const InputDecoration(
                    labelText: 'Client association',
                    hintText: 'Optional client name',
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _notes,
                  minLines: 2,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    hintText: 'Optional operating notes for this geofence',
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: PioneerGoogleMap(
                      initialCenter: _points.isNotEmpty
                          ? _points.first
                          : const gmaps.LatLng(14.2788, 121.1248),
                      initialZoom: 14,
                      onTap: (point) => setState(() {
                        if (_polygonClosed) {
                          return;
                        }
                        if (_points.isNotEmpty &&
                            _distanceMeters(_points.first, point) < 18 &&
                            _points.length >= 3) {
                          _polygonClosed = true;
                          return;
                        }
                        _points.add(point);
                      }),
                      markers: _points.asMap().entries.map((entry) {
                        return gmaps.Marker(
                          markerId: gmaps.MarkerId('zone-point-${entry.key}'),
                          position: entry.value,
                          infoWindow: gmaps.InfoWindow(
                            title: 'Point ${entry.key + 1}',
                          ),
                        );
                      }).toSet(),
                      polygons: _points.length >= 3
                          ? {
                              gmaps.Polygon(
                                polygonId: const gmaps.PolygonId('draft-zone'),
                                points: _points,
                                fillColor: AppTheme.primaryBlue.withValues(
                                  alpha: 0.16,
                                ),
                                strokeColor: AppTheme.primaryBlue,
                                strokeWidth: 3,
                              ),
                            }
                          : const <gmaps.Polygon>{},
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _points.length < 3
                            ? 'Tap the map to add at least 3 polygon points.'
                            : _polygonClosed
                            ? '${_points.length} polygon points closed. Center will be computed automatically.'
                            : '${_points.length} points added. Tap the first point again or press Done to close.',
                        style: AppTheme.getSubtitleStyle(context),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _points.length < 3
                          ? null
                          : () => setState(() => _polygonClosed = true),
                      icon: const Icon(Icons.check_circle_outline_rounded),
                      label: const Text('Done'),
                    ),
                    TextButton.icon(
                      onPressed: _points.isEmpty
                          ? null
                          : () => setState(() {
                              _polygonClosed = false;
                              _points.removeLast();
                            }),
                      icon: const Icon(Icons.undo_rounded),
                      label: const Text('Undo point'),
                    ),
                    TextButton.icon(
                      onPressed: _points.isEmpty
                          ? null
                          : () => setState(() {
                              _polygonClosed = false;
                              _points.clear();
                            }),
                      icon: const Icon(Icons.clear_rounded),
                      label: const Text('Clear'),
                    ),
                    FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_rounded),
                      label: const Text('Save'),
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

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_points.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Draw at least 3 polygon points.')),
      );
      return;
    }
    if (!_polygonClosed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Press Done to close the polygon.')),
      );
      return;
    }

    setState(() => _saving = true);
    final center = _center(_points);
    final payload = {
      'name': _name.text.trim(),
      'zoneType': _zoneType,
      'clientName': _clientName.text.trim(),
      'notes': _notes.text.trim(),
      'centerLatitude': center.latitude,
      'centerLongitude': center.longitude,
      'boundaryPoints': _points
          .map(
            (point) => {
              'latitude': point.latitude,
              'longitude': point.longitude,
            },
          )
          .toList(),
    };

    try {
      if (_editing) {
        await BackendApiService.updateFleetZone(
          (widget.zone!['id'] ?? '').toString(),
          payload,
        );
      } else {
        await BackendApiService.createFleetZone(payload);
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
            FormValidation.backendError(error, 'Zone could not be saved.'),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static List<gmaps.LatLng> _pointsFrom(Map<String, dynamic> zone) {
    final raw = (zone['points'] as List?) ?? (zone['boundaryPoints'] as List?);
    if (raw == null) return [];
    return raw
        .whereType<Map>()
        .map((point) {
          return gmaps.LatLng(
            double.tryParse(point['latitude']?.toString() ?? '') ?? 0,
            double.tryParse(point['longitude']?.toString() ?? '') ?? 0,
          );
        })
        .where((point) => point.latitude != 0 || point.longitude != 0)
        .toList();
  }

  static gmaps.LatLng _center(List<gmaps.LatLng> points) {
    final latitude =
        points.map((point) => point.latitude).reduce((a, b) => a + b) /
        points.length;
    final longitude =
        points.map((point) => point.longitude).reduce((a, b) => a + b) /
        points.length;
    return gmaps.LatLng(latitude, longitude);
  }

  static double _distanceMeters(gmaps.LatLng a, gmaps.LatLng b) {
    const earthRadius = 6371000.0;
    final dLat = (b.latitude - a.latitude) * 0.017453292519943295;
    final dLon = (b.longitude - a.longitude) * 0.017453292519943295;
    final lat1 = a.latitude * 0.017453292519943295;
    final lat2 = b.latitude * 0.017453292519943295;
    final h =
        (math.sin(dLat / 2) * math.sin(dLat / 2)) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return earthRadius * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
  }
}

class _ZoneMapPreview extends StatelessWidget {
  const _ZoneMapPreview({required this.zone});

  final Map<String, dynamic> zone;

  @override
  Widget build(BuildContext context) {
    final points = _ZoneEditorDialogState._pointsFrom(zone);
    final center = points.isNotEmpty
        ? _ZoneEditorDialogState._center(points)
        : const gmaps.LatLng(14.2788, 121.1248);
    return Stack(
      children: [
        PioneerGoogleMap(
          initialCenter: center,
          initialZoom: 15,
          polygons: points.length >= 3
              ? {
                  gmaps.Polygon(
                    polygonId: const gmaps.PolygonId('zone-preview'),
                    points: points,
                    fillColor: AppTheme.primaryBlue.withValues(alpha: 0.16),
                    strokeColor: AppTheme.primaryBlue,
                    strokeWidth: 3,
                  ),
                }
              : const <gmaps.Polygon>{},
        ),
        Positioned(
          top: 12,
          left: 12,
          right: 12,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '${zone['name'] ?? 'Zone'} • ${readableZoneType(zone['zoneType'] ?? zone['type'])}',
                style: AppTheme.getHeadingStyle(context, fontSize: 14),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
