import 'package:flutter/material.dart';
import '../services/auth.dart';
import '../services/sidebar_service.dart';
import 'pioneer_logo.dart';
import '../services/role_service.dart';
import '../theme/app_theme.dart';

class FleetSidebar extends StatefulWidget {
  final String currentRoute;
  final bool isCollapsed;
  final VoidCallback onToggleCollapse;

  const FleetSidebar({
    super.key,
    required this.currentRoute,
    required this.isCollapsed,
    required this.onToggleCollapse,
  });

  @override
  State<FleetSidebar> createState() => _FleetSidebarState();
}

class _FleetSidebarState extends State<FleetSidebar> {
  String? _hoveredRoute;
  final Set<String> _expandedSections = {};
  bool _isLoggingOut = false;

  @override
  void initState() {
    super.initState();
    AuthService.logoutInProgress.addListener(_syncLogoutProgress);
    // Auto-expand the section that contains the current route
    final role = AuthService.currentRole;
    if (role != null) {
      final sections = SidebarService.getSectionsForRole(role);
      for (final section in sections) {
        if (section.items.any((item) => item.route == widget.currentRoute)) {
          _expandedSections.add(section.key);
        }
      }
      // Default: expand first section
      if (_expandedSections.isEmpty && sections.isNotEmpty) {
        _expandedSections.add(sections.first.key);
      }
    }
  }

  void _syncLogoutProgress() {
    if (!mounted) return;
    setState(() => _isLoggingOut = AuthService.logoutInProgress.value);
  }

  @override
  void dispose() {
    AuthService.logoutInProgress.removeListener(_syncLogoutProgress);
    super.dispose();
  }

  @override
  void didUpdateWidget(FleetSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync expanded sections whenever the active route changes
    if (oldWidget.currentRoute != widget.currentRoute) {
      final role = AuthService.currentRole;
      if (role != null) {
        final sections = SidebarService.getSectionsForRole(role);
        for (final section in sections) {
          if (section.items.any((item) => item.route == widget.currentRoute)) {
            if (!_expandedSections.contains(section.key)) {
              setState(() => _expandedSections.add(section.key));
            }
            break;
          }
        }
      }
    }
  }

  // â”€â”€ Role accent color â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Color _getRoleAccent(UserRole? role) {
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final role = AuthService.currentRole;
    final user = AuthService.currentUserData;
    final accent = _getRoleAccent(role);

