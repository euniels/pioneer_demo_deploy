import 'package:flutter/material.dart';

import '../services/backend_api.dart';
import '../services/fleet_sync_service.dart';
import '../services/soa_exporter.dart';
import '../utils/workflow_status_helper.dart';
import '../widgets/dashboard_layout.dart';
import '../widgets/page_skeletons.dart';
import '../theme/app_theme.dart';

class StatementOfAccountsPage extends StatefulWidget {
  const StatementOfAccountsPage({super.key});

  @override
  State<StatementOfAccountsPage> createState() =>
      _StatementOfAccountsPageState();
}

class _StatementOfAccountsPageState extends State<StatementOfAccountsPage> {
  late Future<Map<String, dynamic>> _future;
  final TextEditingController _clientFilterController = TextEditingController();
  String _search = '';
  String _status = 'all';
  DateTimeRange? _dateRange;

  @override
  void initState() {
    super.initState();
    _future = _load(forceRefresh: true);
  }

  Future<Map<String, dynamic>> _load({bool forceRefresh = false}) async {
    return BackendApiService.loadWithWarmRetry<Map<String, dynamic>>(
      attempts: forceRefresh ? 2 : 4,
      request: (retryForceRefresh) async {
        final effectiveForceRefresh = forceRefresh || retryForceRefresh;
        warmOperationalCachesSilently(forceRefresh: effectiveForceRefresh);
        final results = await Future.wait<Map<String, dynamic>>([
          BackendApiService.getStatementOfAccounts(
            forceRefresh: effectiveForceRefresh,
          ),
          BackendApiService.getBillingInvoices(
            forceRefresh: effectiveForceRefresh,
          ),
        ]);

        final soa = Map<String, dynamic>.from(results[0]);
        soa['billingInvoices'] = _listOfMaps(results[1]['invoices']);
        return soa;
      },
    );
  }

  void _reload() {
    setState(() {
      _future = _load(forceRefresh: true);
    });
  }

  @override
  void dispose() {
    _clientFilterController.dispose();
    super.dispose();
  }

  InputDecoration _filterDecoration(bool isDark, Widget icon, String hint) {
    return InputDecoration(
      prefixIcon: icon,
      hintText: hint,
      filled: true,
      fillColor: isDark ? AppTheme.colorFF141924 : AppTheme.colorFFF8FAFC,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
    );
  }

