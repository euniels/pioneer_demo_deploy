import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../config/pioneer_runtime_config.dart';
import '../services/backend_api.dart';
import '../services/demo_telemetry_fixtures.dart';
import '../services/fleet_sync_service.dart';
import '../services/page_cache_service.dart';
import '../services/vehicles_store.dart';
import '../theme/app_theme.dart';
import '../utils/display_format.dart';
import '../utils/form_validation.dart';
import '../widgets/dashboard_layout.dart';
import '../widgets/page_skeletons.dart';
import '../widgets/telemetry_widgets.dart';

class FuelExpensesPage extends StatefulWidget {
  const FuelExpensesPage({super.key});

  @override
  State<FuelExpensesPage> createState() => _FuelExpensesPageState();
}

class _FuelExpensesPageState extends State<FuelExpensesPage> {
  static const String _cacheKey = 'fuel_expenses_page';

  late Future<Map<String, dynamic>> _fuelFuture;
  final List<Map<String, dynamic>> _localEntries = [];
  String _fuelSearch = '';
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
          final chargeEvents = _listOfMaps(data['chargeEvents']);
          final realUsageByVehicle = _listOfMaps(
            data['usageByVehicle'],
          ).where((item) => _toDouble(item['fuelUsedLiters']) > 0).toList();
          final priceSettings = _mapOf(data['priceSettings']);
          final preferredFuelRecords = fuelTransactions.isNotEmpty
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
          final filteredMergedEvents = _searchFuelRows(mergedEvents);

