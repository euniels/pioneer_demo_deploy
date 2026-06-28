import 'package:flutter/material.dart';

import '../services/backend_api.dart';
import '../theme/app_theme.dart';
import '../widgets/admin_page_controls.dart';
import '../widgets/dashboard_layout.dart';
import '../widgets/page_skeletons.dart';

class AuditLogPage extends StatefulWidget {
  const AuditLogPage({super.key});

  @override
  State<AuditLogPage> createState() => _AuditLogPageState();
}

class _AuditLogPageState extends State<AuditLogPage> {
  late Future<PaginatedBackendList> _future;
  int _page = 1;
  final _actorController = TextEditingController();
  final _fromController = TextEditingController();
  final _toController = TextEditingController();
  String _entityType = 'all';
  String _actionType = 'all';
  String _sortMode = 'Date Newest';
  bool _filtersExpanded = false;
  DateTime? _lastLoadedAt;

  static const _entityTypes = [
    'all',
    'session',
    'user',
    'system_setting',
    'client',
    'geotab_write_job',
    'invoice',
  ];
  static const _actionTypes = [
    'all',
    'login',
    'login_failed',
    'create',
    'update',
    'delete',
    'role_change',
    'deactivate',
    'password_reset',
    'approved',
    'failed',
    'cancelled',
    'status_changed',
  ];

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void dispose() {
    _actorController.dispose();
    _fromController.dispose();
    _toController.dispose();
    super.dispose();
  }

  Future<PaginatedBackendList> _load({bool forceRefresh = false}) async {
    final page = await BackendApiService.getAuditLogsPage(
      page: _page,
      perPage: 25,
      forceRefresh: forceRefresh,
      actor: _actorController.text,
      from: _fromController.text,
      to: _toController.text,
      entityType: _entityType,
      actionType: _actionType,
    );
    _lastLoadedAt = DateTime.now();
    return page;
  }

  void _reload({bool resetPage = false}) {
    setState(() {
      if (resetPage) _page = 1;
      _future = _load(forceRefresh: true);
    });
  }

