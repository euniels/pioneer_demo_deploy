import 'package:flutter/material.dart';

import '../services/backend_api.dart';
import '../services/crud_permissions.dart';
import '../services/fleet_sync_service.dart';
import '../services/soa_exporter.dart';
import '../utils/form_validation.dart';
import '../widgets/dashboard_layout.dart';
import '../widgets/page_skeletons.dart';
import '../theme/app_theme.dart';

class BillingPage extends StatefulWidget {
  const BillingPage({super.key});

  @override
  State<BillingPage> createState() => _BillingPageState();
}

class _BillingPageState extends State<BillingPage> {
  late Future<Map<String, dynamic>> _future;
  late Future<Map<String, dynamic>> _coverageFuture;
  String _search = '';
  String _status = 'all';
  DateTime? _fromDate;
  DateTime? _toDate;

  @override
  void initState() {
    super.initState();
    _future = _load(forceRefresh: true);
    _coverageFuture = BackendApiService.getVehicleSubscriptionCoverageReport();
  }

  Future<Map<String, dynamic>> _load({bool forceRefresh = false}) {
    return BackendApiService.loadWithWarmRetry<Map<String, dynamic>>(
      attempts: forceRefresh ? 2 : 4,
      request: (retryForceRefresh) {
        final effectiveForceRefresh = forceRefresh || retryForceRefresh;
        warmOperationalCachesSilently(forceRefresh: effectiveForceRefresh);
        return BackendApiService.getBillingInvoices(
          forceRefresh: effectiveForceRefresh,
        );
      },
    );
  }

