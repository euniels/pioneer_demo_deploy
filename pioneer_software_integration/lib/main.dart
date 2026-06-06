import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'src/pages/dashboard_page.dart';
import 'src/pages/notification_page.dart' deferred as notifications_page;
import 'src/pages/live_tracking_page_enhanced.dart' deferred as live_page;
import 'src/pages/vehicles_page.dart' deferred as vehicles_page;
import 'src/pages/client_tracking_page.dart' deferred as client_tracking_page;
import 'src/pages/drivers_page.dart' deferred as drivers_page;
import 'src/pages/dispatch_queue_page.dart' deferred as dispatch_page;
import 'src/pages/analytics_page.dart' deferred as analytics_page;
import 'src/pages/trips_page.dart' deferred as trips_page;
import 'src/pages/routes_page.dart' deferred as routes_page;
import 'src/pages/zones_page.dart' deferred as zones_page;
import 'src/pages/clients_page.dart' deferred as clients_page;
import 'src/pages/login_page.dart';
import 'src/pages/change_password_page.dart';
import 'src/pages/reset_password_page.dart';
import 'src/pages/settings_page.dart' deferred as settings_page;
import 'src/pages/users_page.dart' deferred as users_page;
import 'src/pages/audit_log_page.dart' deferred as audit_page;
import 'src/pages/fuel_expenses_page.dart' deferred as fuel_page;
import 'src/pages/statements_of_accounts.dart' deferred as soa_page;
import 'src/services/auth.dart';
import 'src/services/app_logger.dart';
import 'src/services/backend_api.dart';
import 'src/services/sidebar_service.dart';
import 'src/services/route_guard.dart';
import 'src/pages/billing_page.dart' deferred as billing_page;
import 'src/pages/maintenance_page.dart' deferred as maintenance_page;
// Driver pages
import 'src/pages/driver_dashboard_page.dart';
import 'src/pages/driver_profile_page.dart';
import 'src/pages/driver_earnings_page.dart';
import 'src/pages/driver_vehicle_page.dart';
import 'src/pages/driver_map_page.dart';
import 'src/pages/driver_trips_page.dart';
// Role profile pages
import 'src/pages/ceo_profile_page.dart';
import 'src/pages/finance_profile_page.dart';
import 'src/pages/manager_profile_page.dart';
import 'src/services/fleet_data_coordinator.dart';
import 'src/services/google_maps_loader.dart';
import 'src/services/push_notification_service.dart';
import 'src/services/realtime_stream_service.dart';
import 'src/theme/app_theme.dart';
import 'src/widgets/page_skeletons.dart';

final GlobalKey<NavigatorState> pioneerNavigatorKey =
    GlobalKey<NavigatorState>();

class _NoTransitionsBuilder extends PageTransitionsBuilder {
  const _NoTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }
}

void main() {
  // Run inside a guarded zone so the binding is initialized and runApp
  // execute in the same zone (avoids "Zone mismatch" errors).
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // Global Flutter error handler to surface uncaught Flutter errors.
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        AppLogger.reportFlutterError(details);
      };
      PlatformDispatcher.instance.onError = AppLogger.reportPlatformError;

      Future<void> _safeInit(String name, Future<void> Function() fn) async {
        final sw = Stopwatch()..start();
        try {
          await fn();
          AppLogger.info('Startup step completed', {
            'name': name,
            'elapsedMs': sw.elapsedMilliseconds,
          });
        } catch (e, st) {
          AppLogger.error(
            'Startup step failed',
            error: e,
            stackTrace: st,
            context: {'name': name, 'elapsedMs': sw.elapsedMilliseconds},
          );
        } finally {
          sw.stop();
        }
      }

      // Run each initialization step safely and log timings/errors.
      await _safeInit('AuthService.init', () => AuthService.init());
      AuthService.setSessionExpiredRedirect(() {
        pioneerNavigatorKey.currentState?.pushNamedAndRemoveUntil(
          '/login',
          (_) => false,
        );
      });
      await _safeInit('SidebarService.init', () => SidebarService.init());
      // Start the app.
      runApp(const PioneerPathApp());

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (AuthService.isLoggedIn) {
          unawaited(
            _safeInit('FleetDataCoordinator.initialize', () {
              return FleetDataCoordinator.initialize();
            }).then((_) => FleetDataCoordinator.startPriorityQueue()),
          );
          RealtimeStreamService.start();
        }
        unawaited(PushNotificationService.initialize());
        unawaited(BackendApiService.replayQueuedMutations().catchError((_) {}));
        preloadGoogleMaps();
      });
    },
    (error, stack) {
      AppLogger.error('Unhandled zone error', error: error, stackTrace: stack);
    },
  );
}