  Widget _filterTextField({
    required bool isDark,
    required IconData icon,
    required String hint,
    required ValueChanged<String> onChanged,
    TextEditingController? controller,
  }) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      decoration: _filterDecoration(isDark, Icon(icon), hint),
    );
  }

  Future<void> _selectDateRange() async {
    final selected = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDateRange: _dateRange,
    );
    if (selected != null && mounted) {
      setState(() => _dateRange = selected);
    }
  }

  Future<void> _exportCurrentView(
    List<Map<String, dynamic>> clients,
    Map<String, dynamic> overview,
  ) async {
    final total = overview['grandTotalLabel'] ?? _money(overview['grandTotal']);
    final rows = clients
        .map(
          (client) =>
              '<tr><td>${_escapeHtml(client['name'])}</td><td class="num">${client['invoices'] ?? 0}</td><td class="num">${_escapeHtml(client['outstandingLabel'])}</td><td>${_escapeHtml(client['oldestUnpaid'] ?? 'N/A')}</td></tr>',
        )
        .join();
    final ok = await exportSoaHtmlAsPdf('PioneerPath Statement of Accounts', '''
        <h1>PioneerPath Statement of Accounts</h1>
        <div class="muted">Filtered export generated ${DateTime.now().toLocal()}</div>
        <table>
          <thead><tr><th>Client</th><th>Invoices</th><th>Outstanding</th><th>Oldest unpaid</th></tr></thead>
          <tbody>$rows</tbody>
        </table>
        <div class="total">Grand total: ${_escapeHtml(total)}</div>
      ''');

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Downloaded SOA export for ${clients.length} clients. Open it in the browser and save/print as PDF.'
              : 'SOA PDF export is available in the web build. Grand total: $total',
        ),
      ),
    );
  }

  Future<void> _exportCsvCurrentView(List<Map<String, dynamic>> clients) async {
    final invoices = clients
        .expand((client) => _listOfMaps(client['invoiceRows']))
        .toList();
    final csv = buildStatementCsv(clients);
    final ok = await exportSoaCsv(
      'pioneerpath-soa-${DateTime.now().millisecondsSinceEpoch}.csv',
      csv,
    );

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Downloaded CSV export for ${invoices.length} invoices.'
              : 'CSV export is available in the web build.',
        ),
      ),
    );
  }

  String _escapeHtml(Object? value) {
    return (value?.toString() ?? '')
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  List<Map<String, dynamic>> _filteredClients(List<Map<String, dynamic>> raw) {
    final query = _search.trim().toLowerCase();
    return raw
        .map((client) {
          final name = (client['name'] ?? '').toString();
          final invoices =
              _listOfMaps(client['invoiceRows']).where((invoice) {
                if (query.isNotEmpty && !name.toLowerCase().contains(query)) {
                  return false;
                }
                if (_status != 'all' &&
                    _statementStatus(invoice) != _status.toLowerCase()) {
                  return false;
                }
                final issueDate = _parseStatementDate(invoice['issueDate']);
                if (_dateRange != null &&
                    (issueDate == null ||
                        issueDate.isBefore(_dateRange!.start) ||
                        !issueDate.isBefore(
                          _dateRange!.end.add(const Duration(days: 1)),
                        ))) {
                  return false;
                }
                return true;
              }).toList()..sort(
                (left, right) =>
                    (_parseStatementDate(right['issueDate']) ??
                            DateTime.fromMillisecondsSinceEpoch(0))
                        .compareTo(
                          _parseStatementDate(left['issueDate']) ??
                              DateTime.fromMillisecondsSinceEpoch(0),
                        ),
              );
          if (invoices.isEmpty) return <String, dynamic>{};
          return _clientTotals(name, invoices);
        })
        .where((client) => client.isNotEmpty)
        .toList();
  }

  Map<String, dynamic> _clientTotals(
    String name,
    List<Map<String, dynamic>> invoices,
  ) {
    var total = 0.0;
    var paid = 0.0;
    var outstanding = 0.0;
    var overdueCount = 0;
    for (final invoice in invoices) {
      final amount = _statementTotal(invoice);
      final status = _statementStatus(invoice);
      if (status != 'voided') total += amount;
      if (status == 'paid') {
        paid += amount;
      } else if (status == 'partial') {
        final partialPaid = _numericMoney(invoice['paidAmount']);
        paid += partialPaid;
        outstanding += (amount - partialPaid).clamp(0, amount);
      } else if (status != 'voided') {
        outstanding += amount;
      }
      if (status == 'overdue') overdueCount++;
    }
    return {
      'name': name,
      'invoices': invoices.length,
      'invoiceRows': invoices,
      'totalBilled': total,
      'total': _money(total),
      'paid': paid,
      'paidLabel': _money(paid),
      'outstanding': outstanding,
      'outstandingLabel': _money(outstanding),
      'overdueCount': overdueCount,
    };
  }

  Map<String, dynamic> _filteredOverview(List<Map<String, dynamic>> clients) {
    final total = clients.fold<double>(
      0,
      (sum, row) => sum + _numericMoney(row['totalBilled']),
    );
    final paid = clients.fold<double>(
      0,
      (sum, row) => sum + _numericMoney(row['paid']),
    );
    final outstanding = clients.fold<double>(
      0,
      (sum, row) => sum + _numericMoney(row['outstanding']),
    );
    final overdue = clients.fold<double>(
      0,
      (sum, row) =>
          sum +
          _listOfMaps(row['invoiceRows'])
              .where((invoice) => _statementStatus(invoice) == 'overdue')
              .fold<double>(
                0,
                (amount, invoice) => amount + _statementTotal(invoice),
              ),
    );
    return {
      'clients': clients.length,
      'grandTotal': total,
      'grandTotalLabel': _money(total),
      'totalPaid': paid,
      'totalOutstanding': outstanding,
      'totalOverdue': overdue,
    };
  }

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      currentRoute: '/statements-of-accounts',
      title: 'Statement of Accounts',
      subtitle: 'Client balances generated from backend invoice data',
      child: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        initialData: BackendApiService.peekCachedDataMap('/billing/soa'),
        builder: (context, snapshot) {
          final isDark = Theme.of(context).brightness == Brightness.dark;

          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const PioneerRouteSkeletonBody(
              routeName: '/statements-of-accounts',
            );
          }

          if (snapshot.hasError) {
            return _SoaEmptyState(
              isDark: isDark,
              title: 'SOA data is temporarily unavailable',
              message: 'The backend did not return client balance data.',
              actionLabel: 'Retry',
              onTap: _reload,
            );
          }

          final data = snapshot.data ?? const <String, dynamic>{};
          final billingInvoices = _listOfMaps(data['billingInvoices']);
          final clients = _filteredClients(_listOfMaps(data['clients']));
          final overview = _filteredOverview(clients);

          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                _buildOverview(isDark, overview),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: 280,
                      child: _filterTextField(
                        isDark: isDark,
                        icon: Icons.search_rounded,
                        hint: 'Filter by client',
                        controller: _clientFilterController,
                        onChanged: (value) => setState(() => _search = value),
                      ),
                    ),
                    SizedBox(
                      width: 270,
                      child: OutlinedButton.icon(
                        onPressed: _selectDateRange,
                        icon: const Icon(Icons.date_range_rounded),
                        label: Text(
                          _dateRange == null
                              ? 'All invoice dates'
                              : '${_displayDate(_dateRange!.start)} - ${_displayDate(_dateRange!.end)}',
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: DropdownButtonFormField<String>(
                        key: ValueKey(_status),
                        initialValue: _status,
                        decoration: _filterDecoration(
                          isDark,
                          const Icon(Icons.payments_rounded),
                          'Payment status',
                        ),
                        items: const [
                          DropdownMenuItem(value: 'all', child: Text('All')),
                          DropdownMenuItem(value: 'paid', child: Text('Paid')),
                          DropdownMenuItem(
                            value: 'unpaid',
                            child: Text('Unpaid'),
                          ),
                          DropdownMenuItem(
                            value: 'overdue',
                            child: Text('Overdue'),
                          ),
                          DropdownMenuItem(
                            value: 'partial',
                            child: Text('Partial'),
                          ),
                          DropdownMenuItem(
                            value: 'voided',
                            child: Text('Voided'),
                          ),
                        ],
                        onChanged: (value) =>
                            setState(() => _status = value ?? 'all'),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: () async =>
                          _exportCurrentView(clients, overview),
                      icon: const Icon(Icons.picture_as_pdf_rounded),
                      label: const Text('Export PDF'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async => _exportCsvCurrentView(clients),
                      icon: const Icon(Icons.table_view_rounded),
                      label: const Text('Export CSV'),
                    ),
                    if (_dateRange != null ||
                        _search.isNotEmpty ||
                        _status != 'all')
                      TextButton.icon(
                        onPressed: () => setState(() {
                          _clientFilterController.clear();
                          _search = '';
                          _status = 'all';
                          _dateRange = null;
                        }),
                        icon: const Icon(Icons.filter_alt_off_rounded),
                        label: const Text('Clear filters'),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                if (clients.isEmpty)
                  _SoaEmptyState(
                    isDark: isDark,
                    title: 'No client balances found',
                    message: 'No SOA rows match the current search.',
                  )
                else
                  ...clients.map(
                    (client) => _ClientStatementSection(
                      client: client,
                      isDark: isDark,
                      onViewDetail: () => _showClientAccountDetail(
                        client,
                        billingInvoices,
                        isDark,
                      ),
                    ),
                  ),
                if (clients.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _GrandTotalRow(overview: overview, isDark: isDark),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _showClientAccountDetail(
    Map<String, dynamic> client,
    List<Map<String, dynamic>> billingInvoices,
    bool isDark,
  ) async {
    final clientName = (client['name'] ?? '').toString().trim();
    final invoices = billingInvoices
        .where(
          (invoice) =>
              (invoice['client'] ?? '').toString().trim().toLowerCase() ==
              clientName.toLowerCase(),
        )
        .toList();

    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: AppTheme.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.colorFF111723 : AppTheme.white,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: isDark
                    ? AppTheme.white.withValues(alpha: 0.08)
                    : AppTheme.black.withValues(alpha: 0.08),
              ),
            ),
            child: SingleChildScrollView(
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
                              clientName.isEmpty
                                  ? 'Client Account'
                                  : clientName,
                              style: TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w900,
                                color: isDark
                                    ? AppTheme.white
                                    : AppTheme.colorFF18212F,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Statement of account detail',
                              style: TextStyle(
                                fontSize: 13,
                                color: isDark
                                    ? AppTheme.white60
                                    : AppTheme.colorFF64748B,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _accountPill(
                        'Invoices',
                        '${client['invoices'] ?? 0}',
                        isDark,
                        AppTheme.colorFF4B7BE5,
                      ),
                      _accountPill(
                        'Billed',
                        (client['total'] ?? 'PHP 0.00').toString(),
                        isDark,
                        AppTheme.colorFF0EA5E9,
                      ),
                      _accountPill(
                        'Paid',
                        (client['paidLabel'] ?? 'PHP 0.00').toString(),
                        isDark,
                        AppTheme.colorFF10B981,
                      ),
                      _accountPill(
                        'Outstanding',
                        (client['outstandingLabel'] ?? 'PHP 0.00').toString(),
                        isDark,
                        AppTheme.colorFFF59E0B,
                      ),
                      _accountPill(
                        'Overdue',
                        (client['overdueLabel'] ?? 'PHP 0.00').toString(),
                        isDark,
                        AppTheme.colorFFEF4444,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _AccountSection(
                    title: 'Client Invoice History',
                    isDark: isDark,
                    child: invoices.isEmpty
                        ? Text(
                            'No invoice rows are currently attached to this client account.',
                            style: TextStyle(
                              color: isDark
                                  ? AppTheme.white60
                                  : AppTheme.colorFF64748B,
                            ),
                          )
                        : Column(
                            children: invoices
                                .map(
                                  (invoice) => Container(
                                    margin: const EdgeInsets.only(bottom: 12),
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? AppTheme.colorFF141924
                                          : AppTheme.colorFFF8FAFC,
                                      borderRadius: BorderRadius.circular(18),
                                      border: Border.all(
                                        color: isDark
                                            ? AppTheme.white.withValues(
                                                alpha: 0.06,
                                              )
                                            : AppTheme.black.withValues(
                                                alpha: 0.06,
                                              ),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                (invoice['invoiceNumber'] ??
                                                        'INV-SYNCED')
                                                    .toString(),
                                                style: TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w800,
                                                  color: isDark
                                                      ? AppTheme.white
                                                      : AppTheme.colorFF18212F,
                                                ),
                                              ),
                                            ),
                                            Text(
                                              (invoice['amount'] ?? 'PHP 0.00')
                                                  .toString(),
                                              style: const TextStyle(
                                                fontSize: 15,
                                                fontWeight: FontWeight.w900,
                                                color: AppTheme.colorFF10B981,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Wrap(
                                          spacing: 10,
                                          runSpacing: 10,
                                          children: [
                                            _historyPill(
                                              'Trip',
                                              (invoice['tripId'] ?? 'N/A')
                                                  .toString(),
                                            ),
                                            _historyPill(
                                              'Issue',
                                              (invoice['issueDate'] ?? 'N/A')
                                                  .toString(),
                                            ),
                                            _historyPill(
                                              'Due',
                                              (invoice['dueDate'] ?? 'N/A')
                                                  .toString(),
                                            ),
                                            _historyPill(
                                              'Status',
                                              (invoice['status'] ?? 'sent')
                                                  .toString()
                                                  .toUpperCase(),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOverview(bool isDark, Map<String, dynamic> overview) {
    final cards = [
      _SoaMetric(
        label: 'Clients',
        value: '${overview['clients'] ?? 0}',
        accent: AppTheme.colorFF4B7BE5,
        isDark: isDark,
      ),
      _SoaMetric(
        label: 'Outstanding',
        value: _money(overview['totalOutstanding']),
        accent: AppTheme.colorFFF59E0B,
        isDark: isDark,
      ),
      _SoaMetric(
        label: 'Paid',
        value: _money(overview['totalPaid']),
        accent: AppTheme.colorFF10B981,
        isDark: isDark,
      ),
      _SoaMetric(
        label: 'Overdue',
        value: _money(overview['totalOverdue']),
        accent: AppTheme.colorFFEF4444,
        isDark: isDark,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 920) {
          return Column(
            children: [
              Row(
                children: [
                  Expanded(child: cards[0]),
                  const SizedBox(width: 12),
                  Expanded(child: cards[1]),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: cards[2]),
                  const SizedBox(width: 12),
                  Expanded(child: cards[3]),
                ],
              ),
            ],
          );
        }

        return Row(
          children: [
            Expanded(child: cards[0]),
            const SizedBox(width: 12),
            Expanded(child: cards[1]),
            const SizedBox(width: 12),
            Expanded(child: cards[2]),
            const SizedBox(width: 12),
            Expanded(child: cards[3]),
          ],
        );
      },
    );
  }

  Widget _accountPill(String label, String value, bool isDark, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF141924 : AppTheme.colorFFF8FAFC,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: accent,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.white : AppTheme.colorFF18212F,
            ),
          ),
        ],
      ),
    );
  }

  Widget _historyPill(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AppTheme.colorFF4B7BE5,
        ),
      ),
    );
  }
}

class _SoaMetric extends StatelessWidget {
  final String label;
  final String value;
  final Color accent;
  final bool isDark;

  const _SoaMetric({
    required this.label,
    required this.value,
    required this.accent,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF141924 : AppTheme.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: accent,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w900,
              color: isDark ? AppTheme.white : AppTheme.colorFF18212F,
            ),
          ),
        ],
      ),
    );
  }
}