  Future<void> _pickDate(TextEditingController controller) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
    );
    if (picked == null) return;
    controller.text =
        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    _reload(resetPage: true);
  }

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      currentRoute: '/audit-logs',
      title: 'Audit Logs',
      subtitle: 'Read-only history of administrative and operational changes',
      child: FutureBuilder<PaginatedBackendList>(
        future: _future,
        builder: (context, snapshot) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const PioneerRouteSkeletonBody(routeName: '/audit-logs');
          }
          if (snapshot.hasError) {
            return _AuditEmptyState(
              isDark: isDark,
              title: 'Audit logs are unavailable',
              message:
                  'The backend could not return the audit trail right now.',
              actionLabel: 'Retry',
              onTap: () => _reload(),
            );
          }
          final page = snapshot.data;
          final entries = _sortedEntries(
            page?.items ?? const <Map<String, dynamic>>[],
          );
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: Container(
              color: isDark ? AppTheme.colorFF0A0E1A : AppTheme.colorFFF5F6F8,
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _buildFilterPanel(isDark),
                  const SizedBox(height: 18),
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1220),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          children: [
                            if (page != null) ...[
                              _buildAuditSummary(page, entries, isDark),
                              const SizedBox(height: 16),
                            ],
                            if (entries.isEmpty)
                              _AuditEmptyState(
                                isDark: isDark,
                                title: 'No audit entries found',
                                message:
                                    'Try widening the date range or clearing filters.',
                              )
                            else
                              ...entries.asMap().entries.map(
                                (indexed) => _AuditLogCard(
                                  entry: indexed.value,
                                  alternate: indexed.key.isOdd,
                                ),
                              ),
                            if (page != null && page.lastPage > 1) ...[
                              const SizedBox(height: 12),
                              _buildPagination(page, isDark),
                            ],
                            const SizedBox(height: 24),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildFilterPanel(bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 16),
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
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1220),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 760;
                  final actorSearch = _AuditSearchField(
                    controller: _actorController,
                    onChanged: (_) => _reload(resetPage: true),
                    onClear: () {
                      _actorController.clear();
                      _reload(resetPage: true);
                    },
                  );
                  final filterButton = _AuditActionButton(
                    icon: _filtersExpanded
                        ? Icons.filter_alt_off_rounded
                        : Icons.tune_rounded,
                    label: _filtersExpanded ? 'Hide filters' : 'Filters',
                    color: AppTheme.primaryBlue,
                    onTap: () =>
                        setState(() => _filtersExpanded = !_filtersExpanded),
                  );

                  if (compact) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        actorSearch,
                        const SizedBox(height: 12),
                        filterButton,
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(child: actorSearch),
                      const SizedBox(width: 14),
                      filterButton,
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _AuditResultCount(activeCount: _activeFilterCount),
                      const SizedBox(width: 10),
                      _AuditFilterChip(
                        label: 'Entity',
                        value: _entityType,
                        activeWhen: 'all',
                        displayValue: _entityType == 'all'
                            ? 'All entities'
                            : _label(_entityType),
                        options: {
                          for (final value in _entityTypes)
                            value: value == 'all'
                                ? 'All entities'
                                : _label(value),
                        },
                        onSelected: (value) {
                          _entityType = value;
                          _reload(resetPage: true);
                        },
                        onClear: () {
                          _entityType = 'all';
                          _reload(resetPage: true);
                        },
                      ),
                      const SizedBox(width: 8),
                      _AuditFilterChip(
                        label: 'Action',
                        value: _actionType,
                        activeWhen: 'all',
                        displayValue: _actionType == 'all'
                            ? 'All actions'
                            : _label(_actionType),
                        options: {
                          for (final value in _actionTypes)
                            value: value == 'all'
                                ? 'All actions'
                                : _label(value),
                        },
                        onSelected: (value) {
                          _actionType = value;
                          _reload(resetPage: true);
                        },
                        onClear: () {
                          _actionType = 'all';
                          _reload(resetPage: true);
                        },
                      ),
                      const SizedBox(width: 8),
                      _AuditFilterChip(
                        label: 'Sort',
                        value: _sortMode,
                        activeWhen: 'Date Newest',
                        displayValue: _sortMode,
                        options: const {
                          'Date Newest': 'Date Newest',
                          'Date Oldest': 'Date Oldest',
                          'Entity A-Z': 'Entity A-Z',
                          'Entity Z-A': 'Entity Z-A',
                          'Actor A-Z': 'Actor A-Z',
                          'Actor Z-A': 'Actor Z-A',
                        },
                        onSelected: (value) {
                          _sortMode = value;
                          _reload(resetPage: true);
                        },
                        onClear: () {
                          _sortMode = 'Date Newest';
                          _reload(resetPage: true);
                        },
                      ),
                      if (_hasActiveFilters) ...[
                        const SizedBox(width: 8),
                        _AuditActionButton(
                          icon: Icons.close_rounded,
                          label: 'Clear All',
                          color: AppTheme.errorRed,
                          onTap: _clearFilters,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                alignment: Alignment.topCenter,
                child: !_filtersExpanded
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: _buildFilters(isDark),
                      ),
              ),
              if (_hasActiveFilters) ...[
                const SizedBox(height: AppTheme.space10),
                _buildActiveFilterBar(isDark),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAuditSummary(
    PaginatedBackendList page,
    List<Map<String, dynamic>> entries,
    bool isDark,
  ) {
    final securityEvents = entries.where(_isSecurityEvent).length;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF171B23 : AppTheme.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.08)
              : AppTheme.black.withValues(alpha: 0.08),
        ),
        boxShadow: AppTheme.getCardShadow(context),
      ),
      child: Wrap(
        spacing: AppTheme.space8,
        runSpacing: AppTheme.space8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _summaryPill(
            icon: Icons.receipt_long_rounded,
            label: '${page.total} audit results',
            color: AppTheme.primaryBlue,
            isDark: isDark,
          ),
          _summaryPill(
            icon: Icons.filter_alt_rounded,
            label: '$_activeFilterCount active filters',
            color: _activeFilterCount == 0
                ? AppTheme.neutralGray
                : AppTheme.infoBlue,
            isDark: isDark,
          ),
          _summaryPill(
            icon: Icons.security_rounded,
            label: '$securityEvents security events on this page',
            color: securityEvents == 0
                ? AppTheme.neutralGray
                : AppTheme.warningOrange,
            isDark: isDark,
          ),
          _summaryPill(
            icon: Icons.description_rounded,
            label: 'Page ${page.currentPage} of ${page.lastPage}',
            color: AppTheme.pioneerDeepBlue,
            isDark: isDark,
          ),
          _summaryPill(
            icon: Icons.update_rounded,
            label: 'Last refresh: ${_lastRefreshLabel()}',
            color: AppTheme.successGreen,
            isDark: isDark,
          ),
        ],
      ),
    );
  }

  Widget _summaryPill({
    required IconData icon,
    required String label,
    required Color color,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.16 : 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: isDark ? AppTheme.white : color,
            ),
          ),
        ],
      ),
    );
  }

  String _lastRefreshLabel() {
    final value = _lastLoadedAt;
    if (value == null) {
      return 'Not loaded';
    }
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    final second = value.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  bool _isSecurityEvent(Map<String, dynamic> entry) {
    return _AuditLogCard.securityEventLabel(entry) != null;
  }

  Widget _buildFilters(bool isDark) {
    return Wrap(
      spacing: AppTheme.space12,
      runSpacing: AppTheme.space12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _filterField(
          width: 240,
          child: TextField(
            controller: _actorController,
            onChanged: (_) => _reload(resetPage: true),
            onSubmitted: (_) => _reload(resetPage: true),
            decoration: _decoration(
              isDark,
              const Icon(Icons.person_search_rounded),
              'Actor name or role',
            ),
          ),
        ),
        _filterField(
          width: 180,
          child: TextField(
            controller: _fromController,
            readOnly: true,
            onTap: () => _pickDate(_fromController),
            decoration: _decoration(
              isDark,
              const Icon(Icons.date_range_rounded),
              'From date',
            ),
          ),
        ),
        _filterField(
          width: 180,
          child: TextField(
            controller: _toController,
            readOnly: true,
            onTap: () => _pickDate(_toController),
            decoration: _decoration(
              isDark,
              const Icon(Icons.event_rounded),
              'To date',
            ),
          ),
        ),
        _filterField(
          width: 240,
          child: DropdownButtonFormField<String>(
            initialValue: _entityType,
            isExpanded: true,
            decoration: _decoration(
              isDark,
              const Icon(Icons.category_rounded),
              'Entity type',
            ),
            items: _entityTypes
                .map(
                  (value) => DropdownMenuItem(
                    value: value,
                    child: Text(
                      _label(value),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: (value) {
              _entityType = value ?? 'all';
              _reload(resetPage: true);
            },
          ),
        ),
        _filterField(
          width: 260,
          child: DropdownButtonFormField<String>(
            initialValue: _actionType,
            isExpanded: true,
            decoration: _decoration(
              isDark,
              const Icon(Icons.rule_rounded),
              'Action type',
            ),
            items: _actionTypes
                .map(
                  (value) => DropdownMenuItem(
                    value: value,
                    child: Text(
                      _label(value),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: (value) {
              _actionType = value ?? 'all';
              _reload(resetPage: true);
            },
          ),
        ),
        _filterField(
          width: 240,
          child: DropdownButtonFormField<String>(
            initialValue: _sortMode,
            isExpanded: true,
            decoration: _decoration(
              isDark,
              const Icon(Icons.sort_rounded),
              'Sort',
            ),
            items: const [
              DropdownMenuItem(
                value: 'Date Newest',
                child: Text(
                  'Date Newest',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              DropdownMenuItem(
                value: 'Date Oldest',
                child: Text(
                  'Date Oldest',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              DropdownMenuItem(
                value: 'Entity A-Z',
                child: Text(
                  'Entity A-Z',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              DropdownMenuItem(
                value: 'Entity Z-A',
                child: Text(
                  'Entity Z-A',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              DropdownMenuItem(
                value: 'Actor A-Z',
                child: Text(
                  'Actor A-Z',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              DropdownMenuItem(
                value: 'Actor Z-A',
                child: Text(
                  'Actor Z-A',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            onChanged: (value) {
              _sortMode = value ?? 'Date Newest';
              _reload(resetPage: true);
            },
          ),
        ),
      ],
    );
  }

  Widget _filterField({required double width, required Widget child}) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: width, minWidth: width),
      child: child,
    );
  }

  bool get _hasActiveFilters =>
      _actorController.text.trim().isNotEmpty ||
      _fromController.text.trim().isNotEmpty ||
      _toController.text.trim().isNotEmpty ||
      _entityType != 'all' ||
      _actionType != 'all' ||
      _sortMode != 'Date Newest';

  int get _activeFilterCount {
    var count = 0;
    if (_actorController.text.trim().isNotEmpty) count++;
    if (_fromController.text.trim().isNotEmpty) count++;
    if (_toController.text.trim().isNotEmpty) count++;
    if (_entityType != 'all') count++;
    if (_actionType != 'all') count++;
    if (_sortMode != 'Date Newest') count++;
    return count;
  }

  void _clearFilters() {
    _actorController.clear();
    _fromController.clear();
    _toController.clear();
    _entityType = 'all';
    _actionType = 'all';
    _sortMode = 'Date Newest';
    _reload(resetPage: true);
  }

  Widget _buildActiveFilterBar(bool isDark) {
    final chips = <Widget>[];
    void addChip(String label) {
      chips.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppTheme.colorFF1A3A6B.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.35),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: isDark ? AppTheme.white : AppTheme.colorFF1A3A6B,
            ),
          ),
        ),
      );
    }

    if (_actorController.text.trim().isNotEmpty) {
      addChip('Actor: ${_actorController.text.trim()}');
    }
    if (_fromController.text.trim().isNotEmpty) {
      addChip('From: ${_fromController.text.trim()}');
    }
    if (_toController.text.trim().isNotEmpty) {
      addChip('To: ${_toController.text.trim()}');
    }
    if (_entityType != 'all') {
      addChip('Entity: ${_label(_entityType)}');
    }
    if (_actionType != 'all') {
      addChip('Action: ${_label(_actionType)}');
    }
    if (_sortMode != 'Date Newest') {
      addChip('Sort: $_sortMode');
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ...chips,
        TextButton.icon(
          onPressed: _clearFilters,
          icon: const Icon(Icons.close_rounded, size: 16),
          label: const Text('Clear All'),
        ),
      ],
    );
  }

  Widget _buildPagination(PaginatedBackendList page, bool isDark) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          'Page ${page.currentPage} of ${page.lastPage}',
          style: TextStyle(
            color: isDark ? AppTheme.white70 : AppTheme.colorFF64748B,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 12),
        IconButton(
          onPressed: page.previousPage == null
              ? null
              : () {
                  _page = page.previousPage!;
                  _reload();
                },
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        IconButton(
          onPressed: page.nextPage == null
              ? null
              : () {
                  _page = page.nextPage!;
                  _reload();
                },
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ],
    );
  }

  InputDecoration _decoration(bool isDark, Widget icon, String hint) {
    return InputDecoration(
      prefixIcon: icon,
      hintText: hint,
      filled: true,
      fillColor: isDark ? AppTheme.colorFF141924 : AppTheme.colorFFF8FAFC,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    );
  }

  String _label(String value) {
    if (value == 'all') return 'All';
    return value
        .split('_')
        .map(
          (part) => part.isEmpty
              ? part
              : '${part[0].toUpperCase()}${part.substring(1)}',
        )
        .join(' ');
  }

  List<Map<String, dynamic>> _sortedEntries(List<Map<String, dynamic>> rows) {
    final sorted = List<Map<String, dynamic>>.from(rows);
    sorted.sort((a, b) {
      return switch (_sortMode) {
        'Date Oldest' => _compareAuditDates(a, b, newestFirst: false),
        'Entity A-Z' => _compareAuditText(a, b, 'entityType'),
        'Entity Z-A' => _compareAuditText(b, a, 'entityType'),
        'Actor A-Z' => _compareAuditText(a, b, 'actorName'),
        'Actor Z-A' => _compareAuditText(b, a, 'actorName'),
        _ => _compareAuditDates(a, b, newestFirst: true),
      };
    });
    return sorted;
  }

  int _compareAuditDates(
    Map<String, dynamic> a,
    Map<String, dynamic> b, {
    required bool newestFirst,
  }) {
    final dateA = DateTime.tryParse(a['timestamp']?.toString() ?? '');
    final dateB = DateTime.tryParse(b['timestamp']?.toString() ?? '');
    if (dateA == null && dateB == null) return 0;
    if (dateA == null) return 1;
    if (dateB == null) return -1;
    return newestFirst ? dateB.compareTo(dateA) : dateA.compareTo(dateB);
  }

  int _compareAuditText(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
    String field,
  ) {
    return (a[field]?.toString().toLowerCase() ?? '').compareTo(
      b[field]?.toString().toLowerCase() ?? '',
    );
  }
}

class _AuditSearchField extends StatelessWidget {
  const _AuditSearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return AdminSearchField(
      controller: controller,
      hintText: 'Search by actor, role, or email...',
      onChanged: onChanged,
      onClear: onClear,
    );
  }
}

class _AuditResultCount extends StatelessWidget {
  const _AuditResultCount({required this.activeCount});

  final int activeCount;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = activeCount == 0
        ? 'Audit trail'
        : '$activeCount active filter${activeCount == 1 ? '' : 's'}';
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppTheme.primaryBlue.withValues(alpha: isDark ? 0.18 : 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.primaryBlue.withValues(alpha: 0.36)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppTheme.primaryBlue,
          fontWeight: FontWeight.w900,
          fontSize: 13,
        ),
      ),
    );
  }
}

class _AuditActionButton extends StatelessWidget {
  const _AuditActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: FilledButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: color.withValues(alpha: 0.16),
          foregroundColor: color,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: color.withValues(alpha: 0.32)),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class _AuditFilterChip extends StatelessWidget {
  const _AuditFilterChip({
    required this.label,
    required this.value,
    required this.activeWhen,
    required this.displayValue,
    required this.options,
    required this.onSelected,
    required this.onClear,
  });

  final String label;
  final String value;
  final String activeWhen;
  final String displayValue;
  final Map<String, String> options;
  final ValueChanged<String> onSelected;
  final VoidCallback onClear;

  bool get _active => value != activeWhen;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = _active
        ? AppTheme.successGreen.withValues(alpha: isDark ? 0.18 : 0.1)
        : (isDark ? const Color(0xFF20242B) : const Color(0xFFF1F5F9));
    final border = _active
        ? AppTheme.successGreen.withValues(alpha: 0.35)
        : (isDark
              ? AppTheme.white.withValues(alpha: 0.08)
              : AppTheme.black.withValues(alpha: 0.08));
    final textColor = _active
        ? AppTheme.successGreen
        : (isDark ? AppTheme.white : AppTheme.colorFF18212F);

    return PopupMenuButton<String>(
      tooltip: label,
      onSelected: (selected) {
        if (selected == '__clear__') {
          onClear();
        } else {
          onSelected(selected);
        }
      },
      itemBuilder: (context) => [
        ...options.entries.map(
          (entry) => PopupMenuItem(
            value: entry.key,
            child: Row(
              children: [
                Icon(
                  entry.key == value
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 18,
                  color: entry.key == value
                      ? AppTheme.successGreen
                      : AppTheme.neutralGray,
                ),
                const SizedBox(width: 8),
                Text(entry.value),
              ],
            ),
          ),
        ),
        if (_active)
          const PopupMenuItem(
            value: '__clear__',
            child: Row(
              children: [
                Icon(Icons.close_rounded, size: 18, color: AppTheme.errorRed),
                SizedBox(width: 8),
                Text('Clear'),
              ],
            ),
          ),
      ],
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              displayValue,
              style: TextStyle(
                color: textColor,
                fontWeight: FontWeight.w900,
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: textColor),
          ],
        ),
      ),
    );
  }
}