class PioneerPathApp extends StatelessWidget {
  const PioneerPathApp({super.key});

  @override
  Widget build(BuildContext context) {
    const transitions = PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _NoTransitionsBuilder(),
        TargetPlatform.iOS: _NoTransitionsBuilder(),
        TargetPlatform.windows: _NoTransitionsBuilder(),
        TargetPlatform.linux: _NoTransitionsBuilder(),
        TargetPlatform.macOS: _NoTransitionsBuilder(),
      },
    );

    final baseThemeLight = AppTheme.buildLightTheme().copyWith(
      pageTransitionsTheme: transitions,
    );
    final baseThemeDark = AppTheme.buildDarkTheme().copyWith(
      pageTransitionsTheme: transitions,
    );

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AuthService.themeMode,
      builder: (context, mode, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'PioneerPath',
          navigatorKey: pioneerNavigatorKey,
          theme: baseThemeLight,
          darkTheme: baseThemeDark,
          themeMode: mode,
          // ── Role-aware initial route ──────────────────────────────
          initialRoute: AuthService.isLoggedIn
              ? (AuthService.mustChangePassword
                    ? '/change-password'
                    : RouteGuard.getHomeRoute())
              : '/login',
          // ── Route guard on every navigation ──────────────────────
          onGenerateRoute: (settings) {
            final routeName = settings.name ?? '/login';
            final parsedRoute = Uri.tryParse(routeName);
            final routePath = parsedRoute?.path.isNotEmpty == true
                ? parsedRoute!.path
                : routeName;

            // Always allow login
            if (routePath == '/login') {
              return MaterialPageRoute(
                builder: (_) => const LoginPage(),
                settings: settings,
              );
            }

            if (routePath == '/reset-password') {
              return MaterialPageRoute(
                builder: (_) => ResetPasswordPage(
                  email: parsedRoute?.queryParameters['email'] ?? '',
                  token: parsedRoute?.queryParameters['token'] ?? '',
                ),
                settings: RouteSettings(name: routePath),
              );
            }

            if (routePath == '/change-password') {
              return MaterialPageRoute(
                builder: (_) => const ChangePasswordPage(),
                settings: settings,
              );
            }

            // Check access
            final redirect = RouteGuard.checkAccess(routePath);
            if (redirect != null) {
              return MaterialPageRoute(
                builder: (_) => _routeWidget(redirect),
                settings: RouteSettings(name: redirect),
              );
            }

            return MaterialPageRoute(
              builder: (_) => _routeWidget(routePath),
              settings: RouteSettings(name: routePath),
            );
          },
        );
      },
    );
  }

  Widget _routeWidget(String route) {
    switch (route) {
      // ── Admin / Manager / CEO shared ──────────────────────────────
      case '/dashboard':
        return const DashboardPage();
      case '/change-password':
        return const ChangePasswordPage();
      case '/reset-password':
        return const ResetPasswordPage();
      case '/live-tracking':
        return _DeferredRoutePage(
          routeName: route,
          loadLibrary: live_page.loadLibrary,
          builder: () => live_page.LiveTrackingPageEnhanced(),
        );
      case '/vehicles':
        return _DeferredRoutePage(
          routeName: route,
          loadLibrary: vehicles_page.loadLibrary,
          builder: () => vehicles_page.VehiclesPage(),
        );
      case '/client-tracking':
        return _DeferredRoutePage(
          routeName: route,
          loadLibrary: client_tracking_page.loadLibrary,
          builder: () => client_tracking_page.ClientTrackingPage(),
        );
      case '/drivers':
        return _DeferredRoutePage(
          routeName: route,
          loadLibrary: drivers_page.loadLibrary,
          builder: () => drivers_page.DriversPage(),
        );
      case '/dispatch-queue':
        return _DeferredRoutePage(
          routeName: route,
          loadLibrary: dispatch_page.loadLibrary,
          builder: () => dispatch_page.DispatchQueuePage(),
        );
      case '/trips':
        return _DeferredRoutePage(
          routeName: route,
          loadLibrary: trips_page.loadLibrary,
          builder: () => trips_page.TripsPage(),
        );
      case '/routes':
        return _DeferredRoutePage(
          routeName: route,
          loadLibrary: routes_page.loadLibrary,
          builder: () => routes_page.RoutesPage(),
        );
      case '/zones':
        return _DeferredRoutePage(
          routeName: route,
          loadLibrary: zones_page.loadLibrary,
          builder: () => zones_page.ZonesPage(),
        );
      case '/clients':
        return _DeferredRoutePage(
          routeName: route,
          loadLibrary: clients_page.loadLibrary,
          builder: () => clients_page.ClientsPage(),
        );
      case '/billing':
        return _DeferredRoutePage(
          routeName: route,
          loadLibrary: billing_page.loadLibrary,
          builder: () => billing_page.BillingPage(),
        );
      case '/maintenance':
        return _DeferredRoutePage(
          routeName: route,
          loadLibrary: maintenance_page.loadLibrary,
          builder: () => maintenance_page.MaintenancePage(),
        );
      case '/delivery-confirm':
        return _DeferredRoutePage(
          routeName: route,
          loadLibrary: fuel_page.loadLibrary,
          builder: () => fuel_page.FuelExpensesPage(),
        );
      case '/notifications':
        return _DeferredRoutePage(
          routeName: route,
          loadLibrary: notifications_page.loadLibrary,
          builder: () => notifications_page.NotificationsPage(),
        );
      case '/statements-of-accounts':
        return _DeferredRoutePage(
          routeName: route,
          loadLibrary: soa_page.loadLibrary,
          builder: () => soa_page.StatementOfAccountsPage(),
        );
      case '/analytics':
        return _DeferredRoutePage(
          routeName: route,
          loadLibrary: analytics_page.loadLibrary,
          builder: () => analytics_page.AnalyticsPage(),
        );
      case '/settings':
        return _DeferredRoutePage(
          routeName: route,
          loadLibrary: settings_page.loadLibrary,
          builder: () => settings_page.SettingsPage(),
        );
      case '/users':
        return _DeferredRoutePage(
          routeName: route,
          loadLibrary: users_page.loadLibrary,
          builder: () => users_page.UsersPage(),
        );
      case '/audit-logs':
        return _DeferredRoutePage(
          routeName: route,
          loadLibrary: audit_page.loadLibrary,
          builder: () => audit_page.AuditLogPage(),
        );
      // ── Driver routes ─────────────────────────────────────────────
      case '/driver-dashboard':
        return const DriverDashboardPage();
      case '/driver-profile':
        return const DriverProfilePage();
      case '/driver-earnings':
        return const DriverEarningsPage();
      case '/driver-vehicle':
        return const DriverVehiclePage();
      case '/driver-map':
        return const DriverMapPage();
      case '/driver-trips':
        return const DriverTripsPage();
      // ── Role profile routes ───────────────────────────────────────
      case '/ceo-profile':
        return const CeoProfilePage();
      case '/finance-profile':
        return const FinanceProfilePage();
      case '/manager-profile':
        return const ManagerProfilePage();
      // ── Fallback ──────────────────────────────────────────────────
      default:
        return const LoginPage();
    }
  }
}

class _DeferredRoutePage extends StatefulWidget {
  const _DeferredRoutePage({
    required this.routeName,
    required this.loadLibrary,
    required this.builder,
  });

  final String routeName;
  final Future<void> Function() loadLibrary;
  final Widget Function() builder;

  @override
  State<_DeferredRoutePage> createState() => _DeferredRoutePageState();
}

class _DeferredRoutePageState extends State<_DeferredRoutePage> {
  late final Future<void> _future = widget.loadLibrary();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          return widget.builder();
        }

        return DeferredRouteSkeleton(routeName: widget.routeName);
      },
    );
  }
}