class _ClientStatementSection extends StatelessWidget {
  final Map<String, dynamic> client;
  final bool isDark;
  final VoidCallback onViewDetail;

  const _ClientStatementSection({
    required this.client,
    required this.isDark,
    required this.onViewDetail,
  });

  @override
  Widget build(BuildContext context) {
    final invoices = _listOfMaps(client['invoiceRows']);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF141924 : AppTheme.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.08)
              : AppTheme.black.withValues(alpha: 0.08),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: ExpansionTile(
          initiallyExpanded: true,
          backgroundColor: isDark ? AppTheme.colorFF141924 : AppTheme.white,
          collapsedBackgroundColor: isDark
              ? AppTheme.colorFF141924
              : AppTheme.white,
          tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
          title: Text(
            (client['name'] ?? 'Unknown Client').toString(),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: isDark ? AppTheme.white : AppTheme.colorFF18212F,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                _summaryPill(
                  'Invoiced',
                  (client['total'] ?? 'PHP 0.00').toString(),
                  AppTheme.primaryBlue,
                ),
                _summaryPill(
                  'Paid',
                  (client['paidLabel'] ?? 'PHP 0.00').toString(),
                  AppTheme.successGreen,
                ),
                _summaryPill(
                  'Outstanding',
                  (client['outstandingLabel'] ?? 'PHP 0.00').toString(),
                  AppTheme.warningOrange,
                ),
                _summaryPill(
                  'Overdue',
                  '${client['overdueCount'] ?? 0}',
                  AppTheme.errorRed,
                ),
              ],
            ),
          ),
          children: [
            for (final invoice in invoices)
              _StatementInvoiceRow(invoice: invoice, isDark: isDark),
            _ClientSubtotalRow(client: client, isDark: isDark),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onViewDetail,
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('View account details'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryPill(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _StatementInvoiceRow extends StatelessWidget {
  final Map<String, dynamic> invoice;
  final bool isDark;

  const _StatementInvoiceRow({required this.invoice, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final invoiceNumber = (invoice['invoiceNumber'] ?? invoice['id'] ?? 'N/A')
        .toString();
    final status = _statementStatus(invoice);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkPanel : AppTheme.lightPanel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.getBorderColor(context)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 720;
          final main = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                invoiceNumber,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  decoration: status == 'voided'
                      ? TextDecoration.lineThrough
                      : null,
                  color: AppTheme.getTextColor(context),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 18,
                runSpacing: 8,
                children: [
                  _InvoiceDatum(
                    label: 'Date',
                    value: _displayDateValue(invoice['issueDate']),
                  ),
                  _InvoiceDatum(
                    label: 'Trip reference',
                    value: (invoice['tripId'] ?? 'N/A').toString(),
                  ),
                  _InvoiceDatum(
                    label: 'Subtotal',
                    value: _money(
                      _numericMoney(
                        invoice['subtotalBeforeVat'] ?? invoice['subtotal'],
                      ),
                    ),
                  ),
                  _InvoiceDatum(
                    label: 'VAT',
                    value: _money(
                      _numericMoney(invoice['vatAmount'] ?? invoice['vat']),
                    ),
                  ),
                ],
              ),
            ],
          );
          final trailing = Column(
            crossAxisAlignment: compact
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.end,
            children: [
              _PaymentStatusBadge(invoice: invoice),
              const SizedBox(height: 9),
              Text(
                _money(_statementTotal(invoice)),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.getTextColor(context),
                ),
              ),
            ],
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [main, const SizedBox(height: 12), trailing],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: main),
              const SizedBox(width: 18),
              trailing,
            ],
          );
        },
      ),
    );
  }
}