    final sidebarBg = isDark ? AppTheme.colorFF0F1117 : AppTheme.white;
    final dividerColor = isDark
        ? AppTheme.white.withValues(alpha: 0.06)
        : AppTheme.black.withValues(alpha: 0.08);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
      width: widget.isCollapsed ? 64 : 240,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: sidebarBg,
        border: Border(right: BorderSide(color: dividerColor)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Switch collapsed/expanded layout based on actual rendered width
          // so the expanded nav tiles are never laid out during animation
          // when the container is still narrow.
          final eff = constraints.maxWidth < 120;
          return Column(
            children: [
              // â”€â”€ Brand header â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
              _buildBrand(isDark, accent, eff),

              Divider(height: 1, thickness: 1, color: dividerColor),

              // â”€â”€ User card (expanded only) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
              if (!eff) ...[
                _buildUserCard(isDark, user, role, accent),
                Divider(height: 1, thickness: 1, color: dividerColor),
              ],

              // â”€â”€ Collapsed: avatar only â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
              if (eff) ...[
                const SizedBox(height: 10),
                _buildCollapsedAvatar(user, accent),
                const SizedBox(height: 8),
                Divider(height: 1, thickness: 1, color: dividerColor),
              ],

              // â”€â”€ Navigation â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
              Expanded(
                child: eff
                    ? _buildCollapsedNav(isDark, accent)
                    : _buildExpandedNav(isDark, role, accent, dividerColor),
              ),

              Divider(height: 1, thickness: 1, color: dividerColor),

              // â”€â”€ Collapse toggle at the BOTTOM â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
              _buildCollapseButton(isDark, accent, eff),

              // â”€â”€ Logout â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
              _buildLogout(isDark, eff),
            ],
          );
        },
      ),
    );
  }

  // â”€â”€ Brand â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildBrand(bool isDark, Color accent, bool isCollapsed) {
    // Logo box shared between collapsed and expanded
    final logo = PioneerPathLogo(
      size: isCollapsed ? 32 : 48,
      variant: isDark
          ? PioneerPathLogoVariant.lightOnDark
          : PioneerPathLogoVariant.darkOnLight,
    );

    return SizedBox(
      height: 56,
      // Collapsed: just center the logo, no horizontal padding
      child: isCollapsed
          ? Center(child: logo)
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  logo,

                  // Title â€” only when expanded
                  ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'PioneerPath',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: isDark
                                  ? AppTheme.white
                                  : AppTheme.colorFF1A1D23,
                              letterSpacing: 0.2,
                            ),
                          ),
                          Text(
                            'PIONEER',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: accent,
                              letterSpacing: 2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  // â”€â”€ User card â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildUserCard(
    bool isDark,
    dynamic user,
    UserRole? role,
    Color accent,
  ) {
    final name = user?.fullName ?? 'User';
    final roleName = role != null
        ? RolePermissions.getRoleDisplayName(role)
        : '';

    return Container(
      margin: const EdgeInsets.all(10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark
            ? AppTheme.white.withValues(alpha: 0.04)
            : AppTheme.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.07)
              : AppTheme.black.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        children: [
          // Avatar
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: accent.withValues(alpha: 0.3),
                width: 1.5,
              ),
            ),
            child: Center(
              child: Text(
                name.isNotEmpty ? name[0].toUpperCase() : 'U',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: accent,
                ),
              ),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppTheme.white : AppTheme.colorFF1A1D23,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    roleName,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: accent,
                      letterSpacing: 0.2,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // â”€â”€ Collapsed avatar circle â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildCollapsedAvatar(dynamic user, Color accent) {
    final name = user?.fullName ?? 'U';
    return Tooltip(
      message: name,
      preferBelow: false,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: accent.withValues(alpha: 0.3), width: 1.5),
        ),
        child: Center(
          child: Text(
            name.isNotEmpty ? name[0].toUpperCase() : 'U',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: accent,
            ),
          ),
        ),
      ),
    );
  }

  // â”€â”€ Expanded nav with sections â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildExpandedNav(
    bool isDark,
    UserRole? role,
    Color accent,
    Color dividerColor,
  ) {
    if (role == null) return const SizedBox.shrink();

    final sections = SidebarService.getSectionsForRole(role);
    // standalone items = items NOT belonging to any section
    // (notifications, settings)
    final allSectionRoutes = sections
        .expand((s) => s.items.map((i) => i.route))
        .toSet();
    final standaloneItems = SidebarService.getItemsForRole(
      role,
    ).where((i) => !allSectionRoutes.contains(i.route)).toList();

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        // Sections with accordion headers
        for (final section in sections) ...[
          _buildSectionHeader(section, isDark, accent, dividerColor),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: _expandedSections.contains(section.key)
                ? Column(
                    children: section.items
                        .map(
                          (item) => _buildNavTile(
                            item: item,
                            isDark: isDark,
                            accent: accent,
                            indent: true,
                          ),
                        )
                        .toList(),
                  )
                : const SizedBox.shrink(),
          ),
        ],

        // Standalone items (notifications, settings)
        if (standaloneItems.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
            child: Text(
              'GENERAL',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: isDark ? AppTheme.gray600 : AppTheme.gray500,
                letterSpacing: 1.2,
              ),
            ),
          ),
          ...standaloneItems.map(
            (item) => _buildNavTile(
              item: item,
              isDark: isDark,
              accent: accent,
              indent: false,
            ),
          ),
        ],

        const SizedBox(height: 8),
      ],
    );
  }

  // â”€â”€ Collapsed nav: icon-only â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildCollapsedNav(bool isDark, Color accent) {
    final role = AuthService.currentRole;
    if (role == null) return const SizedBox.shrink();

    final items = SidebarService.getItemsForRole(role);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: items.map((item) {
        final isActive = widget.currentRoute == item.route;
        return Tooltip(
          message: item.title,
          preferBelow: false,
          waitDuration: const Duration(milliseconds: 300),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hoveredRoute = item.route),
            onExit: (_) => setState(() => _hoveredRoute = null),
            child: GestureDetector(
              onTap: () {
                if (widget.currentRoute != item.route) {
                  Navigator.pushReplacementNamed(context, item.route);
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 130),
                margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                height: 40,
                decoration: BoxDecoration(
                  color: isActive
                      ? accent.withValues(alpha: 0.14)
                      : _hoveredRoute == item.route
                      ? (isDark
                            ? AppTheme.white.withValues(alpha: 0.05)
                            : AppTheme.black.withValues(alpha: 0.04))
                      : AppTheme.transparent,
                  borderRadius: BorderRadius.circular(9),
                  border: isActive
                      ? Border.all(color: accent.withValues(alpha: 0.25))
                      : null,
                ),
                child: Center(
                  child: Icon(
                    item.icon,
                    size: 19,
                    color: isActive
                        ? accent
                        : (isDark ? AppTheme.gray500 : AppTheme.gray500),
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  // â”€â”€ Section accordion header â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildSectionHeader(
    SidebarSection section,
    bool isDark,
    Color accent,
    Color dividerColor,
  ) {
    final isOpen = _expandedSections.contains(section.key);
    final hasActive = section.items.any((i) => i.route == widget.currentRoute);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          setState(() {
            if (isOpen) {
              _expandedSections.remove(section.key);
            } else {
              _expandedSections.add(section.key);
            }
          });
        },
        child: Container(
          margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
          child: Row(
            children: [
              Icon(
                section.icon,
                size: 15,
                color: hasActive
                    ? accent
                    : (isDark ? AppTheme.gray500 : AppTheme.gray500),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  section.title.toUpperCase(),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                    color: hasActive
                        ? accent
                        : (isDark ? AppTheme.gray500 : AppTheme.gray500),
                  ),
                ),
              ),
              AnimatedRotation(
                turns: isOpen ? 0.25 : 0,
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 16,
                  color: isDark ? AppTheme.gray600 : AppTheme.gray500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // â”€â”€ Single nav tile â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildNavTile({
    required SidebarItem item,
    required bool isDark,
    required Color accent,
    required bool indent,
  }) {
    final isActive = widget.currentRoute == item.route;
    final isHovered = _hoveredRoute == item.route;

    Color bgColor = AppTheme.transparent;
    Color iconColor = isDark ? AppTheme.gray500 : AppTheme.gray500;
    Color textColor = isDark ? AppTheme.gray400 : AppTheme.gray600;

    if (isActive) {
      bgColor = accent.withValues(alpha: 0.12);
      iconColor = accent;
      textColor = isDark ? AppTheme.white : AppTheme.colorFF1A1D23;
    } else if (isHovered) {
      bgColor = isDark
          ? AppTheme.white.withValues(alpha: 0.05)
          : AppTheme.black.withValues(alpha: 0.04);
      iconColor = isDark ? AppTheme.gray300 : AppTheme.gray700;
      textColor = isDark ? AppTheme.white : AppTheme.colorFF1A1D23;
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hoveredRoute = item.route),
      onExit: (_) => setState(() => _hoveredRoute = null),
      child: GestureDetector(
        onTap: () {
          if (widget.currentRoute != item.route) {
            Navigator.pushReplacementNamed(context, item.route);
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          margin: EdgeInsets.fromLTRB(indent ? 14 : 8, 2, 8, 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(9),
            border: isActive
                ? Border.all(color: accent.withValues(alpha: 0.2))
                : null,
          ),
          child: Row(
            children: [
              // Active indicator bar
              AnimatedContainer(
                duration: const Duration(milliseconds: 130),
                width: 2.5,
                height: 16,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: isActive ? accent : AppTheme.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Icon(item.icon, size: 16, color: iconColor),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  item.title,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                    color: textColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // â”€â”€ Collapse toggle â€” BOTTOM of sidebar, no overflow â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Inspired by VS Code / Notion / Linear sidebar collapse button
  Widget _buildCollapseButton(bool isDark, Color accent, bool isCollapsed) {
    return Tooltip(
      message: isCollapsed ? 'Expand sidebar' : 'Collapse sidebar',
      preferBelow: false,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onToggleCollapse,
          child: Container(
            height: 40,
            padding: EdgeInsets.symmetric(horizontal: isCollapsed ? 0 : 12),
            child: isCollapsed
                // collapsed: centred icon
                ? Center(
                    child: Icon(
                      Icons.keyboard_double_arrow_right_rounded,
                      size: 18,
                      color: isDark ? AppTheme.gray500 : AppTheme.gray500,
                    ),
                  )
                // expanded: icon + label on the left
                : Row(
                    children: [
                      Icon(
                        Icons.keyboard_double_arrow_left_rounded,
                        size: 18,
                        color: isDark ? AppTheme.gray500 : AppTheme.gray500,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Collapse',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: isDark ? AppTheme.gray500 : AppTheme.gray500,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  // â”€â”€ Logout â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildLogout(bool isDark, bool isCollapsed) {
    const red = AppTheme.colorFFE74C3C;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () async {
          if (_isLoggingOut) return;
          final confirm = await showDialog<bool>(
            context: context,
            barrierDismissible: !_isLoggingOut,
            builder: (ctx) => StatefulBuilder(
              builder: (ctx, setDialogState) => AlertDialog(
                backgroundColor:
                    isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                title: Text(
                  'Sign Out',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppTheme.white : AppTheme.colorFF1A1D23,
                  ),
                ),
                content: Text(
                  _isLoggingOut
                      ? 'Signing you out and clearing this session...'
                      : 'Are you sure you want to sign out?',
                  style: TextStyle(
                    color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed:
                        _isLoggingOut ? null : () => Navigator.pop(ctx, false),
                    child: Text(
                      'Cancel',
                      style: TextStyle(
                        color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _isLoggingOut
                        ? null
                        : () async {
                            setDialogState(() => _isLoggingOut = true);
                            setState(() => _isLoggingOut = true);
                            await AuthService.logout();
                            if (ctx.mounted) {
                              Navigator.pushNamedAndRemoveUntil(
                                ctx,
                                '/login',
                                (route) => false,
                              );
                            }
                          },
                    style: TextButton.styleFrom(foregroundColor: red),
                    child: _isLoggingOut
                        ? const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Signing out...',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ],
                          )
                        : const Text(
                            'Sign Out',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                  ),
                ],
              ),
            ),
          );
          if (confirm != true && mounted) {
            setState(() => _isLoggingOut = false);
          }
        },
        child: Container(
          height: 44,
          padding: EdgeInsets.symmetric(horizontal: isCollapsed ? 0 : 14),
          child: isCollapsed
              ? Tooltip(
                  message: 'Sign Out',
                  preferBelow: false,
                  child: Center(
                    child: Icon(
                      Icons.logout_rounded,
                      size: 18,
                      color: red.withValues(alpha: 0.75),
                    ),
                  ),
                )
              : Row(
                  children: [
                    Icon(
                      Icons.logout_rounded,
                      size: 17,
                      color: red.withValues(alpha: 0.75),
                    ),
                    const SizedBox(width: 9),
                    Text(
                      'Sign Out',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: red.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