  void _reload() {
    setState(() {
      _future = _load(forceRefresh: true);
      _coverageFuture = BackendApiService.getVehicleSubscriptionCoverageReport(
        forceRefresh: true,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      currentRoute: '/billing',
      title: 'Delivery Trip Billing',
      subtitle:
          'PioneerPath delivery trip charges, separate from ERP service billing',
      child: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        initialData: BackendApiService.peekCachedDataMap('/billing/invoices'),
        builder: (context, snapshot) {
          final isDark = Theme.of(context).brightness == Brightness.dark;

          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const PioneerRouteSkeletonBody(routeName: '/billing');
          }

          if (snapshot.hasError) {
            return _BillingEmptyState(
              isDark: isDark,
              title: 'Billing is temporarily unavailable',
              message:
                  'The backend did not return invoice data right now. Try refreshing again.',
              actionLabel: 'Retry',
              onTap: _reload,
            );
          }

          final data = snapshot.data ?? const <String, dynamic>{};
          final contextData = _mapOf(data['context']);
          final overview = _mapOf(data['overview']);
          final invoices = _listOfMaps(data['invoices']);
          final filtered = invoices.where((invoice) {
            final status = (invoice['status'] ?? '').toString().toLowerCase();
            final query = _search.trim().toLowerCase();

            if (_status != 'all' && status != _status) {
              return false;
            }

            final issueDate = DateTime.tryParse(
              (invoice['issueDate'] ?? '').toString(),
            );
            if (_fromDate != null &&
                (issueDate == null || issueDate.isBefore(_fromDate!))) {
              return false;
            }
            if (_toDate != null &&
                (issueDate == null ||
                    issueDate.isAfter(
                      DateTime(
                        _toDate!.year,
                        _toDate!.month,
                        _toDate!.day,
                        23,
                        59,
                        59,
                      ),
                    ))) {
              return false;
            }

            if (query.isEmpty) {
              return true;
            }

            return (invoice['invoiceNumber'] ?? '')
                    .toString()
                    .toLowerCase()
                    .contains(query) ||
                (invoice['client'] ?? '').toString().toLowerCase().contains(
                  query,
                ) ||
                (invoice['tripId'] ?? '').toString().toLowerCase().contains(
                  query,
                ) ||
                (invoice['erpReference'] ?? '')
                    .toString()
                    .toLowerCase()
                    .contains(query) ||
                (invoice['poNumber'] ?? '').toString().toLowerCase().contains(
                  query,
                ) ||
                (invoice['drNumber'] ?? '').toString().toLowerCase().contains(
                  query,
                );
          }).toList();

          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                _buildBillingScopeNotice(isDark, contextData),
                const SizedBox(height: 12),
                _buildSummary(isDark, overview),
                const SizedBox(height: 12),
                _buildBillingCommandCenter(isDark, overview),
                const SizedBox(height: 12),
                _buildVehicleSubscriptionCoverage(isDark),
                const SizedBox(height: 12),
                _buildFilters(isDark, invoices),
                const SizedBox(height: 12),
                if (filtered.isEmpty)
                  _BillingEmptyState(
                    isDark: isDark,
                    title: 'No invoices match the current filters',
                    message:
                        'Try a different search term or switch the invoice status filter.',
                  )
                else
                  _buildInvoiceTable(isDark, filtered),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _showInvoiceReceipt(
    Map<String, dynamic> invoice,
    bool isDark,
  ) async {
    final erpController = TextEditingController(
      text: (invoice['erpReference'] ?? '').toString(),
    );
    final poController = TextEditingController(
      text: (invoice['poNumber'] ?? '').toString(),
    );
    final drController = TextEditingController(
      text: (invoice['drNumber'] ?? '').toString(),
    );
    final notesController = TextEditingController(
      text: (invoice['referenceNotes'] ?? '').toString(),
    );

    try {
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: AppTheme.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
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
                                'Invoice Receipt',
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
                                (invoice['invoiceNumber'] ?? 'INV-SYNCED')
                                    .toString(),
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.colorFF4B7BE5,
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
                    const SizedBox(height: 12),
                    _buildInvoiceActions(invoice, isDark),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _receiptPill(
                          'Client',
                          (invoice['client'] ?? 'Unknown Client').toString(),
                          isDark,
                        ),
                        _receiptPill(
                          'Trip',
                          (invoice['tripId'] ?? 'N/A').toString(),
                          isDark,
                        ),
                        _receiptPill(
                          'Issue Date',
                          (invoice['issueDate'] ?? 'N/A').toString(),
                          isDark,
                        ),
                        _receiptPill(
                          'Due Date',
                          (invoice['dueDate'] ?? 'N/A').toString(),
                          isDark,
                        ),
                        _receiptPill(
                          'Status',
                          (invoice['status'] ?? 'sent')
                              .toString()
                              .toUpperCase(),
                          isDark,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _ReceiptSection(
                      title: 'Line Items',
                      isDark: isDark,
                      child: _buildLineItemsTable(invoice, isDark),
                    ),
                    const SizedBox(height: 18),
                    _ReceiptSection(
                      title: 'ERP Reference Details',
                      isDark: isDark,
                      child: Column(
                        children: [
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final compact = constraints.maxWidth < 620;
                              final fields = [
                                _referenceField(
                                  isDark,
                                  controller: erpController,
                                  label: 'ERP SO / Quotation No.',
                                ),
                                _referenceField(
                                  isDark,
                                  controller: poController,
                                  label: 'PO Number',
                                ),
                                _referenceField(
                                  isDark,
                                  controller: drController,
                                  label: 'DR Number',
                                ),
                              ];

                              if (compact) {
                                return Column(
                                  children: [
                                    fields[0],
                                    const SizedBox(height: 10),
                                    fields[1],
                                    const SizedBox(height: 10),
                                    fields[2],
                                  ],
                                );
                              }

                              return Row(
                                children: [
                                  Expanded(child: fields[0]),
                                  const SizedBox(width: 10),
                                  Expanded(child: fields[1]),
                                  const SizedBox(width: 10),
                                  Expanded(child: fields[2]),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 10),
                          _referenceField(
                            isDark,
                            controller: notesController,
                            label: 'Reference notes',
                            maxLines: 2,
                          ),
                          const SizedBox(height: 10),
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.icon(
                              onPressed: () async {
                                final tripId = (invoice['tripId'] ?? '')
                                    .toString();
                                if (tripId.isEmpty) {
                                  return;
                                }
                                await BackendApiService.saveBillingInvoiceReferences(
                                  tripId,
                                  {
                                    'invoiceNumber':
                                        (invoice['invoiceNumber'] ?? '')
                                            .toString(),
                                    'erpReference': erpController.text.trim(),
                                    'poNumber': poController.text.trim(),
                                    'drNumber': drController.text.trim(),
                                    'notes': notesController.text.trim(),
                                  },
                                );
                                if (!context.mounted) {
                                  return;
                                }
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'ERP invoice references saved.',
                                    ),
                                  ),
                                );
                                Navigator.pop(context);
                                _reload();
                              },
                              icon: const Icon(Icons.save_rounded),
                              label: const Text('Save references'),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    _ReceiptSection(
                      title: 'Operational Assurance',
                      isDark: isDark,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _receiptRow(
                            'Collection readiness',
                            (invoice['collectionReadiness'] ?? 'Hold for POD')
                                .toString(),
                            isDark,
                          ),
                          _receiptRow(
                            'Pricing model',
                            (invoice['pricingModel'] ?? 'Manual review')
                                .toString(),
                            isDark,
                          ),
                          _receiptRow(
                            'Billing decision',
                            (invoice['billingDecision'] ??
                                    'Ready for normal invoice collection.')
                                .toString(),
                            isDark,
                            withBottomSpacing: false,
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _listOfMaps(invoice['pricingRules'])
                                .map(
                                  (rule) => _AssuranceChip(
                                    label: (rule['label'] ?? 'Rule').toString(),
                                    value: (rule['state'] ?? 'review')
                                        .toString(),
                                    isDark: isDark,
                                  ),
                                )
                                .toList(),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    _ReceiptSection(
                      title: 'Totals',
                      isDark: isDark,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: SizedBox(
                          width: 340,
                          child: Column(
                            children: [
                              _receiptRow(
                                'Subtotal before VAT',
                                _peso(
                                  invoice['subtotalBeforeVat'] ??
                                      invoice['subtotal'],
                                ),
                                isDark,
                                emphasized: true,
                              ),
                              _receiptRow(
                                'VAT (${invoice['vatRatePercent'] ?? 12}%)',
                                _peso(invoice['vat'] ?? invoice['vatAmount']),
                                isDark,
                              ),
                              Divider(
                                height: 24,
                                color: isDark
                                    ? AppTheme.white.withValues(alpha: 0.08)
                                    : AppTheme.black.withValues(alpha: 0.08),
                              ),
                              _receiptRow(
                                'Total with VAT',
                                _peso(
                                  invoice['totalWithVat'] ?? invoice['amount'],
                                ),
                                isDark,
                                prominent: true,
                                withBottomSpacing: false,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    _ReceiptSection(
                      title: 'Source',
                      isDark: isDark,
                      child: Text(
                        (invoice['source'] ??
                                'Derived from synced trip and billing data.')
                            .toString(),
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: isDark
                              ? AppTheme.white70
                              : AppTheme.colorFF64748B,
                        ),
                      ),
                    ),
                    if ((invoice['voidReason'] ?? '').toString().isNotEmpty ||
                        _listOfMaps(invoice['statusHistory']).isNotEmpty) ...[
                      const SizedBox(height: 18),
                      _ReceiptSection(
                        title: 'Lifecycle Audit',
                        isDark: isDark,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if ((invoice['voidReason'] ?? '')
                                .toString()
                                .isNotEmpty)
                              _receiptRow(
                                'Void reason',
                                (invoice['voidReason'] ?? '').toString(),
                                isDark,
                              ),
                            ..._listOfMaps(invoice['statusHistory']).map(
                              (row) => _receiptRow(
                                '${row['from'] ?? 'created'} -> ${row['to'] ?? 'updated'}',
                                (row['at'] ?? row['note'] ?? '').toString(),
                                isDark,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    } finally {
      erpController.dispose();
      poController.dispose();
      drController.dispose();
      notesController.dispose();
    }
  }

  Widget _buildInvoiceActions(Map<String, dynamic> invoice, bool isDark) {
    final status = (invoice['status'] ?? '').toString().toLowerCase();
    final podReady = invoice['podReady'] == true;
    final editable = CrudPermissions.canEdit(CrudEntity.invoices);
    final canVoid =
        CrudPermissions.canDelete(CrudEntity.invoices) &&
        !{'paid', 'voided'}.contains(status);
    final canApprove = editable && status == 'draft' && podReady;
    final canReject = editable && {'draft', 'approved'}.contains(status);
    final canIssue = editable && status == 'approved' && podReady;
    final canMarkPaid = editable && {'issued', 'overdue'}.contains(status);
    final canMarkOverdue = editable && status == 'issued';
    final canEditOverride = editable && !{'paid', 'voided'}.contains(status);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: AppTheme.space12),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: isDark
                ? AppTheme.white.withValues(alpha: 0.08)
                : AppTheme.black.withValues(alpha: 0.08),
          ),
          bottom: BorderSide(
            color: isDark
                ? AppTheme.white.withValues(alpha: 0.08)
                : AppTheme.black.withValues(alpha: 0.08),
          ),
        ),
      ),
      child: Wrap(
        spacing: AppTheme.space8,
        runSpacing: AppTheme.space8,
        children: [
          OutlinedButton.icon(
            onPressed: editable
                ? () => _confirmRecalculateInvoice(invoice)
                : null,
            icon: const Icon(Icons.calculate_rounded),
            label: const Text('Recalculate'),
          ),
          FilledButton.icon(
            onPressed: canApprove
                ? () => _advanceInvoiceStatus(invoice, 'approved')
                : null,
            icon: const Icon(Icons.fact_check_rounded),
            label: const Text('Approve'),
          ),
          OutlinedButton.icon(
            onPressed: canReject
                ? () => _advanceInvoiceStatus(invoice, 'rejected')
                : null,
            icon: const Icon(Icons.report_gmailerrorred_rounded),
            label: const Text('Reject'),
          ),
          FilledButton.icon(
            onPressed: canIssue
                ? () => _advanceInvoiceStatus(invoice, 'issued')
                : null,
            icon: const Icon(Icons.receipt_long_rounded),
            label: const Text('Issue'),
          ),
          FilledButton.icon(
            onPressed: canMarkPaid
                ? () => _advanceInvoiceStatus(invoice, 'paid')
                : null,
            icon: const Icon(Icons.verified_rounded),
            label: const Text('Mark Paid'),
          ),
          OutlinedButton.icon(
            onPressed: canVoid ? () => _showVoidInvoiceDialog(invoice) : null,
            icon: const Icon(Icons.block_rounded),
            label: const Text('Void'),
          ),
          OutlinedButton.icon(
            onPressed: () => _printInvoice(invoice),
            icon: const Icon(Icons.print_rounded),
            label: const Text('Print'),
          ),
          if (editable)
            PopupMenuButton<String>(
              tooltip: 'More invoice actions',
              onSelected: (value) {
                if (value == 'overdue') {
                  _advanceInvoiceStatus(invoice, 'overdue');
                } else if (value == 'edit') {
                  _showManualInvoiceDialog(
                    [invoice],
                    isDark,
                    existingInvoice: invoice,
                  );
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'overdue',
                  enabled: canMarkOverdue,
                  child: const Text('Mark Overdue'),
                ),
                PopupMenuItem(
                  value: 'edit',
                  enabled: canEditOverride,
                  child: const Text('Edit Invoice'),
                ),
              ],
              child: const Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: AppTheme.space12,
                  vertical: AppTheme.space10,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.more_horiz_rounded),
                    SizedBox(width: AppTheme.space6),
                    Text('More'),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLineItemsTable(Map<String, dynamic> invoice, bool isDark) {
    final lineItems = _financialLineItems(invoice);
    if (lineItems.isEmpty) {
      return Text(
        'No line items are attached to this invoice.',
        style: AppTheme.getDashboardBodyStyle(
          context,
        ).copyWith(color: isDark ? AppTheme.white60 : AppTheme.colorFF64748B),
      );
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.space12,
            vertical: AppTheme.space10,
          ),
          decoration: const BoxDecoration(color: AppTheme.primaryBlue),
          child: const Row(
            children: [
              Expanded(flex: 46, child: _InvoiceTableHeader('DESCRIPTION')),
              Expanded(
                flex: 12,
                child: _InvoiceTableHeader('QTY', alignRight: true),
              ),
              Expanded(
                flex: 20,
                child: _InvoiceTableHeader('UNIT PRICE', alignRight: true),
              ),
              Expanded(
                flex: 22,
                child: _InvoiceTableHeader('SUBTOTAL', alignRight: true),
              ),
            ],
          ),
        ),
        ...lineItems.indexed.map((entry) {
          final row = entry.$2;
          final amount = row['amountLabel'] ?? row['amount'];
          return Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.space12,
              vertical: AppTheme.space12,
            ),
            decoration: BoxDecoration(
              color: entry.$1.isEven
                  ? AppTheme.transparent
                  : (isDark
                        ? AppTheme.white.withValues(alpha: 0.025)
                        : AppTheme.colorFFF8FBFF),
              border: Border(
                bottom: BorderSide(
                  color: isDark
                      ? AppTheme.white.withValues(alpha: 0.06)
                      : AppTheme.black.withValues(alpha: 0.06),
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 46,
                  child: Text(
                    (row['label'] ?? 'Charge').toString(),
                    style: AppTheme.getDashboardBodyStyle(context),
                  ),
                ),
                const Expanded(
                  flex: 12,
                  child: Text('1', textAlign: TextAlign.right),
                ),
                Expanded(
                  flex: 20,
                  child: Text(
                    _peso(amount),
                    textAlign: TextAlign.right,
                    style: AppTheme.getDashboardBodyStyle(context),
                  ),
                ),
                Expanded(
                  flex: 22,
                  child: Text(
                    _peso(amount),
                    textAlign: TextAlign.right,
                    style: AppTheme.getDashboardBodyStyle(
                      context,
                    ).copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Future<void> _printInvoice(Map<String, dynamic> invoice) async {
    final ok = await printHtmlDocument(
      'Invoice ${(invoice['invoiceNumber'] ?? '').toString()}',
      _invoicePrintHtml(invoice),
    );
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Invoice opened for printing.'
              : 'Invoice printing is available in the web build.',
        ),
      ),
    );
  }

  String _invoicePrintHtml(Map<String, dynamic> invoice) {
    final lines = _financialLineItems(invoice)
        .map(
          (row) =>
              '<tr><td>${_escapeHtml((row['label'] ?? 'Charge').toString())}</td>'
              '<td class="num">1</td><td class="num">${_escapeHtml(_peso(row['amountLabel'] ?? row['amount']))}</td>'
              '<td class="num">${_escapeHtml(_peso(row['amountLabel'] ?? row['amount']))}</td></tr>',
        )
        .join();
    final history = _listOfMaps(invoice['statusHistory'])
        .take(8)
        .map(
          (row) =>
              '<li>${_escapeHtml((row['to'] ?? '').toString().toUpperCase())}'
              ' - ${_escapeHtml((row['note'] ?? 'status updated').toString())}'
              ' (${_escapeHtml((row['at'] ?? '').toString())})</li>',
        )
        .join();
    return '''
      <h1>PioneerPath Delivery Trip Invoice / Receipt</h1>
      <p><strong>${_escapeHtml((invoice['invoiceNumber'] ?? '').toString())}</strong></p>
      <p>Client: ${_escapeHtml((invoice['client'] ?? '').toString())}<br>
      Trip reference: ${_escapeHtml((invoice['tripId'] ?? '').toString())}<br>
      Origin: ${_escapeHtml((invoice['origin'] ?? '').toString())}<br>
      Destination: ${_escapeHtml((invoice['destination'] ?? '').toString())}<br>
      Issue date: ${_escapeHtml((invoice['issueDate'] ?? '').toString())}<br>
      Due date: ${_escapeHtml((invoice['dueDate'] ?? '').toString())}<br>
      Status: ${_escapeHtml((invoice['status'] ?? '').toString().toUpperCase())}<br>
      POD: ${_escapeHtml((invoice['collectionReadiness'] ?? invoice['podReadiness'] ?? '').toString())}
      (${_escapeHtml((invoice['podStatus'] ?? '').toString())})</p>
      <table><thead><tr><th>Description</th><th>Quantity</th><th>Unit price</th><th>Subtotal</th></tr></thead><tbody>$lines</tbody></table>
      <div class="totals"><p>Subtotal before VAT: <strong>${_escapeHtml(_peso(invoice['subtotalBeforeVat'] ?? invoice['subtotal']))}</strong></p>
      <p>VAT (${_escapeHtml((invoice['vatRatePercent'] ?? 12).toString())}%): <strong>${_escapeHtml(_peso(invoice['vat'] ?? invoice['vatAmount']))}</strong></p>
      <h2>Total with VAT: ${_escapeHtml(_peso(invoice['totalWithVat'] ?? invoice['amount']))}</h2></div>
      <h3>Delivery Charge Basis</h3>
      <p>${_escapeHtml((invoice['finalChargeBasis'] ?? invoice['billingDecision'] ?? 'Delivery trip charges from GPS/POD evidence.').toString())}</p>
      <h3>ERP Reference Details</h3>
      <p>SO / Quotation: ${_escapeHtml((invoice['erpReference'] ?? '').toString())}<br>
      PO: ${_escapeHtml((invoice['poNumber'] ?? '').toString())}<br>
      DR: ${_escapeHtml((invoice['drNumber'] ?? '').toString())}</p>
      <h3>Status History Summary</h3>
      <ul>${history.isEmpty ? '<li>No manual lifecycle audit entries yet.</li>' : history}</ul>
      <p><em>This PioneerPath delivery trip invoice/receipt is not an official ERP accounting document.</em></p>
    ''';
  }

  List<Map<String, dynamic>> _financialLineItems(Map<String, dynamic> invoice) {
    return _listOfMaps(invoice['itemizedBreakdown'])
        .where((row) => (row['label'] ?? '').toString() != 'Policy review')
        .toList();
  }

  Future<void> _showManualInvoiceDialog(
    List<Map<String, dynamic>> invoices,
    bool isDark, {
    Map<String, dynamic>? existingInvoice,
  }) async {
    var selectedTripId =
        (existingInvoice?['tripId'] ?? invoices.first['tripId'] ?? '')
            .toString();

    final baseController = TextEditingController(
      text: _plainAmount(existingInvoice?['baseCharge']),
    );
    final distanceController = TextEditingController(
      text: _plainAmount(existingInvoice?['distanceCharge']),
    );
    final fuelController = TextEditingController(
      text: _plainAmount(existingInvoice?['fuelCostEstimate']),
    );
    final surchargeController = TextEditingController(
      text: _plainAmount(existingInvoice?['surcharges']),
    );
    final reasonController = TextEditingController(
      text: (existingInvoice?['overrideReason'] ?? '').toString(),
    );
    final formKey = GlobalKey<FormState>();
    var saving = false;

    try {
      await showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            backgroundColor: isDark ? AppTheme.colorFF111723 : AppTheme.white,
            title: Text(
              existingInvoice == null
                  ? 'New Manual Invoice'
                  : 'Edit invoice override',
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: selectedTripId,
                        hint: const Text('Select...'),
                        decoration: const InputDecoration(
                          labelText: 'Linked trip',
                          helperText:
                              'Every invoice must stay attached to a trip.',
                        ),
                        items: invoices
                            .where(
                              (invoice) => (invoice['tripId'] ?? '')
                                  .toString()
                                  .isNotEmpty,
                            )
                            .map(
                              (invoice) => DropdownMenuItem(
                                value: (invoice['tripId'] ?? '').toString(),
                                child: Text(
                                  '${invoice['tripId'] ?? ''} - ${invoice['client'] ?? 'Unknown Client'}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: existingInvoice == null
                            ? (value) {
                                if (value != null) {
                                  setDialogState(() => selectedTripId = value);
                                }
                              }
                            : null,
                        validator: (value) => FormValidation.requiredSelection(
                          'linked trip',
                          value,
                        ),
                      ),
                      if (existingInvoice == null) ...[
                        const SizedBox(height: 12),
                        TextFormField(
                          initialValue: 'Draft',
                          enabled: false,
                          decoration: InputDecoration(
                            labelText: 'Status',
                            helperText:
                                'Manual invoices start as draft until approved.',
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _amountField(baseController, 'Base charge'),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _amountField(
                              distanceController,
                              'Distance charge',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: _amountField(
                              fuelController,
                              'Fuel estimate',
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _amountField(
                              surchargeController,
                              'Surcharges',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: reasonController,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Required override reason',
                          alignLabelWithHint: true,
                        ),
                        validator: (value) => FormValidation.requiredField(
                          'Override reason',
                          value,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: saving
                    ? null
                    : () async {
                        if (!(formKey.currentState?.validate() ?? false)) {
                          return;
                        }
                        final reason = reasonController.text.trim();
                        setDialogState(() => saving = true);

                        final payload = <String, dynamic>{
                          'tripId': selectedTripId,
                          'overrideReason': reason,
                          'lineItems': [
                            {
                              'label': 'Base delivery charge',
                              'amount': _amountValue(baseController.text),
                            },
                            {
                              'label': 'GPS distance charge',
                              'amount': _amountValue(distanceController.text),
                            },
                            {
                              'label': 'Fuel cost estimate',
                              'amount': _amountValue(fuelController.text),
                            },
                            {
                              'label': 'Surcharges',
                              'amount': _amountValue(surchargeController.text),
                            },
                          ],
                        };
                        if (existingInvoice == null) {
                          payload['status'] = 'draft';
                        }

                        try {
                          if (existingInvoice == null) {
                            await BackendApiService.createBillingInvoice(
                              payload,
                            );
                          } else {
                            await BackendApiService.updateBillingInvoice(
                              selectedTripId,
                              payload,
                            );
                          }
                          if (!context.mounted) {
                            return;
                          }
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                existingInvoice == null
                                    ? 'Manual invoice saved.'
                                    : 'Invoice override saved.',
                              ),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                          _reload();
                        } catch (error) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  FormValidation.backendError(
                                    error,
                                    'Invoice could not be saved.',
                                  ),
                                ),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        } finally {
                          if (context.mounted) {
                            setDialogState(() => saving = false);
                          }
                        }
                      },
                icon: saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_rounded),
                label: Text(saving ? 'Saving...' : 'Save'),
              ),
            ],
          ),
        ),
      );
    } finally {
      baseController.dispose();
      distanceController.dispose();
      fuelController.dispose();
      surchargeController.dispose();
      reasonController.dispose();
    }
  }

  Future<void> _confirmRecalculateInvoice(Map<String, dynamic> invoice) async {
    final tripId = (invoice['tripId'] ?? '').toString();
    if (tripId.isEmpty) {
      return;
    }
    final updated = await BackendApiService.recalculateInvoice(tripId);
    if (!mounted) {
      return;
    }

    final before = _mapOf(updated['before']);
    final after = _mapOf(updated['after']);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm recalculation'),
        content: Text(
          'Before: ${_peso(before['totalWithVat'] ?? invoice['totalWithVat'] ?? invoice['amount'])}\n'
          'After: ${_peso(after['totalWithVat'] ?? updated['totalWithVat'] ?? updated['amount'])}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Use recalculated amount'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Recalculated ${updated['invoiceNumber'] ?? tripId}: ${_peso(updated['totalWithVat'] ?? updated['amount'] ?? updated['total'])}',
        ),
      ),
    );
    _reload();
  }

  Future<void> _advanceInvoiceStatus(
    Map<String, dynamic> invoice,
    String status,
  ) async {
    final tripId = (invoice['tripId'] ?? '').toString();
    final current = (invoice['status'] ?? '').toString().toLowerCase();
    if (tripId.isEmpty || current == status || current == 'voided') {
      return;
    }
    final noteController = TextEditingController(
      text: status == 'issued'
          ? (invoice['billingDecision'] ?? 'Final charge reviewed against GPS/POD evidence.').toString()
          : '',
    );
    final paymentDateController = TextEditingController(
      text: DateTime.now().toIso8601String().substring(0, 10),
    );
    final formKey = GlobalKey<FormState>();
    var saving = false;

    final title = switch (status) {
      'approved' => 'Approve invoice',
      'rejected' => 'Reject invoice',
      'issued' => 'Issue invoice',
      'paid' => 'Mark invoice paid',
      'overdue' => 'Mark invoice overdue',
      _ => 'Update invoice',
    };
    final fieldLabel = switch (status) {
      'approved' => 'Approval note',
      'rejected' => 'Rejection reason',
      'issued' => 'Final charge basis',
      'paid' => 'Payment reference',
      _ => 'Audit note',
    };
    final fieldKey = switch (status) {
      'approved' => 'approvalNote',
      'rejected' => 'rejectionReason',
      'issued' => 'finalChargeBasis',
      'paid' => 'paymentReference',
      _ => 'notes',
    };
    final requiresText = status != 'overdue';

    try {
      await showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 460,
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Transition ${current.toUpperCase()} to ${status.toUpperCase()} for trip $tripId.',
                      ),
                    ),
                    if (requiresText) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: noteController,
                        maxLines: status == 'paid' ? 1 : 3,
                        decoration: InputDecoration(
                          labelText: fieldLabel,
                          alignLabelWithHint: status != 'paid',
                        ),
                        validator: (value) => FormValidation.requiredField(
                          fieldLabel,
                          value,
                        ),
                      ),
                    ],
                    if (status == 'paid') ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: paymentDateController,
                        decoration: const InputDecoration(
                          labelText: 'Payment date',
                          helperText: 'Use YYYY-MM-DD.',
                        ),
                      ),
                    ],
                    if (status == 'overdue') ...[
                      const SizedBox(height: 12),
                      const Text(
                        'This keeps the invoice collectible and records an overdue audit timestamp.',
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: saving
                    ? null
                    : () async {
                        if (!(formKey.currentState?.validate() ?? false)) {
                          return;
                        }
                        final payload = <String, dynamic>{'status': status};
                        if (requiresText) {
                          payload[fieldKey] = noteController.text.trim();
                        }
                        if (status == 'paid') {
                          payload['paymentDate'] =
                              paymentDateController.text.trim();
                        }
                        setDialogState(() => saving = true);
                        try {
                          await BackendApiService.updateBillingInvoice(
                            tripId,
                            payload,
                          );
                          if (!context.mounted) {
                            return;
                          }
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                'Invoice marked ${status.toUpperCase()}.',
                              ),
                            ),
                          );
                          Navigator.pop(context);
                          _reload();
                        } catch (error) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  FormValidation.backendError(
                                    error,
                                    'That invoice status transition is not allowed.',
                                  ),
                                ),
                              ),
                            );
                          }
                        } finally {
                          if (context.mounted) {
                            setDialogState(() => saving = false);
                          }
                        }
                      },
                icon: saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_circle_rounded),
                label: Text(saving ? 'Saving...' : 'Confirm'),
              ),
            ],
          ),
        ),
      );
    } finally {
      noteController.dispose();
      paymentDateController.dispose();
    }
  }

  Future<void> _showVoidInvoiceDialog(Map<String, dynamic> invoice) async {
    final tripId = (invoice['tripId'] ?? '').toString();
    final reasonController = TextEditingController();
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Void invoice'),
          content: TextField(
            controller: reasonController,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Required void reason',
              alignLabelWithHint: true,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () async {
                final reason = reasonController.text.trim();
                if (tripId.isEmpty || reason.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('A void reason is required.')),
                  );
                  return;
                }
                await BackendApiService.voidBillingInvoice(tripId, reason);
                if (!context.mounted) {
                  return;
                }
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Invoice voided.')),
                );
                _reload();
              },
              icon: const Icon(Icons.block_rounded),
              label: const Text('Void'),
            ),
          ],
        ),
      );
    } finally {
      reasonController.dispose();
    }
  }

  Widget _amountField(TextEditingController controller, String label) {
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      validator: (value) => FormValidation.nonNegativeNumber(label, value),
      decoration: InputDecoration(labelText: label, prefixText: '₱ '),
    );
  }

  Widget _buildVehicleSubscriptionCoverage(bool isDark) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _coverageFuture,
      initialData: BackendApiService.peekCachedDataMap(
        '/fleet/reports/vehicle-subscription-coverage',
      ),
      builder: (context, snapshot) {
        final data = snapshot.data ?? const <String, dynamic>{};
        final groups = _listOfMaps(data['groups']);
        final loading =
            snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData;

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.colorFF101826 : AppTheme.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isDark
                  ? AppTheme.white.withValues(alpha: 0.08)
                  : AppTheme.black.withValues(alpha: 0.08),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.fact_check_rounded,
                    size: 18,
                    color: AppTheme.colorFF4B7BE5,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Vehicle Subscription Coverage Report',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        color: isDark ? AppTheme.white : AppTheme.colorFF111827,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _coverageFuture =
                            BackendApiService.getVehicleSubscriptionCoverageReport(
                              forceRefresh: true,
                            );
                      });
                    },
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Refresh'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Reference only for ERP GeoTab subscription descriptions. Copy the plate lists into ERP service billing; this does not create a PioneerPath invoice.',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  color: isDark ? AppTheme.white60 : AppTheme.colorFF64748B,
                ),
              ),
              const SizedBox(height: 12),
              if (loading)
                Text(
                  'Loading coverage report...',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? AppTheme.white54 : AppTheme.colorFF64748B,
                  ),
                )
              else if (groups.isEmpty)
                Text(
                  'No active vehicle subscription coverage records yet.',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? AppTheme.white54 : AppTheme.colorFF64748B,
                  ),
                )
              else
                ...groups
                    .take(4)
                    .map(
                      (group) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isDark
                                ? AppTheme.white.withValues(alpha: 0.04)
                                : AppTheme.colorFFF8FAFC,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${group['client'] ?? 'Unassigned Client'} (${group['count'] ?? 0})',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w900,
                                  color: isDark
                                      ? AppTheme.white
                                      : AppTheme.colorFF111827,
                                ),
                              ),
                              const SizedBox(height: 4),
                              SelectableText(
                                (group['copyText'] ?? '').toString(),
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.4,
                                  color: isDark
                                      ? AppTheme.white70
                                      : AppTheme.colorFF475569,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSummary(bool isDark, Map<String, dynamic> overview) {
    final cards = [
      _BillingKpiCard(
        label: 'Total Invoiced This Month',
        value: _peso(
          overview['totalInvoicedThisMonth'] ?? overview['totalBilled'],
        ),
        icon: Icons.receipt_long_rounded,
        accent: AppTheme.colorFF4B7BE5,
        isDark: isDark,
      ),
      _BillingKpiCard(
        label: 'Total Collected This Month',
        value: _peso(
          overview['totalCollectedThisMonth'] ?? overview['totalPaid'],
        ),
        icon: Icons.account_balance_wallet_rounded,
        accent: AppTheme.colorFF10B981,
        isDark: isDark,
      ),
      _BillingKpiCard(
        label: 'Outstanding Balance',
        value: _peso(overview['outstandingBalance'] ?? overview['totalSent']),
        icon: Icons.pending_actions_rounded,
        accent: AppTheme.pioneerRed,
        isDark: isDark,
      ),
      _BillingKpiCard(
        label: 'Overdue Amount',
        value: _peso(overview['overdueAmount'] ?? overview['totalOverdue']),
        icon: Icons.warning_amber_rounded,
        accent: AppTheme.colorFF7F1D1D,
        isDark: isDark,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 900) {
          return Column(
            children: [
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: cards[0]),
                    const SizedBox(width: 12),
                    Expanded(child: cards[1]),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: cards[2]),
                    const SizedBox(width: 12),
                    Expanded(child: cards[3]),
                  ],
                ),
              ),
            ],
          );
        }

        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: cards[0]),
              const SizedBox(width: 12),
              Expanded(child: cards[1]),
              const SizedBox(width: 12),
              Expanded(child: cards[2]),
              const SizedBox(width: 12),
              Expanded(child: cards[3]),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBillingCommandCenter(
    bool isDark,
    Map<String, dynamic> overview,
  ) {
    final policy = _mapOf(overview['billingPolicy']);
    final freeDelivery = overview['freeDeliveryCandidates'] ?? 0;
    final podHold = overview['podHoldCount'] ?? 0;
    final manualReview = overview['manualReviewCount'] ?? 0;
    final thirdParty = overview['thirdPartyCandidateCount'] ?? 0;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF101826 : AppTheme.colorFFF8FAFC,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.06)
              : AppTheme.black.withValues(alpha: 0.06),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 820;
          final stats = Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _BillingSignal(
                icon: Icons.local_shipping_rounded,
                label: 'Free-delivery review',
                value: freeDelivery.toString(),
                accent: AppTheme.colorFF2563EB,
                isDark: isDark,
              ),
              _BillingSignal(
                icon: Icons.fact_check_rounded,
                label: 'POD holds',
                value: podHold.toString(),
                accent: AppTheme.colorFFF59E0B,
                isDark: isDark,
              ),
              _BillingSignal(
                icon: Icons.manage_search_rounded,
                label: 'Manual reviews',
                value: manualReview.toString(),
                accent: AppTheme.colorFFEF4444,
                isDark: isDark,
              ),
              _BillingSignal(
                icon: Icons.hub_rounded,
                label: '3rd-party routes',
                value: thirdParty.toString(),
                accent: AppTheme.colorFF7C3AED,
                isDark: isDark,
              ),
            ],
          );

          final narrative = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Billing command center',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: isDark ? AppTheme.white : AppTheme.colorFF111827,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Invoices now surface ₱100,000 free-delivery eligibility, POD collection holds, and third-party pass-through reviews before finance sends or collects.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: isDark ? AppTheme.white70 : AppTheme.colorFF64748B,
                ),
              ),
              const SizedBox(height: 12),
              _PolicyLine(
                text:
                    policy['freeDeliveryRule']?.toString() ??
                    'Free-delivery candidates require order value and distance review.',
                isDark: isDark,
              ),
              _PolicyLine(
                text:
                    policy['podRule']?.toString() ??
                    'POD evidence gates collection readiness.',
                isDark: isDark,
              ),
              _PolicyLine(
                text:
                    policy['thirdPartyRule']?.toString() ??
                    'Third-party delivery costs stay visible for client pass-through.',
                isDark: isDark,
              ),
            ],
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [narrative, const SizedBox(height: 14), stats],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: narrative),
              const SizedBox(width: 18),
              Expanded(flex: 4, child: stats),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFilters(bool isDark, List<Map<String, dynamic>> invoices) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF141924 : AppTheme.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.06)
              : AppTheme.black.withValues(alpha: 0.06),
        ),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 320,
            child: TextField(
              onChanged: (value) => setState(() => _search = value),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: 'Search invoice, client, or trip ID',
                filled: true,
                fillColor: isDark
                    ? AppTheme.colorFF0E1420
                    : AppTheme.colorFFF8FAFC,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'all', label: Text('All')),
              ButtonSegment(value: 'draft', label: Text('Draft')),
              ButtonSegment(value: 'approved', label: Text('Approved')),
              ButtonSegment(value: 'rejected', label: Text('Rejected')),
              ButtonSegment(value: 'issued', label: Text('Issued')),
              ButtonSegment(value: 'paid', label: Text('Paid')),
              ButtonSegment(value: 'overdue', label: Text('Overdue')),
              ButtonSegment(value: 'voided', label: Text('Voided')),
            ],
            selected: {_status},
            onSelectionChanged: (value) {
              setState(() => _status = value.first);
            },
          ),
          OutlinedButton.icon(
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _fromDate ?? DateTime.now(),
                firstDate: DateTime(2020),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (picked != null) {
                setState(() => _fromDate = picked);
              }
            },
            icon: const Icon(Icons.date_range_rounded),
            label: Text(
              _fromDate == null
                  ? 'From date'
                  : 'From ${_fromDate!.toIso8601String().substring(0, 10)}',
            ),
          ),
          OutlinedButton.icon(
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _toDate ?? DateTime.now(),
                firstDate: DateTime(2020),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (picked != null) {
                setState(() => _toDate = picked);
              }
            },
            icon: const Icon(Icons.event_available_rounded),
            label: Text(
              _toDate == null
                  ? 'To date'
                  : 'To ${_toDate!.toIso8601String().substring(0, 10)}',
            ),
          ),
          if (_fromDate != null || _toDate != null)
            TextButton(
              onPressed: () => setState(() {
                _fromDate = null;
                _toDate = null;
              }),
              child: const Text('Clear dates'),
            ),
          if (CrudPermissions.canCreate(CrudEntity.invoices))
            FilledButton.icon(
              onPressed: invoices.isEmpty
                  ? null
                  : () => _showManualInvoiceDialog(invoices, isDark),
              icon: const Icon(Icons.add_card_rounded),
              label: const Text('New Manual Invoice'),
            ),
        ],
      ),
    );
  }

  Widget _buildInvoiceTable(bool isDark, List<Map<String, dynamic>> invoices) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 600) {
          return Column(
            children: invoices
                .map(
                  (invoice) => _InvoiceCard(
                    invoice: invoice,
                    isDark: isDark,
                    onTap: () => _showInvoiceReceipt(invoice, isDark),
                  ),
                )
                .toList(),
          );
        }

        final table = Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: isDark ? AppTheme.colorFF141924 : AppTheme.white,
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            border: Border.all(
              color: isDark
                  ? AppTheme.white.withValues(alpha: 0.08)
                  : AppTheme.black.withValues(alpha: 0.08),
            ),
          ),
          child: Column(
            children: [
              _buildInvoiceTableHeader(),
              ...invoices.indexed.map(
                (entry) => _buildInvoiceTableRow(entry.$2, isDark, entry.$1),
              ),
            ],
          ),
        );

        if (constraints.maxWidth < 980) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: 1080, child: table),
          );
        }
        return table;
      },
    );
  }

  Widget _buildInvoiceTableHeader() {
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.space8),
      decoration: const BoxDecoration(
        color: AppTheme.primaryBlue,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(AppTheme.radiusLg),
          topRight: Radius.circular(AppTheme.radiusLg),
        ),
      ),
      child: const Row(
        children: [
          Expanded(flex: 10, child: _InvoiceTableHeader('INVOICE NO.')),
          Expanded(flex: 10, child: _InvoiceTableHeader('DATE')),
          Expanded(flex: 18, child: _InvoiceTableHeader('CLIENT')),
          Expanded(flex: 12, child: _InvoiceTableHeader('TRIP REFERENCE')),
          Expanded(
            flex: 10,
            child: _InvoiceTableHeader('SUBTOTAL', alignRight: true),
          ),
          Expanded(
            flex: 8,
            child: _InvoiceTableHeader('VAT', alignRight: true),
          ),
          Expanded(
            flex: 10,
            child: _InvoiceTableHeader('TOTAL', alignRight: true),
          ),
          Expanded(flex: 10, child: _InvoiceTableHeader('STATUS')),
          Expanded(flex: 12, child: _InvoiceTableHeader('ACTIONS')),
        ],
      ),
    );
  }

  Widget _buildInvoiceTableRow(
    Map<String, dynamic> invoice,
    bool isDark,
    int index,
  ) {
    final status = (invoice['status'] ?? '').toString().toLowerCase();
    final podReady = invoice['podReady'] == true;
    final editable = CrudPermissions.canEdit(CrudEntity.invoices);
    final canApprove = editable && status == 'draft' && podReady;
    final canReject = editable && {'draft', 'approved'}.contains(status);
    final canIssue = editable && status == 'approved' && podReady;
    final canMarkPaid = editable && {'issued', 'overdue'}.contains(status);
    final canMarkOverdue = editable && status == 'issued';
    final canVoid =
        CrudPermissions.canDelete(CrudEntity.invoices) &&
        !{'paid', 'voided'}.contains(status);
    final canEditOverride = editable && !{'paid', 'voided'}.contains(status);

    return InkWell(
      onTap: () => _showInvoiceReceipt(invoice, isDark),
      child: Container(
        constraints: const BoxConstraints(minHeight: 60),
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.space8,
          vertical: AppTheme.space8,
        ),
        decoration: BoxDecoration(
          color: isDark
              ? (index.isEven ? AppTheme.colorFF141924 : AppTheme.colorFF171B23)
              : (index.isEven ? AppTheme.white : AppTheme.colorFFF8FBFF),
          border: Border(
            bottom: BorderSide(
              color: isDark
                  ? AppTheme.white.withValues(alpha: 0.06)
                  : AppTheme.black.withValues(alpha: 0.06),
            ),
          ),
        ),
        child: Row(
          children: [
            _invoiceTextColumn(
              (invoice['invoiceNumber'] ?? 'INV-SYNCED').toString(),
              10,
              isDark,
              weight: FontWeight.w700,
              color: AppTheme.colorFF4B7BE5,
            ),
            _invoiceTextColumn(
              (invoice['issueDate'] ?? 'N/A').toString(),
              10,
              isDark,
            ),
            _invoiceTextColumn(
              (invoice['client'] ?? 'Unknown Client').toString(),
              18,
              isDark,
              weight: FontWeight.w600,
            ),
            _invoiceTextColumn(
              (invoice['tripId'] ?? 'N/A').toString(),
              12,
              isDark,
            ),
            _invoiceTextColumn(
              _peso(invoice['subtotalBeforeVat'] ?? invoice['subtotal']),
              10,
              isDark,
              textAlign: TextAlign.right,
            ),
            _invoiceTextColumn(
              _peso(invoice['vat'] ?? invoice['vatAmount']),
              8,
              isDark,
              textAlign: TextAlign.right,
            ),
            _invoiceTextColumn(
              _peso(invoice['totalWithVat'] ?? invoice['amount']),
              10,
              isDark,
              textAlign: TextAlign.right,
              weight: FontWeight.w800,
            ),
            Expanded(
              flex: 10,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTheme.space8,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _InvoiceStatusBadge(
                    status: (invoice['status'] ?? 'issued').toString(),
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 12,
              child: PopupMenuButton<String>(
                tooltip: 'Invoice actions',
                onSelected: (value) {
                  if (value == 'view') {
                    _showInvoiceReceipt(invoice, isDark);
                  } else if (value == 'approved') {
                    _advanceInvoiceStatus(invoice, 'approved');
                  } else if (value == 'rejected') {
                    _advanceInvoiceStatus(invoice, 'rejected');
                  } else if (value == 'issued') {
                    _advanceInvoiceStatus(invoice, 'issued');
                  } else if (value == 'paid') {
                    _advanceInvoiceStatus(invoice, 'paid');
                  } else if (value == 'overdue') {
                    _advanceInvoiceStatus(invoice, 'overdue');
                  } else if (value == 'void') {
                    _showVoidInvoiceDialog(invoice);
                  } else if (value == 'edit') {
                    _showManualInvoiceDialog(
                      [invoice],
                      isDark,
                      existingInvoice: invoice,
                    );
                  } else if (value == 'print') {
                    _printInvoice(invoice);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'view',
                    child: Text('View Details'),
                  ),
                  if (editable)
                    PopupMenuItem(
                      value: 'approved',
                      enabled: canApprove,
                      child: const Text('Approve'),
                    ),
                  if (editable)
                    PopupMenuItem(
                      value: 'rejected',
                      enabled: canReject,
                      child: const Text('Reject'),
                    ),
                  if (editable)
                    PopupMenuItem(
                      value: 'issued',
                      enabled: canIssue,
                      child: const Text('Issue'),
                    ),
                  if (editable)
                    PopupMenuItem(
                      value: 'paid',
                      enabled: canMarkPaid,
                      child: const Text('Mark Paid'),
                    ),
                  if (editable)
                    PopupMenuItem(
                      value: 'overdue',
                      enabled: canMarkOverdue,
                      child: const Text('Mark Overdue'),
                    ),
                  if (editable)
                    PopupMenuItem(
                      value: 'edit',
                      enabled: canEditOverride,
                      child: const Text('Edit Invoice'),
                    ),
                  if (CrudPermissions.canDelete(CrudEntity.invoices))
                    PopupMenuItem(
                      value: 'void',
                      enabled: canVoid,
                      child: const Text('Void'),
                    ),
                  const PopupMenuItem(value: 'print', child: Text('Print')),
                ],
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('Manage'),
                    SizedBox(width: AppTheme.space4),
                    Icon(Icons.more_vert_rounded, size: 18),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _invoiceTextColumn(
    String value,
    int flex,
    bool isDark, {
    TextAlign textAlign = TextAlign.left,
    FontWeight weight = FontWeight.w500,
    Color? color,
  }) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppTheme.space8),
        child: Text(
          value,
          textAlign: textAlign,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: weight,
            color: color ?? (isDark ? AppTheme.white : AppTheme.colorFF18212F),
          ),
        ),
      ),
    );
  }

  Widget _receiptRow(
    String label,
    String value,
    bool isDark, {
    bool emphasized = false,
    bool prominent = false,
    bool withBottomSpacing = true,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: withBottomSpacing ? 8 : 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: emphasized ? 13 : 12,
                fontWeight: emphasized ? FontWeight.w700 : FontWeight.w600,
                color: isDark ? AppTheme.white70 : AppTheme.colorFF64748B,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: prominent ? 16 : 13,
              fontWeight: prominent ? FontWeight.w900 : FontWeight.w800,
              color: prominent
                  ? AppTheme.colorFF10B981
                  : (isDark ? AppTheme.white : AppTheme.colorFF18212F),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBillingScopeNotice(
    bool isDark,
    Map<String, dynamic> contextData,
  ) {
    final note =
        contextData['note']?.toString() ??
        'GeoTab subscriptions, monthly fees, onboarding, activation, overtime, and contract fees are managed through the Pioneer ERP system separately.';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF101826 : AppTheme.colorFFF8FAFC,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.08)
              : AppTheme.black.withValues(alpha: 0.08),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppTheme.colorFF1A3A6B.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.receipt_long_rounded,
              color: AppTheme.colorFF4B7BE5,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Delivery Trip Billing',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    color: isDark ? AppTheme.white : AppTheme.colorFF111827,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'PioneerPath covers delivery trip charges only. $note',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: isDark ? AppTheme.white70 : AppTheme.colorFF64748B,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _receiptPill(String label, String value, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF141924 : AppTheme.colorFFF8FAFC,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.06)
              : AppTheme.black.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: AppTheme.colorFF4B7BE5,
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

  Widget _referenceField(
    bool isDark, {
    required TextEditingController controller,
    required String label,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      style: TextStyle(
        fontSize: 13,
        color: isDark ? AppTheme.white : AppTheme.colorFF111827,
      ),
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        filled: true,
        fillColor: isDark
            ? AppTheme.white.withValues(alpha: 0.04)
            : AppTheme.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: isDark
                ? AppTheme.white.withValues(alpha: 0.08)
                : AppTheme.black.withValues(alpha: 0.08),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: isDark
                ? AppTheme.white.withValues(alpha: 0.08)
                : AppTheme.black.withValues(alpha: 0.08),
          ),
        ),
      ),
    );
  }
}

