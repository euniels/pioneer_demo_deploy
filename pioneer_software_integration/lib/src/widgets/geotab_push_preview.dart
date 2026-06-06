import 'dart:convert';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

const String noGeotabChangesMessage =
    'No changes to push. GeoTab already has the current version of this record.';

Future<bool> guardGeotabPushPreview({
  required BuildContext context,
  required Map<String, dynamic> preview,
}) async {
  if (preview['geotabAlreadyUpToDate'] == true) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text(noGeotabChangesMessage)));
    return false;
  }

  if (preview['hasPendingGeotabPush'] != true) {
    return true;
  }

  final submitAnyway = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('Push already waiting'),
      content: const Text(
        'A push for this record is already waiting for approval.\n\n'
        'Submitting another push will create a second job in the queue.\n'
        'You may want to wait for the current job to be processed first.\n\n'
        'Do you want to submit anyway?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        OutlinedButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.add_task_rounded),
          label: const Text('Submit Anyway'),
        ),
      ],
    ),
  );

  return submitAnyway == true;
}

Future<bool?> showGeotabPushPreview({
  required BuildContext context,
  required String entityType,
  required String entityName,
  required Object? payload,
  required Object? snapshot,
  Object? previewPayload,
}) {
  final storedPreview = _previewMap(previewPayload);
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(
        'Push ${storedPreview?['entityType']?.toString() ?? entityType} to GeoTab?',
      ),
      content: GeotabPushPreviewContent(
        entityType: storedPreview?['entityType']?.toString() ?? entityType,
        entityName: storedPreview?['entityName']?.toString() ?? entityName,
        payload: storedPreview?['payload'] ?? payload,
        snapshot: storedPreview?['snapshot'] ?? snapshot,
        previewRows: _previewRows(storedPreview),
        previewGroups: _previewGroups(storedPreview),
        isFirstPushOverride: storedPreview?['isFirstPush'] == true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        OutlinedButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.cloud_upload_outlined),
          label: const Text('Confirm Push to GeoTab'),
        ),
      ],
    ),
  );
}

class GeotabPushPreviewContent extends StatelessWidget {
  const GeotabPushPreviewContent({
    super.key,
    required this.entityType,
    required this.entityName,
    required this.payload,
    required this.snapshot,
    this.previewRows,
    this.previewGroups,
    this.isFirstPushOverride,
  });

  final String entityType;
  final String entityName;
  final Object? payload;
  final Object? snapshot;
  final List<Map<String, dynamic>>? previewRows;
  final List<Map<String, dynamic>>? previewGroups;
  final bool? isFirstPushOverride;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final payloadMap = _asMap(payload);
    final snapshotMap = _asMap(snapshot);
    final isFirstPush =
        isFirstPushOverride ?? (snapshotMap == null || snapshotMap.isEmpty);
    final rows = previewRows == null
        ? _changedRows(payloadMap, snapshotMap)
        : _rowsFromStoredPreview(previewRows!);
    final groupedSections = previewGroups
        ?.map((group) => _PreviewGroup.fromMap(group))
        .where((group) => group.rows.isNotEmpty || group.isFirstPush)
        .toList();
    final isGrouped = groupedSections != null && groupedSections.isNotEmpty;