class _AuditLogCard extends StatelessWidget {
  const _AuditLogCard({required this.entry, required this.alternate});

  final Map<String, dynamic> entry;
  final bool alternate;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final allBefore = _mapOf(entry['before']);
    final allAfter = _mapOf(entry['after']);
    final actionType = _text(entry['actionType']).toLowerCase();
    final actionLabel = _actionLabel(entry);
    final securityLabel = securityEventLabel(entry);
    final isSession =
        entry['isSessionEvent'] == true ||
        actionType == 'login' ||
        actionType == 'login_failed';
    final timestamp = _timestampText(entry);
    final diff = _changedDiff(allBefore, allAfter, actionType);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark
            ? (alternate ? AppTheme.colorFF111827 : AppTheme.colorFF171B23)
            : (alternate ? AppTheme.colorFFF8FBFF : AppTheme.lightCardBg),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _actionColor(
            actionType,
          ).withValues(alpha: isDark ? 0.24 : 0.18),
        ),
        boxShadow: AppTheme.getCardShadow(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppTheme.space8,
            runSpacing: AppTheme.space8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _ActionChip(
                icon: _actionIcon(actionType),
                label: actionLabel,
                color: _actionColor(actionType),
              ),
              if (securityLabel != null)
                _SecurityEventChip(label: securityLabel),
              _TimestampChip(timestamp: timestamp),
            ],
          ),
          const SizedBox(height: AppTheme.space8),
          _buildActorSection(context),
          const SizedBox(height: AppTheme.space8),
          _buildEventContext(context, actionType, isSession, diff),
          if (!isSession) ...[
            const SizedBox(height: AppTheme.space8),
            _buildDiffPanes(context, diff.$1, diff.$2, actionType),
          ],
        ],
      ),
    );
  }

  Widget _buildActorSection(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final email = _actorEmail(entry);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.person_outline_rounded,
          size: 20,
          color: isDark ? AppTheme.darkSubtleText : AppTheme.lightSubtleText,
        ),
        const SizedBox(width: AppTheme.space8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _actorName(entry),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: isDark ? AppTheme.darkText : AppTheme.lightText,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _actorRole(entry),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: isDark
                      ? AppTheme.darkSubtleText
                      : AppTheme.lightSubtleText,
                ),
              ),
              if (email != 'N/A') ...[
                const SizedBox(height: 2),
                SelectableText(
                  email,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? AppTheme.darkMutedText
                        : AppTheme.lightSubtleText,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEventContext(
    BuildContext context,
    String actionType,
    bool isSession,
    (Map<String, dynamic>, Map<String, dynamic>) diff,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final entityId = _entityId(entry);
    final entityLabel = _text(entry['entityLabel']);
    final failureReason = _text(entry['failureReason']);
    final contextColor = isDark
        ? AppTheme.darkSubtleText
        : AppTheme.lightSubtleText;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppTheme.space10),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkPanel : AppTheme.lightPanel,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.tag_rounded, size: 16, color: contextColor),
              const SizedBox(width: AppTheme.space6),
              Text(
                '${_entityTypeLabel(entry)}:',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: contextColor,
                ),
              ),
              const SizedBox(width: AppTheme.space6),
              Flexible(
                child: SelectableText(
                  entityId,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: isDark ? AppTheme.darkText : AppTheme.lightText,
                  ),
                ),
              ),
              if (entityLabel != 'N/A') ...[
                const SizedBox(width: AppTheme.space6),
                Expanded(
                  child: Text(
                    entityLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: contextColor),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppTheme.space8),
          if (isSession) ...[
            Row(
              children: [
                Icon(Icons.language_rounded, size: 16, color: contextColor),
                const SizedBox(width: AppTheme.space6),
                Text(
                  'IP address:',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: contextColor,
                  ),
                ),
                const SizedBox(width: AppTheme.space6),
                Flexible(
                  child: SelectableText(
                    _text(entry['ipAddress']),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: isDark ? AppTheme.darkText : AppTheme.lightText,
                    ),
                  ),
                ),
                const SizedBox(width: AppTheme.space12),
                Expanded(
                  child: Text(
                    'Session duration: ${_sessionDuration(entry)}',
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: contextColor),
                  ),
                ),
              ],
            ),
            if (actionType == 'login_failed' && failureReason != 'N/A') ...[
              const SizedBox(height: AppTheme.space8),
              Row(
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    size: 16,
                    color: AppTheme.errorRed,
                  ),
                  const SizedBox(width: AppTheme.space6),
                  Expanded(
                    child: Text(
                      'Failure reason: $failureReason',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.errorRed,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ] else
            Row(
              children: [
                Icon(Icons.edit_note_rounded, size: 16, color: contextColor),
                const SizedBox(width: AppTheme.space6),
                Text(
                  'Changed ${_changedFieldCount(diff)} fields',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: contextColor,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildDiffPanes(
    BuildContext context,
    Map<String, dynamic> before,
    Map<String, dynamic> after,
    String actionType,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final panes = [
          _AuditDiffBox(
            title: 'Before',
            data: before,
            tone: _DiffTone.before,
            emptyMessage: actionType == 'create'
                ? 'New record created'
                : 'No previous value recorded',
          ),
          _AuditDiffBox(
            title: 'After',
            data: after,
            tone: _DiffTone.after,
            emptyMessage: 'No changed value recorded',
          ),
        ];
        if (constraints.maxWidth < 700) {
          return Column(
            children: [
              panes.first,
              const SizedBox(height: AppTheme.space12),
              panes.last,
            ],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: panes.first),
              const SizedBox(width: AppTheme.space8),
              Expanded(child: panes.last),
            ],
          ),
        );
      },
    );
  }

  static Map<String, dynamic> _mapOf(Object? value) {
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), item));
    }
    return const {};
  }

  static String _text(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? 'N/A' : text;
  }

  static String _actionLabel(Map<String, dynamic> entry) {
    final label = entry['actionLabel']?.toString().trim();
    if (label != null && label.isNotEmpty) return label;
    return _labelText(entry['actionType']);
  }

  static String _timestampText(Map<String, dynamic> entry) {
    final display = entry['displayTimestamp']?.toString().trim();
    if (display != null && display.isNotEmpty) return display;
    final parsed = DateTime.tryParse(entry['timestamp']?.toString() ?? '');
    if (parsed == null) return _text(entry['timestamp']);
    final manila = parsed.toUtc().add(const Duration(hours: 8));
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final hour = manila.hour % 12 == 0 ? 12 : manila.hour % 12;
    final minute = manila.minute.toString().padLeft(2, '0');
    final suffix = manila.hour >= 12 ? 'PM' : 'AM';
    return '${months[manila.month - 1]} ${manila.day}, ${manila.year} $hour:$minute $suffix';
  }

  static String _actorName(Map<String, dynamic> entry) {
    final name = _text(entry['actorName']);
    return name == 'N/A' ? _preferredActor(entry) : name;
  }

  static String _actorEmail(Map<String, dynamic> entry) {
    final email = entry['actorEmail']?.toString().trim() ?? '';
    return email.isEmpty ? 'N/A' : email;
  }

  static String _actorRole(Map<String, dynamic> entry) {
    final role = _text(entry['actorRole']);
    return role == 'N/A' ? 'Role not recorded' : _labelText(role);
  }

  static String? securityEventLabel(Map<String, dynamic> entry) {
    final actionType = _text(entry['actionType']).toLowerCase();
    final entityType = _text(entry['entityType']).toLowerCase();
    return switch (actionType) {
      'login' => 'Security: login',
      'login_failed' => 'Security: failed login',
      'role_change' => 'Security: role change',
      'password_reset' => 'Security: password reset',
      'deactivate' => 'Security: account disabled',
      'delete' || 'deleted' => 'Security: deletion',
      _ => entityType == 'system_setting'
          ? 'Security: settings change'
          : null,
    };
  }

  static String _entityTypeLabel(Map<String, dynamic> entry) {
    final type = _text(entry['entityType']);
    return type == 'N/A' ? 'Entity' : _labelText(type);
  }

  static String _entityId(Map<String, dynamic> entry) {
    final id = _text(entry['entityId']);
    return id == 'N/A' ? 'Not recorded' : id;
  }

  static int _changedFieldCount(
    (Map<String, dynamic>, Map<String, dynamic>) diff,
  ) {
    return {...diff.$1.keys, ...diff.$2.keys}.length;
  }

  static String _sessionDuration(Map<String, dynamic> entry) {
    final raw =
        entry['sessionDuration'] ??
        entry['sessionDurationLabel'] ??
        entry['duration'];
    final value = raw?.toString().trim() ?? '';
    return value.isEmpty ? 'Not recorded' : value;
  }

  static (Map<String, dynamic>, Map<String, dynamic>) _changedDiff(
    Map<String, dynamic> before,
    Map<String, dynamic> after,
    String actionType,
  ) {
    if (actionType == 'create') {
      return (const {}, after);
    }
    final keys = {...before.keys, ...after.keys}.where((key) {
      return before[key]?.toString() != after[key]?.toString();
    });
    return (
      {
        for (final key in keys)
          if (before.containsKey(key)) key: before[key],
      },
      {
        for (final key in keys)
          if (after.containsKey(key)) key: after[key],
      },
    );
  }

  static String _labelText(Object? value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return 'Record';
    return text
        .split('_')
        .map(
          (part) => part.isEmpty
              ? part
              : '${part[0].toUpperCase()}${part.substring(1)}',
        )
        .join(' ');
  }

  static IconData _actionIcon(String actionType) {
    return switch (actionType) {
      'login' || 'login_failed' => Icons.login_rounded,
      'create' => Icons.add_circle_outline_rounded,
      'role_change' => Icons.admin_panel_settings_rounded,
      'deactivate' => Icons.block_rounded,
      'password_reset' => Icons.key_rounded,
      _ => Icons.history_rounded,
    };
  }

  static Color _actionColor(String actionType) {
    return switch (actionType) {
      'login' => AppTheme.successGreen,
      'create' => AppTheme.infoBlue,
      'update' || 'status_changed' => AppTheme.warningOrange,
      'delete' || 'deleted' || 'login_failed' || 'failed' => AppTheme.errorRed,
      'role_change' || 'password_reset' => AppTheme.purpleAccent,
      'deactivate' || 'cancelled' => AppTheme.neutralGray,
      _ => AppTheme.primaryBlue,
    };
  }

  static String _preferredActor(Map<String, dynamic> entry) {
    final email = entry['actorEmail']?.toString().trim() ?? '';
    return email.isEmpty ? _text(entry['actorName']) : email;
  }
}

