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
  String _typeFilter = 'All Types';
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
      actions: [
        IconButton(
          tooltip: 'Refresh zones',
          onPressed: () => _loadZones(forceRefresh: true),
          icon: const Icon(Icons.refresh_rounded),
        ),
        if (CrudPermissions.canCreate(CrudEntity.zones))
          FilledButton.icon(
            onPressed: () => _openZoneEditor(),
            icon: const Icon(Icons.add_location_alt_rounded, size: 18),
            label: const Text('New Zone'),
          ),
      ],
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    final zones = _filteredZones;
    if (_loading) {
      return const PioneerRouteSkeletonBody(routeName: '/zones');
    }

    return RefreshIndicator(
      onRefresh: () => _loadZones(forceRefresh: true),
      child: ListView(
        padding: const EdgeInsets.all(20),
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
          _ZoneSummary(zones: _zones),
          const SizedBox(height: 12),
          _buildZoneControls(),
          const SizedBox(height: 12),
          if (zones.isEmpty)
            PioneerStateCard(
              icon: Icons.hexagon_rounded,
              title: 'No managed zones yet',
              message:
                  'Draw customer sites, depots, rest stops, or restricted areas so dispatch and live tracking can show delivery geofences.',
              actionLabel: CrudPermissions.canCreate(CrudEntity.zones)
                  ? 'Create zone'
                  : null,
              onAction: CrudPermissions.canCreate(CrudEntity.zones)
                  ? () => _openZoneEditor()
                  : null,
            )
          else
            ...zones.map(
              (zone) => _ZoneCard(
                zone: zone,
                onEdit:
                    CrudPermissions.canEdit(CrudEntity.zones) &&
                        zone['managedLocally'] == true
                    ? () => _openZoneEditor(zone: zone)
                    : null,
                onDelete:
                    CrudPermissions.canDelete(CrudEntity.zones) &&
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
      ),
    );
  }

  List<Map<String, dynamic>> get _filteredZones {
    var zones = _zones;
    if (_typeFilter != 'All Types') {
      zones = zones.where((zone) {
        final type = readableZoneType(zone['zoneType'] ?? zone['type']);
        return type.toLowerCase() == _typeFilter.toLowerCase();
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

  Widget _buildZoneControls() {
    final types = {
      'All Types',
      ..._zones.map(
        (zone) => readableZoneType(zone['zoneType'] ?? zone['type']),
      ),
    }.where((value) => value.trim().isNotEmpty).toList()..sort();
    final safeTypeFilter = types.contains(_typeFilter)
        ? _typeFilter
        : 'All Types';
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        SizedBox(
          width: 220,
          child: DropdownButtonFormField<String>(
            initialValue: safeTypeFilter,
            decoration: const InputDecoration(labelText: 'Type'),
            items: types
                .map((type) => DropdownMenuItem(value: type, child: Text(type)))
                .toList(),
            onChanged: (value) =>
                setState(() => _typeFilter = value ?? 'All Types'),
          ),
        ),
        SizedBox(
          width: 220,
          child: DropdownButtonFormField<String>(
            initialValue: _sortMode,
            decoration: const InputDecoration(labelText: 'Sort zones'),
            items: const [
              DropdownMenuItem(value: 'Name A-Z', child: Text('Name A-Z')),
              DropdownMenuItem(value: 'Name Z-A', child: Text('Name Z-A')),
              DropdownMenuItem(value: 'Type A-Z', child: Text('Type A-Z')),
              DropdownMenuItem(value: 'Type Z-A', child: Text('Type Z-A')),
              DropdownMenuItem(value: 'Client A-Z', child: Text('Client A-Z')),
              DropdownMenuItem(value: 'Client Z-A', child: Text('Client Z-A')),
            ],
            onChanged: (value) =>
                setState(() => _sortMode = value ?? 'Name A-Z'),
          ),
        ),
      ],
    );
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
}

class _ZoneSummary extends StatelessWidget {
  const _ZoneSummary({required this.zones});

  final List<Map<String, dynamic>> zones;

  @override
  Widget build(BuildContext context) {
    final local = zones.length;
    final synced = zones.where((zone) => zone['syncStatus'] == 'synced').length;
    final pending = zones
        .where((zone) => zone['syncStatus'] == 'pending_approval')
        .length;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _summaryTile(context, 'Managed zones', '$local', Icons.hexagon_rounded),
        _summaryTile(context, 'GeoTab synced', '$synced', Icons.cloud_done),
        _summaryTile(context, 'Pending approval', '$pending', Icons.pending),
      ],
    );
  }

  Widget _summaryTile(
    BuildContext context,
    String label,
    String value,
    IconData icon,
  ) {
    return Container(
      width: 240,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.getCardBg(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.getBorderColor(context)),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.primaryBlue),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value, style: AppTheme.getHeadingStyle(context)),
                Text(label, style: AppTheme.getSubtitleStyle(context)),
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
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.getCardBg(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.getBorderColor(context)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppTheme.primaryBlue.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.hexagon_rounded,
              color: AppTheme.primaryBlue,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (zone['name'] ?? 'Unnamed zone').toString(),
                  style: AppTheme.getHeadingStyle(context, fontSize: 16),
                ),
                const SizedBox(height: 4),
                Text(
                  '$zoneType • ${zone['clientName'] ?? 'No client'} • $pointCount points',
                  style: AppTheme.getSubtitleStyle(context),
                ),
                if (notes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      notes,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.getSubtitleStyle(context),
                    ),
                  ),
                if (isMockZone)
                  Container(
                    margin: const EdgeInsets.only(top: 7),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
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
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.warningOrange,
                      ),
                    ),
                  ),
                if ((zone['syncError'] ?? '').toString().isNotEmpty)
                  Text(
                    (zone['syncError'] ?? '').toString(),
                    style: const TextStyle(color: AppTheme.errorRed),
                  ),
              ],
            ),
          ),
          GeoTabSyncStatusBadge.fromEntity({
            ...zone,
            'syncStatus': syncStatus,
          }, compact: true),
          IconButton(
            tooltip: 'View map',
            onPressed: onView,
            icon: const Icon(Icons.map_rounded),
          ),
          IconButton(
            tooltip: 'Edit zone',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_rounded),
          ),
          IconButton(
            tooltip: onPush == null
                ? 'GeoTab is already up to date.'
                : 'Push to GeoTab',
            onPressed: onPush,
            icon: const Icon(Icons.cloud_upload_outlined),
          ),
          IconButton(
            tooltip: 'Soft delete zone',
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
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
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920, maxHeight: 760),
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
                      child: Text(
                        _editing ? 'Edit zone' : 'New zone',
                        style: AppTheme.getHeadingStyle(context, fontSize: 20),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
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