    return SizedBox(
      width: 760,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 620),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _sectionTitle('What is being pushed'),
              const SizedBox(height: 8),
              _identityRow('Entity type', entityType),
              _identityRow('Entity name', entityName),
              const SizedBox(height: 12),
              if (isGrouped)
                ...groupedSections.map(
                  (group) => Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: _groupComparison(context, group),
                  ),
                )
              else ...[
                if (isFirstPush)
                  _firstPushNotice()
                else if (rows.isEmpty)
                  const Text(
                    'No changed fields were found in the GeoTab payload.',
                  ),
                if (rows.isNotEmpty)
                  _comparisonTable(context, rows, isFirstPush),
              ],
              const SizedBox(height: 16),
              _sectionTitle('Warning about GeoTab edits'),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark
                      ? AppTheme.warningOrange.withValues(alpha: 0.16)
                      : AppTheme.colorFFFFF6E6,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.warningOrange),
                ),
                child: const Text(
                  'Data pushed to GeoTab is difficult to change after submission. '
                  'Please verify all fields carefully before confirming. '
                  'Incorrect data will require GeoTab administrator access to correct.',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(height: 16),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Actual GeoTab API payload'),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      const JsonEncoder.withIndent(
                        '  ',
                      ).convert(payloadMap ?? {}),
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String value) {
    return Text(
      value,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
    );
  }

  Widget _identityRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(child: Text(value.isEmpty ? 'N/A' : value)),
        ],
      ),
    );
  }

  Widget _firstPushNotice() {
    return const Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: Text(
        'New - does not exist in GeoTab yet. All payload fields below will be created.',
        style: TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _groupComparison(BuildContext context, _PreviewGroup group) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${group.entityType}: ${group.entityName}',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 6),
        if (group.isFirstPush) _firstPushNotice(),
        if (group.rows.isEmpty && !group.isFirstPush)
          const Text('No changed fields were found for this entity.'),
        if (group.rows.isNotEmpty)
          _comparisonTable(context, group.rows, group.isFirstPush),
      ],
    );
  }

  Widget _comparisonTable(
    BuildContext context,
    List<_PreviewRow> rows,
    bool isFirstPush,
  ) {
    return Table(
      columnWidths: const {
        0: FlexColumnWidth(1.2),
        1: FlexColumnWidth(1.4),
        2: FlexColumnWidth(1.4),
      },
      border: TableBorder.all(color: Theme.of(context).dividerColor),
      children: [
        _tableRow(const [
          'Field name',
          'Current value in GeoTab',
          'New value to be pushed',
        ], header: true),
        ...rows.map(
          (row) => _tableRow([
            row.field,
            isFirstPush ? 'Not in GeoTab' : row.before,
            row.after,
          ]),
        ),
      ],
    );
  }

  TableRow _tableRow(List<String> cells, {bool header = false}) {
    return TableRow(
      children: cells
          .map(
            (cell) => Padding(
              padding: const EdgeInsets.all(8),
              child: SelectableText(
                cell,
                style: TextStyle(
                  fontWeight: header ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
            ),
          )
          .toList(),
    );
  }

  List<_PreviewRow> _changedRows(
    Map<String, dynamic>? payloadMap,
    Map<String, dynamic>? snapshotMap,
  ) {
    final after = _flatten(payloadMap ?? {});
    final before = _flatten(snapshotMap ?? {});
    final isFirstPush = snapshotMap == null || snapshotMap.isEmpty;
    final rows = <_PreviewRow>[];
    after.forEach((field, value) {
      final oldValue = before[field] ?? '';
      if (isFirstPush || oldValue != value) {
        rows.add(_PreviewRow(field, oldValue, value));
      }
    });
    rows.sort((a, b) => a.field.compareTo(b.field));

    return rows;
  }

  List<_PreviewRow> _rowsFromStoredPreview(
    List<Map<String, dynamic>> storedRows,
  ) {
    final rows = storedRows
        .map(
          (row) => _PreviewRow(
            row['field']?.toString() ?? '',
            row['before']?.toString() ?? '',
            row['after']?.toString() ?? '',
          ),
        )
        .where((row) => row.field.isNotEmpty)
        .toList();
    rows.sort((a, b) => a.field.compareTo(b.field));
    return rows;
  }

  Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), item));
    }
    if (value is String && value.trim().isNotEmpty) {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        return decoded.map((key, item) => MapEntry(key.toString(), item));
      }
    }

    return null;
  }

  Map<String, String> _flatten(Object? value, [String prefix = '']) {
    final rows = <String, String>{};
    if (value is Map) {
      value.forEach((key, item) {
        final next = prefix.isEmpty
            ? key.toString()
            : '$prefix.${key.toString()}';
        rows.addAll(_flatten(item, next));
      });
    } else if (value is List) {
      for (var index = 0; index < value.length; index += 1) {
        rows.addAll(_flatten(value[index], '$prefix[$index]'));
      }
    } else if (prefix.isNotEmpty) {
      rows[prefix] = _displayValue(value);
    }

    return rows;
  }

  String _displayValue(Object? value) {
    if (value == null) {
      return 'N/A';
    }
    if (value is String && value.trim().isEmpty) {
      return 'N/A';
    }
    if (value is num || value is bool || value is String) {
      return value.toString();
    }

    return jsonEncode(value);
  }
}

class _PreviewRow {
  const _PreviewRow(this.field, this.before, this.after);

  final String field;
  final String before;
  final String after;
}

class _PreviewGroup {
  const _PreviewGroup({
    required this.entityType,
    required this.entityName,
    required this.rows,
    required this.isFirstPush,
  });

  factory _PreviewGroup.fromMap(Map<String, dynamic> value) {
    final rows =
        ((value['rows'] as List?) ?? const [])
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .map(
              (row) => _PreviewRow(
                row['field']?.toString() ?? '',
                row['before']?.toString() ?? '',
                row['after']?.toString() ?? '',
              ),
            )
            .where((row) => row.field.isNotEmpty)
            .toList()
          ..sort((a, b) => a.field.compareTo(b.field));

    return _PreviewGroup(
      entityType: value['entityType']?.toString() ?? 'GeoTab entity',
      entityName: value['entityName']?.toString() ?? 'N/A',
      rows: rows,
      isFirstPush: value['isFirstPush'] == true,
    );
  }

  final String entityType;
  final String entityName;
  final List<_PreviewRow> rows;
  final bool isFirstPush;
}

Map<String, dynamic>? _previewMap(Object? value) {
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return null;
}

List<Map<String, dynamic>>? _previewRows(Map<String, dynamic>? value) {
  return ((value?['rows'] as List?) ?? const [])
      .whereType<Map>()
      .map((row) => Map<String, dynamic>.from(row))
      .toList();
}

List<Map<String, dynamic>>? _previewGroups(Map<String, dynamic>? value) {
  return ((value?['groups'] as List?) ?? const [])
      .whereType<Map>()
      .map((group) => Map<String, dynamic>.from(group))
      .toList();
}