class _PaymentStatusBadge extends StatelessWidget {
  final Map<String, dynamic> invoice;

  const _PaymentStatusBadge({required this.invoice});

  @override
  Widget build(BuildContext context) {
    final status = _statementStatus(invoice);
    final presentation = WorkflowStatusHelper.invoice(status);
    final color = presentation.color;
    final label = _statementStatusLabel(invoice);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.42)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 13,
          fontWeight: FontWeight.w800,
          decoration: presentation.strikethrough
              ? TextDecoration.lineThrough
              : null,
        ),
      ),
    );
  }
}

class _InvoiceDatum extends StatelessWidget {
  final String label;
  final String value;

  const _InvoiceDatum({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 125,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: AppTheme.getDashboardSecondaryStyle(context),
          ),
          const SizedBox(height: 3),
          Text(value, style: AppTheme.getDashboardBodyStyle(context)),
        ],
      ),
    );
  }
}

class _ClientSubtotalRow extends StatelessWidget {
  final Map<String, dynamic> client;
  final bool isDark;

  const _ClientSubtotalRow({required this.client, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: AppTheme.primaryBlue.withValues(alpha: isDark ? 0.18 : 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 28,
        runSpacing: 10,
        children: [
          Text(
            'Client subtotal',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: AppTheme.getTextColor(context),
            ),
          ),
          _SubtotalValue(
            label: 'Invoiced',
            value: (client['total'] ?? _money(0)).toString(),
          ),
          _SubtotalValue(
            label: 'Paid',
            value: (client['paidLabel'] ?? _money(0)).toString(),
          ),
          _SubtotalValue(
            label: 'Outstanding',
            value: (client['outstandingLabel'] ?? _money(0)).toString(),
          ),
        ],
      ),
    );
  }
}

