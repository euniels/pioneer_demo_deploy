import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth.dart';
import 'crud_permissions.dart';
import 'role_service.dart';

class SidebarItem {
  final IconData icon;
  final String title;
  final String route;
  final String? sectionKey; // for dropdown grouping
  const SidebarItem({
    required this.icon,
    required this.title,
    required this.route,
    this.sectionKey,
  });
}

class SidebarSection {
  final String key;
  final String title;
  final IconData icon;
  final List<SidebarItem> items;
  const SidebarSection({
    required this.key,
    required this.title,
    required this.icon,
    required this.items,
  });
}

class SidebarService {
  static bool _isCollapsed = false;
  static bool get isCollapsed => _isCollapsed;

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _isCollapsed = prefs.getBool('sidebar_collapsed') ?? false;
  }

  static Future<void> setCollapsed(bool value) async {
    _isCollapsed = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sidebar_collapsed', value);
  }

  // ── Returns flat list of sidebar items for current role ────────────────────
  static List<SidebarItem> getItemsForRole(UserRole role) {
    final items = switch (role) {
      UserRole.admin => _adminItems,
      UserRole.ceo => _ceoItems,
      UserRole.finance => _financeItems,
      UserRole.manager => _managerItems,
      UserRole.driver => _driverItems,
      UserRole.client => _clientItems,
    };
    return items
        .where((item) => CrudPermissions.canAccessRoute(item.route))
        .toList(growable: false);
  }

  // ── Returns grouped sections for current role ──────────────────────────────
  static List<SidebarSection> getSectionsForRole(UserRole role) {
    final sections = switch (role) {
      UserRole.admin => _adminSections,
      UserRole.ceo => _ceoSections,
      UserRole.finance => _financeSections,
      UserRole.manager => _managerSections,
      UserRole.driver => _driverSections,
      UserRole.client => _clientSections,
    };
    return sections
        .map(
          (section) => SidebarSection(
            key: section.key,
            title: section.title,
            icon: section.icon,
            items: section.items
                .where((item) => CrudPermissions.canAccessRoute(item.route))
                .toList(growable: false),
          ),
        )
        .where((section) => section.items.isNotEmpty)
        .toList(growable: false);
  }

  static List<SidebarItem> getCurrentItems() {
    final role = AuthService.currentRole;
    if (role == null) return [];
    return getItemsForRole(role);
  }

  // ── ADMIN ──────────────────────────────────────────────────────────────────
  static const _adminItems = [
    SidebarItem(
      icon: Icons.dashboard_rounded,
      title: 'Dashboard',
      route: '/dashboard',
    ),
    SidebarItem(
      icon: Icons.analytics_rounded,
      title: 'Analytics',
      route: '/analytics',
    ),
    SidebarItem(
      icon: Icons.people_rounded,
      title: 'Drivers',
      route: '/drivers',
    ),
    SidebarItem(
      icon: Icons.local_shipping_rounded,
      title: 'Vehicles',
      route: '/vehicles',
    ),
    SidebarItem(
      icon: Icons.send_rounded,
      title: 'Dispatch Queue',
      route: '/dispatch-queue',
    ),
    SidebarItem(
      icon: Icons.alt_route_rounded,
      title: 'Routes',
      route: '/routes',
    ),
    SidebarItem(icon: Icons.hexagon_rounded, title: 'Zones', route: '/zones'),
    SidebarItem(
      icon: Icons.map_rounded,
      title: 'Live Tracking',
      route: '/live-tracking',
    ),
    SidebarItem(icon: Icons.route_rounded, title: 'Trips', route: '/trips'),
    SidebarItem(
      icon: Icons.payment_rounded,
      title: 'Billing',
      route: '/billing',
    ),
    SidebarItem(
      icon: Icons.business_rounded,
      title: 'Clients',
      route: '/clients',
    ),
    SidebarItem(
      icon: Icons.local_gas_station_rounded,
      title: 'Fuel & Expenses',
      route: '/delivery-confirm',
    ),
    SidebarItem(
      icon: Icons.public_rounded,
      title: 'Client Tracking',
      route: '/client-tracking',
    ),
    SidebarItem(
      icon: Icons.build_rounded,
      title: 'Maintenance',
      route: '/maintenance',
    ),
    SidebarItem(
      icon: Icons.description_rounded,
      title: 'Statements',
      route: '/statements-of-accounts',
    ),
    SidebarItem(
      icon: Icons.notifications_rounded,
      title: 'Notifications',
      route: '/notifications',
    ),
    SidebarItem(
      icon: Icons.manage_accounts_rounded,
      title: 'Users & Roles',
      route: '/users',
    ),
    SidebarItem(
      icon: Icons.manage_search_rounded,
      title: 'Audit Logs',
      route: '/audit-logs',
    ),
    SidebarItem(
      icon: Icons.settings_rounded,
      title: 'Settings',
      route: '/settings',
    ),
  ];

  static const _adminSections = [
    SidebarSection(
      key: 'overview',
      title: 'Overview',
      icon: Icons.dashboard_rounded,
      items: [
        SidebarItem(
          icon: Icons.dashboard_rounded,
          title: 'Dashboard',
          route: '/dashboard',
        ),
        SidebarItem(
          icon: Icons.analytics_rounded,
          title: 'Analytics',
          route: '/analytics',
        ),
        SidebarItem(
          icon: Icons.map_rounded,
          title: 'Live Tracking',
          route: '/live-tracking',
        ),
      ],
    ),
    SidebarSection(
      key: 'fleet',
      title: 'Fleet',
      icon: Icons.local_shipping_rounded,
      items: [
        SidebarItem(
          icon: Icons.people_rounded,
          title: 'Drivers',
          route: '/drivers',
        ),
        SidebarItem(
          icon: Icons.local_shipping_rounded,
          title: 'Vehicles',
          route: '/vehicles',
        ),
        SidebarItem(
          icon: Icons.send_rounded,
          title: 'Dispatch Queue',
          route: '/dispatch-queue',
        ),
        SidebarItem(
          icon: Icons.alt_route_rounded,
          title: 'Routes',
          route: '/routes',
        ),
        SidebarItem(
          icon: Icons.hexagon_rounded,
          title: 'Zones',
          route: '/zones',
        ),
        SidebarItem(icon: Icons.route_rounded, title: 'Trips', route: '/trips'),
        SidebarItem(
          icon: Icons.build_rounded,
          title: 'Maintenance',
          route: '/maintenance',
        ),
      ],
    ),
    SidebarSection(
      key: 'administration',
      title: 'Administration',
      icon: Icons.admin_panel_settings_rounded,
      items: [
        SidebarItem(
          icon: Icons.notifications_rounded,
          title: 'Notifications',
          route: '/notifications',
        ),
        SidebarItem(
          icon: Icons.manage_accounts_rounded,
          title: 'Users & Roles',
          route: '/users',
        ),
        SidebarItem(
          icon: Icons.manage_search_rounded,
          title: 'Audit Logs',
          route: '/audit-logs',
        ),
        SidebarItem(
          icon: Icons.settings_rounded,
          title: 'Settings',
          route: '/settings',
        ),
      ],
    ),
    SidebarSection(
      key: 'finance',
      title: 'Finance',
      icon: Icons.account_balance_rounded,
      items: [
        SidebarItem(
          icon: Icons.payment_rounded,
          title: 'Billing',
          route: '/billing',
        ),
        SidebarItem(
          icon: Icons.business_rounded,
          title: 'Clients',
          route: '/clients',
        ),
        SidebarItem(
          icon: Icons.local_gas_station_rounded,
          title: 'Fuel & Expenses',
          route: '/delivery-confirm',
        ),
        SidebarItem(
          icon: Icons.public_rounded,
          title: 'Client Tracking',
          route: '/client-tracking',
        ),
        SidebarItem(
          icon: Icons.description_rounded,
          title: 'Statements',
          route: '/statements-of-accounts',
        ),
      ],
    ),
  ];

  // ── CEO ────────────────────────────────────────────────────────────────────
  static const _ceoItems = [
    SidebarItem(
      icon: Icons.dashboard_rounded,
      title: 'Dashboard',
      route: '/dashboard',
    ),
    SidebarItem(
      icon: Icons.analytics_rounded,
      title: 'Analytics',
      route: '/analytics',
    ),
    SidebarItem(
      icon: Icons.people_rounded,
      title: 'Drivers',
      route: '/drivers',
    ),
    SidebarItem(
      icon: Icons.map_rounded,
      title: 'Live Tracking',
      route: '/live-tracking',
    ),
    SidebarItem(icon: Icons.route_rounded, title: 'Trips', route: '/trips'),
    SidebarItem(
      icon: Icons.description_rounded,
      title: 'Statements',
      route: '/statements-of-accounts',
    ),
    SidebarItem(
      icon: Icons.person_rounded,
      title: 'My Profile',
      route: '/ceo-profile',
    ),
    SidebarItem(
      icon: Icons.notifications_rounded,
      title: 'Notifications',
      route: '/notifications',
    ),
    SidebarItem(
      icon: Icons.settings_rounded,
      title: 'Settings',
      route: '/settings',
    ),
  ];

  static const _ceoSections = [
    SidebarSection(
      key: 'overview',
      title: 'Overview',
      icon: Icons.dashboard_rounded,
      items: [
        SidebarItem(
          icon: Icons.dashboard_rounded,
          title: 'Dashboard',
          route: '/dashboard',
        ),
        SidebarItem(
          icon: Icons.analytics_rounded,
          title: 'Analytics',
          route: '/analytics',
        ),
        SidebarItem(
          icon: Icons.map_rounded,
          title: 'Live Tracking',
          route: '/live-tracking',
        ),
      ],
    ),
    SidebarSection(
      key: 'operations',
      title: 'Operations',
      icon: Icons.local_shipping_rounded,
      items: [
        SidebarItem(
          icon: Icons.people_rounded,
          title: 'Drivers',
          route: '/drivers',
        ),
        SidebarItem(icon: Icons.route_rounded, title: 'Trips', route: '/trips'),
        SidebarItem(
          icon: Icons.description_rounded,
          title: 'Statements',
          route: '/statements-of-accounts',
        ),
      ],
    ),
  ];

  // ── FINANCE ────────────────────────────────────────────────────────────────
  static const _financeItems = [
    SidebarItem(
      icon: Icons.payment_rounded,
      title: 'Billing',
      route: '/billing',
    ),
    SidebarItem(
      icon: Icons.business_rounded,
      title: 'Clients',
      route: '/clients',
    ),
    SidebarItem(
      icon: Icons.local_gas_station_rounded,
      title: 'Fuel & Expenses',
      route: '/delivery-confirm',
    ),
    SidebarItem(
      icon: Icons.public_rounded,
      title: 'Client Tracking',
      route: '/client-tracking',
    ),
    SidebarItem(
      icon: Icons.description_rounded,
      title: 'Statements',
      route: '/statements-of-accounts',
    ),
    SidebarItem(
      icon: Icons.person_rounded,
      title: 'My Profile',
      route: '/finance-profile',
    ),
    SidebarItem(
      icon: Icons.notifications_rounded,
      title: 'Notifications',
      route: '/notifications',
    ),
    SidebarItem(
      icon: Icons.settings_rounded,
      title: 'Settings',
      route: '/settings',
    ),
  ];

  static const _financeSections = [
    SidebarSection(
      key: 'finance',
      title: 'Finance',
      icon: Icons.account_balance_rounded,
      items: [
        SidebarItem(
          icon: Icons.payment_rounded,
          title: 'Billing',
          route: '/billing',
        ),
        SidebarItem(
          icon: Icons.business_rounded,
          title: 'Clients',
          route: '/clients',
        ),
        SidebarItem(
          icon: Icons.local_gas_station_rounded,
          title: 'Fuel & Expenses',
          route: '/delivery-confirm',
        ),
        SidebarItem(
          icon: Icons.description_rounded,
          title: 'Statements',
          route: '/statements-of-accounts',
        ),
      ],
    ),
  ];

  // ── MANAGER ────────────────────────────────────────────────────────────────
  static const _managerItems = [
    SidebarItem(
      icon: Icons.dashboard_rounded,
      title: 'Dashboard',
      route: '/dashboard',
    ),
    SidebarItem(
      icon: Icons.people_rounded,
      title: 'Drivers',
      route: '/drivers',
    ),
    SidebarItem(
      icon: Icons.local_shipping_rounded,
      title: 'Vehicles',
      route: '/vehicles',
    ),
    SidebarItem(
      icon: Icons.send_rounded,
      title: 'Dispatch Queue',
      route: '/dispatch-queue',
    ),
    SidebarItem(
      icon: Icons.alt_route_rounded,
      title: 'Routes',
      route: '/routes',
    ),
    SidebarItem(icon: Icons.hexagon_rounded, title: 'Zones', route: '/zones'),
    SidebarItem(
      icon: Icons.map_rounded,
      title: 'Live Tracking',
      route: '/live-tracking',
    ),
    SidebarItem(icon: Icons.route_rounded, title: 'Trips', route: '/trips'),
    SidebarItem(
      icon: Icons.build_rounded,
      title: 'Maintenance',
      route: '/maintenance',
    ),
    SidebarItem(
      icon: Icons.person_rounded,
      title: 'My Profile',
      route: '/manager-profile',
    ),
    SidebarItem(
      icon: Icons.notifications_rounded,
      title: 'Notifications',
      route: '/notifications',
    ),
    SidebarItem(
      icon: Icons.settings_rounded,
      title: 'Settings',
      route: '/settings',
    ),
  ];

  static const _managerSections = [
    SidebarSection(
      key: 'overview',
      title: 'Overview',
      icon: Icons.dashboard_rounded,
      items: [
        SidebarItem(
          icon: Icons.dashboard_rounded,
          title: 'Dashboard',
          route: '/dashboard',
        ),
        SidebarItem(
          icon: Icons.map_rounded,
          title: 'Live Tracking',
          route: '/live-tracking',
        ),
      ],
    ),
    SidebarSection(
      key: 'fleet',
      title: 'Fleet',
      icon: Icons.local_shipping_rounded,
      items: [
        SidebarItem(
          icon: Icons.people_rounded,
          title: 'Drivers',
          route: '/drivers',
        ),
        SidebarItem(
          icon: Icons.local_shipping_rounded,
          title: 'Vehicles',
          route: '/vehicles',
        ),
        SidebarItem(
          icon: Icons.send_rounded,
          title: 'Dispatch Queue',
          route: '/dispatch-queue',
        ),
        SidebarItem(
          icon: Icons.alt_route_rounded,
          title: 'Routes',
          route: '/routes',
        ),
        SidebarItem(
          icon: Icons.hexagon_rounded,
          title: 'Zones',
          route: '/zones',
        ),
        SidebarItem(icon: Icons.route_rounded, title: 'Trips', route: '/trips'),
        SidebarItem(
          icon: Icons.build_rounded,
          title: 'Maintenance',
          route: '/maintenance',
        ),
      ],
    ),
  ];

  // ── DRIVER ─────────────────────────────────────────────────────────────────
  static const _driverItems = [
    SidebarItem(
      icon: Icons.dashboard_rounded,
      title: 'Dashboard',
      route: '/driver-dashboard',
    ),
    SidebarItem(icon: Icons.map_rounded, title: 'My Map', route: '/driver-map'),
    SidebarItem(
      icon: Icons.route_rounded,
      title: 'My Trips',
      route: '/driver-trips',
    ),
    SidebarItem(
      icon: Icons.attach_money_rounded,
      title: 'My Earnings',
      route: '/driver-earnings',
    ),
    SidebarItem(
      icon: Icons.local_shipping_rounded,
      title: 'My Vehicle',
      route: '/driver-vehicle',
    ),
    SidebarItem(
      icon: Icons.person_rounded,
      title: 'My Profile',
      route: '/driver-profile',
    ),
    SidebarItem(
      icon: Icons.notifications_rounded,
      title: 'Notifications',
      route: '/notifications',
    ),
    SidebarItem(
      icon: Icons.settings_rounded,
      title: 'Settings',
      route: '/settings',
    ),
  ];

  static const _driverSections = [
    SidebarSection(
      key: 'driver',
      title: 'My Work',
      icon: Icons.work_rounded,
      items: [
        SidebarItem(
          icon: Icons.dashboard_rounded,
          title: 'Dashboard',
          route: '/driver-dashboard',
        ),
        SidebarItem(
          icon: Icons.map_rounded,
          title: 'My Map',
          route: '/driver-map',
        ),
        SidebarItem(
          icon: Icons.route_rounded,
          title: 'My Trips',
          route: '/driver-trips',
        ),
        SidebarItem(
          icon: Icons.attach_money_rounded,
          title: 'My Earnings',
          route: '/driver-earnings',
        ),
        SidebarItem(
          icon: Icons.local_shipping_rounded,
          title: 'My Vehicle',
          route: '/driver-vehicle',
        ),
      ],
    ),
  ];

  static const _clientItems = [
    SidebarItem(
      icon: Icons.public_rounded,
      title: 'Client Tracking',
      route: '/client-tracking',
    ),
    SidebarItem(
      icon: Icons.notifications_rounded,
      title: 'Notifications',
      route: '/notifications',
    ),
    SidebarItem(
      icon: Icons.settings_rounded,
      title: 'Settings',
      route: '/settings',
    ),
  ];

  static const _clientSections = [
    SidebarSection(
      key: 'client',
      title: 'Client Portal',
      icon: Icons.public_rounded,
      items: [
        SidebarItem(
          icon: Icons.public_rounded,
          title: 'Client Tracking',
          route: '/client-tracking',
        ),
        SidebarItem(
          icon: Icons.notifications_rounded,
          title: 'Notifications',
          route: '/notifications',
        ),
        SidebarItem(
          icon: Icons.settings_rounded,
          title: 'Settings',
          route: '/settings',
        ),
      ],
    ),
  ];
}
