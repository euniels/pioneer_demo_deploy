import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/backend_api.dart';
import '../services/fleet_sync_service.dart';
import '../services/notification_service.dart';
import '../theme/app_theme.dart';
import '../widgets/admin_page_controls.dart';
import '../widgets/dashboard_layout.dart';
import '../widgets/page_skeletons.dart';

enum _ReadFilter { all, unread, read }

enum _DateFilter { all, today }

enum _NotificationTab { all, unread, alerts, system }

enum _NotificationSort { newest, oldest, typeAZ, typeZA }

const List<String> notificationPrimaryTabLabels = [
  'All',
  'Unread',
  'Alerts',
  'System',
];

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  final _svc = NotificationService.instance;

  bool _isLoading = true;
  String? _loadError;
  _NotificationTab _activeTab = _NotificationTab.all;
  NotificationCategory? _activeCategory;
  _ReadFilter _readFilter = _ReadFilter.all;
  _DateFilter _dateFilter = _DateFilter.all;
  _NotificationSort _sort = _NotificationSort.newest;

  bool get _hasActiveFilters =>
      _activeCategory != null ||
      _readFilter != _ReadFilter.all ||
      _dateFilter != _DateFilter.all ||
      _sort != _NotificationSort.newest;

  @override
  void initState() {
    super.initState();
    _svc.notifications.addListener(_onChanged);
    _load(forceRefresh: true);
  }

  @override
  void dispose() {
    _svc.notifications.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _load({bool forceRefresh = false}) async {
    setState(() => _isLoading = true);
    try {
      await refreshNotificationsFromBackend(forceRefresh: forceRefresh);
      if (mounted) {
        setState(() => _loadError = null);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadError =
              'Notifications could not refresh. Showing the latest saved inbox.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  List<NotificationItem> get _filteredItems {
    final now = DateTime.now();
    final filtered = _svc.notifications.value.where((item) {
      switch (_activeTab) {
        case _NotificationTab.unread:
          if (item.isRead) return false;
          break;
        case _NotificationTab.alerts:
          if (item.category != NotificationCategory.alert &&
              item.category != NotificationCategory.maintenance) {
            return false;
          }
          break;
        case _NotificationTab.system:
          if (item.category != NotificationCategory.system) return false;
          break;
        case _NotificationTab.all:
          break;
      }

      if (_activeCategory != null && item.category != _activeCategory) {
        return false;
      }

      switch (_readFilter) {
        case _ReadFilter.unread:
          if (item.isRead) return false;
          break;
        case _ReadFilter.read:
          if (!item.isRead) return false;
          break;
        case _ReadFilter.all:
          break;
      }

      if (_dateFilter == _DateFilter.today &&
          (item.timestamp.year != now.year ||
              item.timestamp.month != now.month ||
              item.timestamp.day != now.day)) {
        return false;
      }

      return true;
    }).toList();

    filtered.sort((a, b) {
      return switch (_sort) {
        _NotificationSort.oldest => a.timestamp.compareTo(b.timestamp),
        _NotificationSort.typeAZ => a.category.label.compareTo(
          b.category.label,
        ),
        _NotificationSort.typeZA => b.category.label.compareTo(
          a.category.label,
        ),
        _NotificationSort.newest => b.timestamp.compareTo(a.timestamp),
      };
    });
    return filtered;
  }

  void _openNotification(NotificationItem item) {
    if (!item.isRead) {
      _svc.markAsRead(item.id);
      unawaited(BackendApiService.markNotificationRead(item.id));
    }
    final route = switch (item.category) {
      NotificationCategory.maintenance => '/maintenance',
      NotificationCategory.trip => '/trips',
      NotificationCategory.fuel => '/delivery-confirm',
      NotificationCategory.driver => '/drivers',
      NotificationCategory.billing => '/billing',
      NotificationCategory.alert => '/live-tracking',
      NotificationCategory.system => null,
    };
    if (route != null) {
      Navigator.pushNamed(context, route);
    }
  }

  Future<void> _markAllRead() async {
    _svc.markAllAsRead();
    await BackendApiService.markAllNotificationsRead();
    await _load(forceRefresh: true);
  }

  Future<void> _deleteItem(NotificationItem item) async {
    _svc.deleteNotification(item.id);
    await BackendApiService.deleteNotification(item.id);
    await _load(forceRefresh: true);
  }

  Future<void> _clearAll() async {
    _svc.deleteAll();
    await BackendApiService.clearNotifications();
    await _load(forceRefresh: true);
  }

  void _resetFilters() {
    setState(() {
      _activeCategory = null;
      _readFilter = _ReadFilter.all;
      _dateFilter = _DateFilter.all;
      _sort = _NotificationSort.newest;
    });
  }

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      currentRoute: '/notifications',
      title: 'Notifications',
      subtitle: '${_svc.unreadCount} unread',
      child: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final items = _filteredItems;

    return Column(
      children: [
        _buildInboxControls(isDark),
        if (_loadError != null) _buildErrorBanner(isDark),
        Expanded(
          child: Container(
            color: isDark ? AppTheme.colorFF0A0E1A : AppTheme.colorFFF5F6F8,
            child: _isLoading && _svc.notifications.value.isEmpty
                ? const PioneerRouteSkeletonBody(routeName: '/notifications')
                : RefreshIndicator(
                    onRefresh: () => _load(forceRefresh: true),
                    child: items.isEmpty
                        ? ListView(
                            padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                            children: [
                              Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 1120,
                                  ),
                                  child: SizedBox(
                                    height: 360,
                                    child: _EmptyState(
                                      isDark: isDark,
                                      hasNotifications:
                                          _svc.notifications.value.isNotEmpty,
                                      onClearFilters: _hasActiveFilters
                                          ? _resetFilters
                                          : null,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : ListView(
                            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                            children: [
                              Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 1120,
                                  ),
                                  child: Column(
                                    children: _groupedNotificationChildren(
                                      items,
                                      isDark,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildInboxControls(bool isDark) {
    final categories = <NotificationCategory?>[
      null,
      NotificationCategory.trip,
      NotificationCategory.maintenance,
      NotificationCategory.fuel,
      NotificationCategory.billing,
      NotificationCategory.driver,
      NotificationCategory.alert,
      NotificationCategory.system,
    ];
    final categoryOptions = [
      'All Types',
      ...categories.whereType<NotificationCategory>().map((item) => item.label),
    ];
    final activeCategoryLabel = _activeCategory?.label ?? 'All Types';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 12),
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
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: Column(
            children: [
              Row(
                children: [
                  AdminResultCount(
                    count: _filteredItems.length,
                    label: 'notifications',
                  ),
                  const SizedBox(width: 10),
                  _summaryPill(
                    isDark,
                    label: 'unread',
                    value: '${_svc.unreadCount}',
                    accent: AppTheme.colorFF4B7BE5,
                  ),
                  const Spacer(),
                  _NotificationActionButton(
                    label: 'Mark read',
                    icon: Icons.done_all_rounded,
                    color: AppTheme.successGreen,
                    onTap: _svc.unreadCount == 0 ? null : _markAllRead,
                  ),
                  const SizedBox(width: 8),
                  _NotificationActionButton(
                    label: 'Clear',
                    icon: Icons.delete_sweep_rounded,
                    color: AppTheme.errorRed,
                    onTap: _svc.notifications.value.isEmpty ? null : _clearAll,
                  ),
                  const SizedBox(width: 8),
                  _filterMenu(),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final tab in _NotificationTab.values) ...[
                            _tabChip(
                              isDark,
                              label: notificationPrimaryTabLabels[tab.index],
                              selected: _activeTab == tab,
                              onTap: () => setState(() {
                                _activeTab = tab;
                                if (_activeTab != _NotificationTab.all) {
                                  _activeCategory = null;
                                }
                              }),
                            ),
                            const SizedBox(width: 8),
                          ],
                          const SizedBox(width: 4),
                          AdminFilterChip(
                            label: 'Type',
                            value: activeCategoryLabel,
                            activeWhen: 'All Types',
                            options: categoryOptions,
                            onSelected: (value) => setState(() {
                              _activeCategory = value == 'All Types'
                                  ? null
                                  : categories.whereType<NotificationCategory>().firstWhere(
                                      (category) => category.label == value,
                                    );
                            }),
                            onClear: () => setState(() {
                              _activeCategory = null;
                            }),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_hasActiveFilters)
                    TextButton.icon(
                      onPressed: _resetFilters,
                      icon: const Icon(Icons.filter_alt_off_rounded, size: 16),
                      label: const Text('Clear filters'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tabChip(
    bool isDark, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
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
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: selected
                ? AppTheme.successGreen
                : (isDark ? AppTheme.gray300 : AppTheme.gray700),
          ),
        ),
      ),
    );
  }

  Widget _filterMenu() {
    return PopupMenuButton<String>(
      tooltip: 'Notification filters',
      icon: const Icon(Icons.tune_rounded),
      onSelected: (value) {
        setState(() {
          switch (value) {
            case 'read_all':
              _readFilter = _ReadFilter.all;
              break;
            case 'read_unread':
              _readFilter = _ReadFilter.unread;
              break;
            case 'read_read':
              _readFilter = _ReadFilter.read;
              break;
            case 'date_all':
              _dateFilter = _DateFilter.all;
              break;
            case 'date_today':
              _dateFilter = _DateFilter.today;
              break;
            case 'sort_newest':
              _sort = _NotificationSort.newest;
              break;
            case 'sort_oldest':
              _sort = _NotificationSort.oldest;
              break;
            case 'sort_type_az':
              _sort = _NotificationSort.typeAZ;
              break;
            case 'sort_type_za':
              _sort = _NotificationSort.typeZA;
              break;
          }
        });
      },
      itemBuilder: (context) => [
        CheckedPopupMenuItem(
          value: 'read_all',
          checked: _readFilter == _ReadFilter.all,
          child: const Text('Read status: All'),
        ),
        CheckedPopupMenuItem(
          value: 'read_unread',
          checked: _readFilter == _ReadFilter.unread,
          child: const Text('Read status: Unread'),
        ),
        CheckedPopupMenuItem(
          value: 'read_read',
          checked: _readFilter == _ReadFilter.read,
          child: const Text('Read status: Read'),
        ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(
          value: 'date_all',
          checked: _dateFilter == _DateFilter.all,
          child: const Text('Date: Any date'),
        ),
        CheckedPopupMenuItem(
          value: 'date_today',
          checked: _dateFilter == _DateFilter.today,
          child: const Text('Date: Today'),
        ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(
          value: 'sort_newest',
          checked: _sort == _NotificationSort.newest,
          child: const Text('Sort: Newest'),
        ),
        CheckedPopupMenuItem(
          value: 'sort_oldest',
          checked: _sort == _NotificationSort.oldest,
          child: const Text('Sort: Oldest'),
        ),
        CheckedPopupMenuItem(
          value: 'sort_type_az',
          checked: _sort == _NotificationSort.typeAZ,
          child: const Text('Sort: Type A-Z'),
        ),
        CheckedPopupMenuItem(
          value: 'sort_type_za',
          checked: _sort == _NotificationSort.typeZA,
          child: const Text('Sort: Type Z-A'),
        ),
      ],
    );
  }

  Widget _buildErrorBanner(bool isDark) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.colorFFF59E0B.withValues(alpha: isDark ? 0.16 : 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppTheme.colorFFF59E0B.withValues(alpha: 0.28),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            size: 18,
            color: AppTheme.colorFFF59E0B,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _loadError!,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: isDark ? AppTheme.white70 : AppTheme.colorFF7A4B00,
              ),
            ),
          ),
          TextButton(
            onPressed: () => _load(forceRefresh: true),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  List<Widget> _groupedNotificationChildren(
    List<NotificationItem> items,
    bool isDark,
  ) {
    final groups = <String, List<NotificationItem>>{};
    for (final item in items) {
      groups.putIfAbsent(_dateGroupFor(item.timestamp), () => []).add(item);
    }

    return groups.entries.expand((entry) {
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 10, 2, 8),
          child: Text(
            entry.key,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: isDark ? AppTheme.white70 : AppTheme.colorFF1A3A6B,
            ),
          ),
        ),
        ...entry.value.map(
          (item) => _NotificationTile(
            item: item,
            isDark: isDark,
            onTap: () => _openNotification(item),
            onDelete: () => _deleteItem(item),
          ),
        ),
      ];
    }).toList();
  }

  String _dateGroupFor(DateTime timestamp) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(timestamp.year, timestamp.month, timestamp.day);
    final delta = today.difference(date).inDays;
    if (delta == 0) return 'Today';
    if (delta == 1) return 'Yesterday';
    if (delta <= 6) return 'Earlier This Week';
    return 'Earlier';
  }

  Widget _summaryPill(
    bool isDark, {
    required String label,
    required String value,
    Color accent = AppTheme.colorFF10B981,
  }) {
    return Container(
      height: 38,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Text(
        '$value $label',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w900,
          color: accent,
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _filterChip(
    bool isDark, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 38,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.successGreen.withValues(alpha: 0.13)
              : AppTheme.white.withAlpha(8),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? AppTheme.successGreen.withValues(alpha: 0.34)
                : AppTheme.white.withAlpha(18),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: selected
                ? AppTheme.successGreen
                : (isDark ? AppTheme.white70 : AppTheme.colorFF334155),
          ),
        ),
      ),
    );
  }
}

class _NotificationActionButton extends StatelessWidget {
  const _NotificationActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return MouseRegion(
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 140),
          opacity: disabled ? 0.45 : 1,
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: 0.24)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: color, size: 16),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
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

class _NotificationTile extends StatelessWidget {
  final NotificationItem item;
  final bool isDark;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _NotificationTile({
    required this.item,
    required this.isDark,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final accent = _accentFor(item.category);
    final card = Container(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: item.isRead
            ? (isDark ? AppTheme.colorFF171B23 : AppTheme.white)
            : Color.lerp(
                isDark ? AppTheme.colorFF171B23 : AppTheme.white,
                accent,
                isDark ? 0.14 : 0.08,
              ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: item.isRead
              ? (isDark ? AppTheme.white.withAlpha(18) : AppTheme.black.withAlpha(14))
              : accent.withValues(alpha: 0.32),
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: item.isRead ? 0.05 : 0.12),
            blurRadius: 20,
            spreadRadius: -14,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 5, color: accent),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.13),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: accent.withValues(alpha: 0.18),
                          ),
                        ),
                        child: Icon(
                          _iconFor(item.category),
                          color: accent,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    item.title,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: isDark
                                          ? AppTheme.white
                                          : AppTheme.colorFF18212F,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  item.time,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark
                                        ? AppTheme.white38
                                        : AppTheme.colorFF9CA3AF,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              item.message,
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.35,
                                color: isDark
                                    ? AppTheme.white70
                                    : AppTheme.colorFF5A6070,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 9),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                item.category == NotificationCategory.system
                                    ? 'System notice'
                                    : 'Open ${item.category.label}',
                                style: TextStyle(
                                  color: accent,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (kIsWeb)
                        IconButton(
                          onPressed: onDelete,
                          tooltip: 'Dismiss notification',
                          icon: const Icon(Icons.close_rounded, size: 18),
                        )
                      else
                        PopupMenuButton<String>(
                          onSelected: (value) {
                            switch (value) {
                              case 'read':
                                onTap();
                                break;
                              case 'delete':
                                onDelete();
                                break;
                            }
                          },
                          itemBuilder: (context) => [
                            if (!item.isRead)
                              const PopupMenuItem(
                                value: 'read',
                                child: Text('Mark as read'),
                              ),
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('Delete'),
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
    );

    if (kIsWeb) {
      return card;
    }

    return Dismissible(
      key: ValueKey<String>('notification-${item.id}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        alignment: Alignment.centerRight,
        decoration: BoxDecoration(
          color: AppTheme.errorRed.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(
          Icons.delete_outline_rounded,
          color: AppTheme.errorRed,
        ),
      ),
      child: card,
    );
  }

  IconData _iconFor(NotificationCategory category) {
    switch (category) {
      case NotificationCategory.trip:
        return Icons.route_rounded;
      case NotificationCategory.maintenance:
        return Icons.build_circle_outlined;
      case NotificationCategory.fuel:
        return Icons.local_gas_station_rounded;
      case NotificationCategory.driver:
        return Icons.badge_rounded;
      case NotificationCategory.billing:
        return Icons.receipt_long_rounded;
      case NotificationCategory.alert:
        return Icons.warning_amber_rounded;
      case NotificationCategory.system:
        return Icons.info_outline_rounded;
    }
  }

  Color _accentFor(NotificationCategory category) {
    final wording = '${item.title} ${item.message}'.toLowerCase();
    if (wording.contains('approved') ||
        wording.contains('complete') ||
        wording.contains('success') ||
        wording.contains('paid')) {
      return AppTheme.successGreen;
    }
    switch (category) {
      case NotificationCategory.alert:
        return AppTheme.errorRed;
      case NotificationCategory.maintenance:
        return AppTheme.warningOrange;
      case NotificationCategory.trip:
      case NotificationCategory.fuel:
      case NotificationCategory.driver:
      case NotificationCategory.billing:
      case NotificationCategory.system:
        return AppTheme.primaryBlue;
    }
  }
}

class _EmptyState extends StatelessWidget {
  final bool isDark;
  final bool hasNotifications;
  final VoidCallback? onClearFilters;

  const _EmptyState({
    required this.isDark,
    required this.hasNotifications,
    this.onClearFilters,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.colorFF141924 : AppTheme.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.getBorderColor(context)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasNotifications
                  ? Icons.filter_alt_off_rounded
                  : Icons.notifications_off_outlined,
              size: 54,
              color: isDark ? AppTheme.white24 : AppTheme.black26,
            ),
            const SizedBox(height: 12),
            Text(
              hasNotifications
                  ? 'No notifications match these filters'
                  : 'No real notifications yet',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: isDark ? AppTheme.white : AppTheme.colorFF18212F,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hasNotifications
                  ? 'Change the tabs or filters to see the rest of the inbox.'
                  : 'Operational alerts will appear here when dispatch, maintenance, billing, driver, or system events happen.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark ? AppTheme.white60 : AppTheme.colorFF64748B,
              ),
            ),
            if (onClearFilters != null) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: onClearFilters,
                icon: const Icon(Icons.filter_alt_off_rounded),
                label: const Text('Clear filters'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