class _SubtotalValue extends StatelessWidget {
  final String label;
  final String value;

  const _SubtotalValue({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Text(
      '$label: $value',
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: AppTheme.getTextColor(context),
      ),
    );
  }
}

class _GrandTotalRow extends StatelessWidget {
  final Map<String, dynamic> overview;
  final bool isDark;

  const _GrandTotalRow({required this.overview, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkPanelAlt : AppTheme.lightPanel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.primaryBlue.withValues(alpha: 0.35)),
      ),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 32,
        runSpacing: 10,
        children: [
          Text(
            'Grand total',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: AppTheme.getTextColor(context),
            ),
          ),
          _SubtotalValue(
            label: 'Invoiced',
            value: _money(overview['grandTotal']),
          ),
          _SubtotalValue(label: 'Paid', value: _money(overview['totalPaid'])),
          _SubtotalValue(
            label: 'Outstanding',
            value: _money(overview['totalOutstanding']),
          ),
        ],
      ),
    );
  }
}

class _AccountSection extends StatelessWidget {
  final String title;
  final bool isDark;
  final Widget child;

  const _AccountSection({
    required this.title,
    required this.isDark,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF141924 : AppTheme.colorFFF8FAFC,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.06)
              : AppTheme.black.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: isDark ? AppTheme.white : AppTheme.colorFF18212F,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _SoaEmptyState extends StatelessWidget {
  final bool isDark;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onTap;

  const _SoaEmptyState({
    required this.isDark,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.account_balance_wallet_outlined,
              size: 56,
              color: isDark ? AppTheme.white24 : AppTheme.black26,
            ),
            const SizedBox(height: 14),
            Text(
              title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: isDark ? AppTheme.white : AppTheme.colorFF18212F,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark ? AppTheme.white60 : AppTheme.colorFF64748B,
              ),
            ),
            if (actionLabel != null && onTap != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onTap, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

List<Map<String, dynamic>> _listOfMaps(dynamic raw) {
  if (raw is! List) return [];
  return raw
      .whereType<Map>()
      .map((item) => item.map((key, value) => MapEntry(key.toString(), value)))
      .toList();
}

String buildStatementCsv(List<Map<String, dynamic>> clients) {
  final invoices = clients
      .expand((client) => _listOfMaps(client['invoiceRows']))
      .toList();
  final rows = <List<String>>[
    ['Amounts in Philippine Peso (PHP)'],
    [
      'Invoice Number',
      'Date',
      'Client',
      'Trip Reference',
      'Subtotal',
      'VAT',
      'Total',
      'Status',
      'Days Overdue',
      'Payment Date',
    ],
    ...invoices.map(
      (invoice) => [
        (invoice['invoiceNumber'] ?? invoice['id'] ?? '').toString(),
        _csvDate(invoice['issueDate']),
        (invoice['client'] ?? '').toString(),
        (invoice['tripId'] ?? '').toString(),
        _csvAmount(invoice['subtotalBeforeVat'] ?? invoice['subtotal'] ?? 0),
        _csvAmount(invoice['vatAmount'] ?? invoice['vat'] ?? 0),
        _csvAmount(invoice['totalWithVat'] ?? invoice['amount'] ?? 0),
        _statementStatusLabel(invoice),
        '${_daysOverdue(invoice)}',
        _csvDate(invoice['paymentDate'] ?? invoice['paidAt']),
      ],
    ),
  ];
  return '\uFEFF${rows.map((row) => row.map(_csvValue).join(',')).join('\r\n')}';
}

String _csvValue(String value) {
  final normalized = value.replaceAll('\r', ' ').replaceAll('\n', ' ');
  final escaped = normalized.replaceAll('"', '""');
  return '"$escaped"';
}

String _statementStatus(Map<String, dynamic> invoice) {
  final value = (invoice['status'] ?? 'issued').toString().toLowerCase();
  if (value.contains('void')) return 'voided';
  if (value.contains('partial')) return 'partial';
  if (value.contains('overdue') || value.contains('late')) return 'overdue';
  if (value.contains('paid') || value.contains('collected')) return 'paid';
  return 'unpaid';
}

String _statementStatusLabel(Map<String, dynamic> invoice) {
  final status = _statementStatus(invoice);
  final presentation = WorkflowStatusHelper.invoice(status);
  return switch (status) {
    'partial' => 'Partial',
    'overdue' => 'Overdue ${_daysOverdue(invoice)} days',
    'unpaid' => 'Issued',
    _ => presentation.label,
  };
}

int _daysOverdue(Map<String, dynamic> invoice) {
  if (_statementStatus(invoice) != 'overdue') return 0;
  final value = invoice['daysOverdue'];
  if (value is num) return value.toInt().clamp(0, 1000000).toInt();
  final dueDate = _parseStatementDate(invoice['dueDate']);
  if (dueDate == null) return 0;
  return DateTime.now().difference(dueDate).inDays.clamp(0, 1000000).toInt();
}

DateTime? _parseStatementDate(dynamic value) {
  if (value == null) return null;
  final text = value.toString().trim();
  if (text.isEmpty || text == 'N/A') return null;
  return DateTime.tryParse(text);
}

String _displayDate(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '${value.year}-$month-$day';
}

String _displayDateValue(dynamic value) {
  final parsed = _parseStatementDate(value);
  return parsed == null ? 'N/A' : _displayDate(parsed);
}

String _csvDate(dynamic value) {
  final parsed = _parseStatementDate(value);
  return parsed == null ? '' : _displayDate(parsed);
}

double _statementTotal(Map<String, dynamic> invoice) {
  return _numericMoney(invoice['totalWithVat'] ?? invoice['amount'] ?? 0);
}

double _numericMoney(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(
        (value ?? '').toString().replaceAll(RegExp(r'[^0-9.\-]'), ''),
      ) ??
      0;
}

String _csvAmount(dynamic value) => _numericMoney(value).toStringAsFixed(2);

String _money(dynamic value) {
  if (value is String && value.trim().isNotEmpty) return value;
  final amount = value is num
      ? value.toDouble()
      : double.tryParse('$value') ?? 0;
  return 'PHP ${amount.toStringAsFixed(2)}';
}
