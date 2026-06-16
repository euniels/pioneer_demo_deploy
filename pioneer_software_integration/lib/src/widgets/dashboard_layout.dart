import 'package:flutter/material.dart';
import '../widgets/fleet_sidebar.dart';
import '../services/auth.dart';
import '../services/backend_api.dart';
import '../services/role_service.dart';
import '../services/sidebar_service.dart';
import '../services/notification_service.dart';
import '../services/network_status_service.dart';
import '../services/trips_store.dart';
import '../services/fleet_sync_service.dart';
import '../theme/app_theme.dart';

class DashboardLayout extends StatefulWidget {
  final Widget child;
  final String currentRoute;
  final String title;
  final String? subtitle;
  final List<Widget>? actions;
  final TextStyle? titleTextStyle;
  final Future<void> Function()? onRefresh;

  const DashboardLayout({
    Key? key,
    required this.child,
    required this.currentRoute,
    required this.title,
    this.subtitle,
    this.actions,
    this.titleTextStyle,
    this.onRefresh,
  }) : super(key: key);

  @override
  State<DashboardLayout> createState() => _DashboardLayoutState();
}

class _DashboardLayoutState extends State<DashboardLayout> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _isCollapsed = false;

  void _onToggleCollapse() {
    setState(() => _isCollapsed = !_isCollapsed);
    SidebarService.setCollapsed(_isCollapsed);
  }

  OverlayEntry? _notificationOverlay;
  OverlayEntry? _profileOverlay;
  final LayerLink _notificationLayerLink = LayerLink();
  final LayerLink _profileLayerLink = LayerLink();
  bool _isLoggingOut = false;

  // Single source of truth â€” shared with the notifications page
  final _svc = NotificationService.instance;

  @override
  void initState() {
    super.initState();
    _isCollapsed = SidebarService.isCollapsed;
    _syncNotifications();
    // Rebuild the top bar badge whenever the notification list changes
    _svc.notifications.addListener(_onNotificationsChanged);
    // Rebuild sidebar when trips change (for dispatch badge)
    tripsNotifier.addListener(_onTripsChanged);
    _isLoggingOut = AuthService.isLoggingOut;
    AuthService.logoutInProgress.addListener(_onLogoutStateChanged);
  }

  void _onNotificationsChanged() {
    if (mounted) setState(() {});
    // Also refresh the overlay if it's open
    _notificationOverlay?.markNeedsBuild();
  }

  void _onTripsChanged() {
    if (mounted) setState(() {});
  }

  void _onLogoutStateChanged() {
    if (mounted) {
      setState(() => _isLoggingOut = AuthService.isLoggingOut);
    }
  }

  Future<void> _syncNotifications({bool forceRefresh = false}) async {
    try {
      await refreshNotificationsFromBackend(forceRefresh: forceRefresh);
    } catch (_) {
      // Keep the last visible inbox when the backend is temporarily slow.
    }
  }

  Future<void> _markAllNotificationsRead() async {
    if (_svc.unreadCount == 0) {
      return;
    }

    _svc.markAllAsRead();
    _notificationOverlay?.markNeedsBuild();

    try {
      await BackendApiService.markAllNotificationsRead();
    } catch (_) {
      // Optimistic local update stays visible until the next refresh.
    } finally {
      await _syncNotifications(forceRefresh: true);
    }
  }

  Future<void> _markNotificationRead(String id) async {
    final alreadyRead = _svc.notifications.value.any(
      (item) => item.id == id && item.isRead,
    );
    if (alreadyRead) {
      return;
    }

    _svc.markAsRead(id);
    _notificationOverlay?.markNeedsBuild();

    try {
      await BackendApiService.markNotificationRead(id);
    } catch (_) {
      // Optimistic local update stays visible until the next refresh.
    } finally {
      await _syncNotifications(forceRefresh: true);
    }
  }

  @override
  void dispose() {
    _svc.notifications.removeListener(_onNotificationsChanged);
    tripsNotifier.removeListener(_onTripsChanged);
    AuthService.logoutInProgress.removeListener(_onLogoutStateChanged);
    _removeNotificationOverlay();
    _removeProfileOverlay();
    super.dispose();
  }

  void _toggleTheme(bool dark) async {
    final mode = dark ? ThemeMode.dark : ThemeMode.light;
    await AuthService.setTheme(mode);
    setState(() {});
  }

  bool _isMobile(BuildContext context) =>
      MediaQuery.of(context).size.width < 600;
  bool _isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= 600 &&
      MediaQuery.of(context).size.width < 1024;

  void _removeNotificationOverlay() {
    _notificationOverlay?.remove();
    _notificationOverlay = null;
  }

  void _removeProfileOverlay() {
    _profileOverlay?.remove();
    _profileOverlay = null;
  }

  void _toggleNotifications(BuildContext context) {
    if (_notificationOverlay != null) {
      _removeNotificationOverlay();
      return;
    }

    _removeProfileOverlay();

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    final double panelWidth;
    if (screenWidth < 360) {
      panelWidth = screenWidth - 24;
    } else if (screenWidth < 600) {
      panelWidth = screenWidth - 32;
    } else {
      panelWidth = 380.0;
    }

    final isMobile = screenWidth < 600;

    final horizontalOffset = isMobile
        ? -(screenWidth - 140)
        : -(panelWidth - 40);
    final verticalOffset = 50.0;

    // â”€â”€ Max height: leaves ~60 px gap above bottom of screen â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    final maxHeight = isMobile ? screenHeight * 0.75 : screenHeight * 0.8;

    _notificationOverlay = OverlayEntry(
      builder: (context) => GestureDetector(
        onTap: _removeNotificationOverlay,
        behavior: HitTestBehavior.translucent,
        child: Stack(
          children: [
            Positioned(
              child: CompositedTransformFollower(
                link: _notificationLayerLink,
                showWhenUnlinked: false,
                offset: Offset(horizontalOffset, verticalOffset),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: panelWidth,
                    maxHeight: maxHeight,
                  ),
                  child: Material(
                    elevation: 8,
                    borderRadius: BorderRadius.circular(16),
                    child: _buildNotificationPanel(
                      context,
                      isDark,
                      isMobile,
                      panelWidth,
                      screenWidth,
                      maxHeight,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    Overlay.of(context).insert(_notificationOverlay!);
  }

  void _toggleProfile(BuildContext context) {
    if (_profileOverlay != null) {
      _removeProfileOverlay();
      return;
    }

    _removeNotificationOverlay();

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;

    final double panelWidth;
    if (screenWidth < 360) {
      panelWidth = screenWidth - 32;
    } else if (screenWidth < 600) {
      panelWidth = screenWidth * 0.85;
    } else {
      panelWidth = 280.0;
    }

    final isMobile = screenWidth < 600;

    final horizontalOffset = -(panelWidth - 40);
    final verticalOffset = 50.0;

    _profileOverlay = OverlayEntry(
      builder: (context) => GestureDetector(
        onTap: _removeProfileOverlay,
        behavior: HitTestBehavior.translucent,
        child: Stack(
          children: [
            Positioned(
              child: CompositedTransformFollower(
                link: _profileLayerLink,
                showWhenUnlinked: false,
                offset: Offset(horizontalOffset, verticalOffset),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: panelWidth),
                  child: Material(
                    elevation: 8,
                    borderRadius: BorderRadius.circular(16),
                    child: _buildProfileMenu(
                      context,
                      isDark,
                      isMobile,
                      panelWidth,
                      screenWidth,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    Overlay.of(context).insert(_profileOverlay!);
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Notification panel â€” driven by NotificationService
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildNotificationPanel(
    BuildContext context,
    bool isDark,
    bool isMobile,
    double panelWidth,
    double screenWidth,
    double maxPanelHeight,
  ) {
    final items = _svc.notifications.value;
    final unreadCount = _svc.unreadCount;
    final isVerySmall = screenWidth < 360;

    final headerPadding = isVerySmall ? 8.0 : (isMobile ? 10.0 : 16.0);
    final headerFontSize = isVerySmall ? 12.0 : (isMobile ? 13.0 : 16.0);
    final badgeFontSize = isVerySmall ? 9.0 : (isMobile ? 10.0 : 12.0);
    final buttonFontSize = isVerySmall ? 10.0 : (isMobile ? 11.0 : 12.0);
    final footerPadding = isVerySmall ? 6.0 : (isMobile ? 8.0 : 12.0);

    // 52 header + 44 footer + 2 borders + 4 safety buffer = 102
    const double headerHeight = 52.0;
    const double footerHeight = 44.0;
    const double overhead = headerHeight + footerHeight + 2.0 + 4.0;
    final double listMaxHeight = maxPanelHeight - overhead;

    return Container(
      width: panelWidth,
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        borderRadius: BorderRadius.circular(isVerySmall ? 12 : 16),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.1)
              : AppTheme.black.withValues(alpha: 0.1),
        ),
      ),
      // ClipRRect silences any residual sub-pixel overflow
      child: ClipRRect(
        borderRadius: BorderRadius.circular(isVerySmall ? 12 : 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // â”€â”€ Header â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
            Container(
              padding: EdgeInsets.all(headerPadding),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: isDark
                        ? AppTheme.white.withValues(alpha: 0.08)
                        : AppTheme.black.withValues(alpha: 0.08),
                  ),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            'Notifications',
                            style: TextStyle(
                              fontSize: headerFontSize,
                              fontWeight: FontWeight.w700,
                              color: isDark
                                  ? AppTheme.white
                                  : AppTheme.colorFF2C3E50,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (unreadCount > 0) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: isVerySmall ? 6 : 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.colorFF4B7BE5,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '$unreadCount',
                              style: TextStyle(
                                fontSize: badgeFontSize,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.white,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: _markAllNotificationsRead,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.symmetric(
                        horizontal: isVerySmall ? 6 : (isMobile ? 8 : 12),
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      isVerySmall ? 'Mark' : 'Mark all',
                      style: TextStyle(
                        fontSize: buttonFontSize,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.colorFF4B7BE5,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // â”€â”€ Scrollable notifications list â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
            if (items.isEmpty)
              Center(
                child: Padding(
                  padding: EdgeInsets.all(
                    isVerySmall ? 20 : (isMobile ? 24 : 32),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.notifications_off_outlined,
                        size: isVerySmall ? 36 : (isMobile ? 40 : 48),
                        color: isDark ? AppTheme.gray600 : AppTheme.gray400,
                      ),
                      SizedBox(height: isVerySmall ? 6 : (isMobile ? 8 : 12)),
                      Text(
                        'No notifications',
                        style: TextStyle(
                          fontSize: isVerySmall ? 11 : (isMobile ? 12 : 14),
                          color: isDark ? AppTheme.gray500 : AppTheme.gray600,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: listMaxHeight.clamp(100.0, 520.0),
                ),
                child: Scrollbar(
                  thumbVisibility: true,
                  child: ListView.builder(
                    padding: EdgeInsets.symmetric(
                      vertical: isVerySmall ? 3 : (isMobile ? 4 : 8),
                    ),
                    shrinkWrap: false,
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      return _buildNotificationItem(
                        items[index],
                        isDark,
                        isMobile,
                        isVerySmall,
                      );
                    },
                  ),
                ),
              ),

            // â”€â”€ Footer â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
            Container(
              padding: EdgeInsets.all(footerPadding),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: isDark
                        ? AppTheme.white.withValues(alpha: 0.08)
                        : AppTheme.black.withValues(alpha: 0.08),
                  ),
                ),
              ),
              child: TextButton(
                onPressed: () {
                  _removeNotificationOverlay();
                  Navigator.pushNamed(context, '/notifications');
                },
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  isVerySmall ? 'View all' : 'View all notifications',
                  style: TextStyle(
                    fontSize: buttonFontSize,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.colorFF4B7BE5,
                  ),
                ),
              ),
            ),
          ],
        ), // Column
      ), // ClipRRect
    );
  }

  Widget _buildNotificationItem(
    NotificationItem item,
    bool isDark,
    bool isMobile,
    bool isVerySmall,
  ) {
    final iconSize = isVerySmall ? 28.0 : (isMobile ? 32.0 : 40.0);
    final iconInnerSize = isVerySmall ? 14.0 : (isMobile ? 16.0 : 20.0);
    final titleFontSize = isVerySmall ? 11.0 : (isMobile ? 12.0 : 13.0);
    final messageFontSize = isVerySmall ? 10.0 : (isMobile ? 11.0 : 12.0);
    final timeFontSize = isVerySmall ? 9.0 : (isMobile ? 10.0 : 11.0);

    final color = _categoryColor(item.category);

    return GestureDetector(
      onTap: () => _markNotificationRead(item.id),
      child: Container(
        margin: EdgeInsets.symmetric(
          horizontal: isVerySmall ? 3 : (isMobile ? 4 : 8),
          vertical: isVerySmall ? 2 : (isMobile ? 2 : 4),
        ),
        decoration: BoxDecoration(
          color: item.isRead
              ? AppTheme.transparent
              : (isDark
                    ? AppTheme.colorFF4B7BE5.withValues(alpha: 0.1)
                    : AppTheme.colorFF4B7BE5.withValues(alpha: 0.05)),
          borderRadius: BorderRadius.circular(
            isVerySmall ? 8 : (isMobile ? 10 : 12),
          ),
        ),
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.symmetric(
            horizontal: isVerySmall ? 6 : (isMobile ? 8 : 12),
            vertical: isVerySmall ? 3 : (isMobile ? 4 : 8),
          ),
          leading: Container(
            width: iconSize,
            height: iconSize,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(
                isVerySmall ? 6 : (isMobile ? 8 : 10),
              ),
            ),
            child: Icon(
              _categoryIcon(item.category),
              color: color,
              size: iconInnerSize,
            ),
          ),
          title: Text(
            item.title,
            style: TextStyle(
              fontSize: titleFontSize,
              fontWeight: item.isRead ? FontWeight.w600 : FontWeight.w700,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: isVerySmall ? 2 : (isMobile ? 2 : 4)),
              Text(
                item.message,
                style: TextStyle(
                  fontSize: messageFontSize,
                  color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                  height: 1.2,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: isVerySmall ? 2 : (isMobile ? 2 : 4)),
              Text(
                item.time,
                style: TextStyle(
                  fontSize: timeFontSize,
                  color: isDark ? AppTheme.gray500 : AppTheme.gray500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
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

  IconData _categoryIcon(NotificationCategory cat) {
    switch (cat) {
      case NotificationCategory.maintenance:
        return Icons.build_rounded;
      case NotificationCategory.trip:
        return Icons.check_circle_rounded;
      case NotificationCategory.fuel:
        return Icons.local_gas_station_rounded;
      case NotificationCategory.driver:
        return Icons.person_add_rounded;
      case NotificationCategory.billing:
        return Icons.payment_rounded;
      case NotificationCategory.alert:
        return Icons.report_problem_rounded;
      case NotificationCategory.system:
        return Icons.settings_rounded;
    }
  }

  Widget _buildProfileMenu(
    BuildContext context,
    bool isDark,
    bool isMobile,
    double panelWidth,
    double screenWidth,
  ) {
    final isVerySmall = screenWidth < 360;
    final headerPadding = isVerySmall ? 10.0 : (isMobile ? 12.0 : 16.0);
    final avatarSize = isVerySmall ? 36.0 : (isMobile ? 40.0 : 48.0);
    final avatarFontSize = isVerySmall ? 14.0 : (isMobile ? 16.0 : 18.0);
    final nameFontSize = isVerySmall ? 12.0 : (isMobile ? 13.0 : 14.0);
    final emailFontSize = isVerySmall ? 10.0 : (isMobile ? 11.0 : 12.0);
    final menuPadding = isVerySmall ? 6.0 : (isMobile ? 8.0 : 12.0);

    return Container(
      width: panelWidth,
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        borderRadius: BorderRadius.circular(isVerySmall ? 12 : 16),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.1)
              : AppTheme.black.withValues(alpha: 0.1),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Profile Header
          Container(
            padding: EdgeInsets.all(headerPadding),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: isDark
                      ? AppTheme.white.withValues(alpha: 0.08)
                      : AppTheme.black.withValues(alpha: 0.08),
                ),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: avatarSize,
                  height: avatarSize,
                  decoration: BoxDecoration(
                    color: _getRoleColor(AuthService.currentRole),
                    borderRadius: BorderRadius.circular(isVerySmall ? 10 : 12),
                  ),
                  child: Center(
                    child: Text(
                      _getUserInitials(),
                      style: TextStyle(
                        fontSize: avatarFontSize,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.white,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: isVerySmall ? 8 : 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AuthService.currentUserData?.fullName ??
                            AuthService.currentUser,
                        style: TextStyle(
                          fontSize: nameFontSize,
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? AppTheme.white
                              : AppTheme.colorFF2C3E50,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        AuthService.currentUserData?.email ?? '',
                        style: TextStyle(
                          fontSize: emailFontSize,
                          color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Menu Items
          Padding(
            padding: EdgeInsets.symmetric(vertical: menuPadding),
            child: Column(
              children: [
                _buildProfileMenuItem(
                  icon: Icons.person_outline_rounded,
                  title: 'Profile',
                  onTap: () {
                    _removeProfileOverlay();
                    final role = AuthService.currentRole;
                    final profileRoute = role != null
                        ? RolePermissions.getProfileRoute(role)
                        : '/settings';
                    Navigator.pushReplacementNamed(context, profileRoute);
                  },
                  isDark: isDark,
                  isMobile: isMobile,
                  isVerySmall: isVerySmall,
                ),
                _buildProfileMenuItem(
                  icon: Icons.settings_outlined,
                  title: 'Settings',
                  onTap: () {
                    _removeProfileOverlay();
                    Navigator.pushNamed(context, '/settings');
                  },
                  isDark: isDark,
                  isMobile: isMobile,
                  isVerySmall: isVerySmall,
                ),
                _buildProfileMenuItem(
                  icon: Icons.help_outline_rounded,
                  title: 'Help & Support',
                  onTap: () {
                    _removeProfileOverlay();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Support is available through your fleet administrator or implementation contact.',
                        ),
                      ),
                    );
                  },
                  isDark: isDark,
                  isMobile: isMobile,
                  isVerySmall: isVerySmall,
                ),
                const Divider(height: 1),
                _buildProfileMenuItem(
                  icon: Icons.logout_rounded,
                  title: 'Logout',
                  onTap: () {
                    _removeProfileOverlay();
                    _showLogoutDialog(context, isDark);
                  },
                  isDark: isDark,
                  isMobile: isMobile,
                  isVerySmall: isVerySmall,
                  isDestructive: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileMenuItem({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    required bool isDark,
    required bool isMobile,
    required bool isVerySmall,
    bool isDestructive = false,
  }) {
    final iconSize = isVerySmall ? 16.0 : (isMobile ? 18.0 : 20.0);
    final fontSize = isVerySmall ? 12.0 : (isMobile ? 13.0 : 14.0);
    final horizontalPadding = isVerySmall ? 10.0 : (isMobile ? 12.0 : 16.0);
    final verticalPadding = isVerySmall ? 8.0 : (isMobile ? 10.0 : 12.0);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: horizontalPadding,
          vertical: verticalPadding,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: iconSize,
              color: isDestructive
                  ? AppTheme.colorFFE74C3C
                  : (isDark ? AppTheme.gray400 : AppTheme.gray700),
            ),
            SizedBox(width: isVerySmall ? 10 : 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w500,
                  color: isDestructive
                      ? AppTheme.colorFFE74C3C
                      : (isDark ? AppTheme.white : AppTheme.colorFF2C3E50),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showLogoutDialog(BuildContext context, bool isDark) {
    showDialog(
      context: context,
      barrierDismissible: !_isLoggingOut,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            'Logout',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
            ),
          ),
          content: Text(
            _isLoggingOut
                ? 'Signing you out and clearing this session...'
                : 'Are you sure you want to logout?',
            style: TextStyle(
              fontSize: 14,
              color: isDark ? AppTheme.gray400 : AppTheme.gray700,
            ),
          ),
          actions: [
            TextButton(
              onPressed: _isLoggingOut ? null : () => Navigator.pop(context),
              child: Text(
                'Cancel',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: isDark ? AppTheme.gray400 : AppTheme.gray700,
                ),
              ),
            ),
            ElevatedButton(
              onPressed: _isLoggingOut
                  ? null
                  : () async {
                      setDialogState(() => _isLoggingOut = true);
                      setState(() => _isLoggingOut = true);
                      await AuthService.logout();
                      if (context.mounted) {
                        Navigator.pushNamedAndRemoveUntil(
                          context,
                          '/login',
                          (route) => false,
                        );
                      }
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.colorFFE74C3C,
                foregroundColor: AppTheme.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: _isLoggingOut
                  ? const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppTheme.white,
                          ),
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Logging out...',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                      ],
                    )
                  : const Text(
                      'Logout',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isMobile = _isMobile(context);
    final isTablet = _isTablet(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 1180;

        if (isNarrow) {
          return Scaffold(
            key: _scaffoldKey,
            backgroundColor: AppTheme.getBackgroundColor(context),
            drawer: Drawer(
              // Match the sidebar background so the status-bar/notch area
              // shows the correct colour while SafeArea pushes content below.
              backgroundColor: isDark ? AppTheme.colorFF0F1117 : AppTheme.white,
              child: SafeArea(
                bottom: false,
                left: false,
                right: false,
                child: FleetSidebar(
                  currentRoute: widget.currentRoute,
                  isCollapsed: false,
                  onToggleCollapse: () {},
                ),
              ),
            ),
            body: SafeArea(
              child: Column(
                children: [
                  _buildTopBar(
                    context,
                    isDark,
                    showMenu: true,
                    isMobile: isMobile,
                    isTablet: isTablet,
                  ),
                  _buildOfflineModeBanner(context),
                  Expanded(child: widget.child),
                ],
              ),
            ),
          );
        }

        return Scaffold(
          backgroundColor: AppTheme.getBackgroundColor(context),
          body: Row(
            children: [
              FleetSidebar(
                currentRoute: widget.currentRoute,
                isCollapsed: _isCollapsed,
                onToggleCollapse: _onToggleCollapse,
              ),
              Expanded(
                child: SafeArea(
                  child: Column(
                    children: [
                      _buildTopBar(
                        context,
                        isDark,
                        showMenu: false,
                        isMobile: isMobile,
                        isTablet: isTablet,
                      ),
                      _buildOfflineModeBanner(context),
                      Expanded(child: widget.child),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTopBar(
    BuildContext context,
    bool isDark, {
    bool showMenu = false,
    required bool isMobile,
    required bool isTablet,
  }) {
    final screenWidth = MediaQuery.of(context).size.width;

    final iconSize = screenWidth < 600
        ? 20.0
        : screenWidth < 1024
        ? 22.0
        : 24.0;
    final iconSpacing = screenWidth < 600 ? 12.0 : 16.0;
    final titleFontSize = screenWidth < 600
        ? 18.0
        : screenWidth < 1024
        ? 20.0
        : 22.0;
    final subtitleFontSize = screenWidth < 600
        ? 11.0
        : screenWidth < 1024
        ? 12.0
        : 13.0;
    final horizontalPadding = screenWidth < 600
        ? 16.0
        : screenWidth < 1024
        ? 24.0
        : 32.0;
    final topBarHeight = screenWidth < 600 ? 60.0 : 70.0;
    final profileSize = screenWidth < 600 ? 32.0 : 36.0;
    final profileFontSize = screenWidth < 600 ? 12.0 : 14.0;

    final badgeSize = screenWidth < 600 ? 8.0 : 16.0;
    final badgeFontSize = screenWidth < 600 ? 8.0 : 9.0;

    final unreadCount = _svc.unreadCount;

    return Container(
      height: topBarHeight,
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [AppTheme.darkPanel, AppTheme.darkPanelAlt]
              : [AppTheme.white, AppTheme.colorFFF5F8FF],
        ),
        border: Border(
          bottom: BorderSide(
            color: AppTheme.getBorderColor(context).withValues(alpha: 0.7),
            width: 1.0,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: AppTheme.black.withValues(alpha: isDark ? 0.24 : 0.06),
            blurRadius: 24.0,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          if (showMenu) ...[
            IconButton(
              icon: Icon(
                Icons.menu_rounded,
                size: iconSize,
                color: isDark ? AppTheme.gray300 : AppTheme.colorFF2C3E50,
              ),
              onPressed: () {
                _scaffoldKey.currentState?.openDrawer();
              },
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            SizedBox(width: iconSpacing),
          ],

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.title,
                  style:
                      widget.titleTextStyle ??
                      AppTheme.getHeadingStyle(
                        context,
                        fontSize: titleFontSize,
                      ).copyWith(
                        fontSize: titleFontSize,
                        fontWeight: FontWeight.w800,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (widget.subtitle != null)
                  Text(
                    widget.subtitle!,
                    style: AppTheme.getSubtitleStyle(
                      context,
                    ).copyWith(fontSize: subtitleFontSize),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                else
                  Text(
                    _getFormattedDate(),
                    style: AppTheme.getSubtitleStyle(
                      context,
                    ).copyWith(fontSize: subtitleFontSize),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),

          SizedBox(width: iconSpacing),

          if (widget.actions != null)
            ...widget.actions!
          else
            ..._buildHeaderActions(
              context,
              isDark,
              iconSize,
              iconSpacing,
              profileSize,
              profileFontSize,
              badgeSize,
              badgeFontSize,
              unreadCount,
              screenWidth,
            ),
        ],
      ),
    );
  }

  Widget _buildOfflineModeBanner(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: NetworkStatusService.isOffline,
      builder: (context, isOffline, _) {
        if (!isOffline) {
          return const SizedBox.shrink();
        }

        final isDark = Theme.of(context).brightness == Brightness.dark;
        return ValueListenableBuilder<String?>(
          valueListenable: NetworkStatusService.offlineReason,
          builder: (context, reason, _) {
            return Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 24),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
              decoration: BoxDecoration(
                color: isDark
                    ? AppTheme.colorFF1A3A6B.withValues(alpha: 0.14)
                    : AppTheme.colorFFEAF2FF.withValues(alpha: 0.72),
                border: Border(
                  bottom: BorderSide(
                    color: AppTheme.colorFF1A3A6B.withValues(alpha: 0.12),
                  ),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.cloud_off_rounded,
                    size: 13,
                    color: AppTheme.colorFF64748B,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Offline mode: saved local data is shown; changes sync when the connection returns.',
                      style: TextStyle(
                        color: isDark
                            ? AppTheme.white70
                            : AppTheme.colorFF64748B,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  List<Widget> _buildHeaderActions(
    BuildContext context,
    bool isDark,
    double iconSize,
    double iconSpacing,
    double profileSize,
    double profileFontSize,
    double badgeSize,
    double badgeFontSize,
    int unreadCount,
    double screenWidth,
  ) {
    final isMobile = screenWidth < 600;

    return [
      // Notifications Button with Badge
      CompositedTransformTarget(
        link: _notificationLayerLink,
        child: SizedBox(
          width: iconSize + 8,
          height: iconSize + 8,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Center(
                child: Semantics(
                  button: true,
                  label: unreadCount > 0
                      ? 'Notifications, $unreadCount unread'
                      : 'Notifications',
                  child: IconButton(
                    icon: Icon(
                      Icons.notifications_outlined,
                      size: iconSize,
                      color: AppTheme.getSubtleTextColor(context),
                    ),
                    onPressed: () => _toggleNotifications(context),
                    tooltip: 'Notifications',
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints.tightFor(
                      width: iconSize + 12,
                      height: iconSize + 12,
                    ),
                  ),
                ),
              ),
              if (unreadCount > 0)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    width: badgeSize,
                    height: badgeSize,
                    decoration: const BoxDecoration(
                      color: AppTheme.colorFFE74C3C,
                      shape: BoxShape.circle,
                    ),
                    child: isMobile
                        ? null
                        : Center(
                            child: Text(
                              unreadCount > 9 ? '9+' : '$unreadCount',
                              style: TextStyle(
                                fontSize: badgeFontSize,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.white,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                  ),
                ),
            ],
          ),
        ),
      ),

      SizedBox(width: iconSpacing),

      // Theme Toggle
      SizedBox(
        width: iconSize + 8,
        height: iconSize + 8,
        child: Center(
          child: Semantics(
            button: true,
            label: isDark ? 'Switch to light mode' : 'Switch to dark mode',
            child: IconButton(
              icon: Icon(
                isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                size: iconSize,
                color: AppTheme.getSubtleTextColor(context),
              ),
              onPressed: () {
                _toggleTheme(!isDark);
              },
              tooltip: isDark ? 'Light Mode' : 'Dark Mode',
              padding: EdgeInsets.zero,
              constraints: BoxConstraints.tightFor(
                width: iconSize + 12,
                height: iconSize + 12,
              ),
            ),
          ),
        ),
      ),

      // Refresh button â€” desktop only
      if (!isMobile) ...[
        SizedBox(width: iconSpacing),
        SizedBox(
          width: iconSize + 8,
          height: iconSize + 8,
          child: Center(
            child: Semantics(
              button: true,
              label: 'Refresh fleet data',
              child: IconButton(
                icon: Icon(
                  Icons.refresh_rounded,
                  size: iconSize,
                  color: AppTheme.getSubtleTextColor(context),
                ),
                onPressed: () {
                  final routeRefresh = widget.onRefresh;
                  if (routeRefresh != null) {
                    routeRefresh();
                  } else {
                    refreshFleetSnapshotSilently(forceRefresh: true);
                  }
                  _syncNotifications(forceRefresh: true);
                },
                tooltip: 'Refresh',
                padding: EdgeInsets.zero,
                constraints: BoxConstraints.tightFor(
                  width: iconSize + 12,
                  height: iconSize + 12,
                ),
              ),
            ),
          ),
        ),
      ],

      SizedBox(width: iconSpacing),

      // Profile Button
      CompositedTransformTarget(
        link: _profileLayerLink,
        child: Tooltip(
          message: 'Open account menu',
          child: Semantics(
            button: true,
            label: 'Open account menu',
            child: InkWell(
              onTap: () => _toggleProfile(context),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: profileSize,
                height: profileSize,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppTheme.goldAccent, AppTheme.primaryBlue],
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Text(
                    _getUserInitials(),
                    style: TextStyle(
                      fontSize: profileFontSize,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ];
  }

  String _getUserInitials() {
    final name =
        AuthService.currentUserData?.fullName ?? AuthService.currentUser;
    if (name.isEmpty) return '?';
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return name[0].toUpperCase();
  }

  Color _getRoleColor(UserRole? role) {
    switch (role) {
      case UserRole.admin:
        return AppTheme.colorFFE74C3C;
      case UserRole.ceo:
        return AppTheme.colorFFE74C3C;
      case UserRole.finance:
        return AppTheme.colorFF8B5CF6;
      case UserRole.manager:
        return AppTheme.colorFF4B7BE5;
      case UserRole.driver:
        return AppTheme.colorFF27AE60;
      case UserRole.client:
        return AppTheme.colorFF14B8A6;
      default:
        return AppTheme.colorFF4B7BE5;
    }
  }

  String _getFormattedDate() {
    final now = DateTime.now();
    final days = [
      'Sunday',
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
    ];
    final months = [
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
    return '${days[now.weekday % 7]}, ${months[now.month - 1]} ${now.day}, ${now.year}';
  }
}
