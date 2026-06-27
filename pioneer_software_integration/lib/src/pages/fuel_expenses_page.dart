import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../config/pioneer_runtime_config.dart';
import '../services/backend_api.dart';
import '../services/fleet_sync_service.dart';
import '../services/page_cache_service.dart';
import '../services/vehicles_store.dart';
import '../theme/app_theme.dart';
import '../utils/display_format.dart';
import '../utils/form_validation.dart';
import '../widgets/dashboard_layout.dart';
import '../widgets/page_skeletons.dart';

class FuelExpensesPage extends StatefulWidget {
  const FuelExpensesPage({super.key});

  @override
  State<FuelExpensesPage> createState() => _FuelExpensesPageState();
}

class _FuelExpensesPageState extends State<FuelExpensesPage> {
  static const String _cacheKey = 'fuel_expenses_page';

  late Future<Map<String, dynamic>> _fuelFuture;
  final List<Map<String, dynamic>> _localEntries = [];
  String _selectedVehicle = '';

  @override
  void initState() {
    super.initState();
    refreshVehiclesFromBackendSilently();
    _fuelFuture = _loadFuel(forceRefresh: true);
  }

  String get _filteredCacheKey =>
      '$_cacheKey:${_selectedVehicle.isEmpty ? 'all' : _selectedVehicle}';

  Future<Map<String, dynamic>> _loadFuel({bool forceRefresh = false}) async {
    return PageCacheService.getOrLoad<Map<String, dynamic>>(
      key: _filteredCacheKey,
      ttl: PageCacheService.fuelTtl,
      forceRefresh: forceRefresh,
      loader: () => BackendApiService.loadWithWarmRetry<Map<String, dynamic>>(
        attempts: forceRefresh ? 2 : 4,
        request: (retryForceRefresh) async {
          final effectiveForceRefresh = forceRefresh || retryForceRefresh;
          refreshFleetSnapshotSilently(forceRefresh: effectiveForceRefresh);
          warmOperationalCachesSilently(forceRefresh: effectiveForceRefresh);
          final results = await Future.wait<dynamic>([
            BackendApiService.getFleetFuel(
              forceRefresh: effectiveForceRefresh,
              vehicle: _selectedVehicle,
            ),
            _safeListRequest(
              () => BackendApiService.getFleetFuelTransactions(
                forceRefresh: effectiveForceRefresh,
                vehicle: _selectedVehicle,
              ),
            ),
            _safeListRequest(
              () => BackendApiService.getFleetEnergyCharges(
                forceRefresh: effectiveForceRefresh,
              ),
            ),
          ]);

          final fuel = Map<String, dynamic>.from(
            results[0] as Map<String, dynamic>,
          );
          fuel['transactions'] = results[1];
          fuel['chargeEvents'] = _filterVehicleRows(
            results[2] as List<Map<String, dynamic>>,
          );
          return fuel;
        },
      ),
    );
  }

  void _reload() {
    setState(() {
      _fuelFuture = _loadFuel(forceRefresh: true);
    });
  }