class _BillingKpiCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color accent;
  final bool isDark;

  const _BillingKpiCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.accent,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppTheme.dashboardKpiPadding),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF141924 : AppTheme.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusXl),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  style: TextStyle(
                    fontSize: AppTheme.dashboardKpiLabelSize,
                    fontWeight: FontWeight.w700,
                    color: accent,
                  ),
                ),
              ),
              Icon(icon, color: accent, size: AppTheme.dashboardKpiIconSize),
            ],
          ),
          const SizedBox(height: AppTheme.space16),
          Text(
            value,
            style: TextStyle(
              fontSize: AppTheme.dashboardKpiValueSize,
              fontWeight: FontWeight.w800,
              color: isDark ? AppTheme.white : AppTheme.colorFF18212F,
            ),
          ),
          const SizedBox(height: AppTheme.space6),
          Text(
            'Delivery trip invoices',
            style: TextStyle(
              fontSize: AppTheme.dashboardSecondarySize,
              color: isDark ? AppTheme.white60 : AppTheme.colorFF64748B,
            ),
          ),
        ],
      ),
    );
  }
}

class _BillingSignal extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color accent;
  final bool isDark;

  const _BillingSignal({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 176,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: isDark ? 0.14 : 0.09),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Icon(icon, color: accent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: isDark ? AppTheme.white : AppTheme.colorFF111827,
                  ),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppTheme.white70 : AppTheme.colorFF64748B,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PolicyLine extends StatelessWidget {
  final String text;
  final bool isDark;

  const _PolicyLine({required this.text, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.verified_rounded,
            size: 15,
            color: AppTheme.colorFF10B981,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: isDark ? AppTheme.white60 : AppTheme.colorFF64748B,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AssuranceChip extends StatelessWidget {
  final String label;
  final String value;
  final bool isDark;

  const _AssuranceChip({
    required this.label,
    required this.value,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final normalized = value.toLowerCase();
    final color =
        normalized.contains('verified') || normalized.contains('clear')
        ? AppTheme.colorFF10B981
        : normalized.contains('review') ||
              normalized.contains('required') ||
              normalized.contains('candidate')
        ? AppTheme.colorFFF59E0B
        : AppTheme.colorFF4B7BE5;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}

class _StatusDotPill extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusDotPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _InvoiceCard extends StatelessWidget {
  final Map<String, dynamic> invoice;
  final bool isDark;
  final VoidCallback onTap;

  const _InvoiceCard({
    required this.invoice,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final status = (invoice['status'] ?? 'sent').toString().toLowerCase();
    final accent = switch (status) {
      'draft' => AppTheme.colorFF94A3B8,
      'approved' => AppTheme.colorFF4B7BE5,
      'rejected' => AppTheme.colorFFEF4444,
      'issued' || 'sent' => AppTheme.colorFFF59E0B,
      'paid' => AppTheme.colorFF10B981,
      'overdue' => AppTheme.colorFFEF4444,
      'voided' => AppTheme.colorFF64748B,
      _ => AppTheme.colorFFF59E0B,
    };
    final podReady = invoice['podReady'] == true;
    final manualReview = invoice['manualReviewRequired'] == true;
    final pricingModel =
        (invoice['pricingModel'] ?? 'Distance, fuel, and service charge')
            .toString();
    final decision =
        (invoice['billingDecision'] ?? 'Ready for normal invoice collection.')
            .toString();

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.colorFF141924 : AppTheme.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: isDark
                ? AppTheme.white.withValues(alpha: 0.06)
                : AppTheme.black.withValues(alpha: 0.06),
          ),
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
                        (invoice['invoiceNumber'] ?? 'INV-SYNCED').toString(),
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          color: isDark
                              ? AppTheme.white
                              : AppTheme.colorFF18212F,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        (invoice['client'] ?? 'Unknown Client').toString(),
                        style: TextStyle(
                          color: isDark
                              ? AppTheme.white70
                              : AppTheme.colorFF475569,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    status.toUpperCase(),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: accent,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark
                    ? AppTheme.white.withValues(alpha: 0.04)
                    : AppTheme.colorFFF8FAFC,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Container(
                    width: 6,
                    height: 46,
                    decoration: BoxDecoration(
                      color: manualReview
                          ? AppTheme.colorFFF59E0B
                          : AppTheme.colorFF10B981,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          pricingModel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                            color: isDark
                                ? AppTheme.white
                                : AppTheme.colorFF18212F,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          decision,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? AppTheme.white60
                                : AppTheme.colorFF64748B,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  _StatusDotPill(
                    label: podReady ? 'POD READY' : 'POD HOLD',
                    color: podReady
                        ? AppTheme.colorFF10B981
                        : AppTheme.colorFFF59E0B,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _dataPill(
                  'Trip',
                  (invoice['tripId'] ?? 'N/A').toString(),
                  accent,
                ),
                _dataPill(
                  'Issue',
                  (invoice['issueDate'] ?? 'N/A').toString(),
                  accent,
                ),
                _dataPill(
                  'Due',
                  (invoice['dueDate'] ?? 'N/A').toString(),
                  accent,
                ),
                _dataPill(
                  'Amount',
                  _peso(invoice['totalWithVat'] ?? invoice['amount']),
                  accent,
                ),
              ],
            ),
            if (_hasReference(invoice)) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if ((invoice['erpReference'] ?? '').toString().isNotEmpty)
                    _dataPill(
                      'ERP',
                      (invoice['erpReference'] ?? '').toString(),
                      AppTheme.colorFF4B7BE5,
                    ),
                  if ((invoice['poNumber'] ?? '').toString().isNotEmpty)
                    _dataPill(
                      'PO',
                      (invoice['poNumber'] ?? '').toString(),
                      AppTheme.colorFF10B981,
                    ),
                  if ((invoice['drNumber'] ?? '').toString().isNotEmpty)
                    _dataPill(
                      'DR',
                      (invoice['drNumber'] ?? '').toString(),
                      AppTheme.colorFFF59E0B,
                    ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            Text(
              '${invoice['origin'] ?? 'Trip start'} -> ${invoice['destination'] ?? 'Trip stop'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: isDark ? AppTheme.white60 : AppTheme.colorFF64748B,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Base ${_peso(invoice['baseRate'])} - Distance ${_peso(invoice['distanceCost'])} - Fuel ${_peso(invoice['fuelCost'])}',
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: isDark ? AppTheme.white54 : AppTheme.colorFF94A3B8,
              ),
            ),
            const SizedBox(height: 12),
            const Row(
              children: [
                Icon(
                  Icons.receipt_long_rounded,
                  size: 16,
                  color: AppTheme.colorFF4B7BE5,
                ),
                SizedBox(width: 6),
                Text(
                  'Tap to view invoice receipt',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.colorFF4B7BE5,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _dataPill(String label, String value, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: accent,
        ),
      ),
    );
  }

  bool _hasReference(Map<String, dynamic> invoice) {
    return (invoice['erpReference'] ?? '').toString().isNotEmpty ||
        (invoice['poNumber'] ?? '').toString().isNotEmpty ||
        (invoice['drNumber'] ?? '').toString().isNotEmpty;
  }
}

class _InvoiceTableHeader extends StatelessWidget {
  final String text;
  final bool alignRight;

  const _InvoiceTableHeader(this.text, {this.alignRight = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.space8),
      child: Text(
        text,
        textAlign: alignRight ? TextAlign.right : TextAlign.left,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AppTheme.white,
        ),
      ),
    );
  }
}

class _InvoiceStatusBadge extends StatelessWidget {
  final String status;

  const _InvoiceStatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final normalized = status.trim().toLowerCase();
    final display = switch (normalized) {
      'paid' => 'Paid',
      'approved' => 'Approved',
      'rejected' => 'Rejected',
      'issued' || 'sent' => 'Unpaid',
      'overdue' => 'Overdue',
      'draft' => 'Draft',
      'voided' => 'Voided',
      _ => status,
    };
    final color = switch (normalized) {
      'paid' => AppTheme.colorFF10B981,
      'approved' => AppTheme.colorFF4B7BE5,
      'rejected' => AppTheme.colorFFEF4444,
      'issued' || 'sent' => AppTheme.pioneerRed,
      'overdue' => AppTheme.colorFF7F1D1D,
      'draft' => AppTheme.colorFF64748B,
      'voided' => AppTheme.colorFF94A3B8,
      _ => AppTheme.colorFF64748B,
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space10,
        vertical: AppTheme.space6,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      ),
      child: Text(
        display,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color,
          decoration: normalized == 'voided'
              ? TextDecoration.lineThrough
              : TextDecoration.none,
          decorationColor: color,
        ),
      ),
    );
  }
}

class _ReceiptSection extends StatelessWidget {
  final String title;
  final bool isDark;
  final Widget child;

  const _ReceiptSection({
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

class _BillingEmptyState extends StatelessWidget {
  final bool isDark;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onTap;

  const _BillingEmptyState({
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
              Icons.receipt_long_rounded,
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

Map<String, dynamic> _mapOf(dynamic raw) {
  if (raw is! Map) return {};
  return raw.map((key, value) => MapEntry(key.toString(), value));
}

List<Map<String, dynamic>> _listOfMaps(dynamic raw) {
  if (raw is! List) return [];
  return raw
      .whereType<Map>()
      .map((item) => item.map((key, value) => MapEntry(key.toString(), value)))
      .toList();
}

String _peso(dynamic value) {
  final amount = value is num
      ? value.toDouble()
      : double.tryParse(
              (value ?? '').toString().replaceAll(RegExp(r'[^0-9.\-]'), ''),
            ) ??
            0;
  return '₱${amount.toStringAsFixed(2)}';
}

String _escapeHtml(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
}

String _plainAmount(dynamic value) {
  if (value == null) return '';
  if (value is num) return value.toStringAsFixed(2);
  return value.toString().replaceAll(RegExp(r'[^0-9.\-]'), '').trim();
}

double _amountValue(String value) {
  return double.tryParse(value.replaceAll(RegExp(r'[^0-9.\-]'), '')) ?? 0;
}
