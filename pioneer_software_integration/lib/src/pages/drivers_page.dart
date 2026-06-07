import 'dart:async';

import 'package:flutter/material.dart';
import '../widgets/dashboard_layout.dart';
import '../services/drivers_store.dart';
import '../services/crud_permissions.dart';
import '../services/fleet_crud_policy.dart';
import '../services/page_cache_service.dart';
import '../services/vehicles_store.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';
import '../utils/form_validation.dart';
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
  String _statusFilter = 'All Status';
  String _sortMode = 'Name A-Z';
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
    final color = driver['statusColor'];
    return color is Color ? color : AppTheme.materialGrey;
  }

  @override
  void dispose() {
    driversNotifier.removeListener(_onDriversChanged);
    _animationController.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _leaderboardDrivers {
    final sorted = List<Map<String, dynamic>>.from(driversNotifier.value)
      ..sort((a, b) => (b['score'] as int).compareTo(a['score'] as int));
    return sorted.take(3).toList();
  }

  List<Map<String, dynamic>> get _filteredDrivers {
    var drivers = driversNotifier.value;
    if (_statusFilter != 'All Status') {
      final target = _statusFilter.toLowerCase();
      drivers = drivers.where((driver) {
        final status = driver['status']?.toString().toLowerCase() ?? '';
        return status == target ||
            status.replaceAll(' ', '') == target.replaceAll(' ', '');
      }).toList();
    }

    final sorted = List<Map<String, dynamic>>.from(drivers);
    sorted.sort((a, b) {
      return switch (_sortMode) {
        'Name Z-A' => _compareDriverText(b, a, 'name'),
        'Status A-Z' => _compareDriverText(a, b, 'status'),
        'Status Z-A' => _compareDriverText(b, a, 'status'),
        'Score High-Low' => _driverScore(b).compareTo(_driverScore(a)),
        'Score Low-High' => _driverScore(a).compareTo(_driverScore(b)),
        _ => _compareDriverText(a, b, 'name'),
      };
    });
    return sorted;
  }

  void _toggleLeaderboard() {
    setState(() => _isLeaderboardExpanded = !_isLeaderboardExpanded);
    if (_isLeaderboardExpanded) {
      _animationController.forward();
    } else {
      _animationController.reverse();
    }
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
          await addDriverToBackend(driver);
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
    final isTablet = screenWidth >= 600 && screenWidth < 1024;

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
          // Header
          Container(
            padding: EdgeInsets.all(isMobile ? 16 : 24),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
              border: Border(
                bottom: BorderSide(
                  color: isDark
                      ? AppTheme.white.withAlpha(20)
                      : AppTheme.black.withAlpha(20),
                ),
              ),
            ),
            child: _buildHeader(isDark, isMobile, isTablet, screenWidth)
                .animate()
                .fadeIn(duration: 500.ms)
                .slideY(
                  begin: 0.2,
                  end: 0,
                  duration: 500.ms,
                  curve: Curves.easeOut,
                ),
          ),

          Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(
              isMobile ? 16 : 24,
              12,
              isMobile ? 16 : 24,
              12,
            ),
            color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
            child: _buildDriverControls(isDark),
          ),

          // Leaderboard section
          Container(
            decoration: BoxDecoration(
              color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
              border: Border(
                bottom: BorderSide(
                  color: isDark
                      ? AppTheme.white.withAlpha(20)
                      : AppTheme.black.withAlpha(20),
                ),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: _toggleLeaderboard,
                  child: Container(
                    padding: EdgeInsets.all(
                      isMobile
                          ? 12
                          : isTablet
                          ? 16
                          : 20,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Performance Leaderboard',
                                style: TextStyle(
                                  fontSize: isMobile ? 16 : 18,
                                  fontWeight: FontWeight.w700,
                                  color: isDark
                                      ? AppTheme.white
                                      : AppTheme.colorFF2C3E50,
                                ),
                              ),
                              AnimatedOpacity(
                                duration: const Duration(milliseconds: 200),
                                opacity: _isLeaderboardExpanded ? 1.0 : 0.0,
                                child: SizedBox(
                                  height: _isLeaderboardExpanded ? 20 : 0,
                                  child: Text(
                                    'Top performing drivers',
                                    style: TextStyle(
                                      fontSize: isMobile ? 11 : 12,
                                      color: isDark
                                          ? AppTheme.gray400
                                          : AppTheme.gray600,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: isDark
                                ? AppTheme.white.withAlpha(13)
                                : AppTheme.black.withAlpha(13),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: AnimatedRotation(
                            duration: const Duration(milliseconds: 300),
                            turns: _isLeaderboardExpanded ? 0.5 : 0,
                            child: Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 20,
                              color: isDark
                                  ? AppTheme.gray400
                                  : AppTheme.gray600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizeTransition(
                  sizeFactor: _contentAnimation,
                  axisAlignment: -1.0,
                  child: Container(
                    padding: EdgeInsets.fromLTRB(
                      isMobile
                          ? 12
                          : isTablet
                          ? 16
                          : 20,
                      0,
                      isMobile
                          ? 12
                          : isTablet
                          ? 16
                          : 20,
                      isMobile
                          ? 12
                          : isTablet
                          ? 16
                          : 20,
                    ),
                    child: _buildLeaderboardSection(isDark, isMobile, isTablet)
                        .animate()
                        .fadeIn(duration: 600.ms)
                        .slideY(
                          begin: 0.2,
                          end: 0,
                          duration: 500.ms,
                          curve: Curves.easeOut,
                        ),
                  ),
                ),
              ],
            ),
          ),

          // Driver cards grid
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refreshDrivers,
              child: _filteredDrivers.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(height: 420, child: _buildEmptyState(isDark)),
                      ],
                    )
                  : GridView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.all(isMobile ? 16 : 24),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 400,
                            crossAxisSpacing: 20,
                            mainAxisSpacing: 20,
                            childAspectRatio: 1.45,
                          ),
                      itemCount: _filteredDrivers.length,
                      itemBuilder: (context, index) {
                        return _buildDriverCard(_filteredDrivers[index], isDark)
                            .animate()
                            .fadeIn(duration: 700.ms)
                            .slideY(
                              begin: 0.2,
                              end: 0,
                              duration: 500.ms,
                              curve: Curves.easeOut,
                            );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(
    bool isDark,
    bool isMobile,
    bool isTablet,
    double screenWidth,
  ) {
    if (screenWidth < 500) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '${_filteredDrivers.length} drivers shown',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
            ),
          ),
          if (CrudPermissions.canCreate(CrudEntity.drivers))
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: _showAddDriverModal,
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [AppTheme.colorFF4B7BE5, AppTheme.colorFF00D4FF],
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: const [
                      Icon(Icons.add_rounded, color: AppTheme.white, size: 18),
                      SizedBox(width: 4),
                      Text(
                        'Add',
                        style: TextStyle(
                          color: AppTheme.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
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

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          '${_filteredDrivers.length} drivers shown',
          style: TextStyle(
            fontSize: isMobile ? 14 : 16,
            color: isDark ? AppTheme.gray400 : AppTheme.gray600,
          ),
        ),
        if (CrudPermissions.canCreate(CrudEntity.drivers))
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: _showAddDriverModal,
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppTheme.colorFF4B7BE5, AppTheme.colorFF00D4FF],
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: const [
                    Icon(Icons.add_rounded, color: AppTheme.white, size: 20),
                    SizedBox(width: 8),
                    Text(
                      'Add Driver',
                      style: TextStyle(
                        color: AppTheme.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
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

  Widget _buildDriverControls(bool isDark) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        SizedBox(
          width: 210,
          child: DropdownButtonFormField<String>(
            initialValue: _statusFilter,
            decoration: const InputDecoration(labelText: 'Status'),
            items: const [
              DropdownMenuItem(value: 'All Status', child: Text('All Status')),
              DropdownMenuItem(value: 'Active', child: Text('Active')),
              DropdownMenuItem(value: 'Available', child: Text('Available')),
              DropdownMenuItem(value: 'On Trip', child: Text('On Trip')),
              DropdownMenuItem(value: 'Inactive', child: Text('Inactive')),
            ],
            onChanged: (value) =>
                setState(() => _statusFilter = value ?? 'All Status'),
          ),
        ),
        SizedBox(
          width: 210,
          child: DropdownButtonFormField<String>(
            initialValue: _sortMode,
            decoration: const InputDecoration(labelText: 'Sort'),
            items: const [
              DropdownMenuItem(value: 'Name A-Z', child: Text('Name A-Z')),
              DropdownMenuItem(value: 'Name Z-A', child: Text('Name Z-A')),
              DropdownMenuItem(value: 'Status A-Z', child: Text('Status A-Z')),
              DropdownMenuItem(value: 'Status Z-A', child: Text('Status Z-A')),
              DropdownMenuItem(
                value: 'Score High-Low',
                child: Text('Score High-Low'),
              ),
              DropdownMenuItem(
                value: 'Score Low-High',
                child: Text('Score Low-High'),
              ),
            ],
            onChanged: (value) =>
                setState(() => _sortMode = value ?? 'Name A-Z'),
          ),
        ),
        if (_statusFilter != 'All Status' || _sortMode != 'Name A-Z')
          TextButton.icon(
            onPressed: () => setState(() {
              _statusFilter = 'All Status';
              _sortMode = 'Name A-Z';
            }),
            icon: const Icon(Icons.filter_alt_off_rounded),
            label: const Text('Reset'),
          ),
      ],
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

  Widget _buildLeaderboardSection(bool isDark, bool isMobile, bool isTablet) {
    final leaders = _leaderboardDrivers;
    if (leaders.isEmpty) {
      return const SizedBox(height: 0);
    }

    final medals = [
      {'icon': Icons.emoji_events, 'color': AppTheme.colorFFFFD700},
      {'icon': Icons.emoji_events, 'color': AppTheme.colorFFC0C0C0},
      {'icon': Icons.emoji_events, 'color': AppTheme.colorFFCD7F32},
    ];

    if (isMobile) {
      return FadeTransition(
        opacity: _contentAnimation,
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            children: [
              for (int i = 0; i < leaders.length; i++) ...[
                _buildLeaderboardCard(leaders[i], medals[i], isDark, isMobile),
                if (i < leaders.length - 1) const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      );
    }

    return FadeTransition(
      opacity: _contentAnimation,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < leaders.length; i++) ...[
            Expanded(
              child: _buildLeaderboardCard(
                leaders[i],
                medals[i],
                isDark,
                false,
              ),
            ),
            if (i < leaders.length - 1) const SizedBox(width: 12),
          ],
        ],
      ),
    );
  }

  Widget _buildLeaderboardCard(
    Map<String, dynamic> driver,
    Map<String, dynamic> medal,
    bool isDark,
    bool isMobile,
  ) {
    return Container(
      padding: EdgeInsets.all(isMobile ? 10 : 12),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF8FAFD,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: (medal['color'] as Color).withAlpha(77),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                medal['icon'] as IconData,
                color: medal['color'] as Color,
                size: isMobile ? 16 : 20,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      driver['name'].toString().split(' ').last,
                      style: TextStyle(
                        fontSize: isMobile ? 12 : 13,
                        fontWeight: FontWeight.w700,
                        color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'Score: ${driver['score']}',
                      style: TextStyle(
                        fontSize: isMobile ? 10 : 11,
                        color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${driver['trips']} trips',
                style: TextStyle(
                  fontSize: isMobile ? 10 : 11,
                  color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                ),
              ),
              Text(
                driver['revenue'],
                style: TextStyle(
                  fontSize: isMobile ? 11 : 12,
                  fontWeight: FontWeight.w700,
                  color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDriverCard(Map<String, dynamic> driver, bool isDark) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = (constraints.maxWidth / 350).clamp(0.85, 1.2);
        final crudPolicy = FleetCrudPolicy.driver(driver);

        return Container(
          padding: EdgeInsets.fromLTRB(
            16 * scale,
            12 * scale,
            16 * scale,
            12 * scale,
          ),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isDark
                  ? AppTheme.white.withAlpha(20)
                  : AppTheme.black.withAlpha(20),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40 * scale,
                    height: 40 * scale,
                    decoration: BoxDecoration(
                      color: _driverStatusColor(driver).withAlpha(38),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.person_rounded,
                      color: _driverStatusColor(driver),
                      size: 20 * scale,
                    ),
                  ),
                  SizedBox(width: 12 * scale),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          driver['name'],
                          style: TextStyle(
                            fontSize: 16.0 * scale,
                            fontWeight: FontWeight.w900,
                            color: isDark
                                ? AppTheme.white
                                : AppTheme.colorFF2C3E50,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        SizedBox(height: 2 * scale),
                        Text(
                          driver['license'],
                          style: TextStyle(
                            fontSize: 12.0 * scale,
                            color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 10 * scale,
                      vertical: 5 * scale,
                    ),
                    decoration: BoxDecoration(
                      color: _driverStatusColor(driver).withAlpha(38),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _statusLabel(driver['status']),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: _driverStatusColor(driver),
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Driver actions',
                    onSelected: (value) async {
                      if (value == 'view') {
                        await _showDriverDetails(driver, isDark);
                      } else if (value == 'deactivate') {
                        if (!crudPolicy.canDeactivate) {
                          _showDriverActionMessage(
                            crudPolicy.deactivateDisabledReason,
                          );
                          return;
                        }
                        final confirmed = await _confirmDeactivateDriver(
                          driver,
                          isDark,
                        );
                        if (!confirmed) {
                          return;
                        }
                        try {
                          await deactivateDriverInBackend(driver);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              behavior: SnackBarBehavior.floating,
                              content: Text('Driver deactivated successfully.'),
                            ),
                          );
                        } catch (error) {
                          if (!context.mounted) return;
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
                          _showDriverActionMessage(
                            crudPolicy.deactivateDisabledReason,
                          );
                          return;
                        }
                        try {
                          await reactivateDriverInBackend(driver);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              behavior: SnackBarBehavior.floating,
                              content: Text('Driver reactivated successfully.'),
                            ),
                          );
                        } catch (error) {
                          if (!context.mounted) return;
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
                      } else if (value == 'delete') {
                        if (!crudPolicy.canDelete) {
                          _showDriverActionMessage(
                            crudPolicy.deleteDisabledReason,
                          );
                          return;
                        }
                        final confirmed = await _confirmDeleteDriver(
                          driver,
                          isDark,
                        );
                        if (!confirmed) return;
                        try {
                          await deleteDriverInBackend(driver);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              behavior: SnackBarBehavior.floating,
                              content: Text('Driver deleted successfully.'),
                            ),
                          );
                        } catch (error) {
                          if (!context.mounted) return;
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
                        final reason = await _confirmAnonymizeDriver(
                          driver,
                          isDark,
                        );
                        if (reason == null || reason.trim().isEmpty) {
                          return;
                        }
                        try {
                          await anonymizeDriverInBackend(
                            driver,
                            reason: reason.trim(),
                          );
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              behavior: SnackBarBehavior.floating,
                              content: Text('Driver personal data anonymized.'),
                            ),
                          );
                        } catch (_) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              behavior: SnackBarBehavior.floating,
                              content: Text(
                                'Driver personal data could not be anonymized.',
                              ),
                            ),
                          );
                        }
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'view',
                        child: _DriverActionMenuItem(
                          icon: Icons.visibility_rounded,
                          label: 'View Details',
                        ),
                      ),
                      if (CrudPermissions.canEdit(CrudEntity.drivers))
                        PopupMenuItem(
                          value: 'edit',
                          enabled: crudPolicy.canEdit,
                          child: _DriverActionMenuItem(
                            icon: Icons.edit_rounded,
                            label: crudPolicy.canEdit
                                ? 'Edit'
                                : 'Edit - GeoTab read-only',
                          ),
                        ),
                      if (CrudPermissions.canEdit(CrudEntity.drivers) &&
                          _isDriverInactive(driver))
                        PopupMenuItem(
                          value: 'reactivate',
                          enabled: crudPolicy.canReactivate,
                          child: _DriverActionMenuItem(
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
                            label: crudPolicy.canDelete
                                ? 'Delete'
                                : 'Delete - managed only',
                            destructive: true,
                          ),
                        ),
                      if (CrudPermissions.isSuperAdmin &&
                          _isDriverInactive(driver))
                        const PopupMenuItem(
                          value: 'anonymize',
                          child: _DriverActionMenuItem(
                            icon: Icons.privacy_tip_outlined,
                            label: 'Anonymize personal data',
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              SizedBox(height: 12 * scale),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.local_shipping_rounded,
                              size: 16.0 * scale,
                              color: isDark
                                  ? AppTheme.gray500
                                  : AppTheme.gray600,
                            ),
                            SizedBox(width: 4 * scale),
                            Text(
                              '${driver['trips']} trips',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark
                                    ? AppTheme.gray400
                                    : AppTheme.gray600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                        SizedBox(height: 4 * scale),
                        Text(
                          driver['revenue'],
                          style: TextStyle(
                            fontSize: 14.0 * scale,
                            fontWeight: FontWeight.w700,
                            color: isDark
                                ? AppTheme.white
                                : AppTheme.colorFF2C3E50,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        SizedBox(height: 4 * scale),
                        Text(
                          'License expiry: ${driver['licenseExpiry'] ?? 'N/A'}',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (_licenseExpiryWarning(driver) != null) ...[
                          SizedBox(height: 6 * scale),
                          _licenseExpiryWarningBadge(driver, scale),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(width: 12 * scale),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.star_rounded,
                              size: 16.0 * scale,
                              color: AppTheme.colorFFFFA500,
                            ),
                            SizedBox(width: 4 * scale),
                            Text(
                              'Score: ${driver['score']}',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark
                                    ? AppTheme.gray400
                                    : AppTheme.gray600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                        SizedBox(height: 4 * scale),
                        Row(
                          children: [
                            Icon(
                              Icons.access_time_rounded,
                              size: 14.0 * scale,
                              color: isDark
                                  ? AppTheme.gray500
                                  : AppTheme.gray600,
                            ),
                            SizedBox(width: 4 * scale),
                            Text(
                              '${driver['delays']} delays',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark
                                    ? AppTheme.gray400
                                    : AppTheme.gray600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                        SizedBox(height: 4 * scale),
                        Text(
                          'Vehicle: ${driver['assignedVehicle'] ?? 'N/A'}',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        SizedBox(height: 4 * scale),
                        Wrap(
                          spacing: 8 * scale,
                          runSpacing: 6 * scale,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            GeoTabSyncStatusBadge.fromEntity(
                              driver,
                              compact: true,
                              scale: scale,
                            ),
                            _fleetCrudScopeChip(crudPolicy, isDark, scale),
                            _pushToGeotabButton(
                              enabled: crudPolicy.canPushToGeotab,
                              disabledReason: crudPolicy.pushDisabledReason,
                              onPressed: () => _pushDriverToGeotab(driver),
                              scale: scale,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _pushToGeotabButton({
    required bool enabled,
    required String disabledReason,
    required VoidCallback onPressed,
    required double scale,
  }) {
    return Tooltip(
      message: enabled
          ? 'Review and stage this saved local record for GeoTab approval.'
          : disabledReason,
      child: OutlinedButton.icon(
        onPressed: enabled ? onPressed : null,
        icon: Icon(Icons.cloud_upload_outlined, size: 14 * scale),
        label: Text(
          'Push to GeoTab',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
        ),
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.symmetric(horizontal: 9 * scale),
        ),
      ),
    );
  }

  Widget _fleetCrudScopeChip(
    FleetCrudPolicy policy,
    bool isDark,
    double scale,
  ) {
    return Tooltip(
      message: policy.scopeDetail,
      child: Container(
        constraints: BoxConstraints(maxWidth: 190 * scale),
        padding: EdgeInsets.symmetric(
          horizontal: 9 * scale,
          vertical: 5 * scale,
        ),
        decoration: BoxDecoration(
          color: policy.scopeColor.withValues(alpha: isDark ? 0.18 : 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: policy.scopeColor.withValues(alpha: isDark ? 0.34 : 0.24),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(policy.scopeIcon, size: 12 * scale, color: policy.scopeColor),
            SizedBox(width: 5 * scale),
            Flexible(
              child: Text(
                policy.scopeLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11 * scale,
                  fontWeight: FontWeight.w800,
                  color: policy.scopeColor,
                ),
              ),
            ),
          ],
        ),
      ),
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
      builder: (context) => AlertDialog(
        backgroundColor: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
        title: Text(
          (driver['name'] ?? 'Driver details').toString(),
          style: TextStyle(
            color: isDark ? AppTheme.white : AppTheme.colorFF111827,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    _detailStatusChip(
                      _statusLabel(driver['status']?.toString() ?? ''),
                      _driverStatusColor(driver),
                    ),
                    GeoTabSyncStatusBadge.fromEntity(driver, compact: true),
                  ],
                ),
                const SizedBox(height: 18),
                for (final entry in details) ...[
                  Text(
                    entry.key,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  SelectableText(
                    entry.value,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDark ? AppTheme.white : AppTheme.colorFF111827,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
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
              'This removes license, phone, email, address, and emergency contact for $name while preserving trip history.',
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

  Widget _buildEmptyState(bool isDark) {
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
            'No drivers registered yet',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.gray600 : AppTheme.gray400,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Create a complete driver profile with license, vehicle assignment, and emergency contact details.',
            style: TextStyle(
              fontSize: 14,
              color: isDark ? AppTheme.gray500 : AppTheme.gray500,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          if (CrudPermissions.canCreate(CrudEntity.drivers))
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
              maxWidth: isVerySmall ? sw - 16 : 480,
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
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header
                  Container(
                    padding: EdgeInsets.all(isVerySmall ? 16 : 24),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [
                          AppTheme.colorFF4B7BE5,
                          AppTheme.colorFF1B2A4A,
                        ],
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
                                'Fill in the driver details below',
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

                  // Form
                  Padding(
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
                            validator: (_) => null,
                          ),
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
                                        borderRadius: BorderRadius.circular(12),
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
                ],
              ),
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
