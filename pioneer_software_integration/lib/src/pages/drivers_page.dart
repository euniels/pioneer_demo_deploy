import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/dashboard_layout.dart';
import '../services/drivers_store.dart';
import '../services/crud_permissions.dart';
import '../services/fleet_crud_policy.dart';
import '../services/page_cache_service.dart';
import '../services/vehicles_store.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';
import '../utils/form_validation.dart';
import '../widgets/admin_page_controls.dart';
import '../widgets/geotab_push_preview.dart';
import '../widgets/geotab_sync_status_badge.dart';

Future<void>? _driverVehicleOptionsRequest;
bool _driverVehicleOptionsLoaded = false;

void _preloadDriverVehicleOptions() {
  if (_driverVehicleOptionsLoaded || _driverVehicleOptionsRequest != null) {
    return;
  }
  if (vehiclesNotifier.value.isNotEmpty) {
    _driverVehicleOptionsLoaded = true;
    return;
  }

  final request = _loadDriverVehicleOptions();
  _driverVehicleOptionsRequest = request;
  unawaited(
    request.whenComplete(() {
      if (identical(_driverVehicleOptionsRequest, request)) {
        _driverVehicleOptionsRequest = null;
      }
    }),
  );
}

Future<void> _loadDriverVehicleOptions() async {
  try {
    await refreshVehiclesFromBackend();
    _driverVehicleOptionsLoaded = true;
  } catch (_) {
    // The next form open may retry after a transient backend failure.
  }
}

class DriversPage extends StatefulWidget {
  const DriversPage({super.key});

  @override
  State<DriversPage> createState() => _DriversPageState();
}