class _SecurityEventChip extends StatelessWidget {
  const _SecurityEventChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space8,
        vertical: AppTheme.space6,
      ),
      decoration: BoxDecoration(
        color: AppTheme.warningOrange.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(
          color: AppTheme.warningOrange.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.security_rounded,
            size: 15,
            color: AppTheme.warningOrange,
          ),
          const SizedBox(width: AppTheme.space6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: AppTheme.warningOrange,
            ),
          ),
        ],
      ),
    );
  }
}

class _TimestampChip extends StatelessWidget {
  const _TimestampChip({required this.timestamp});

  final String timestamp;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space10,
        vertical: AppTheme.space6,
      ),
      decoration: BoxDecoration(
        color: isDark
            ? AppTheme.white.withValues(alpha: 0.05)
            : AppTheme.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.08)
              : AppTheme.black.withValues(alpha: 0.08),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.schedule_rounded,
            size: 15,
            color: isDark ? AppTheme.white60 : AppTheme.colorFF64748B,
          ),
          const SizedBox(width: AppTheme.space6),
          Text(
            timestamp,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: isDark ? AppTheme.white70 : AppTheme.colorFF64748B,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space10,
        vertical: AppTheme.space6,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: AppTheme.space6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

enum _DiffTone { before, after }

class _AuditDiffBox extends StatelessWidget {
  const _AuditDiffBox({
    required this.title,
    required this.data,
    required this.emptyMessage,
    required this.tone,
  });

  final String title;
  final Map<String, dynamic> data;
  final String emptyMessage;
  final _DiffTone tone;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = isDark
        ? (tone == _DiffTone.before
              ? AppTheme.errorRed.withValues(alpha: 0.08)
              : AppTheme.successGreen.withValues(alpha: 0.08))
        : (tone == _DiffTone.before
              ? AppTheme.colorFFFFEAEA
              : AppTheme.colorFFE8FFF2);
    final border = tone == _DiffTone.before
        ? AppTheme.errorRed.withValues(alpha: 0.18)
        : AppTheme.successGreen.withValues(alpha: 0.18);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w900,
              color: isDark ? AppTheme.white70 : AppTheme.colorFF475569,
            ),
          ),
          const SizedBox(height: 8),
          if (data.isEmpty)
            Text(
              emptyMessage,
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: isDark ? AppTheme.white60 : AppTheme.colorFF64748B,
              ),
            )
          else
            ...data.entries
                .take(12)
                .map(
                  (entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: SelectableText(
                      '${_fieldLabel(entry.key)}: ${entry.value}',
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: isDark
                            ? AppTheme.white60
                            : AppTheme.colorFF64748B,
                      ),
                    ),
                  ),
                ),
        ],
      ),
    );
  }

  String _fieldLabel(String key) {
    return key
        .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (match) {
          return '${match.group(1)} ${match.group(2)}';
        })
        .split('_')
        .map(
          (part) => part.isEmpty
              ? part
              : '${part[0].toUpperCase()}${part.substring(1)}',
        )
        .join(' ');
  }
}

class _AuditEmptyState extends StatelessWidget {
  const _AuditEmptyState({
    required this.isDark,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onTap,
  });

  final bool isDark;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF111723 : AppTheme.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.08)
              : AppTheme.black.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        children: [
          const Icon(Icons.manage_search_rounded, size: 46),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: isDark ? AppTheme.white : AppTheme.colorFF18212F,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isDark ? AppTheme.white60 : AppTheme.colorFF64748B,
            ),
          ),
          if (actionLabel != null && onTap != null) ...[
            const SizedBox(height: 14),
            FilledButton(onPressed: onTap, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}