  Future<List<Map<String, dynamic>>> _safeListRequest(
    Future<List<Map<String, dynamic>>> Function() request,
  ) async {
    try {
      return await request();
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  Map<String, dynamic>? _cachedFuelData() {
    final cached = PageCacheService.anyData<Map<String, dynamic>>(
      _filteredCacheKey,
    );
    if (cached != null) {
      return cached;
    }

    final suffix = _selectedVehicle.isEmpty
        ? ''
        : '?${Uri(queryParameters: {'vehicle': _selectedVehicle}).query}';
    final fuel = BackendApiService.peekCachedDataMap('/fleet/fuel$suffix');
    if (fuel == null || fuel.isEmpty) {
      return null;
    }

    return {
      ...fuel,
      'transactions':
          BackendApiService.peekCachedDataList(
            '/fleet/fuel/transactions$suffix',
          ) ??
          const <Map<String, dynamic>>[],
      'chargeEvents': _filterVehicleRows(
        BackendApiService.peekCachedDataList('/fleet/energy/charges') ??
            const <Map<String, dynamic>>[],
      ),
    };
  }

  List<Map<String, dynamic>> _filterVehicleRows(
    List<Map<String, dynamic>> rows,
  ) {
    final selected = _selectedVehicle.trim().toLowerCase();
    if (selected.isEmpty) return rows;
    return rows.where((row) {
      return [
        row['vehicle'],
        row['plate'],
        row['vehiclePlate'],
        row['geotabId'],
        row['deviceId'],
        row['vehicleGeotabId'],
      ].any((value) => value?.toString().trim().toLowerCase() == selected);
    }).toList();
  }

  List<String> _vehicleFilterOptions(Map<String, dynamic> data) {
    final values = <String>{};
    for (final vehicle in vehiclesNotifier.value) {
      final plate = vehicle['plate']?.toString().trim() ?? '';
      if (plate.isNotEmpty && plate.toLowerCase() != 'n/a') values.add(plate);
    }
    for (final row in [
      ..._listOfMaps(data['events']),
      ..._listOfMaps(data['transactions']),
      ..._listOfMaps(data['usageByVehicle']),
    ]) {
      final plate = row['vehicle']?.toString().trim() ?? '';
      if (plate.isNotEmpty && plate.toLowerCase() != 'n/a') values.add(plate);
    }
    final sorted = values.toList()..sort();
    if (_selectedVehicle.isNotEmpty && !sorted.contains(_selectedVehicle)) {
      sorted.add(_selectedVehicle);
      sorted.sort();
    }
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      currentRoute: '/delivery-confirm',
      title: 'Fuel & Energy',
      subtitle: 'Executive spend, consumption, and refuel visibility',
      child: FutureBuilder<Map<String, dynamic>>(
        future: _fuelFuture,
        initialData: _cachedFuelData(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return _FuelPageScaffold(
              child: const PioneerRouteSkeletonBody(
                routeName: '/delivery-confirm',
              ),
            );
          }

          if (snapshot.hasError) {
            return _FuelPageScaffold(
              child: _FuelEmptyState(
                title: 'Fuel intelligence is temporarily unavailable',
                message:
                    'The page is ready for live Geotab fuel data, but the backend did not return a valid response just now.',
                actionLabel: 'Retry',
                onTap: _reload,
              ),
            );
          }

          final data = snapshot.data ?? const <String, dynamic>{};
          final totals = _mapOf(data['totals']);
          final backendEvents = _listOfMaps(data['events']);
          final fuelTransactions = _listOfMaps(data['transactions']);
          final normalizedEvents = _listOfMaps(data['normalizedEvents']);
          final chargeEvents = _listOfMaps(data['chargeEvents']);
          final realUsageByVehicle = _listOfMaps(
            data['usageByVehicle'],
          ).where((item) => _toDouble(item['fuelUsedLiters']) > 0).toList();
          final priceSettings = _mapOf(data['priceSettings']);
          final preferredFuelRecords = normalizedEvents.isNotEmpty
              ? normalizedEvents
              : fuelTransactions.isNotEmpty
              ? fuelTransactions
              : backendEvents;
          final visibleLocalEntries = _filterVehicleRows(_localEntries);
          final realMergedEvents = [
            ...visibleLocalEntries,
            ...preferredFuelRecords,
          ];
          final usingSampleFuel =
              PioneerRuntimeConfig.showMockData &&
              realUsageByVehicle.isEmpty &&
              realMergedEvents.isEmpty;
          final usageByVehicle = usingSampleFuel
              ? _sampleFuelUsageByVehicle()
              : realUsageByVehicle;
          final mergedEvents = usingSampleFuel
              ? _sampleFuelRecords()
              : realMergedEvents;
          final reviewEvents = mergedEvents
              .where(
                (record) =>
                    record['reviewStatus']?.toString().toLowerCase() ==
                    'needs_review',
              )
              .toList();

          final totalSpend =
              _toDouble(totals['totalSpend']) +
              _sumField(visibleLocalEntries, 'totalCost');
          final totalLiters =
              _toDouble(totals['totalLiters']) +
              _sumField(visibleLocalEntries, 'liters');
          final avgPrice = totalLiters > 0 ? totalSpend / totalLiters : 0.0;
          final idleFuel = _toDouble(totals['idlingFuelUsedLiters']);
          final energyUsedKwh = _toDouble(totals['energyUsedKwh']);
          final chargingSessions = _toInt(totals['chargingSessions']);
          final abnormal = usageByVehicle
              .where((item) => item['abnormalConsumption'] == true)
              .length;
          final hasEnergyData =
              chargeEvents.isNotEmpty ||
              energyUsedKwh > 0 ||
              chargingSessions > 0;

          return _FuelPageScaffold(
            child: RefreshIndicator(
              onRefresh: () async => _reload(),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (usingSampleFuel) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      margin: const EdgeInsets.only(bottom: AppTheme.space12),
                      decoration: BoxDecoration(
                        color: AppTheme.colorFFF39C12.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppTheme.colorFFF39C12.withValues(alpha: 0.2)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.cloud_off, color: AppTheme.colorFFF39C12),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'GeoTab data unavailable — showing local data only. Live updates will resume when connection is restored.',
                              style: AppTheme.getSubtitleStyle(context).copyWith(fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  _buildHero(
                    context,
                    totalSpend: totalSpend,
                    totalLiters: totalLiters,
                    avgPrice: avgPrice,
                    idleFuel: idleFuel,
                    abnormalCount: abnormal,
                    energyUsedKwh: energyUsedKwh,
                    chargingSessions: chargingSessions,
                  ).animate().fadeIn(duration: 350.ms),
                  const SizedBox(height: AppTheme.space16),
                  _buildVehicleFilter(context, _vehicleFilterOptions(data)),
                  const SizedBox(height: AppTheme.space16),
                  _buildUsagePanel(
                    context,
                    usageByVehicle,
                    isSample: usingSampleFuel,
                  ).animate().fadeIn(duration: 450.ms),
                  if (reviewEvents.isNotEmpty) ...[
                    const SizedBox(height: AppTheme.space16),
                    _buildRefuelReviewPanel(context, reviewEvents),
                  ],
                  const SizedBox(height: AppTheme.space16),
                  if (mergedEvents.isEmpty)
                    _buildNoFuelRecordsPrompt(context)
                  else
                    _buildRecentEventsPanel(
                      context,
                      mergedEvents,
                      priceSettings,
                    ).animate().fadeIn(duration: 475.ms),
                  if (hasEnergyData) ...[
                    const SizedBox(height: AppTheme.space16),
                    _buildEnergyPanel(
                      context,
                      chargeEvents,
                      energyUsedKwh: energyUsedKwh,
                      chargingSessions: chargingSessions,
                    ).animate().fadeIn(duration: 500.ms),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _addFuelRecord() async {
    final record = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.transparent,
      builder: (context) => const _AddFuelRecordSheet(),
    );

    if (record == null || !mounted) {
      return;
    }

    try {
      await BackendApiService.createManualFuelEvent(record);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fuel record saved.')),
      );
      PageCacheService.invalidate(_filteredCacheKey);
      _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            FormValidation.backendError(error, 'Fuel record could not be saved.'),
          ),
        ),
      );
    }
  }

  Future<void> _confirmFuelEvent(Map<String, dynamic> record) async {
    final id = record['id']?.toString() ?? '';
    if (id.isEmpty || record['sourceType']?.toString().startsWith('geotab') == true) {
      return;
    }
    try {
      await BackendApiService.confirmFuelEvent(id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fuel event confirmed.')),
      );
      PageCacheService.invalidate(_filteredCacheKey);
      _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(FormValidation.backendError(error, 'Fuel event could not be confirmed.'))),
      );
    }
  }

  Future<void> _rejectFuelEvent(Map<String, dynamic> record) async {
    final id = record['id']?.toString() ?? '';
    if (id.isEmpty || record['sourceType']?.toString().startsWith('geotab') == true) {
      return;
    }
    try {
      await BackendApiService.rejectFuelEvent(
        id,
        reason: 'Rejected from Fuel & Energy review.',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fuel event rejected.')),
      );
      PageCacheService.invalidate(_filteredCacheKey);
      _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(FormValidation.backendError(error, 'Fuel event could not be rejected.'))),
      );
    }
  }

  Widget _buildVehicleFilter(BuildContext context, List<String> vehicles) {
    return _ExecutivePanel(
      title: 'Report scope',
      subtitle:
          'Filter every fuel total and record by a specific fleet vehicle.',
      child: Row(
        children: [
          const Icon(Icons.filter_alt_rounded, color: AppTheme.primaryBlue),
          const SizedBox(width: AppTheme.space16),
          Expanded(
            child: DropdownButtonFormField<String>(
              key: ValueKey(_selectedVehicle),
              initialValue: _selectedVehicle,
              decoration: const InputDecoration(labelText: 'Vehicle'),
              items: [
                const DropdownMenuItem(value: '', child: Text('All vehicles')),
                ...vehicles.map(
                  (vehicle) =>
                      DropdownMenuItem(value: vehicle, child: Text(vehicle)),
                ),
              ],
              onChanged: (value) {
                setState(() {
                  _selectedVehicle = value ?? '';
                  _fuelFuture = _loadFuel(forceRefresh: true);
                });
              },
            ),
          ),
          if (_selectedVehicle.isNotEmpty) ...[
            const SizedBox(width: 10),
            TextButton.icon(
              onPressed: () {
                setState(() {
                  _selectedVehicle = '';
                  _fuelFuture = _loadFuel(forceRefresh: true);
                });
              },
              icon: const Icon(Icons.close_rounded),
              label: const Text('Clear'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHero(
    BuildContext context, {
    required double totalSpend,
    required double totalLiters,
    required double avgPrice,
    required double idleFuel,
    required int abnormalCount,
    required double energyUsedKwh,
    required int chargingSessions,
  }) {
    final cards = [
      _HeroStat(
        label: 'Total Spend',
        value: _money(totalSpend),
        caption: 'Refuel cost across synced events',
        icon: Icons.account_balance_wallet_rounded,
        accent: AppTheme.colorFFD9B56D,
      ),
      _HeroStat(
        label: 'Total Liters',
        value: '${totalLiters.toStringAsFixed(totalLiters >= 100 ? 0 : 1)} L',
        caption: 'Combined fill-up volume',
        icon: Icons.local_gas_station_rounded,
        accent: AppTheme.colorFF00D4FF,
      ),
      _HeroStat(
        label: 'Average Price / L',
        value: 'PHP ${avgPrice.toStringAsFixed(2)}',
        caption: 'Weighted by actual liters',
        icon: Icons.trending_up_rounded,
        accent: AppTheme.colorFF10B981,
      ),
      _HeroStat(
        label: 'Idle Fuel',
        value: '${idleFuel.toStringAsFixed(idleFuel >= 100 ? 0 : 1)} L',
        caption: abnormalCount > 0
            ? '$abnormalCount asset${abnormalCount == 1 ? '' : 's'} need review'
            : 'No abnormal consumption flags',
        icon: Icons.warning_amber_rounded,
        accent: AppTheme.colorFFF59E0B,
      ),
      _HeroStat(
        label: 'Charging Sessions',
        value: '$chargingSessions',
        caption: energyUsedKwh > 0
            ? '${energyUsedKwh.toStringAsFixed(1)} kWh synced from EV assets'
            : 'Ready for EV and hybrid fleets when charge data is available',
        icon: Icons.ev_station_rounded,
        accent: AppTheme.colorFF8B5CF6,
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: Theme.of(context).brightness == Brightness.dark
              ? const [
                  AppTheme.colorFF101827,
                  AppTheme.colorFF18263D,
                  AppTheme.colorFF111A28,
                ]
              : const [
                  AppTheme.colorFFFFFFFF,
                  AppTheme.colorFFF4F8FF,
                  AppTheme.colorFFEAF2FF,
                ],
        ),
        border: Border.all(color: AppTheme.getBorderColor(context)),
        boxShadow: AppTheme.getElevatedShadow(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppTheme.goldAccent, AppTheme.primaryBlue],
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.speed_rounded,
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
                      'Fuel and energy command center',
                      style: AppTheme.getHeadingStyle(context, fontSize: 28),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Live Geotab fuel usage, charge sessions, idling burn, and finance-ready refuel visibility.',
                      style: AppTheme.getSubtitleStyle(context),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.space16),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 980;
              if (compact) {
                return Column(
                  children: cards
                      .map(
                        (card) => Padding(
                          padding: const EdgeInsets.only(
                            bottom: AppTheme.space16,
                          ),
                          child: _buildHeroCard(context, card),
                        ),
                      )
                      .toList(),
                );
              }

              return Row(
                children: cards
                    .map(
                      (card) => Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: card == cards.last ? 0 : AppTheme.space16,
                          ),
                          child: _buildHeroCard(context, card),
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildHeroCard(BuildContext context, _HeroStat stat) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Theme.of(context).brightness == Brightness.dark
            ? AppTheme.white.withValues(alpha: 0.03)
            : AppTheme.white.withValues(alpha: 0.92),
        border: Border.all(color: stat.accent.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: stat.accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(stat.icon, color: stat.accent, size: 18),
              ),
              const Spacer(),
              Text(
                stat.label.toUpperCase(),
                style: AppTheme.getCaptionStyle(
                  context,
                ).copyWith(letterSpacing: 0.8),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            stat.value,
            style: AppTheme.getHeadingStyle(
              context,
              fontSize: 26,
            ).copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(stat.caption, style: AppTheme.getSubtitleStyle(context)),
        ],
      ),
    );
  }

  Widget _buildUsagePanel(
    BuildContext context,
    List<Map<String, dynamic>> usageByVehicle,
    {
    bool isSample = false,
  }
  ) {
    if (usageByVehicle.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppTheme.space8),
        child: Row(
          children: [
            const Icon(
              Icons.bar_chart_rounded,
              color: AppTheme.primaryBlue,
              size: 20,
            ),
            const SizedBox(width: AppTheme.space8),
            Text(
              'No consumption data recorded yet.',
              style: AppTheme.getSubtitleStyle(context).copyWith(fontSize: 13),
            ),
          ],
        ),
      );
    }

    final visibleRows = usageByVehicle.take(10).toList();
    final maximumLiters = visibleRows.fold<double>(0, (current, row) {
      final liters = _toDouble(row['fuelUsedLiters']);
      return liters > current ? liters : current;
    });
    final chartCeiling = maximumLiters < 100 ? 100.0 : maximumLiters * 1.15;

    return _ExecutivePanel(
      title: 'Consumption by vehicle',
      subtitle: 'Fuel volume reported by asset for the current period',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isSample) ...[
            const _SampleChip(),
            const SizedBox(height: AppTheme.space12),
          ],
          ...visibleRows.map((item) {
          final vehicle = formatValue(item['vehicle']) == 'N/A'
              ? 'Unassigned vehicle'
              : formatValue(item['vehicle']);
          final liters = _toDouble(item['fuelUsedLiters']);
          final ratio = chartCeiling == 0 ? 0.0 : liters / chartCeiling;
          return Padding(
            padding: const EdgeInsets.only(bottom: AppTheme.space12),
            child: Row(
              children: [
                SizedBox(
                  width: 126,
                  child: Text(
                    vehicle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.getSubtitleStyle(
                      context,
                    ).copyWith(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: AppTheme.space12),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final width = (constraints.maxWidth * ratio).clamp(
                        AppTheme.space12,
                        constraints.maxWidth,
                      );
                      return Stack(
                        children: [
                          Container(
                            height: 18,
                            decoration: BoxDecoration(
                              color: AppTheme.getSecondaryBg(context),
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                          Container(
                            width: width.toDouble(),
                            height: 18,
                            decoration: BoxDecoration(
                              color: AppTheme.primaryBlue,
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(width: AppTheme.space12),
                SizedBox(
                  width: 78,
                  child: Text(
                    '${liters.toStringAsFixed(1)} L',
                    textAlign: TextAlign.right,
                    style: AppTheme.getSubtitleStyle(context).copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.primaryBlue,
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
        ],
      ),
    );
  }

  Widget _buildNoFuelRecordsPrompt(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            'No recent fuel records recorded yet.',
            style: AppTheme.getSubtitleStyle(context).copyWith(fontSize: 13),
          ),
        ),
        OutlinedButton.icon(
          onPressed: _addFuelRecord,
          icon: const Icon(Icons.add_rounded),
          label: const Text('Add record'),
        ),
      ],
    );
  }

  Widget _buildRefuelReviewPanel(
    BuildContext context,
    List<Map<String, dynamic>> events,
  ) {
    return _ExecutivePanel(
      title: 'Refuel review',
      subtitle:
          'Station-stop or manual fuel records that need confirmation before finance uses them.',
      child: Column(
        children: events.take(5).map((record) {
          final vehicle =
              formatValue(record['vehicle'] ?? record['vehiclePlate']);
          final station =
              formatValue(record['stationName'] ?? record['station']);
          final liters = _toDouble(record['liters'] ?? record['volumeLiters']);
          final confidence =
              formatValue(record['confidenceLabel'] ?? record['confidence']);
          final sourceType = record['sourceType']?.toString() ?? '';
          final canReview =
              record['id'] != null && !sourceType.startsWith('geotab');
          return Container(
            margin: const EdgeInsets.only(bottom: AppTheme.space10),
            padding: const EdgeInsets.all(AppTheme.space12),
            decoration: BoxDecoration(
              color: AppTheme.getSecondaryBg(context),
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              border: Border.all(color: AppTheme.getBorderColor(context)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.local_gas_station_rounded,
                  color: AppTheme.colorFFF39C12,
                ),
                const SizedBox(width: AppTheme.space12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$vehicle at $station',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.getHeadingStyle(context, fontSize: 14),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${liters.toStringAsFixed(1)} L | $confidence | ${formatValue(record['sourceLabel'])}',
                        style: AppTheme.getCaptionStyle(context),
                      ),
                    ],
                  ),
                ),
                if (canReview) ...[
                  TextButton(
                    onPressed: () => _rejectFuelEvent(record),
                    child: const Text('Reject'),
                  ),
                  const SizedBox(width: AppTheme.space8),
                  FilledButton(
                    onPressed: () => _confirmFuelEvent(record),
                    child: const Text('Confirm'),
                  ),
                ] else
                  Text(
                    'Read-only',
                    style: AppTheme.getCaptionStyle(context),
                  ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildRecentEventsPanel(
    BuildContext context,
    List<Map<String, dynamic>> events,
    Map<String, dynamic> priceSettings,
  ) {
    final priceBasis = formatValue(priceSettings['priceSourceLabel']);
    final priceConfigured = priceSettings['configured'] == true;

    return _ExecutivePanel(
      title: 'Recent fuel records',
      subtitle: priceConfigured
          ? 'Estimated costs based on: $priceBasis'
          : 'Configure fuel price in Settings to show estimates',
      action: FilledButton.icon(
        onPressed: _addFuelRecord,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add record'),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tableWidth = constraints.maxWidth < 940
              ? 940.0
              : constraints.maxWidth;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: tableWidth,
              child: Column(
                children: [
                  _buildFuelRecordHeader(context),
                  ...events
                      .take(12)
                      .map((record) => _buildFuelRecordRow(context, record)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildFuelRecordHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space16,
        vertical: AppTheme.space12,
      ),
      decoration: BoxDecoration(
        color: AppTheme.primaryBlue,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        children: [
          _FuelTableHeading(label: 'DATE', flex: 14),
          _FuelTableHeading(label: 'VEHICLE', flex: 14),
          _FuelTableHeading(label: 'STATION', flex: 22),
          _FuelTableHeading(label: 'VOLUME', flex: 12, numeric: true),
          _FuelTableHeading(label: 'PRICE / L', flex: 14, numeric: true),
          _FuelTableHeading(label: 'ESTIMATED COST', flex: 16, numeric: true),
          _FuelTableHeading(label: 'SOURCE', flex: 12),
        ],
      ),
    );
  }

  Widget _buildFuelRecordRow(
    BuildContext context,
    Map<String, dynamic> record,
  ) {
    final vehicle = formatValue(record['vehicle']) == 'N/A'
        ? 'Unassigned'
        : formatValue(record['vehicle']);
    final station = formatValue(record['station'] ?? record['siteName']);
    final date = formatValue(record['date'] ?? record['displayDate']);
    final liters = _toDouble(record['liters'] ?? record['volumeLiters']);
    final price = _toDouble(
      record['pricePerLiter'] ?? record['fuelPricePerLiter'],
    );
    final recordedCost = _toDouble(record['totalCost'] ?? record['cost']);
    final estimatedLabel = formatValue(record['estimatedCostLabel']);
    final estimatedCost = recordedCost > 0
        ? _money(recordedCost)
        : (estimatedLabel == 'N/A' ? '-' : estimatedLabel);
    final source = formatValue(record['sourceLabel'] ?? record['source']);
    final sourceType = record['sourceType']?.toString() ?? '';
    final confidence = formatValue(
      record['confidenceLabel'] ?? record['confidence'],
    );
    final reviewStatus = formatValue(
      record['reviewStatusLabel'] ?? record['reviewStatus'],
    );
    final sourceNote = [
      if (confidence != 'N/A') confidence,
      if (reviewStatus != 'N/A') reviewStatus,
    ].join(' | ');

    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space16,
        vertical: AppTheme.space12,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppTheme.getBorderColor(context)),
        ),
      ),
      child: Row(
        children: [
          _FuelTableCell(value: date, flex: 14),
          _FuelTableCell(value: vehicle, flex: 14, emphasized: true),
          _FuelTableCell(
            value: station == 'N/A' ? 'Not recorded' : station,
            flex: 22,
            note: (sourceType.startsWith('geotab') && station == 'N/A')
                ? 'Not reported by GeoTab'
                : null,
          ),
          _FuelTableCell(
            value: '${liters.toStringAsFixed(1)} L',
            flex: 12,
            numeric: true,
          ),
          _FuelTableCell(
            value: 'PHP ${price.toStringAsFixed(2)}',
            flex: 14,
            numeric: true,
          ),
          _FuelTableCell(
            value: estimatedCost,
            flex: 16,
            numeric: true,
            emphasized: true,
          ),
          _FuelTableCell(
            value: source,
            flex: 12,
            note: sourceNote.isEmpty ? null : sourceNote,
          ),
        ],
      ),
    );
  }

  Widget _buildEnergyPanel(
    BuildContext context,
    List<Map<String, dynamic>> chargeEvents, {
    required double energyUsedKwh,
    required int chargingSessions,
  }) {
    return _ExecutivePanel(
      title: 'Energy and charging',
      subtitle: 'Charge sessions for electric and hybrid assets',
      child: chargeEvents.isEmpty
          ? Wrap(
              spacing: AppTheme.space12,
              runSpacing: AppTheme.space12,
              children: [
                _MetricPill(label: 'Sessions', value: '$chargingSessions'),
                _MetricPill(
                  label: 'Energy used',
                  value: '${energyUsedKwh.toStringAsFixed(1)} kWh',
                ),
                const _MetricPill(
                  label: 'Session detail',
                  value: 'Awaiting detail rows',
                ),
              ],
            )
          : Column(
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _MetricPill(label: 'Sessions', value: '$chargingSessions'),
                    _MetricPill(
                      label: 'Energy used',
                      value: '${energyUsedKwh.toStringAsFixed(1)} kWh',
                    ),
                    _MetricPill(
                      label: 'Peak session',
                      value:
                          '${chargeEvents.fold<double>(0, (peak, item) => _toDouble(item['energyConsumedKwh']) > peak ? _toDouble(item['energyConsumedKwh']) : peak).toStringAsFixed(1)} kWh',
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ...chargeEvents
                    .take(6)
                    .map(
                      (event) => Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: AppTheme.getSecondaryBg(context),
                          border: Border.all(
                            color: AppTheme.getBorderColor(context),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    event['vehicle']?.toString() ??
                                        'Unknown asset',
                                    style: AppTheme.getHeadingStyle(
                                      context,
                                      fontSize: 18,
                                    ),
                                  ),
                                ),
                                Text(
                                  '${_toDouble(event['energyConsumedKwh']).toStringAsFixed(1)} kWh',
                                  style: AppTheme.getHeadingStyle(
                                    context,
                                    fontSize: 16,
                                  ).copyWith(color: AppTheme.colorFF8B5CF6),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              [
                                    event['displayDate'],
                                    event['chargeType'],
                                    event['duration'],
                                  ]
                                  .where(
                                    (value) => (value?.toString().trim() ?? '')
                                        .isNotEmpty,
                                  )
                                  .join(' | '),
                              style: AppTheme.getSubtitleStyle(context),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                _MetricPill(
                                  label: 'Peak power',
                                  value:
                                      '${_toDouble(event['peakPowerKw']).toStringAsFixed(1)} kW',
                                ),
                                _MetricPill(
                                  label: 'SOC',
                                  value:
                                      '${_toDouble(event['startStateOfCharge']).toStringAsFixed(0)}% -> ${_toDouble(event['endStateOfCharge']).toStringAsFixed(0)}%',
                                ),
                                _MetricPill(
                                  label: 'Odometer',
                                  value:
                                      '${_toDouble(event['chargingStartedOdometerKm']).toStringAsFixed(0)} km',
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
    );
  }
}

class _FuelPageScaffold extends StatelessWidget {
  final Widget child;

  const _FuelPageScaffold({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: Theme.of(context).brightness == Brightness.dark
              ? const [
                  AppTheme.colorFF08101D,
                  AppTheme.colorFF0B1220,
                  AppTheme.colorFF0A0E1A,
                ]
              : const [
                  AppTheme.colorFFF5F9FF,
                  AppTheme.colorFFF7F8FB,
                  AppTheme.colorFFEFF4FB,
                ],
        ),
      ),
      child: child,
    );
  }
}

class _ExecutivePanel extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;
  final Widget? action;

  const _ExecutivePanel({
    required this.title,
    required this.subtitle,
    required this.child,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.getCardBg(context),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppTheme.getBorderColor(context)),
        boxShadow: AppTheme.getCardShadow(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppTheme.getHeadingStyle(context, fontSize: 22),
                    ),
                    const SizedBox(height: 6),
                    Text(subtitle, style: AppTheme.getSubtitleStyle(context)),
                  ],
                ),
              ),
              if (action != null) action!,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _FuelTableHeading extends StatelessWidget {
  final String label;
  final int flex;
  final bool numeric;

  const _FuelTableHeading({
    required this.label,
    required this.flex,
    this.numeric = false,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Text(
        label,
        textAlign: numeric ? TextAlign.right : TextAlign.left,
        style: AppTheme.getCaptionStyle(context).copyWith(
          color: AppTheme.white,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _FuelTableCell extends StatelessWidget {
  final String value;
  final int flex;
  final bool numeric;
  final bool emphasized;
  final String? note;

  const _FuelTableCell({
    required this.value,
    required this.flex,
    this.numeric = false,
    this.emphasized = false,
    this.note,
  });

  @override
  Widget build(BuildContext context) {
    if (value == 'Sample') {
      return Expanded(
        flex: flex,
        child: Align(
          alignment: numeric ? Alignment.centerRight : Alignment.centerLeft,
          child: const _SampleChip(),
        ),
      );
    }

    return Expanded(
      flex: flex,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: numeric ? TextAlign.right : TextAlign.left,
            style: AppTheme.getSubtitleStyle(context).copyWith(
              fontSize: 13,
              fontWeight: emphasized ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
          if (note != null) ...[
            const SizedBox(height: 4),
            Text(
              note!,
              style: AppTheme.getSubtitleStyle(context).copyWith(
                fontSize: 11,
                fontStyle: FontStyle.italic,
                color: AppTheme.gray500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FuelEmptyState extends StatelessWidget {
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onTap;

  const _FuelEmptyState({
    required this.title,
    required this.message,
    this.actionLabel,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.getSecondaryBg(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.getBorderColor(context)),
      ),
      child: Column(
        children: [
          const Icon(Icons.local_gas_station_rounded, size: 40),
          const SizedBox(height: 12),
          Text(
            title,
            style: AppTheme.getHeadingStyle(context, fontSize: 20),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: AppTheme.getSubtitleStyle(context),
            textAlign: TextAlign.center,
          ),
          if (actionLabel != null && onTap != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onTap, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}

class _SampleChip extends StatelessWidget {
  const _SampleChip({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.colorFFF39C12.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: AppTheme.colorFFF39C12.withValues(alpha: 0.42),
        ),
      ),
      child: Text(
        'Sample',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AppTheme.colorFFF39C12,
        ),
      ),
    );
  }
}

class _MetricPill extends StatelessWidget {
  final String label;
  final String value;

  const _MetricPill({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.getCardBg(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.getBorderColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: AppTheme.getCaptionStyle(context)),
          const SizedBox(height: 4),
          Text(
            value,
            style: AppTheme.getHeadingStyle(
              context,
              fontSize: 14,
            ).copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _AddFuelRecordSheet extends StatefulWidget {
  const _AddFuelRecordSheet();

  @override
  State<_AddFuelRecordSheet> createState() => _AddFuelRecordSheetState();
}

class _AddFuelRecordSheetState extends State<_AddFuelRecordSheet> {
  final _formKey = GlobalKey<FormState>();
  final _stationController = TextEditingController();
  final _litersController = TextEditingController();
  final _priceController = TextEditingController();
  String? _selectedVehiclePlate;

  @override
  void dispose() {
    _stationController.dispose();
    _litersController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;
    final vehicles = vehiclesNotifier.value;
    final selectedVehicle = vehicles.cast<Map<String, dynamic>?>().firstWhere(
      (vehicle) => vehicle?['plate'] == _selectedVehiclePlate,
      orElse: () => null,
    );
    final maxLiters = _toDouble(selectedVehicle?['fuelCapacity']);

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.getCardBg(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Add refuel record',
                  style: AppTheme.getHeadingStyle(context, fontSize: 22),
                ),
                const SizedBox(height: 8),
                Text(
                  'This dispatch-side entry is capacity-aware and keeps the dashboard usable even before a live fill-up sync arrives.',
                  style: AppTheme.getSubtitleStyle(context),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _selectedVehiclePlate,
                  decoration: const InputDecoration(labelText: 'Vehicle'),
                  items: vehicles
                      .map(
                        (vehicle) => DropdownMenuItem<String>(
                          value: vehicle['plate']?.toString(),
                          child: Text(
                            vehicle['plate']?.toString() ?? 'Unknown',
                          ),
                        ),
                      )
                      .toList(),
                  hint: const Text('Select...'),
                  validator: (value) =>
                      FormValidation.requiredSelection('vehicle', value),
                  onChanged: (value) {
                    setState(() {
                      _selectedVehiclePlate = value;
                    });
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _stationController,
                  decoration: const InputDecoration(labelText: 'Station'),
                  validator: (value) =>
                      FormValidation.requiredField('Station', value),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _litersController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: maxLiters > 0
                        ? 'Liters (max ${maxLiters.toStringAsFixed(0)}L)'
                        : 'Liters',
                  ),
                  validator: (value) {
                    final liters = _toDouble(value);
                    final numberError = FormValidation.positiveNumber(
                      'Liters',
                      value,
                    );
                    if (numberError != null) return numberError;
                    if (maxLiters > 0 && liters > maxLiters) {
                      return 'Cannot exceed ${maxLiters.toStringAsFixed(0)}L';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _priceController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Price per liter',
                  ),
                  validator: (value) =>
                      FormValidation.positiveNumber('Price per liter', value),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      if (!_formKey.currentState!.validate()) {
                        return;
                      }

                      final liters = _toDouble(_litersController.text);
                      final price = _toDouble(_priceController.text);
                      final total = liters * price;

                      Navigator.pop(context, {
                        'vehiclePlate': _selectedVehiclePlate ?? 'Unknown',
                        'vehicleGeotabId':
                            selectedVehicle?['geotabId']?.toString() ?? '',
                        'driverName':
                            selectedVehicle?['driver']?.toString() ??
                            'Unassigned',
                        'stationName': _stationController.text.trim(),
                        'station': _stationController.text.trim(),
                        'date': _displayDate(DateTime.now()),
                        'eventAt': DateTime.now().toIso8601String(),
                        'liters': liters,
                        'volumeLiters': liters,
                        'pricePerLiter': price,
                        'fuelType':
                            selectedVehicle?['fuelType']?.toString() ??
                            'diesel',
                        'cost': total,
                        'totalCost': total,
                        'source': 'Manual',
                      });
                    },
                    child: const Text('Save record'),
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

class _HeroStat {
  final String label;
  final String value;
  final String caption;
  final IconData icon;
  final Color accent;

  const _HeroStat({
    required this.label,
    required this.value,
    required this.caption,
    required this.icon,
    required this.accent,
  });
}

List<Map<String, dynamic>> _sampleFuelUsageByVehicle() {
  return [
    {'vehicle': 'TRK-001', 'fuelUsedLiters': 120.4, 'abnormalConsumption': false},
    {'vehicle': 'TRK-002', 'fuelUsedLiters': 95.2, 'abnormalConsumption': false},
    {'vehicle': 'TRK-003', 'fuelUsedLiters': 45.8, 'abnormalConsumption': true},
    {'vehicle': 'TRK-004', 'fuelUsedLiters': 12.6, 'abnormalConsumption': false},
    {'vehicle': 'TRK-005', 'fuelUsedLiters': 78.0, 'abnormalConsumption': false},
  ];
}

List<Map<String, dynamic>> _sampleFuelRecords() {
  final now = DateTime.now();
  return [
    {
      'vehicle': 'TRK-001',
      'station': 'Shell Airport',
      'date': _displayDate(now.subtract(const Duration(days: 1))),
      'displayDate': _displayDate(now.subtract(const Duration(days: 1))),
      'liters': 50.0,
      'volumeLiters': 50.0,
      'pricePerLiter': 78.50,
      'fuelPricePerLiter': 78.50,
      'totalCost': 3925.0,
      'cost': 3925.0,
      'estimatedCostLabel': 'N/A',
      'source': 'sample',
    },
    {
      'vehicle': 'TRK-002',
      'station': 'Petron Main',
      'date': _displayDate(now.subtract(const Duration(days: 2))),
      'displayDate': _displayDate(now.subtract(const Duration(days: 2))),
      'liters': 30.5,
      'volumeLiters': 30.5,
      'pricePerLiter': 79.00,
      'fuelPricePerLiter': 79.00,
      'totalCost': 2400.0,
      'cost': 2400.0,
      'estimatedCostLabel': 'N/A',
      'source': 'sample',
    },
    {
      'vehicle': 'TRK-003',
      'station': null,
      'date': _displayDate(now.subtract(const Duration(days: 3))),
      'displayDate': _displayDate(now.subtract(const Duration(days: 3))),
      'liters': 15.8,
      'volumeLiters': 15.8,
      'pricePerLiter': 80.25,
      'fuelPricePerLiter': 80.25,
      'totalCost': 1268.0,
      'cost': 1268.0,
      'estimatedCostLabel': 'N/A',
      'source': 'sample',
    },
  ];
}

Map<String, dynamic> _mapOf(dynamic raw) {
  if (raw is Map) {
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }
  return {};
}

List<Map<String, dynamic>> _listOfMaps(dynamic raw) {
  if (raw is! List) {
    return [];
  }

  return raw
      .whereType<Map>()
      .map((item) => item.map((key, value) => MapEntry(key.toString(), value)))
      .cast<Map<String, dynamic>>()
      .toList();
}

double _toDouble(dynamic value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0.0;
}

int _toInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _sumField(List<Map<String, dynamic>> rows, String field) {
  return rows.fold(0.0, (sum, row) => sum + _toDouble(row[field]));
}

String _money(double value) => 'PHP ${value.toStringAsFixed(2)}';

String _displayDate(DateTime value) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final hour = value.hour > 12
      ? value.hour - 12
      : (value.hour == 0 ? 12 : value.hour);
  final minute = value.minute.toString().padLeft(2, '0');
  final period = value.hour >= 12 ? 'PM' : 'AM';
  return '${months[value.month - 1]} ${value.day}, $hour:$minute $period';
}