class _DriversPageState extends State<DriversPage>
    with SingleTickerProviderStateMixin {
  static const String _cacheKey = 'drivers_page';

  bool _isLeaderboardExpanded = true;
  bool _showGridView = true;
  String _statusFilter = 'All';
  String _vehicleFilter = 'All';
  String _scoreFilter = 'All';
  String _sortMode = 'Name A-Z';
  String _leaderboardPeriod = 'This week';
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  late AnimationController _animationController;
  late Animation<double> _contentAnimation;

  @override
  void initState() {
    super.initState();
    driversNotifier.addListener(_onDriversChanged);
    _primeDrivers();

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _contentAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    );
    if (_isLeaderboardExpanded) {
      _animationController.value = 1.0;
    }
    unawaited(_loadDriverViewPreferences());
  }

  void _onDriversChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _primeDrivers({bool forceRefresh = false}) async {
    await PageCacheService.getOrLoad<int>(
      key: _cacheKey,
      ttl: PageCacheService.driversTtl,
      forceRefresh: forceRefresh,
      loader: () async {
        await refreshDriversFromBackend(forceRefresh: forceRefresh);
        return driversNotifier.value.length;
      },
    );
  }

  Future<void> _refreshDrivers() async {
    await _primeDrivers(forceRefresh: true);
    if (mounted) {
      setState(() {});
    }
  }

  Color _driverStatusColor(Map<String, dynamic> driver) {
    final status = _driverStatus(driver).toLowerCase();
    if (status == 'available' || status == 'active') {
      return AppTheme.successGreen;
    }
    if (status == 'on trip' || status == 'ontrip' || status == 'in transit') {
      return AppTheme.infoBlue;
    }
    return AppTheme.neutralGray;
  }

  Future<void> _loadDriverViewPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final view = prefs.getString('drivers_view_mode') ?? 'grid';
    final expanded = prefs.getBool('drivers_leaderboard_expanded') ?? true;
    setState(() {
      _showGridView = view != 'list';
      _isLeaderboardExpanded = expanded;
      _animationController.value = expanded ? 1.0 : 0.0;
    });
  }

  Future<void> _setDriverViewMode(bool grid) async {
    setState(() => _showGridView = grid);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('drivers_view_mode', grid ? 'grid' : 'list');
  }

  @override
  void dispose() {
    driversNotifier.removeListener(_onDriversChanged);
    _searchDebounce?.cancel();
    _searchController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _leaderboardDrivers {
    final sorted = List<Map<String, dynamic>>.from(driversNotifier.value)
      ..sort((a, b) => _driverScore(b).compareTo(_driverScore(a)));
    return sorted.take(3).toList();
  }

  List<Map<String, dynamic>> get _filteredDrivers {
    var drivers = driversNotifier.value;
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      drivers = drivers.where((driver) {
        return _driverName(driver).toLowerCase().contains(query) ||
            _driverId(driver).toLowerCase().contains(query) ||
            _driverVehicle(driver).toLowerCase().contains(query);
      }).toList();
    }

    if (_statusFilter != 'All') {
      final target = _statusFilter.toLowerCase();
      drivers = drivers.where((driver) {
        final status = _driverStatus(driver).toLowerCase();
        return status == target ||
            status.replaceAll(' ', '') == target.replaceAll(' ', '');
      }).toList();
    }

    if (_vehicleFilter != 'All') {
      drivers = drivers.where((driver) {
        final vehicle = _driverVehicle(driver);
        if (_vehicleFilter == 'Unassigned') {
          return vehicle == 'Unassigned';
        }
        return vehicle == _vehicleFilter;
      }).toList();
    }

    if (_scoreFilter != 'All') {
      drivers = drivers.where((driver) {
        final score = _driverScore(driver);
        return switch (_scoreFilter) {
          '>=90 Elite' => score >= 90,
          '75-89 Good' => score >= 75 && score < 90,
          '<75 Needs attention' => score < 75,
          _ => true,
        };
      }).toList();
    }

    final sorted = List<Map<String, dynamic>>.from(drivers);
    sorted.sort((a, b) {
      return switch (_sortMode) {
        'Name Z-A' => _compareDriverText(b, a, 'name'),
        'Score: Highest first' => _driverScore(b).compareTo(_driverScore(a)),
        'Score: Lowest first' => _driverScore(a).compareTo(_driverScore(b)),
        'Trips: Most trips' => _driverTrips(b).compareTo(_driverTrips(a)),
        'Trips: Fewest trips' => _driverTrips(a).compareTo(_driverTrips(b)),
        'Earnings: Highest' => _moneyValue(
          _driverRevenue(b),
        ).compareTo(_moneyValue(_driverRevenue(a))),
        'Earnings: Lowest' => _moneyValue(
          _driverRevenue(a),
        ).compareTo(_moneyValue(_driverRevenue(b))),
        'Status: Available first' => _statusSortValue(
          a,
        ).compareTo(_statusSortValue(b)),
        _ => _compareDriverText(a, b, 'name'),
      };
    });
    return sorted;
  }

  Future<void> _toggleLeaderboard() async {
    setState(() => _isLeaderboardExpanded = !_isLeaderboardExpanded);
    if (_isLeaderboardExpanded) {
      _animationController.forward();
    } else {
      _animationController.reverse();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('drivers_leaderboard_expanded', _isLeaderboardExpanded);
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _searchQuery = value.trim());
    });
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() => _searchQuery = '');
  }

  bool get _hasActiveDriverFilters =>
      _searchQuery.isNotEmpty ||
      _statusFilter != 'All' ||
      _vehicleFilter != 'All' ||
      _scoreFilter != 'All';

  void _clearDriverFilters() {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      _statusFilter = 'All';
      _vehicleFilter = 'All';
      _scoreFilter = 'All';
      _sortMode = 'Name A-Z';
    });
  }

  void _showAddDriverModal() {
    // Collapse leaderboard first to free up space
    if (_isLeaderboardExpanded) {
      setState(() => _isLeaderboardExpanded = false);
      _animationController.reverse();
    }
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _AddDriverDialog(
        onAdd: (driver) async {
          final created = await addDriverToBackend(driver);
          final password = created['temporaryPassword']?.toString() ?? '';
          if (password.isNotEmpty) {
            return 'Driver added successfully. Temporary password: $password';
          }
          return 'Driver added successfully.';
        },
      ),
    );
  }

  void _showEditDriverModal(Map<String, dynamic> driver) {
    final policy = FleetCrudPolicy.driver(driver);
    if (!policy.canEdit) {
      _showDriverActionMessage(policy.editDisabledReason);
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _AddDriverDialog(
        initialDriver: driver,
        submitLabel: 'Save Driver',
        onAdd: (updates) async {
          await updateDriverInBackend({...driver, ...updates});
          return 'Driver updated successfully.';
        },
      ),
    );
  }

  Future<void> _pushDriverToGeotab(Map<String, dynamic> driver) async {
    final policy = FleetCrudPolicy.driver(driver);
    if (!policy.canPushToGeotab) {
      _showDriverActionMessage(policy.pushDisabledReason);
      return;
    }

    final preview = await pushDriverToGeotab(driver, previewOnly: true);
    if (!mounted) return;
    if (!await guardGeotabPushPreview(context: context, preview: preview)) {
      return;
    }
    final confirmed = await showGeotabPushPreview(
      context: context,
      entityType: 'Driver',
      entityName: (driver['name'] ?? driver['driverId'] ?? '').toString(),
      payload: preview['preview'],
      snapshot: preview['geotabSnapshot'],
      previewPayload: preview['previewPayload'],
    );
    if (confirmed != true) return;

    try {
      await pushDriverToGeotab(driver);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('GeoTab push request staged for admin approval.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _createDriverLoginAccount(Map<String, dynamic> driver) async {
    try {
      final updated = await createDriverAccountInBackend(driver);
      if (!mounted) return;
      final password = updated['temporaryPassword']?.toString() ?? '';
      final message = password.isEmpty
          ? 'Driver login account linked successfully.'
          : 'Driver login created. Temporary password: $password';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(behavior: SnackBarBehavior.floating, content: Text(message)),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            FormValidation.backendError(
              error,
              'Driver login account could not be created.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _resetDriverLoginPassword(Map<String, dynamic> driver) async {
    try {
      final updated = await resetDriverAccountPasswordInBackend(driver);
      if (!mounted) return;
      final password = updated['temporaryPassword']?.toString() ?? '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            password.isEmpty
                ? 'Driver password reset successfully.'
                : 'Temporary password: $password',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            FormValidation.backendError(
              error,
              'Driver password could not be reset.',
            ),
          ),
        ),
      );
    }
  }

  void _showDriverActionMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(behavior: SnackBarBehavior.floating, content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DashboardLayout(
      currentRoute: '/drivers',
      title: 'Drivers',
      child: _buildPageContent(isDark),
    );
  }

  Widget _buildPageContent(bool isDark) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final isMobile = screenWidth < 600;

    // Auto-collapse leaderboard in landscape (tight height) to prevent overflow
    if (screenHeight < 500 && _isLeaderboardExpanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() => _isLeaderboardExpanded = false);
        _animationController.reverse();
      });
    }

    return ClipRect(
      child: Column(
        children: [
          _buildDriverToolbar(isDark, isMobile),
          _buildDriverFilterBar(isDark, isMobile),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refreshDrivers,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final filtered = _filteredDrivers;
                  final horizontalPadding = isMobile ? 16.0 : 24.0;
                  return CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          horizontalPadding,
                          18,
                          horizontalPadding,
                          0,
                        ),
                        sliver: SliverToBoxAdapter(
                          child: _buildLeaderboardSection(
                            isDark,
                            isMobile,
                            constraints.maxWidth,
                          ),
                        ),
                      ),
                      if (filtered.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _buildEmptyState(
                            isDark,
                            filteredOut: driversNotifier.value.isNotEmpty,
                          ),
                        )
                      else if (_showGridView)
                        SliverPadding(
                          padding: EdgeInsets.all(horizontalPadding),
                          sliver: SliverToBoxAdapter(
                            child: _DriverCardWrap(
                              children: [
                                for (
                                  var index = 0;
                                  index < filtered.length;
                                  index++
                                )
                                  _buildDriverCard(filtered[index], isDark)
                                      .animate()
                                      .fadeIn(duration: 250.ms)
                                      .slideY(
                                        begin: 0.05,
                                        end: 0,
                                        duration: 250.ms,
                                        curve: Curves.easeOut,
                                      ),
                              ],
                            ),
                          ),
                        )
                      else
                        SliverPadding(
                          padding: EdgeInsets.all(horizontalPadding),
                          sliver: SliverToBoxAdapter(
                            child: _buildDriverListView(filtered, isDark),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDriverToolbar(bool isDark, bool isMobile) {
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
          final addButton = FilledButton.icon(
            onPressed: _showAddDriverModal,
            icon: const Icon(Icons.add_rounded),
            label: Text(compact ? 'Add' : 'Add Driver'),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.successGreen,
              foregroundColor: AppTheme.white,
              minimumSize: const Size(172, 50),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
            ),
          );
          final controls = Row(
            mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
            children: [
              _DriverViewToggle(
                gridActive: _showGridView,
                onGrid: () => _setDriverViewMode(true),
                onList: () => _setDriverViewMode(false),
              ),
              const SizedBox(width: 12),
              if (CrudPermissions.canCreate(CrudEntity.drivers))
                if (compact) Expanded(child: addButton) else addButton,
            ],
          );

          final search = _DriverSearchField(
            controller: _searchController,
            onChanged: _onSearchChanged,
            onClear: _clearSearch,
            isDark: isDark,
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
      ).animate().fadeIn(duration: 250.ms),
    );
  }

  Widget _buildDriverFilterBar(bool isDark, bool isMobile) {
    final vehicles = _vehicleFilterOptions;
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
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _DriverResultCount(count: _filteredDrivers.length),
            const SizedBox(width: 12),
            _DriverFilterChip(
              label: 'Status',
              value: _statusFilter,
              options: const [
                'All',
                'Available',
                'On Trip',
                'Offline',
                'Inactive',
              ],
              onSelected: (value) => setState(() => _statusFilter = value),
              onClear: () => setState(() => _statusFilter = 'All'),
            ),
            const SizedBox(width: 8),
            _DriverFilterChip(
              label: 'Vehicle',
              value: _vehicleFilter,
              options: vehicles,
              onSelected: (value) => setState(() => _vehicleFilter = value),
              onClear: () => setState(() => _vehicleFilter = 'All'),
            ),
            const SizedBox(width: 8),
            _DriverFilterChip(
              label: 'Score',
              value: _scoreFilter,
              options: const [
                'All',
                '>=90 Elite',
                '75-89 Good',
                '<75 Needs attention',
              ],
              onSelected: (value) => setState(() => _scoreFilter = value),
              onClear: () => setState(() => _scoreFilter = 'All'),
            ),
            const SizedBox(width: 8),
            _DriverFilterChip(
              label: 'Sort',
              value: _sortMode,
              activeWhen: 'Name A-Z',
              options: const [
                'Name A-Z',
                'Name Z-A',
                'Score: Highest first',
                'Score: Lowest first',
                'Trips: Most trips',
                'Trips: Fewest trips',
                'Earnings: Highest',
                'Earnings: Lowest',
                'Status: Available first',
              ],
              onSelected: (value) => setState(() => _sortMode = value),
              onClear: () => setState(() => _sortMode = 'Name A-Z'),
            ),
            if (_hasActiveDriverFilters) ...[
              const SizedBox(width: 10),
              TextButton.icon(
                onPressed: _clearDriverFilters,
                icon: const Icon(Icons.close_rounded, size: 16),
                label: const Text('Clear all'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  int _compareDriverText(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
    String field,
  ) {
    return (a[field]?.toString().toLowerCase() ?? '').compareTo(
      b[field]?.toString().toLowerCase() ?? '',
    );
  }

  int _driverScore(Map<String, dynamic> driver) {
    final score = driver['score'];
    if (score is num) return score.round();
    return int.tryParse(score?.toString() ?? '') ?? 0;
  }

  List<String> get _vehicleFilterOptions {
    final vehicles =
        driversNotifier.value
            .map(_driverVehicle)
            .where((vehicle) => vehicle.trim().isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    return [
      'All',
      ...vehicles.where((vehicle) => vehicle != 'Unassigned'),
      'Unassigned',
    ];
  }

  String _driverName(Map<String, dynamic> driver) {
    final name = driver['name']?.toString().trim() ?? '';
    return name.isEmpty ? 'Unnamed driver' : name;
  }

  String _driverId(Map<String, dynamic> driver) {
    final id = driver['license']?.toString().trim() ?? '';
    return id.isEmpty || id.toLowerCase() == 'n/a' ? 'License not set' : id;
  }

  String _driverStatus(Map<String, dynamic> driver) {
    final status = driver['status']?.toString().trim() ?? '';
    return status.isEmpty ? 'offline' : status;
  }

  String _driverVehicle(Map<String, dynamic> driver) {
    final vehicle =
        driver['assignedVehiclePlate']?.toString().trim().isNotEmpty == true
        ? driver['assignedVehiclePlate'].toString().trim()
        : driver['assignedVehicle']?.toString().trim() ?? '';
    if (vehicle.isEmpty || vehicle.toLowerCase() == 'n/a') {
      return 'Unassigned';
    }
    return vehicle;
  }

  int _driverTrips(Map<String, dynamic> driver) {
    final trips = driver['trips'];
    if (trips is num) return trips.round();
    return int.tryParse(trips?.toString() ?? '') ?? 0;
  }

  int _driverDelays(Map<String, dynamic> driver) {
    final delays = driver['delays'];
    if (delays is num) return delays.round();
    return int.tryParse(delays?.toString() ?? '') ?? 0;
  }

  String _driverDelayText(Map<String, dynamic> driver) {
    final delays = _driverDelays(driver);
    return delays <= 0
        ? 'No delays recorded'
        : '$delays delay${delays == 1 ? '' : 's'}';
  }

  String _driverPortalStatus(Map<String, dynamic> driver) {
    if (driver['hasLoginAccount'] != true) {
      return 'No login account';
    }
    final userAccount = driver['userAccount'];
    if (userAccount is Map && userAccount['mustChangePassword'] == true) {
      return 'Linked - password change needed';
    }
    return 'Linked driver account';
  }

  String _driverRevenue(Map<String, dynamic> driver) {
    final revenue = driver['revenue']?.toString().trim() ?? '';
    if (revenue.isEmpty || revenue.toLowerCase() == 'n/a') {
      return '₱0';
    }
    if (revenue.startsWith('₱')) {
      return revenue;
    }
    final amount = _moneyValue(revenue);
    if (amount <= 0) {
      return revenue.replaceAll('PHP', '₱').trim();
    }
    return _peso(amount);
  }

  double _moneyValue(String value) {
    final cleaned = value
        .replaceAll('PHP', '')
        .replaceAll('₱', '')
        .replaceAll('â‚±', '')
        .replaceAll(',', '')
        .trim();
    return double.tryParse(cleaned) ?? 0;
  }

  String _peso(double value) {
    final rounded = value.round().toString();
    final buffer = StringBuffer();
    for (var index = 0; index < rounded.length; index++) {
      final fromEnd = rounded.length - index;
      buffer.write(rounded[index]);
      if (fromEnd > 1 && fromEnd % 3 == 1) {
        buffer.write(',');
      }
    }
    return '₱$buffer';
  }

  int _statusSortValue(Map<String, dynamic> driver) {
    return switch (_driverStatus(driver).toLowerCase()) {
      'available' => 0,
      'on trip' || 'ontrip' || 'in transit' => 1,
      'inactive' || 'deactivated' => 2,
      _ => 3,
    };
  }

  String _licenseFilterLabel(Map<String, dynamic> driver) {
    final raw = driver['licenseExpiry']?.toString().trim() ?? '';
    if (raw.isEmpty || raw.toLowerCase() == 'n/a') {
      return 'Not set';
    }

    final expiry = DateTime.tryParse(raw);
    if (expiry == null) {
      return 'Not set';
    }

    final today = DateTime.now();
    final currentDate = DateTime(today.year, today.month, today.day);
    final expiryDate = DateTime(expiry.year, expiry.month, expiry.day);
    final days = expiryDate.difference(currentDate).inDays;
    if (days < 0) return 'Expired';
    if (days <= 30) return 'Expiring in 30d';
    return 'Valid';
  }

  String _licenseExpiryText(Map<String, dynamic> driver) {
    final raw = driver['licenseExpiry']?.toString().trim() ?? '';
    if (raw.isEmpty || raw.toLowerCase() == 'n/a') {
      return 'N/A';
    }
    return raw;
  }

  Color _driverScoreColor(int score) {
    if (score >= 90) return AppTheme.successGreen;
    if (score >= 75) return AppTheme.infoBlue;
    if (score >= 60) return AppTheme.warningOrange;
    return AppTheme.errorRed;
  }

  String _scoreTooltip(Map<String, dynamic> driver) {
    final trips = _driverTrips(driver);
    final delays = _driverDelays(driver);
    if (delays == 0) {
      return '$trips trips with no recorded delays';
    }
    return '$trips trips with $delays delay${delays == 1 ? '' : 's'}';
  }

  Widget _buildLeaderboardSection(
    bool isDark,
    bool isMobile,
    double availableWidth,
  ) {
    final leaders = _leaderboardDrivers;
    if (leaders.isEmpty) {
      return const SizedBox(height: 0);
    }

    final medals = [
      {'icon': Icons.emoji_events, 'color': AppTheme.colorFFFFD700},
      {'icon': Icons.emoji_events, 'color': AppTheme.colorFFC0C0C0},
      {'icon': Icons.emoji_events, 'color': AppTheme.colorFFCD7F32},
    ];

    return Container(
      padding: EdgeInsets.all(isMobile ? 14 : 18),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withAlpha(16)
              : AppTheme.black.withAlpha(12),
        ),
        boxShadow: AppTheme.getElevatedShadow(context),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: _toggleLeaderboard,
            borderRadius: BorderRadius.circular(8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Performance leaderboard',
                        style: TextStyle(
                          fontSize: isMobile ? 18 : 22,
                          fontWeight: FontWeight.w900,
                          color: isDark
                              ? AppTheme.white
                              : AppTheme.colorFF111827,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Top performing drivers this period',
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  initialValue: _leaderboardPeriod,
                  onSelected: (value) =>
                      setState(() => _leaderboardPeriod = value),
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'This week', child: Text('This week')),
                    PopupMenuItem(
                      value: 'This month',
                      child: Text('This month'),
                    ),
                    PopupMenuItem(value: 'All time', child: Text('All time')),
                  ],
                  child: _DriverSoftPill(
                    icon: Icons.calendar_month_rounded,
                    label: _leaderboardPeriod,
                    color: AppTheme.infoBlue,
                  ),
                ),
                const SizedBox(width: 10),
                AnimatedRotation(
                  turns: _isLeaderboardExpanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                  ),
                ),
              ],
            ),
          ),
          SizeTransition(
            sizeFactor: _contentAnimation,
            axisAlignment: -1,
            child: Padding(
              padding: const EdgeInsets.only(top: 16),
              child: availableWidth < 760
                  ? Column(
                      children: [
                        for (var i = 0; i < leaders.length; i++) ...[
                          _buildLeaderboardCard(
                            leaders[i],
                            medals[i],
                            isDark,
                            isMobile,
                            i,
                          ),
                          if (i < leaders.length - 1)
                            const SizedBox(height: 12),
                        ],
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (var i = 0; i < leaders.length; i++) ...[
                          Expanded(
                            child: _buildLeaderboardCard(
                              leaders[i],
                              medals[i],
                              isDark,
                              false,
                              i,
                            ),
                          ),
                          if (i < leaders.length - 1) const SizedBox(width: 12),
                        ],
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeaderboardCard(
    Map<String, dynamic> driver,
    Map<String, dynamic> medal,
    bool isDark,
    bool isMobile,
    int rank,
  ) {
    final color = medal['color'] as Color;
    final score = _driverScore(driver);
    final heightOffset = rank == 0
        ? 18.0
        : rank == 1
        ? 8.0
        : 0.0;
    return Container(
      constraints: BoxConstraints(minHeight: isMobile ? 0 : 162 + heightOffset),
      padding: EdgeInsets.all(isMobile ? 14 : 16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF101827 : AppTheme.colorFFF8FAFD,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(58)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: isDark ? 0.13 : 0.08),
            blurRadius: 18,
            spreadRadius: -14,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _DriverInitialsAvatar(
                name: _driverName(driver),
                color: color,
                size: 48,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _driverName(driver),
                      style: TextStyle(
                        fontSize: isMobile ? 14 : 16,
                        fontWeight: FontWeight.w800,
                        color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '#${rank + 1} driver',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(medal['icon'] as IconData, color: color, size: 24),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _DriverScoreArc(
                score: score,
                color: _driverScoreColor(score),
                size: 64,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _LeaderboardFact(
                      icon: Icons.route_rounded,
                      label: '${_driverTrips(driver)} trips',
                    ),
                    const SizedBox(height: 8),
                    _LeaderboardFact(
                      icon: Icons.payments_rounded,
                      label: '${_driverRevenue(driver)} earned',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDriverListView(List<Map<String, dynamic>> drivers, bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withAlpha(16)
              : AppTheme.black.withAlpha(12),
        ),
      ),
      child: Column(
        children: [
          _DriverListHeader(isDark: isDark),
          for (var index = 0; index < drivers.length; index++)
            _buildDriverListRow(drivers[index], isDark, index),
        ],
      ),
    );
  }

  Widget _buildDriverListRow(
    Map<String, dynamic> driver,
    bool isDark,
    int index,
  ) {
    final crudPolicy = FleetCrudPolicy.driver(driver);
    final score = _driverScore(driver);
    final statusColor = _driverStatusColor(driver);
    return InkWell(
      onTap: () => _showDriverDetails(driver, isDark),
      child: Container(
        constraints: const BoxConstraints(minHeight: 58),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: index.isEven
              ? Colors.transparent
              : (isDark
                    ? AppTheme.white.withAlpha(7)
                    : AppTheme.black.withAlpha(5)),
          border: Border(
            top: BorderSide(
              color: isDark
                  ? AppTheme.white.withAlpha(12)
                  : AppTheme.black.withAlpha(8),
            ),
          ),
        ),
        child: Row(
          children: [
            _DriverInitialsAvatar(
              name: _driverName(driver),
              color: statusColor,
              size: 36,
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: _DriverPrimaryText(
                name: _driverName(driver),
                id: _driverId(driver),
                query: _searchQuery,
                isDark: isDark,
              ),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _DriverStatusBadge(
                  label: _statusLabel(_driverStatus(driver)),
                  color: statusColor,
                  onTap: () =>
                      setState(() => _statusFilter = _driverStatus(driver)),
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: _DriverScoreInline(
                score: score,
                color: _driverScoreColor(score),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                _driverVehicle(driver),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: isDark ? AppTheme.white : AppTheme.colorFF111827,
                ),
              ),
            ),
            Expanded(
              child: Text(
                '${_driverTrips(driver)} trips',
                style: TextStyle(
                  color: isDark ? AppTheme.gray300 : AppTheme.gray600,
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: _LicenseBadge(label: _licenseFilterLabel(driver)),
            ),
            _driverActionsMenu(driver, isDark, crudPolicy),
          ],
        ),
      ),
    );
  }

  Widget _buildDriverCard(Map<String, dynamic> driver, bool isDark) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = (constraints.maxWidth / 390).clamp(0.88, 1.08);
        final crudPolicy = FleetCrudPolicy.driver(driver);
        final statusColor = _driverStatusColor(driver);
        final score = _driverScore(driver);
        final scoreColor = _driverScoreColor(score);
        final accent = statusColor;

        return _DriverHoverLift(
          child: InkWell(
            onTap: () => _showDriverDetails(driver, isDark),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: EdgeInsets.all(14 * scale),
              decoration: BoxDecoration(
                color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: accent.withAlpha(isDark ? 62 : 52)),
                boxShadow: [
                  BoxShadow(
                    color: accent.withValues(alpha: isDark ? 0.13 : 0.08),
                    blurRadius: 20,
                    spreadRadius: -12,
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
                      _DriverInitialsAvatar(
                        name: _driverName(driver),
                        color: statusColor,
                        size: 42 * scale,
                      ),
                      SizedBox(width: 12 * scale),
                      Expanded(
                        child: _DriverPrimaryText(
                          name: _driverName(driver),
                          id: _driverId(driver),
                          query: _searchQuery,
                          isDark: isDark,
                          allowWrap: true,
                        ),
                      ),
                      SizedBox(width: 8 * scale),
                      _DriverStatusBadge(
                        label: _statusLabel(_driverStatus(driver)),
                        color: statusColor,
                        onTap: () => setState(
                          () => _statusFilter = _driverStatus(driver),
                        ),
                      ),
                      _driverActionsMenu(driver, isDark, crudPolicy),
                    ],
                  ),
                  SizedBox(height: 13 * scale),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '$score',
                          style: TextStyle(
                            fontSize: 32 * scale,
                            fontWeight: FontWeight.w900,
                            color: scoreColor,
                          ),
                        ),
                        TextSpan(
                          text: ' / 100',
                          style: TextStyle(
                            fontSize: 13 * scale,
                            fontWeight: FontWeight.w800,
                            color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 7 * scale),
                  Tooltip(
                    message: 'Score $score/100 - ${_scoreTooltip(driver)}',
                    child: _DriverScoreBar(score: score, color: scoreColor),
                  ),
                  SizedBox(height: 13 * scale),
                  _DriverCardFact(
                    icon: Icons.local_shipping_rounded,
                    label: 'Vehicle',
                    value: _driverVehicle(driver),
                    query: _searchQuery,
                  ),
                  SizedBox(height: 7 * scale),
                  _DriverCardFact(
                    icon: Icons.route_rounded,
                    label: 'Trips',
                    value:
                        '${_driverTrips(driver)} trips | ${_driverRevenue(driver)} earned',
                  ),
                  SizedBox(height: 7 * scale),
                  _DriverCardFact(
                    icon: Icons.schedule_rounded,
                    label: 'Delays',
                    value: _driverDelayText(driver),
                  ),
                  SizedBox(height: 7 * scale),
                  _DriverCardFact(
                    icon: driver['hasLoginAccount'] == true
                        ? Icons.verified_user_rounded
                        : Icons.no_accounts_rounded,
                    label: 'Portal',
                    value: _driverPortalStatus(driver),
                  ),
                  SizedBox(height: 10 * scale),
                  _DriverCardDivider(isDark: isDark),
                  SizedBox(height: 10 * scale),
                  Row(
                    children: [
                      Expanded(
                        child: _DriverLicenseLine(
                          label: _licenseFilterLabel(driver),
                          expiry: _licenseExpiryText(driver),
                        ),
                      ),
                    ],
                  ),
                  if (_licenseExpiryWarning(driver) != null) ...[
                    SizedBox(height: 6 * scale),
                    _licenseExpiryWarningBadge(driver, scale),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  PopupMenuButton<String> _driverActionsMenu(
    Map<String, dynamic> driver,
    bool isDark,
    FleetCrudPolicy crudPolicy,
  ) {
    return PopupMenuButton<String>(
      tooltip: 'Driver actions',
      onSelected: (value) async {
        if (value == 'view') {
          await _showDriverDetails(driver, isDark);
        } else if (value == 'deactivate') {
          if (!crudPolicy.canDeactivate) {
            _showDriverActionMessage(crudPolicy.deactivateDisabledReason);
            return;
          }
          final confirmed = await _confirmDeactivateDriver(driver, isDark);
          if (!confirmed) return;
          try {
            await deactivateDriverInBackend(driver);
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                behavior: SnackBarBehavior.floating,
                content: Text('Driver deactivated successfully.'),
              ),
            );
          } catch (error) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                behavior: SnackBarBehavior.floating,
                content: Text(
                  FormValidation.backendError(
                    error,
                    'Driver deactivation could not be saved. The driver was restored.',
                  ),
                ),
              ),
            );
          }
        } else if (value == 'reactivate') {
          if (!crudPolicy.canReactivate) {
            _showDriverActionMessage(crudPolicy.deactivateDisabledReason);
            return;
          }
          try {
            await reactivateDriverInBackend(driver);
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                behavior: SnackBarBehavior.floating,
                content: Text('Driver reactivated successfully.'),
              ),
            );
          } catch (error) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                behavior: SnackBarBehavior.floating,
                content: Text(
                  FormValidation.backendError(
                    error,
                    'Driver reactivation could not be saved. The driver was restored.',
                  ),
                ),
              ),
            );
          }
        } else if (value == 'edit') {
          _showEditDriverModal(driver);
        } else if (value == 'create_account') {
          await _createDriverLoginAccount(driver);
        } else if (value == 'reset_account') {
          await _resetDriverLoginPassword(driver);
        } else if (value == 'push_geotab') {
          if (!crudPolicy.canPushToGeotab) {
            _showDriverActionMessage(crudPolicy.pushDisabledReason);
            return;
          }
          await _pushDriverToGeotab(driver);
        } else if (value == 'delete') {
          if (!crudPolicy.canDelete) {
            _showDriverActionMessage(crudPolicy.deleteDisabledReason);
            return;
          }
          final confirmed = await _confirmDeleteDriver(driver, isDark);
          if (!confirmed) return;
          try {
            await deleteDriverInBackend(driver);
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                behavior: SnackBarBehavior.floating,
                content: Text('Driver deleted successfully.'),
              ),
            );
          } catch (error) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                behavior: SnackBarBehavior.floating,
                content: Text(
                  FormValidation.backendError(
                    error,
                    'Driver could not be deleted.',
                  ),
                ),
              ),
            );
          }
        } else if (value == 'anonymize') {
          final reason = await _confirmAnonymizeDriver(driver, isDark);
          if (reason == null || reason.trim().isEmpty) return;
          try {
            await anonymizeDriverInBackend(driver, reason: reason.trim());
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                behavior: SnackBarBehavior.floating,
                content: Text('Driver personal data anonymized.'),
              ),
            );
          } catch (_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                behavior: SnackBarBehavior.floating,
                content: Text('Driver personal data could not be anonymized.'),
              ),
            );
          }
        }
      },
      itemBuilder: (context) => [
        if (CrudPermissions.canEdit(CrudEntity.drivers))
          PopupMenuItem(
            value: 'edit',
            enabled: crudPolicy.canEdit,
            child: _DriverActionMenuItem(
              icon: Icons.edit_rounded,
              label: crudPolicy.canEdit ? 'Edit' : 'Edit - GeoTab read-only',
            ),
          ),
        if (CrudPermissions.canEdit(CrudEntity.drivers) &&
            driver['hasLoginAccount'] != true)
          PopupMenuItem(
            value: 'create_account',
            enabled: driver['canCreateLoginAccount'] == true,
            child: _DriverActionMenuItem(
              icon: Icons.login_rounded,
              label: driver['canCreateLoginAccount'] == true
                  ? 'Create driver login'
                  : 'Create login - email required',
            ),
          ),
        if (CrudPermissions.canEdit(CrudEntity.drivers) &&
            driver['hasLoginAccount'] == true)
          const PopupMenuItem(
            value: 'reset_account',
            child: _DriverActionMenuItem(
              icon: Icons.password_rounded,
              label: 'Reset driver password',
            ),
          ),
        PopupMenuItem(
          value: 'push_geotab',
          enabled: crudPolicy.canPushToGeotab,
          child: _DriverActionMenuItem(
            icon: Icons.cloud_upload_outlined,
            label: crudPolicy.canPushToGeotab
                ? 'Push to GeoTab'
                : 'Push to GeoTab - no local changes',
          ),
        ),
        if (CrudPermissions.canEdit(CrudEntity.drivers) &&
            _isDriverInactive(driver))
          PopupMenuItem(
            value: 'reactivate',
            enabled: crudPolicy.canReactivate,
            child: const _DriverActionMenuItem(
              icon: Icons.person_add_alt_1_rounded,
              label: 'Reactivate',
            ),
          ),
        if (CrudPermissions.canDelete(CrudEntity.drivers) &&
            !_isDriverInactive(driver))
          PopupMenuItem(
            value: 'deactivate',
            enabled: crudPolicy.canDeactivate,
            child: _DriverActionMenuItem(
              icon: Icons.person_off_rounded,
              label: crudPolicy.canDeactivate
                  ? 'Deactivate'
                  : 'Deactivate - unavailable',
            ),
          ),
        if (CrudPermissions.canDelete(CrudEntity.drivers))
          PopupMenuItem(
            value: 'delete',
            enabled: crudPolicy.canDelete,
            child: _DriverActionMenuItem(
              icon: Icons.delete_outline_rounded,
              label: crudPolicy.canDelete ? 'Delete' : 'Delete - managed only',
              destructive: true,
            ),
          ),
        if (CrudPermissions.isSuperAdmin && _isDriverInactive(driver))
          const PopupMenuItem(
            value: 'anonymize',
            child: _DriverActionMenuItem(
              icon: Icons.privacy_tip_outlined,
              label: 'Anonymize personal data',
            ),
          ),
      ],
    );
  }

  Future<bool> _confirmDeactivateDriver(
    Map<String, dynamic> driver,
    bool isDark,
  ) async {
    final name = driver['name']?.toString() ?? 'this driver';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        title: Text(
          'Deactivate driver?',
          style: TextStyle(
            color: isDark ? AppTheme.white : AppTheme.colorFF111827,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          'This will mark $name inactive and stage the GeoTab deactivation write-back for review when applicable.',
          style: TextStyle(
            color: isDark ? AppTheme.gray300 : AppTheme.colorFF475569,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.person_off_rounded),
            label: const Text('Deactivate'),
          ),
        ],
      ),
    );

    return confirmed == true;
  }

  Future<bool> _confirmDeleteDriver(
    Map<String, dynamic> driver,
    bool isDark,
  ) async {
    final name = driver['name']?.toString() ?? 'this driver';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        title: Text(
          'Delete $name?',
          style: TextStyle(
            color: isDark ? AppTheme.white : AppTheme.colorFF111827,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          'This cannot be undone.',
          style: TextStyle(
            color: isDark ? AppTheme.gray300 : AppTheme.colorFF475569,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.errorRed),
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.delete_outline_rounded),
            label: const Text('Delete'),
          ),
        ],
      ),
    );

    return confirmed == true;
  }

  Future<void> _showDriverDetails(
    Map<String, dynamic> driver,
    bool isDark,
  ) async {
    final details = <MapEntry<String, String>>[
      MapEntry('License number', (driver['license'] ?? 'N/A').toString()),
      MapEntry('Contact number', (driver['phone'] ?? 'N/A').toString()),
      MapEntry('Email', (driver['email'] ?? 'N/A').toString()),
      MapEntry('Address', (driver['address'] ?? 'N/A').toString()),
      MapEntry(
        'Emergency contact',
        (driver['emergencyContact'] ?? 'N/A').toString(),
      ),
      MapEntry(
        'Assigned vehicle',
        (driver['assignedVehicle'] ?? 'Unassigned').toString(),
      ),
      MapEntry('License expiry', (driver['licenseExpiry'] ?? 'N/A').toString()),
    ];
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        final screenWidth = MediaQuery.of(context).size.width;
        final inset = screenWidth < 640 ? 16.0 : 48.0;
        return Dialog(
          backgroundColor: AppTheme.transparent,
          insetPadding: EdgeInsets.symmetric(horizontal: inset, vertical: 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 760,
              maxHeight: MediaQuery.of(context).size.height * 0.86,
            ),
            child: Container(
              decoration: BoxDecoration(
                color: isDark ? AppTheme.colorFF10141D : AppTheme.colorFFF4F6F8,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isDark
                      ? AppTheme.white.withAlpha(12)
                      : AppTheme.black.withAlpha(12),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
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
                        const Icon(Icons.person_rounded, color: AppTheme.white),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                (driver['name'] ?? 'Driver details').toString(),
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
                                'Driver overview and contact details',
                                style: TextStyle(
                                  color: AppTheme.white70,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 10,
                                runSpacing: 8,
                                children: [
                                  _detailStatusChip(
                                    _statusLabel(
                                      driver['status']?.toString() ?? '',
                                    ),
                                    _driverStatusColor(driver),
                                  ),
                                  GeoTabSyncStatusBadge.fromEntity(
                                    driver,
                                    compact: true,
                                  ),
                                ],
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
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final entry in details) ...[
                            Text(
                              entry.key,
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark
                                    ? AppTheme.gray400
                                    : AppTheme.gray600,
                              ),
                            ),
                            const SizedBox(height: 3),
                            SelectableText(
                              entry.value,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: isDark
                                    ? AppTheme.white
                                    : AppTheme.colorFF111827,
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _detailStatusChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  bool _isDriverInactive(Map<String, dynamic> driver) {
    final status = driver['status']?.toString().trim().toLowerCase() ?? '';
    return status == 'inactive' || status == 'deactivated';
  }

  Future<String?> _confirmAnonymizeDriver(
    Map<String, dynamic> driver,
    bool isDark,
  ) async {
    final controller = TextEditingController();
    final name = driver['name']?.toString() ?? 'this driver';
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        title: Text(
          'Anonymize driver personal data?',
          style: TextStyle(
            color: isDark ? AppTheme.white : AppTheme.colorFF111827,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This removes stored personal contact details for $name while preserving trip history.',
              style: TextStyle(
                color: isDark ? AppTheme.gray300 : AppTheme.colorFF475569,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Reason',
                hintText: 'Required for privacy audit',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            icon: const Icon(Icons.privacy_tip_rounded),
            label: const Text('Anonymize'),
          ),
        ],
      ),
    );
    controller.dispose();
    return reason;
  }

  String? _licenseExpiryWarning(Map<String, dynamic> driver) {
    final raw = driver['licenseExpiry']?.toString().trim() ?? '';
    if (raw.isEmpty || raw.toLowerCase() == 'n/a') {
      return null;
    }

    final expiry = DateTime.tryParse(raw);
    if (expiry == null) {
      return null;
    }

    final today = DateTime.now();
    final currentDate = DateTime(today.year, today.month, today.day);
    final expiryDate = DateTime(expiry.year, expiry.month, expiry.day);
    final days = expiryDate.difference(currentDate).inDays;
    if (days < 0) {
      return 'License expired';
    }
    if (days <= 30) {
      return 'Expires in $days days';
    }

    return null;
  }

  Widget _licenseExpiryWarningBadge(Map<String, dynamic> driver, double scale) {
    final warning = _licenseExpiryWarning(driver);
    if (warning == null) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8 * scale, vertical: 4 * scale),
      decoration: BoxDecoration(
        color: AppTheme.errorRed.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppTheme.errorRed.withValues(alpha: 0.34)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 12 * scale,
            color: AppTheme.errorRed,
          ),
          SizedBox(width: 4 * scale),
          Flexible(
            child: Text(
              warning,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: AppTheme.errorRed,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  String _statusLabel(String status) {
    switch (status.toLowerCase()) {
      case 'available':
        return 'AVAILABLE';
      case 'on trip':
      case 'ontrip':
        return 'ON TRIP';
      default:
        return status.toUpperCase();
    }
  }

  Widget _buildEmptyState(bool isDark, {bool filteredOut = false}) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 112,
            height: 112,
            decoration: BoxDecoration(
              color: AppTheme.primaryBlue.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(32),
              border: Border.all(
                color: AppTheme.primaryBlue.withValues(alpha: 0.22),
              ),
            ),
            child: Icon(
              Icons.badge_rounded,
              size: 58,
              color: AppTheme.primaryBlue,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            filteredOut ? 'No drivers found' : 'No drivers registered yet',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.gray600 : AppTheme.gray400,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            filteredOut
                ? 'Try clearing the active search and filters to show all demo drivers.'
                : 'Create a driver assignment profile for dispatch and tracking.',
            style: TextStyle(
              fontSize: 14,
              color: isDark ? AppTheme.gray500 : AppTheme.gray500,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          if (filteredOut)
            OutlinedButton.icon(
              onPressed: _clearDriverFilters,
              icon: const Icon(Icons.filter_alt_off_rounded),
              label: const Text('Clear filters'),
            )
          else if (CrudPermissions.canCreate(CrudEntity.drivers))
            FilledButton.icon(
              onPressed: _showAddDriverModal,
              icon: const Icon(Icons.person_add_rounded),
              label: const Text('Add your first driver'),
            ),
        ],
      ),
    );
  }
}

// ADD DRIVER DIALOG

class _DriverCardWrap extends StatelessWidget {
  const _DriverCardWrap({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 18.0;
        final maxWidth = constraints.maxWidth;
        final columns = maxWidth < 760
            ? 1
            : maxWidth < 1120
            ? 2
            : 3;
        final cardWidth = (maxWidth - spacing * (columns - 1)) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          alignment: WrapAlignment.start,
          children: [
            for (final child in children)
              SizedBox(width: cardWidth, child: child),
          ],
        );
      },
    );
  }
}

class _DriverSearchField extends StatelessWidget {
  const _DriverSearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
    required this.isDark,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return AdminSearchField(
      controller: controller,
      hintText: 'Search by name, driver ID, or vehicle...',
      onChanged: onChanged,
      onClear: onClear,
    );
  }
}