          return _FuelPageScaffold(
            child: Column(
              children: [
                _buildFuelToolbar(context),
                _buildFuelFilterBar(context, _vehicleFilterOptions(data)),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () async => _reload(),
                    child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(24),
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
                  _buildFuelSummaryCards(
                    context,
                    totalSpend: totalSpend,
                    totalLiters: totalLiters,
                    avgPrice: avgPrice,
                    idleFuel: idleFuel,
                    abnormalCount: abnormal,
                    chargingSessions: chargingSessions,
                        ).animate().fadeIn(duration: 300.ms),
                        const SizedBox(height: AppTheme.space16),
                        _buildFuelTelemetryReadiness(
                          context,
                          usageByVehicle,
                        ).animate().fadeIn(duration: 350.ms),
                        const SizedBox(height: AppTheme.space16),
                        _buildUsagePanel(
                    context,
                    usageByVehicle,
                    isSample: usingSampleFuel,
                  ).animate().fadeIn(duration: 450.ms),
                  const SizedBox(height: AppTheme.space16),
                  if (filteredMergedEvents.isEmpty)
                    _buildNoFuelRecordsPrompt(context)
                  else
                    _buildRecentEventsPanel(
                      context,
                      filteredMergedEvents,
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
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Map<String, dynamic>> _searchFuelRows(List<Map<String, dynamic>> rows) {
    final query = _fuelSearch.trim().toLowerCase();
    if (query.isEmpty) return rows;

    return rows.where((row) {
      final haystack = [
        row['vehicle'],
        row['plate'],
        row['driver'],
        row['station'],
        row['siteName'],
        row['source'],
        row['displayDate'],
        row['date'],
      ].map((value) => value?.toString().toLowerCase() ?? '').join(' ');
      return haystack.contains(query);
    }).toList();
  }

  Widget _buildFuelToolbar(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMobile = MediaQuery.sizeOf(context).width < 850;
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
          final search = _FuelSearchField(
            hint: 'Search fuel records by vehicle, station, or driver...',
            onChanged: (value) => setState(() => _fuelSearch = value),
          );
          final addButton = SizedBox(
            height: 50,
            width: compact ? double.infinity : 180,
            child: FilledButton.icon(
              onPressed: _addFuelRecord,
              icon: const Icon(Icons.add_rounded),
              label: Text(compact ? 'Add Record' : 'New Fuel Record'),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.colorFF10B981,
                foregroundColor: AppTheme.white,
                textStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [search, const SizedBox(height: 12), addButton],
            );
          }

          return Row(
            children: [
              Expanded(child: search),
              const SizedBox(width: 14),
              addButton,
            ],
          );
        },
      ),
    );
  }

  Widget _buildFuelFilterBar(BuildContext context, List<String> vehicles) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMobile = MediaQuery.sizeOf(context).width < 850;
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
            const _FuelResultChip(label: 'Fuel records'),
            const SizedBox(width: 10),
            PopupMenuButton<String>(
              tooltip: 'Filter vehicle',
              onSelected: (value) {
                setState(() {
                  _selectedVehicle = value == 'All vehicles' ? '' : value;
                  _fuelFuture = _loadFuel(forceRefresh: true);
                });
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'All vehicles',
                  child: Text('All vehicles'),
                ),
                ...vehicles.map(
                  (vehicle) => PopupMenuItem(
                    value: vehicle,
                    child: Text(vehicle),
                  ),
                ),
              ],
              child: _FuelFilterChip(
                label:
                    _selectedVehicle.isEmpty ? 'All vehicles' : _selectedVehicle,
                icon: Icons.local_shipping_rounded,
              ),
            ),
            if (_selectedVehicle.isNotEmpty || _fuelSearch.isNotEmpty) ...[
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: () {
                  setState(() {
                    _fuelSearch = '';
                    _selectedVehicle = '';
                    _fuelFuture = _loadFuel(forceRefresh: true);
                  });
                },
                icon: const Icon(Icons.filter_alt_off_rounded, size: 18),
                label: const Text('Clear'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFuelSummaryCards(
    BuildContext context, {
    required double totalSpend,
    required double totalLiters,
    required double avgPrice,
    required double idleFuel,
    required int abnormalCount,
    required int chargingSessions,
  }) {
    final cards = [
      _FuelSummaryCard(
        label: 'Total spend',
        value: _money(totalSpend),
        caption: 'Refuel cost',
        icon: Icons.account_balance_wallet_rounded,
        accent: AppTheme.colorFFD9B56D,
      ),
      _FuelSummaryCard(
        label: 'Total liters',
        value: '${totalLiters.toStringAsFixed(totalLiters >= 100 ? 0 : 1)} L',
        caption: 'Fill-up volume',
        icon: Icons.local_gas_station_rounded,
        accent: AppTheme.colorFF00D4FF,
      ),
      _FuelSummaryCard(
        label: 'Average price',
        value: '₱${avgPrice.toStringAsFixed(2)}',
        caption: 'Per liter',
        icon: Icons.trending_up_rounded,
        accent: AppTheme.colorFF10B981,
      ),
      _FuelSummaryCard(
        label: 'Review flags',
        value: '$abnormalCount',
        caption: chargingSessions > 0
            ? '$chargingSessions charge sessions'
            : '${idleFuel.toStringAsFixed(idleFuel >= 100 ? 0 : 1)} L idle fuel',
        icon: Icons.warning_amber_rounded,
        accent: AppTheme.colorFFF59E0B,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = MediaQuery.sizeOf(context).width < 850 ? 12.0 : 16.0;
        final width = constraints.maxWidth;
        final columns = width >= 1000
            ? 4
            : width >= 620
            ? 2
            : 1;
        final cardWidth = (width - (gap * (columns - 1))) / columns;

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final card in cards) SizedBox(width: cardWidth, child: card),
          ],
        );
      },
    );
  }

  Widget _buildFuelTelemetryReadiness(
    BuildContext context,
    List<Map<String, dynamic>> usageByVehicle,
  ) {
    final rows = usageByVehicle.take(4).map((row) {
      final vehicle = <String, dynamic>{
        ...row,
        'plate': row['plate'] ?? row['vehicle'],
      };
      final fuel = DemoTelemetryFixtures.readingsForVehicle(vehicle)
          .firstWhere((reading) => reading.key == 'fuel');
      return (vehicle: vehicle, fuel: fuel);
    }).toList();

    return _ExecutivePanel(
      title: 'Current fuel readiness',
      subtitle:
          'Latest tank levels are separate from transaction and cost history.',
      child: rows.isEmpty
          ? const _FuelEmptyState(
              title: 'No current fuel readings',
              message:
                  'Fuel levels will appear when supported vehicle diagnostics report them.',
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 900 ? 4 : 2;
                const gap = 12.0;
                final width =
                    (constraints.maxWidth - gap * (columns - 1)) / columns;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: rows
                      .map(
                        (row) => SizedBox(
                          width: width,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                formatValue(row.vehicle['vehicle']),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTheme.getBodyStyle(context).copyWith(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 7),
                              TelemetryReadingTile(
                                reading: row.fuel,
                                icon: Icons.local_gas_station_rounded,
                                compact: true,
                                showHistory: false,
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
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

    setState(() {
      _localEntries.insert(0, record);
    });
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
    final _rawSource = (record['source']?.toString().toLowerCase() ?? '');
    final source = _rawSource.contains('manual')
      ? 'Manual'
      : (_rawSource.contains('sample') ? 'Sample' : 'GeoTab');

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
            note: (source == 'GeoTab' && station == 'N/A') ? 'Not reported by GeoTab' : null,
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
          _FuelTableCell(value: source, flex: 12),
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

class _FuelSearchField extends StatelessWidget {
  final String hint;
  final ValueChanged<String> onChanged;

  const _FuelSearchField({required this.hint, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      height: 50,
      child: TextField(
        onChanged: onChanged,
        style: AppTheme.getBodyStyle(context).copyWith(fontSize: 14),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: AppTheme.getSubtitleStyle(context).copyWith(fontSize: 14),
          prefixIcon: Icon(
            Icons.search_rounded,
            color: isDark ? AppTheme.gray400 : AppTheme.gray600,
          ),
          filled: true,
          fillColor: isDark ? AppTheme.colorFF1A1D23 : AppTheme.colorFFF5F6F8,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(
              color: isDark
                  ? AppTheme.white.withAlpha(20)
                  : AppTheme.black.withAlpha(18),
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(
              color: isDark
                  ? AppTheme.white.withAlpha(20)
                  : AppTheme.black.withAlpha(18),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppTheme.primaryBlue),
          ),
        ),
      ),
    );
  }
}

class _FuelResultChip extends StatelessWidget {
  final String label;

  const _FuelResultChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppTheme.colorFF00D4FF.withAlpha(18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.colorFF00D4FF.withAlpha(70)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppTheme.colorFF00D4FF,
          fontSize: 13,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _FuelFilterChip extends StatelessWidget {
  final String label;
  final IconData icon;

  const _FuelFilterChip({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.colorFFF5F6F8,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withAlpha(20)
              : AppTheme.black.withAlpha(18),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: AppTheme.gray400),
          const SizedBox(width: 8),
          Text(
            label,
            style: AppTheme.getBodyStyle(
              context,
            ).copyWith(fontSize: 13, fontWeight: FontWeight.w800),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
        ],
      ),
    );
  }
}

class _FuelSummaryCard extends StatelessWidget {
  final String label;
  final String value;
  final String caption;
  final IconData icon;
  final Color accent;

  const _FuelSummaryCard({
    required this.label,
    required this.value,
    required this.caption,
    required this.icon,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(minHeight: 112),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.getCardBg(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withAlpha(isDark ? 92 : 115)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: accent.withAlpha(isDark ? 34 : 28),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: accent, size: 22),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.getCaptionStyle(context).copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.getHeadingStyle(
                    context,
                    fontSize: 24,
                  ).copyWith(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 4),
                Text(
                  caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.getSubtitleStyle(
                    context,
                  ).copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
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
        crossAxisAlignment: numeric
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
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
                        'vehicle': _selectedVehiclePlate ?? 'Unknown',
                        'driver': selectedVehicle?['driver'] ?? 'Unassigned',
                        'station': _stationController.text.trim(),
                        'date': _displayDate(DateTime.now()),
                        'liters': liters,
                        'volumeLiters': liters,
                        'pricePerLiter': price,
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

List<Map<String, dynamic>> _sampleFuelUsageByVehicle() {
  return [
    {'vehicle': 'TRK-001', 'fuelUsedLiters': 120.4, 'fuelLevelRatio': 0.68, 'abnormalConsumption': false},
    {'vehicle': 'TRK-002', 'fuelUsedLiters': 95.2, 'fuelLevelRatio': 0.31, 'abnormalConsumption': false},
    {'vehicle': 'TRK-003', 'fuelUsedLiters': 45.8, 'fuelLevelRatio': 0.18, 'abnormalConsumption': true},
    {'vehicle': 'TRK-004', 'fuelUsedLiters': 12.6, 'fuelLevelRatio': 0.82, 'abnormalConsumption': false},
    {'vehicle': 'TRK-005', 'fuelUsedLiters': 78.0, 'fuelLevelRatio': 0.54, 'abnormalConsumption': false},
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