class _DriverViewToggle extends StatelessWidget {
  const _DriverViewToggle({
    required this.gridActive,
    required this.onGrid,
    required this.onList,
  });

  final bool gridActive;
  final VoidCallback onGrid;
  final VoidCallback onList;

  @override
  Widget build(BuildContext context) {
    return AdminViewToggle(
      gridActive: gridActive,
      onGrid: onGrid,
      onList: onList,
      height: 44,
      buttonSize: 36,
    );
  }
}

class _DriverResultCount extends StatelessWidget {
  const _DriverResultCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return AdminResultCount(count: count, label: 'drivers');
  }
}

class _DriverFilterChip extends StatelessWidget {
  const _DriverFilterChip({
    required this.label,
    required this.value,
    required this.options,
    required this.onSelected,
    required this.onClear,
    this.activeWhen = 'All',
  });

  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onSelected;
  final VoidCallback onClear;
  final String activeWhen;

  @override
  Widget build(BuildContext context) {
    return AdminFilterChip(
      label: label,
      value: value,
      options: options,
      onSelected: onSelected,
      onClear: onClear,
      activeWhen: activeWhen,
    );
  }
}

class _DriverSoftPill extends StatelessWidget {
  const _DriverSoftPill({
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
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(width: 3),
          Icon(Icons.keyboard_arrow_down_rounded, size: 15, color: color),
        ],
      ),
    );
  }
}

class _DriverInitialsAvatar extends StatelessWidget {
  const _DriverInitialsAvatar({
    required this.name,
    required this.color,
    required this.size,
  });

  final String name;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initials = name
        .split(' ')
        .where((part) => part.trim().isNotEmpty)
        .take(2)
        .map((part) => part[0].toUpperCase())
        .join();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        initials.isEmpty ? 'DR' : initials,
        style: TextStyle(
          color: color,
          fontSize: size * 0.34,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _DriverPrimaryText extends StatelessWidget {
  const _DriverPrimaryText({
    required this.name,
    required this.id,
    required this.query,
    required this.isDark,
    this.allowWrap = false,
  });

  final String name;
  final String id;
  final String query;
  final bool isDark;
  final bool allowWrap;

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? AppTheme.white : AppTheme.colorFF111827;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RichText(
          maxLines: allowWrap ? 2 : 1,
          overflow: TextOverflow.ellipsis,
          text: _highlightSpan(
            name,
            query,
            TextStyle(
              fontSize: name.length > 24 ? 13 : 15,
              fontWeight: FontWeight.w900,
              color: textColor,
            ),
          ),
        ),
        const SizedBox(height: 3),
        RichText(
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          text: _highlightSpan(
            'Driver ID: $id',
            query,
            TextStyle(
              fontSize: 12,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

TextSpan _highlightSpan(String text, String query, TextStyle baseStyle) {
  final normalizedQuery = query.trim().toLowerCase();
  if (normalizedQuery.isEmpty) {
    return TextSpan(text: text, style: baseStyle);
  }
  final lower = text.toLowerCase();
  final start = lower.indexOf(normalizedQuery);
  if (start < 0) {
    return TextSpan(text: text, style: baseStyle);
  }
  final end = start + normalizedQuery.length;
  return TextSpan(
    style: baseStyle,
    children: [
      TextSpan(text: text.substring(0, start)),
      TextSpan(
        text: text.substring(start, end),
        style: baseStyle.copyWith(
          color: AppTheme.goldAccent,
          backgroundColor: AppTheme.goldAccent.withValues(alpha: 0.18),
        ),
      ),
      TextSpan(text: text.substring(end)),
    ],
  );
}

class _DriverStatusBadge extends StatelessWidget {
  const _DriverStatusBadge({
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.28)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

class _DriverScoreBar extends StatelessWidget {
  const _DriverScoreBar({required this.score, required this.color});

  final int score;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 10,
        child: Stack(
          children: [
            Container(color: AppTheme.white.withAlpha(18)),
            FractionallySizedBox(
              widthFactor: (score / 100).clamp(0.0, 1.0),
              child: Container(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _DriverScoreInline extends StatelessWidget {
  const _DriverScoreInline({required this.score, required this.color});

  final int score;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 42,
          child: Text(
            '$score',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w900,
              fontSize: 18,
            ),
          ),
        ),
        Expanded(
          child: _DriverScoreBar(score: score, color: color),
        ),
      ],
    );
  }
}

class _DriverScoreArc extends StatelessWidget {
  const _DriverScoreArc({
    required this.score,
    required this.color,
    required this.size,
  });

  final int score;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _DriverScoreArcPainter(
          progress: (score / 100).clamp(0.0, 1.0),
          color: color,
        ),
        child: Center(
          child: Text(
            '$score',
            style: TextStyle(
              color: color,
              fontSize: size * 0.28,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ),
    );
  }
}

class _DriverScoreArcPainter extends CustomPainter {
  const _DriverScoreArcPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 5;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round
      ..color = AppTheme.white.withAlpha(18);
    final active = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(rect, -1.57, 6.28, false, base);
    canvas.drawArc(rect, -1.57, 6.28 * progress, false, active);
  }

  @override
  bool shouldRepaint(covariant _DriverScoreArcPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

class _LeaderboardFact extends StatelessWidget {
  const _LeaderboardFact({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppTheme.gray400, size: 15),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppTheme.gray300,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _DriverCardFact extends StatelessWidget {
  const _DriverCardFact({
    required this.icon,
    required this.label,
    required this.value,
    this.query = '',
  });

  final IconData icon;
  final String label;
  final String value;
  final String query;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 17, color: AppTheme.gray400),
        const SizedBox(width: 8),
        Expanded(
          child: RichText(
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              style: const TextStyle(
                color: AppTheme.gray300,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
              children: [
                TextSpan(text: '$label: '),
                _highlightSpan(
                  value,
                  query,
                  const TextStyle(
                    color: AppTheme.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _DriverCardDivider extends StatelessWidget {
  const _DriverCardDivider({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      color: isDark
          ? AppTheme.white.withAlpha(14)
          : AppTheme.black.withAlpha(10),
    );
  }
}

class _DriverLicenseLine extends StatelessWidget {
  const _DriverLicenseLine({required this.label, required this.expiry});

  final String label;
  final String expiry;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.badge_rounded, color: AppTheme.gray400, size: 17),
        const SizedBox(width: 8),
        _LicenseBadge(label: label),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'License expiry: $expiry',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppTheme.gray300,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _LicenseBadge extends StatelessWidget {
  const _LicenseBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final color = switch (label) {
      'Valid' => AppTheme.successGreen,
      'Expiring in 30d' => AppTheme.warningOrange,
      'Expired' => AppTheme.errorRed,
      _ => AppTheme.neutralGray,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _DriverListHeader extends StatelessWidget {
  const _DriverListHeader({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: isDark ? AppTheme.gray400 : AppTheme.gray600,
      fontSize: 11,
      fontWeight: FontWeight.w900,
      letterSpacing: 0.2,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF101827 : AppTheme.colorFFF8FAFD,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 48),
          Expanded(flex: 3, child: Text('DRIVER', style: style)),
          Expanded(child: Text('STATUS', style: style)),
          Expanded(flex: 2, child: Text('SCORE', style: style)),
          Expanded(flex: 2, child: Text('VEHICLE', style: style)),
          Expanded(child: Text('TRIPS', style: style)),
          Expanded(flex: 2, child: Text('LICENSE', style: style)),
          const SizedBox(width: 42),
        ],
      ),
    );
  }
}

class _DriverHoverLift extends StatefulWidget {
  const _DriverHoverLift({required this.child});

  final Widget child;

  @override
  State<_DriverHoverLift> createState() => _DriverHoverLiftState();
}

class _DriverHoverLiftState extends State<_DriverHoverLift> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedScale(
        scale: _hovering ? 1.005 : 1,
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          curve: Curves.easeOut,
          transform: Matrix4.translationValues(0, _hovering ? -2 : 0, 0),
          child: widget.child,
        ),
      ),
    );
  }
}

class _DriverActionMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool destructive;

  const _DriverActionMenuItem({
    required this.icon,
    required this.label,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? AppTheme.errorRed : null;
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}

class _AddDriverDialog extends StatefulWidget {
  final Future<String> Function(Map<String, dynamic>) onAdd;
  final Map<String, dynamic>? initialDriver;
  final String submitLabel;

  const _AddDriverDialog({
    required this.onAdd,
    this.initialDriver,
    this.submitLabel = 'Add Driver',
  });

  @override
  State<_AddDriverDialog> createState() => _AddDriverDialogState();
}

class _AddDriverDialogState extends State<_AddDriverDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _licenseCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _licenseExpiryCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _assignedVehicleCtrl = TextEditingController();
  final _emergencyContactCtrl = TextEditingController();

  String _status = 'available';
  bool _saving = false;
  bool _createLoginAccount = false;

  @override
  void initState() {
    super.initState();
    final driver = widget.initialDriver;
    if (driver == null) {
      _preloadDriverVehicleOptions();
      vehiclesNotifier.addListener(_onVehiclesChanged);
      return;
    }

    _nameCtrl.text = driver['name']?.toString() ?? '';
    _licenseCtrl.text = driver['license']?.toString() ?? '';
    _phoneCtrl.text = driver['phone']?.toString() ?? '';
    _emailCtrl.text = driver['email']?.toString() ?? '';
    _licenseExpiryCtrl.text = driver['licenseExpiry']?.toString() ?? '';
    _addressCtrl.text = driver['address']?.toString() ?? '';
    _assignedVehicleCtrl.text = driver['assignedVehicle']?.toString() ?? '';
    _emergencyContactCtrl.text = driver['emergencyContact']?.toString() ?? '';
    _status = driver['status']?.toString().trim().toLowerCase() ?? 'available';
    _preloadDriverVehicleOptions();
    vehiclesNotifier.addListener(_onVehiclesChanged);
  }

  void _onVehiclesChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _licenseCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _licenseExpiryCtrl.dispose();
    _addressCtrl.dispose();
    _assignedVehicleCtrl.dispose();
    _emergencyContactCtrl.dispose();
    vehiclesNotifier.removeListener(_onVehiclesChanged);
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
    });

    final newDriver = {
      'name': _nameCtrl.text.trim(),
      'license': _licenseCtrl.text.trim(),
      'phone': _phoneCtrl.text.trim(),
      'email': _emailCtrl.text.trim(),
      'assignedVehiclePlate': _assignedVehicleCtrl.text.trim(),
      'assignedVehicleGeotabId': _selectedVehicleGeotabId,
      'status': _status,
      if (_createLoginAccount && widget.initialDriver == null)
        'createLoginAccount': true,
      'meta': {
        'licenseExpiry': _licenseExpiryCtrl.text.trim(),
        'address': _addressCtrl.text.trim(),
        'emergencyContact': _emergencyContactCtrl.text.trim(),
        'syncStatus': 'local',
      },
      'statusColor': AppTheme.colorFF27AE60,
      'trips': 0,
      'revenue': 'PHP 0',
      'score': 0,
      'delays': 0,
    };

    try {
      final successMessage = await widget.onAdd(newDriver);
      if (mounted) {
        final messenger = ScaffoldMessenger.of(context);
        Navigator.of(context).pop();
        messenger.showSnackBar(
          SnackBar(
            content: Text(successMessage),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              FormValidation.backendError(error, 'Driver could not be saved.'),
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  List<Map<String, String>> get _vehicleOptions {
    final rows = <Map<String, String>>[
      {'plate': '', 'label': 'Unassigned', 'geotabId': ''},
    ];
    final seen = <String>{''};
    for (final vehicle in vehiclesNotifier.value) {
      final plate = (vehicle['plate'] ?? vehicle['vehicle'] ?? '').toString();
      final status = (vehicle['status'] ?? '').toString().toLowerCase();
      if (plate.trim().isEmpty || seen.contains(plate)) {
        continue;
      }
      if (status == 'inactive' || status == 'deactivated') {
        continue;
      }
      seen.add(plate);
      rows.add({
        'plate': plate,
        'label': plate,
        'geotabId': (vehicle['geotabId'] ?? '').toString(),
      });
    }

    final current = _assignedVehicleCtrl.text.trim();
    if (current.isNotEmpty && !seen.contains(current)) {
      rows.add({'plate': current, 'label': current, 'geotabId': ''});
    }

    return rows;
  }

  String? get _selectedVehicleGeotabId {
    final plate = _assignedVehicleCtrl.text.trim();
    if (plate.isEmpty) {
      return null;
    }
    for (final option in _vehicleOptions) {
      if (option['plate'] == plate) {
        final geotabId = option['geotabId'] ?? '';
        return geotabId.isEmpty ? null : geotabId;
      }
    }

    return null;
  }

  static const List<String> _statusOptions = [
    'available',
    'on trip',
    'maintenance',
    'inactive',
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sw = MediaQuery.of(context).size.width;
    final sh = MediaQuery.of(context).size.height;
    final keyboardH = MediaQuery.of(context).viewInsets.bottom;
    final isVerySmall = sw < 360;
    final isMobile = sw < 600;
    final verticalInset = isVerySmall ? 16.0 : 24.0;

    return Dialog(
          backgroundColor: AppTheme.transparent,
          insetPadding: EdgeInsets.symmetric(
            horizontal: isVerySmall ? 8 : (isMobile ? 16 : 80),
            vertical: verticalInset,
          ),
          child: Container(
            constraints: BoxConstraints(
              maxWidth: isVerySmall ? sw - 16 : (isMobile ? 520 : 680),
              maxHeight: sh - keyboardH - verticalInset * 2,
            ),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
              borderRadius: BorderRadius.circular(isVerySmall ? 14 : 24),
              border: Border.all(
                color: isDark
                    ? AppTheme.white.withAlpha(20)
                    : AppTheme.black.withAlpha(20),
              ),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.black.withAlpha(77),
                  blurRadius: 40,
                  offset: const Offset(0, 16),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: EdgeInsets.all(isVerySmall ? 16 : 24),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [AppTheme.colorFF4B7BE5, AppTheme.colorFF1B2A4A],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(isVerySmall ? 14 : 24),
                      topRight: Radius.circular(isVerySmall ? 14 : 24),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppTheme.white.withAlpha(38),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.person_add_rounded,
                          color: AppTheme.white,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.initialDriver == null
                                  ? 'Add New Driver'
                                  : 'Edit Driver',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.white,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Fill in the required driver profile and assignment details',
                              style: TextStyle(
                                fontSize: 13,
                                color: AppTheme.white70,
                              ),
                            ),
                          ],
                        ),
                      ),
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: AppTheme.white.withAlpha(38),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.close_rounded,
                            color: AppTheme.white,
                            size: 20,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: EdgeInsets.all(isVerySmall ? 16 : 24),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          children: [
                            _formField(
                              controller: _nameCtrl,
                              label: 'Full Name',
                              hint: 'e.g. Juan Dela Cruz',
                              icon: Icons.person_rounded,
                              isDark: isDark,
                              validator: (v) => (v == null || v.trim().isEmpty)
                                  ? 'Name is required'
                                  : null,
                            ),
                            const SizedBox(height: 16),
                            _formField(
                              controller: _licenseCtrl,
                              label: 'License Number',
                              hint: 'e.g. N04-12-345678',
                              icon: Icons.credit_card_rounded,
                              isDark: isDark,
                              validator: (v) => (v == null || v.trim().isEmpty)
                                  ? 'License number is required'
                                  : null,
                            ),
                            const SizedBox(height: 16),
                            _formField(
                              controller: _phoneCtrl,
                              label: 'Contact Number',
                              hint: 'e.g. +63 917 123 4567',
                              icon: Icons.phone_rounded,
                              isDark: isDark,
                              keyboardType: TextInputType.phone,
                              validator: (v) => (v == null || v.trim().isEmpty)
                                  ? 'Phone is required'
                                  : null,
                            ),
                            const SizedBox(height: 16),
                            _formField(
                              controller: _emailCtrl,
                              label: 'Email',
                              hint: 'e.g. juan@pioneer.local',
                              icon: Icons.email_rounded,
                              isDark: isDark,
                              keyboardType: TextInputType.emailAddress,
                              validator: (value) {
                                if (!_createLoginAccount) return null;
                                final email = value?.trim() ?? '';
                                if (email.isEmpty) {
                                  return 'Email is required for driver login';
                                }
                                if (!email.contains('@') ||
                                    !email.contains('.')) {
                                  return 'Enter a valid email address';
                                }
                                return null;
                              },
                            ),
                            if (widget.initialDriver == null) ...[
                              const SizedBox(height: 12),
                              _driverAccountToggle(isDark),
                            ],
                            const SizedBox(height: 16),
                            _licenseExpiryDatePicker(isDark),
                            const SizedBox(height: 16),
                            _vehicleDropdown(isDark),
                            const SizedBox(height: 16),
                            _statusDropdown(isDark),
                            const SizedBox(height: 16),
                            _formField(
                              controller: _emergencyContactCtrl,
                              label: 'Emergency Contact',
                              hint: 'Name and phone number',
                              icon: Icons.emergency_rounded,
                              isDark: isDark,
                              validator: (_) => null,
                            ),
                            const SizedBox(height: 16),
                            _formField(
                              controller: _addressCtrl,
                              label: 'Address',
                              hint: 'Driver home address',
                              icon: Icons.home_rounded,
                              isDark: isDark,
                              validator: (_) => null,
                            ),
                            SizedBox(height: isVerySmall ? 16 : 28),

                            // Buttons
                            Row(
                              children: [
                                Expanded(
                                  child: GestureDetector(
                                    onTap: _saving
                                        ? null
                                        : () => Navigator.pop(context),
                                    child: Container(
                                      height: isVerySmall ? 44 : 50,
                                      decoration: BoxDecoration(
                                        color: isDark
                                            ? AppTheme.colorFF0F1117
                                            : AppTheme.colorFFF5F6F8,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: isDark
                                              ? AppTheme.white.withAlpha(26)
                                              : AppTheme.black.withAlpha(26),
                                        ),
                                      ),
                                      child: Center(
                                        child: Text(
                                          'Cancel',
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                            color: isDark
                                                ? AppTheme.gray300
                                                : AppTheme.gray700,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: MouseRegion(
                                    cursor: SystemMouseCursors.click,
                                    child: GestureDetector(
                                      onTap: _saving ? null : _submit,
                                      child: Container(
                                        height: isVerySmall ? 44 : 50,
                                        decoration: BoxDecoration(
                                          gradient: const LinearGradient(
                                            colors: [
                                              AppTheme.colorFF4B7BE5,
                                              AppTheme.colorFF00D4FF,
                                            ],
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: AppTheme.colorFF4B7BE5
                                                  .withAlpha(102),
                                              blurRadius: 12,
                                              offset: const Offset(0, 4),
                                            ),
                                          ],
                                        ),
                                        child: Center(
                                          child: _saving
                                              ? const SizedBox(
                                                  width: 20,
                                                  height: 20,
                                                  child:
                                                      CircularProgressIndicator(
                                                        color: AppTheme.white,
                                                        strokeWidth: 2,
                                                      ),
                                                )
                                              : Text(
                                                  widget.submitLabel,
                                                  style: TextStyle(
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w700,
                                                    color: AppTheme.white,
                                                  ),
                                                ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        )
        .animate()
        .fadeIn(duration: 200.ms)
        .scale(
          begin: const Offset(0.95, 0.95),
          end: const Offset(1, 1),
          duration: 200.ms,
        );
  }

  Widget _driverAccountToggle(bool isDark) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => setState(() => _createLoginAccount = !_createLoginAccount),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark
              ? AppTheme.darkCardBg.withAlpha(170)
              : AppTheme.colorFFF5F6F8,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _createLoginAccount
                ? AppTheme.accentCyan.withAlpha(130)
                : (isDark
                    ? AppTheme.white.withAlpha(22)
                    : AppTheme.black.withAlpha(18)),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: _createLoginAccount,
              onChanged: (value) =>
                  setState(() => _createLoginAccount = value ?? false),
              activeColor: AppTheme.accentCyan,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Create PioneerPath driver login',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: isDark ? AppTheme.white : AppTheme.gray800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Uses the driver email and issues a one-time temporary password.',
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
      ),
    );
  }

  Widget _licenseExpiryDatePicker(bool isDark) {
    return _labeledControl(
      label: 'License Expiry Date',
      isDark: isDark,
      child: TextFormField(
        controller: _licenseExpiryCtrl,
        readOnly: true,
        onTap: () async {
          final initial =
              DateTime.tryParse(_licenseExpiryCtrl.text.trim()) ??
              DateTime.now().add(const Duration(days: 365));
          final selected = await showDatePicker(
            context: context,
            initialDate: initial,
            firstDate: DateTime(
              DateTime.now().year,
              DateTime.now().month,
              DateTime.now().day,
            ),
            lastDate: DateTime.now().add(const Duration(days: 3650)),
          );
          if (selected == null) {
            return;
          }
          _licenseExpiryCtrl.text = selected.toIso8601String().split('T').first;
        },
        style: TextStyle(
          fontSize: 14,
          color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
        ),
        decoration: _inputDecoration(
          hint: 'Select expiry date',
          icon: Icons.event_rounded,
          isDark: isDark,
        ).copyWith(suffixIcon: const Icon(Icons.calendar_month_rounded)),
        validator: (value) => FormValidation.futureOrTodayDateText(
          'License expiry date',
          value,
          required: true,
        ),
      ),
    );
  }

  Widget _vehicleDropdown(bool isDark) {
    final options = _vehicleOptions;
    final current = _assignedVehicleCtrl.text.trim();
    final value = options.any((option) => option['plate'] == current)
        ? current
        : '';

    return _labeledControl(
      label: 'Assigned Vehicle',
      isDark: isDark,
      child: DropdownButtonFormField<String>(
        initialValue: value.isEmpty ? null : value,
        hint: const Text('Select...'),
        decoration: _inputDecoration(
          hint: 'Select assigned vehicle',
          icon: Icons.local_shipping_rounded,
          isDark: isDark,
        ),
        dropdownColor: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        items: options
            .map(
              (option) => DropdownMenuItem<String>(
                value: option['plate'],
                child: Text(option['label'] ?? 'Unassigned'),
              ),
            )
            .toList(),
        onChanged: (value) {
          setState(() => _assignedVehicleCtrl.text = value ?? '');
        },
        validator: (value) =>
            FormValidation.requiredSelection('assigned vehicle', value),
      ),
    );
  }

  Widget _statusDropdown(bool isDark) {
    final value = _statusOptions.contains(_status) ? _status : 'available';

    return _labeledControl(
      label: 'Status',
      isDark: isDark,
      child: DropdownButtonFormField<String>(
        initialValue: _statusOptions.contains(value) ? value : null,
        hint: const Text('Select...'),
        decoration: _inputDecoration(
          hint: 'Select driver status',
          icon: Icons.verified_rounded,
          isDark: isDark,
        ),
        dropdownColor: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        items: _statusOptions
            .map(
              (status) => DropdownMenuItem<String>(
                value: status,
                child: Text(_statusLabelForForm(status)),
              ),
            )
            .toList(),
        onChanged: (value) {
          setState(() => _status = value ?? 'available');
        },
        validator: (value) => FormValidation.requiredSelection('status', value),
      ),
    );
  }

  Widget _labeledControl({
    required String label,
    required bool isDark,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isDark ? AppTheme.gray300 : AppTheme.colorFF2C3E50,
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }

  String _statusLabelForForm(String status) {
    switch (status) {
      case 'available':
        return 'Available';
      case 'on trip':
        return 'On Trip';
      case 'maintenance':
        return 'Maintenance';
      case 'inactive':
        return 'Inactive';
      default:
        return status;
    }
  }

  Widget _formField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required bool isDark,
    required String? Function(String?) validator,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isDark ? AppTheme.gray300 : AppTheme.colorFF2C3E50,
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          validator: validator,
          keyboardType: keyboardType,
          style: TextStyle(
            fontSize: 14,
            color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              color: isDark ? AppTheme.gray600 : AppTheme.gray500,
              fontSize: 14,
            ),
            prefixIcon: Icon(
              icon,
              size: 18,
              color: isDark ? AppTheme.gray500 : AppTheme.gray600,
            ),
            filled: true,
            fillColor: isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF5F6F8,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: isDark
                    ? AppTheme.white.withAlpha(26)
                    : AppTheme.black.withAlpha(26),
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: isDark
                    ? AppTheme.white.withAlpha(26)
                    : AppTheme.black.withAlpha(26),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(
                color: AppTheme.colorFF4B7BE5,
                width: 2,
              ),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppTheme.colorFFE74C3C),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(
                color: AppTheme.colorFFE74C3C,
                width: 2,
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            isDense: true,
            errorMaxLines: 1,
            errorStyle: const TextStyle(fontSize: 12, height: 0.8),
          ),
        ),
      ],
    );
  }

  InputDecoration _inputDecoration({
    required String hint,
    required IconData icon,
    required bool isDark,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
        color: isDark ? AppTheme.gray600 : AppTheme.gray500,
        fontSize: 14,
      ),
      prefixIcon: Icon(
        icon,
        size: 18,
        color: isDark ? AppTheme.gray500 : AppTheme.gray600,
      ),
      filled: true,
      fillColor: isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF5F6F8,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: isDark
              ? AppTheme.white.withAlpha(26)
              : AppTheme.black.withAlpha(26),
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: isDark
              ? AppTheme.white.withAlpha(26)
              : AppTheme.black.withAlpha(26),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppTheme.colorFF4B7BE5, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppTheme.colorFFE74C3C),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppTheme.colorFFE74C3C, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      isDense: true,
      errorMaxLines: 1,
      errorStyle: const TextStyle(fontSize: 12, height: 0.8),
    );
  }
}
