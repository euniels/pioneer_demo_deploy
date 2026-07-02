import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/backend_api.dart';
import '../services/crud_permissions.dart';
import '../services/fleet_sync_service.dart';
import '../services/soa_exporter.dart';
import '../utils/form_validation.dart';
import '../utils/workflow_status_helper.dart';
import '../widgets/admin_page_controls.dart';
import '../widgets/dashboard_layout.dart';
import '../widgets/page_skeletons.dart';
import '../widgets/signature_pad.dart';
import '../theme/app_theme.dart';

class BillingPage extends StatefulWidget {
  const BillingPage({super.key});

  @override
  State<BillingPage> createState() => _BillingPageState();
}

class _BillingPageState extends State<BillingPage> {
  late Future<Map<String, dynamic>> _future;
  late Future<Map<String, dynamic>> _coverageFuture;
  final TextEditingController _searchController = TextEditingController();
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
  void dispose() {
    _searchController.dispose();
    super.dispose();
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
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                _buildFilters(isDark, invoices),
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 28, 28, 0),
                  child: Column(
                    children: [
                      _buildSummary(isDark, overview),
                      const SizedBox(height: 16),
                      _buildBillingScopeNotice(isDark, contextData),
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
                      const SizedBox(height: 14),
                      _buildVehicleSubscriptionCoverage(isDark),
                    ],
                  ),
                ),
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
                        _receiptPill(
                          'Stage',
                          (invoice['billingStageLabel'] ??
                                  invoice['collectionReadiness'] ??
                                  'Draft estimate')
                              .toString(),
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
                                  label: 'SO / ERP Reference No.',
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
                            'POD review status',
                            (invoice['podReviewStatus'] ??
                                    invoice['podStatus'] ??
                                    'missing')
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
                          if (_stringList(
                            invoice['blockingReasons'],
                          ).isNotEmpty) ...[
                            Text(
                              'Blocking reasons',
                              style: AppTheme.getDashboardBodyStyle(
                                context,
                              ).copyWith(fontWeight: FontWeight.w900),
                            ),
                            const SizedBox(height: AppTheme.space8),
                            ..._stringList(invoice['blockingReasons']).map(
                              (reason) => _receiptRow('Hold', reason, isDark),
                            ),
                          ],
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
    final podStatus = (invoice['podReviewStatus'] ?? invoice['podStatus'] ?? '')
        .toString()
        .toLowerCase();
    final podReady = invoice['podReady'] == true;
    final editable = CrudPermissions.canEdit(CrudEntity.invoices);
    final canVoid =
        CrudPermissions.canDelete(CrudEntity.invoices) &&
        !{'paid', 'voided'}.contains(status);
    final canReviewPod = editable && podStatus == 'submitted';
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
            onPressed: canReviewPod
                ? () => _reviewPod(invoice, approved: true)
                : null,
            icon: const Icon(Icons.verified_user_rounded),
            label: const Text('Verify POD'),
          ),
          OutlinedButton.icon(
            onPressed: canReviewPod
                ? () => _reviewPod(invoice, approved: false)
                : null,
            icon: const Icon(Icons.assignment_late_rounded),
            label: const Text('Reject POD'),
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
                } else if (value == 'verify_pod') {
                  _reviewPod(invoice, approved: true);
                } else if (value == 'reject_pod') {
                  _reviewPod(invoice, approved: false);
                } else if (value == 'edit') {
                  _showManualInvoiceDialog(
                    [invoice],
                    isDark,
                    existingInvoice: invoice,
                  );
                } else if (value == 'manual_toll') {
                  _showManualTollDialog(invoice, isDark);
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'overdue',
                  enabled: canMarkOverdue,
                  child: const Text('Mark Overdue'),
                ),
                PopupMenuItem(
                  value: 'verify_pod',
                  enabled: canReviewPod,
                  child: const Text('Verify POD'),
                ),
                PopupMenuItem(
                  value: 'reject_pod',
                  enabled: canReviewPod,
                  child: const Text('Reject POD'),
                ),
                PopupMenuItem(
                  value: 'edit',
                  enabled: canEditOverride,
                  child: const Text('Edit Invoice'),
                ),
                PopupMenuItem(
                  value: 'manual_toll',
                  enabled: canEditOverride,
                  child: const Text('Add Toll Evidence'),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (row['label'] ?? 'Charge').toString(),
                        style: AppTheme.getDashboardBodyStyle(context),
                      ),
                      const SizedBox(height: AppTheme.space6),
                      Wrap(
                        spacing: AppTheme.space6,
                        runSpacing: AppTheme.space6,
                        children: [
                          _evidenceChip(
                            (row['source'] ?? 'manual').toString(),
                            isDark,
                          ),
                          _evidenceChip(
                            (row['confidence'] ?? 'manual').toString(),
                            isDark,
                          ),
                        ],
                      ),
                      if ((row['note'] ?? '').toString().trim().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: AppTheme.space4),
                          child: Text(
                            (row['note'] ?? '').toString(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppTheme.getDashboardSecondaryStyle(context)
                                .copyWith(
                                  color: isDark
                                      ? AppTheme.white60
                                      : AppTheme.colorFF64748B,
                                ),
                          ),
                        ),
                    ],
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

  Widget _evidenceChip(String value, bool isDark) {
    final normalized = value
        .replaceAll('_', ' ')
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
        .join(' ');
    final lower = value.toLowerCase();
    final color =
        lower.contains('exact') ||
            lower.contains('geotab') ||
            lower.contains('confirmed')
        ? AppTheme.colorFF10B981
        : lower.contains('estimate') ||
              lower.contains('inferred') ||
              lower.contains('toll')
        ? AppTheme.colorFFF59E0B
        : AppTheme.primaryBlue;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space8,
        vertical: AppTheme.space4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        normalized.isEmpty ? 'Manual' : normalized,
        style: AppTheme.getDashboardSecondaryStyle(
          context,
        ).copyWith(color: color, fontWeight: FontWeight.w800),
      ),
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
    final evidence = _financialLineItems(invoice)
        .map(
          (row) =>
              '<li>${_escapeHtml((row['label'] ?? 'Charge').toString())}: '
              '${_escapeHtml((row['source'] ?? 'manual').toString())}, '
              '${_escapeHtml((row['confidence'] ?? 'manual').toString())}</li>',
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
      <h3>Charge Evidence</h3>
      <ul>$evidence</ul>
      <h3>ERP Reference Details</h3>
      <p>SO / ERP Reference: ${_escapeHtml((invoice['erpReference'] ?? '').toString())}<br>
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
              width: math.min(MediaQuery.of(context).size.width - 48, 520),
              child: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: selectedTripId,
                        isExpanded: true,
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
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final stack = constraints.maxWidth < 430;
                          final fields = [
                            _amountField(baseController, 'Base charge'),
                            _amountField(distanceController, 'Distance charge'),
                          ];
                          if (stack) {
                            return Column(
                              children: [
                                fields[0],
                                const SizedBox(height: 10),
                                fields[1],
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(child: fields[0]),
                              const SizedBox(width: 10),
                              Expanded(child: fields[1]),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 10),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final stack = constraints.maxWidth < 430;
                          final fields = [
                            _amountField(fuelController, 'Fuel estimate'),
                            _amountField(surchargeController, 'Surcharges'),
                          ];
                          if (stack) {
                            return Column(
                              children: [
                                fields[0],
                                const SizedBox(height: 10),
                                fields[1],
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(child: fields[0]),
                              const SizedBox(width: 10),
                              Expanded(child: fields[1]),
                            ],
                          );
                        },
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
      builder: (context) => Dialog(
        backgroundColor: AppTheme.transparent,
        child: _BillingDialogFrame(
          icon: Icons.calculate_rounded,
          title: 'Confirm recalculation',
          subtitle: 'Trip $tripId',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dialogAmountCompareRow(
                context,
                'Current amount',
                _peso(
                  before['totalWithVat'] ??
                      invoice['totalWithVat'] ??
                      invoice['amount'],
                ),
              ),
              const SizedBox(height: AppTheme.space10),
              _dialogAmountCompareRow(
                context,
                'Recalculated amount',
                _peso(
                  after['totalWithVat'] ??
                      updated['totalWithVat'] ??
                      updated['amount'],
                ),
                emphasized: true,
              ),
            ],
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

  Future<void> _reviewPod(
    Map<String, dynamic> invoice, {
    required bool approved,
  }) async {
    final tripId = (invoice['tripId'] ?? '').toString();
    if (tripId.isEmpty) {
      return;
    }

    final noteController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    var saving = false;
    final title = approved ? 'Verify POD' : 'Reject POD';
    final message = approved
        ? 'Confirm that the delivery proof, recipient, and signature/attachment are valid. Billing will move to accounting review after verification.'
        : 'Reject this POD and explain what must be corrected before billing can proceed.';

    try {
      await showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => Dialog(
            backgroundColor: AppTheme.transparent,
            child: _BillingDialogFrame(
              icon: approved
                  ? Icons.verified_user_rounded
                  : Icons.assignment_late_rounded,
              title: title,
              subtitle: 'Trip $tripId',
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(message, style: AppTheme.getBodyStyle(context)),
                    const SizedBox(height: AppTheme.space12),
                    TextFormField(
                      controller: noteController,
                      maxLines: 3,
                      decoration: InputDecoration(
                        labelText: approved
                            ? 'Review note'
                            : 'Required rejection reason',
                        alignLabelWithHint: true,
                      ),
                      validator: approved
                          ? null
                          : (value) => FormValidation.requiredField(
                              'Rejection reason',
                              value,
                            ),
                    ),
                  ],
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
                          setDialogState(() => saving = true);
                          try {
                            await BackendApiService.reviewProofOfDelivery(
                              tripId,
                              status: approved ? 'verified' : 'rejected',
                              reviewNote: noteController.text.trim(),
                            );
                            if (!context.mounted) return;
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  approved
                                      ? 'POD verified. Billing is ready for review.'
                                      : 'POD rejected. Billing remains on hold.',
                                ),
                              ),
                            );
                            _reload();
                          } catch (error) {
                            if (!context.mounted) return;
                            setDialogState(() => saving = false);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  FormValidation.backendError(
                                    error,
                                    'POD review could not be saved.',
                                  ),
                                ),
                              ),
                            );
                          }
                        },
                  icon: saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          approved
                              ? Icons.check_circle_rounded
                              : Icons.cancel_rounded,
                        ),
                  label: Text(saving ? 'Saving...' : title),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      noteController.dispose();
    }
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
          ? (invoice['billingDecision'] ??
                    'Final charge reviewed against GPS/POD evidence.')
                .toString()
          : '',
    );
    final paymentDateController = TextEditingController(
      text: DateTime.now().toIso8601String().substring(0, 10),
    );
    final formKey = GlobalKey<FormState>();
    final signatureKey = GlobalKey<SignaturePadState>();
    var saving = false;
    var signatureEmpty = true;

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
    final requiresSignature = const {
      'approved',
      'issued',
      'paid',
    }.contains(status);

    try {
      await showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => Dialog(
            backgroundColor: AppTheme.transparent,
            child: _BillingDialogFrame(
              icon: switch (status) {
                'approved' => Icons.fact_check_rounded,
                'rejected' => Icons.report_gmailerrorred_rounded,
                'issued' => Icons.receipt_long_rounded,
                'paid' => Icons.verified_rounded,
                'overdue' => Icons.schedule_rounded,
                _ => Icons.edit_note_rounded,
              },
              title: title,
              subtitle:
                  'Transition ${current.toUpperCase()} to ${status.toUpperCase()} for trip $tripId.',
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (requiresText)
                      TextFormField(
                        controller: noteController,
                        maxLines: status == 'paid' ? 1 : 3,
                        decoration: InputDecoration(
                          labelText: fieldLabel,
                          alignLabelWithHint: status != 'paid',
                        ),
                        validator: (value) =>
                            FormValidation.requiredField(fieldLabel, value),
                      ),
                    if (status == 'paid') ...[
                      const SizedBox(height: AppTheme.space12),
                      TextFormField(
                        controller: paymentDateController,
                        decoration: const InputDecoration(
                          labelText: 'Payment date',
                          helperText: 'Use YYYY-MM-DD.',
                        ),
                      ),
                    ],
                    if (status == 'overdue')
                      Text(
                        'This keeps the invoice collectible and records an overdue audit timestamp.',
                        style: AppTheme.getBodyStyle(context),
                      ),
                    if (requiresSignature) ...[
                      const SizedBox(height: 14),
                      _billingProofPanel(
                        title: 'Finance digital signature',
                        subtitle:
                            'Sign to confirm this billing action was reviewed and authorized.',
                        child: Column(
                          children: [
                            SignaturePad(
                              key: signatureKey,
                              height: 126,
                              onChanged: (isEmpty) {
                                setDialogState(() => signatureEmpty = isEmpty);
                              },
                            ),
                            const SizedBox(height: AppTheme.space8),
                            Row(
                              children: [
                                Icon(
                                  signatureEmpty
                                      ? Icons.edit_off_rounded
                                      : Icons.verified_rounded,
                                  size: 16,
                                  color: signatureEmpty
                                      ? AppTheme.colorFFF39C12
                                      : AppTheme.colorFF27AE60,
                                ),
                                const SizedBox(width: AppTheme.space6),
                                Expanded(
                                  child: Text(
                                    signatureEmpty
                                        ? 'Signature required before confirming.'
                                        : 'Signature captured.',
                                    style: AppTheme.getDashboardSecondaryStyle(
                                      context,
                                    ),
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: () =>
                                      signatureKey.currentState?.clear(),
                                  icon: const Icon(Icons.refresh_rounded),
                                  label: const Text('Clear'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
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
                          if (requiresSignature && signatureEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Please add a finance digital signature first.',
                                ),
                              ),
                            );
                            return;
                          }
                          final payload = <String, dynamic>{'status': status};
                          if (requiresText) {
                            payload[fieldKey] = noteController.text.trim();
                          }
                          if (status == 'paid') {
                            payload['paymentDate'] = paymentDateController.text
                                .trim();
                          }
                          if (requiresSignature) {
                            payload['billingSignatureDataUrl'] = jsonEncode({
                              'strokes':
                                  signatureKey.currentState?.exportStrokes() ??
                                  const [],
                              'signedAt': DateTime.now().toIso8601String(),
                              'status': status,
                            });
                            payload['billingSignatureRole'] = status == 'paid'
                                ? 'finance'
                                : 'admin';
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
        builder: (context) => Dialog(
          backgroundColor: AppTheme.transparent,
          child: _BillingDialogFrame(
            icon: Icons.block_rounded,
            title: 'Void invoice',
            subtitle: 'Trip $tripId',
            child: TextField(
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
                      const SnackBar(
                        content: Text('A void reason is required.'),
                      ),
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
        ),
      );
    } finally {
      reasonController.dispose();
    }
  }

  Widget _billingProofPanel({
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppTheme.space12),
      decoration: BoxDecoration(
        color: isDark
            ? AppTheme.white.withValues(alpha: 0.04)
            : AppTheme.colorFFF8FAFC,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.09)
              : const Color(0xFFE2E8F0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: AppTheme.getDashboardBodyStyle(
              context,
            ).copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: AppTheme.space4),
          Text(subtitle, style: AppTheme.getDashboardSecondaryStyle(context)),
          const SizedBox(height: AppTheme.space10),
          child,
        ],
      ),
    );
  }

  Future<void> _showManualTollDialog(
    Map<String, dynamic> invoice,
    bool isDark,
  ) async {
    final tripId = (invoice['tripId'] ?? '').toString();
    final amountController = TextEditingController();
    final descriptionController = TextEditingController(text: 'Toll fee');
    final receiptController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    var saving = false;
    String? proofFileName;
    String? proofFileType;
    String? proofDataUrl;

    Future<void> pickTollProof(
      void Function(void Function()) setDialogState,
    ) async {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'pdf'],
        withData: true,
      );
      final file = result?.files.single;
      if (file == null || file.bytes == null) {
        return;
      }
      final extension = (file.extension ?? '').toLowerCase();
      final mime = switch (extension) {
        'jpg' || 'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'pdf' => 'application/pdf',
        _ => 'application/octet-stream',
      };
      setDialogState(() {
        proofFileName = file.name;
        proofFileType = mime;
        proofDataUrl = 'data:$mime;base64,${base64Encode(file.bytes!)}';
      });
    }

    try {
      await showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => Dialog(
            backgroundColor: AppTheme.transparent,
            child: _BillingDialogFrame(
              icon: Icons.add_road_rounded,
              title: 'Add toll evidence',
              subtitle: 'Trip $tripId',
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _amountField(amountController, 'Toll amount'),
                    const SizedBox(height: AppTheme.space12),
                    TextFormField(
                      controller: descriptionController,
                      decoration: const InputDecoration(
                        labelText: 'Description',
                        helperText:
                            'Example: NLEX/SLEX toll receipt or route toll pass-through.',
                      ),
                    ),
                    const SizedBox(height: AppTheme.space12),
                    TextFormField(
                      controller: receiptController,
                      decoration: const InputDecoration(
                        labelText: 'Receipt reference',
                        helperText:
                            'Optional receipt number or document reference.',
                      ),
                    ),
                    const SizedBox(height: AppTheme.space12),
                    _billingProofPanel(
                      title: 'Toll receipt proof',
                      subtitle:
                          'Attach the toll receipt image or PDF before saving.',
                      child: Row(
                        children: [
                          Icon(
                            proofDataUrl == null
                                ? Icons.upload_file_rounded
                                : Icons.verified_rounded,
                            color: proofDataUrl == null
                                ? AppTheme.colorFFF39C12
                                : AppTheme.colorFF27AE60,
                          ),
                          const SizedBox(width: AppTheme.space10),
                          Expanded(
                            child: Text(
                              proofFileName ?? 'No toll proof attached yet',
                              overflow: TextOverflow.ellipsis,
                              style: AppTheme.getDashboardBodyStyle(context),
                            ),
                          ),
                          const SizedBox(width: AppTheme.space8),
                          OutlinedButton.icon(
                            onPressed: saving
                                ? null
                                : () => pickTollProof(setDialogState),
                            icon: const Icon(Icons.attach_file_rounded),
                            label: Text(
                              proofDataUrl == null ? 'Attach' : 'Replace',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
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
                          final amount = _amountValue(amountController.text);
                          if (amount <= 0) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Toll amount must be greater than zero.',
                                ),
                              ),
                            );
                            return;
                          }
                          if (proofDataUrl == null ||
                              proofFileName == null ||
                              proofFileType == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Attach a toll receipt image or PDF first.',
                                ),
                              ),
                            );
                            return;
                          }
                          setDialogState(() => saving = true);
                          try {
                            await BackendApiService.addBillingManualToll(
                              tripId,
                              {
                                'amount': amount,
                                'description': descriptionController.text
                                    .trim(),
                                'receiptReference': receiptController.text
                                    .trim(),
                                'proofFileName': proofFileName,
                                'proofFileType': proofFileType,
                                'proofDataUrl': proofDataUrl,
                                'source': 'manual',
                              },
                            );
                            if (!mounted) return;
                            Navigator.pop(context);
                            _reload();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Manual toll evidence added.'),
                              ),
                            );
                          } catch (error) {
                            setDialogState(() => saving = false);
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(error.toString())),
                            );
                          }
                        },
                  icon: saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_road_rounded),
                  label: const Text('Save Toll'),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      amountController.dispose();
      descriptionController.dispose();
      receiptController.dispose();
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

  Widget _dialogAmountCompareRow(
    BuildContext context,
    String label,
    String value, {
    bool emphasized = false,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppTheme.space12),
      decoration: BoxDecoration(
        color: AppTheme.surfacePanel(context),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppTheme.borderDefault(context)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: AppTheme.getCaptionStyle(context).copyWith(
                fontWeight: FontWeight.w800,
                color: AppTheme.textMuted(context),
              ),
            ),
          ),
          Text(
            value,
            style:
                AppTheme.getHeadingStyle(
                  context,
                  fontSize: emphasized ? 20 : 17,
                ).copyWith(
                  color: emphasized
                      ? AppTheme.colorFF10B981
                      : AppTheme.textPrimary(context),
                ),
          ),
        ],
      ),
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
          child: Theme(
            data: Theme.of(
              context,
            ).copyWith(dividerColor: AppTheme.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              leading: const Icon(
                Icons.fact_check_rounded,
                size: 18,
                color: AppTheme.colorFF4B7BE5,
              ),
              title: Text(
                'Vehicle Subscription Coverage Report',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  color: isDark ? AppTheme.white : AppTheme.colorFF111827,
                ),
              ),
              subtitle: Text(
                'ERP reference only. This does not create a PioneerPath invoice.',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? AppTheme.white60 : AppTheme.colorFF64748B,
                ),
              ),
              children: [
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _coverageFuture =
                            BackendApiService.getVehicleSubscriptionCoverageReport(
                              forceRefresh: true,
                            );
                      });
                    },
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Refresh report'),
                  ),
                ),
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

  // ignore: unused_element
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF101826 : AppTheme.colorFFF8FAFC,
        borderRadius: BorderRadius.circular(18),
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
                  fontSize: 16,
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
              if (policy.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  [
                        policy['freeDeliveryRule'],
                        policy['podRule'],
                        policy['thirdPartyRule'],
                      ]
                      .where((item) => item != null)
                      .map((item) => item.toString())
                      .take(2)
                      .join(' '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: isDark ? AppTheme.white60 : AppTheme.colorFF64748B,
                  ),
                ),
              ],
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
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.colorFFF8FAFC,
        borderRadius: BorderRadius.circular(0),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.08)
              : AppTheme.black.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final search = AdminSearchField(
                controller: _searchController,
                onChanged: (value) => setState(() => _search = value),
                onClear: () {
                  _searchController.clear();
                  setState(() => _search = '');
                },
                hintText: 'Search invoice, client, or trip ID',
              );
              final addButton = CrudPermissions.canCreate(CrudEntity.invoices)
                  ? FilledButton.icon(
                      onPressed: invoices.isEmpty
                          ? null
                          : () => _showManualInvoiceDialog(invoices, isDark),
                      icon: const Icon(Icons.add_card_rounded),
                      label: const Text('New Manual Invoice'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(190, 52),
                        backgroundColor: AppTheme.successGreen,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    )
                  : null;

              if (constraints.maxWidth < 720) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    search,
                    if (addButton != null) ...[
                      const SizedBox(height: 10),
                      addButton,
                    ],
                  ],
                );
              }

              return Row(
                children: [
                  Expanded(child: search),
                  if (addButton != null) ...[
                    const SizedBox(width: 12),
                    addButton,
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _BillingFilterChip(
                  label: '${invoices.length} invoices shown',
                  isDark: isDark,
                ),
                const SizedBox(width: 10),
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
                const SizedBox(width: 10),
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
                const SizedBox(width: 8),
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
                if (_fromDate != null || _toDate != null) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => setState(() {
                      _fromDate = null;
                      _toDate = null;
                    }),
                    child: const Text('Clear dates'),
                  ),
                ],
              ],
            ),
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
            child: SizedBox(width: 980, child: table),
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
          Expanded(flex: 12, child: _InvoiceTableHeader('INVOICE NO.')),
          Expanded(flex: 20, child: _InvoiceTableHeader('CLIENT')),
          Expanded(flex: 14, child: _InvoiceTableHeader('TRIP REFERENCE')),
          Expanded(flex: 10, child: _InvoiceTableHeader('DUE DATE')),
          Expanded(
            flex: 12,
            child: _InvoiceTableHeader('TOTAL', alignRight: true),
          ),
          Expanded(flex: 11, child: _InvoiceTableHeader('STATUS')),
          Expanded(flex: 11, child: _InvoiceTableHeader('STAGE')),
          Expanded(flex: 10, child: _InvoiceTableHeader('ACTIONS')),
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
    final podStatus = (invoice['podReviewStatus'] ?? invoice['podStatus'] ?? '')
        .toString()
        .toLowerCase();
    final podReady = invoice['podReady'] == true;
    final editable = CrudPermissions.canEdit(CrudEntity.invoices);
    final canReviewPod = editable && podStatus == 'submitted';
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
              12,
              isDark,
              weight: FontWeight.w700,
              color: AppTheme.colorFF4B7BE5,
            ),
            _invoiceTextColumn(
              (invoice['client'] ?? 'Unknown Client').toString(),
              20,
              isDark,
              weight: FontWeight.w600,
            ),
            _invoiceTextColumn(
              (invoice['tripId'] ?? 'N/A').toString(),
              14,
              isDark,
            ),
            _invoiceTextColumn(
              (invoice['dueDate'] ?? invoice['issueDate'] ?? 'N/A').toString(),
              10,
              isDark,
            ),
            _invoiceTextColumn(
              _peso(invoice['totalWithVat'] ?? invoice['amount']),
              12,
              isDark,
              textAlign: TextAlign.right,
              weight: FontWeight.w800,
            ),
            Expanded(
              flex: 11,
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
              flex: 11,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTheme.space8,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _StatusDotPill(
                    label:
                        (invoice['billingStageLabel'] ??
                                (podReady ? 'Ready' : 'POD hold'))
                            .toString(),
                    color: _billingStageColor(invoice),
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 10,
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
                  } else if (value == 'verify_pod') {
                    _reviewPod(invoice, approved: true);
                  } else if (value == 'reject_pod') {
                    _reviewPod(invoice, approved: false);
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
                      value: 'verify_pod',
                      enabled: canReviewPod,
                      child: const Text('Verify POD'),
                    ),
                  if (editable)
                    PopupMenuItem(
                      value: 'reject_pod',
                      enabled: canReviewPod,
                      child: const Text('Reject POD'),
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

  Color _billingStageColor(Map<String, dynamic> invoice) {
    final stage = (invoice['billingStage'] ?? '').toString().toLowerCase();
    final status = (invoice['status'] ?? '').toString().toLowerCase();
    return switch (stage.isNotEmpty ? stage : status) {
      'paid' => AppTheme.colorFF10B981,
      'issued' || 'approved' || 'ready_for_review' => AppTheme.colorFF4B7BE5,
      'pod_under_review' ||
      'waiting_for_pod' ||
      'review_required' ||
      'draft_estimate' => AppTheme.colorFFF59E0B,
      'pod_rejected' || 'rejected' || 'overdue' => AppTheme.colorFFEF4444,
      'voided' => AppTheme.colorFF64748B,
      _ => AppTheme.colorFF4B7BE5,
    };
  }

  Widget _buildBillingScopeNotice(
    bool isDark,
    Map<String, dynamic> contextData,
  ) {
    final note =
        contextData['note']?.toString() ??
        'GeoTab subscriptions, monthly fees, onboarding, activation, overtime, and contract fees are managed through the Pioneer ERP system separately.';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF101826 : AppTheme.colorFFF8FAFC,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppTheme.colorFF4B7BE5.withValues(alpha: isDark ? 0.18 : 0.14),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.receipt_long_rounded,
              size: 18,
              color: AppTheme.colorFF4B7BE5,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Delivery trip billing only',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    color: isDark ? AppTheme.white : AppTheme.colorFF111827,
                  ),
                ),
                Text(
                  note,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
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

class _BillingDialogFrame extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget child;
  final List<Widget> actions;

  const _BillingDialogFrame({
    required this.icon,
    required this.title,
    required this.child,
    required this.actions,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(24);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppTheme.surfacePanel(context),
          borderRadius: radius,
          border: Border.all(color: AppTheme.borderDefault(context)),
          boxShadow: [
            BoxShadow(
              color: AppTheme.black.withValues(alpha: isDark ? 0.45 : 0.12),
              blurRadius: 26,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(22, 18, 14, 18),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppTheme.primaryBlue, AppTheme.colorFF4B7BE5],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: AppTheme.white.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(icon, color: AppTheme.white, size: 22),
                    ),
                    const SizedBox(width: AppTheme.space12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            style: AppTheme.getHeadingStyle(
                              context,
                              fontSize: 20,
                            ).copyWith(color: AppTheme.white),
                          ),
                          if (subtitle != null &&
                              subtitle!.trim().isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              subtitle!,
                              style: AppTheme.getCaptionStyle(context).copyWith(
                                color: AppTheme.white.withValues(alpha: 0.78),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.maybePop(context),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: AppTheme.white,
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(22),
                  child: child,
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 20),
                child: Wrap(
                  spacing: AppTheme.space10,
                  runSpacing: AppTheme.space10,
                  alignment: WrapAlignment.end,
                  children: actions,
                ),
              ),
            ],
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
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF111827 : AppTheme.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: isDark ? 0.08 : 0.04),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: isDark ? 0.16 : 0.1),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(icon, color: accent, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    color: accent,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w900,
                    color: isDark ? AppTheme.white : AppTheme.colorFF18212F,
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

class _BillingFilterChip extends StatelessWidget {
  final String label;
  final bool isDark;

  const _BillingFilterChip({required this.label, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: AppTheme.colorFF3498DB.withValues(alpha: isDark ? 0.13 : 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppTheme.colorFF3498DB.withValues(alpha: isDark ? 0.32 : 0.24),
        ),
      ),
      child: Center(
        child: Text(
          label,
          style: const TextStyle(
            color: AppTheme.colorFF3498DB,
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

// ignore: unused_element
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
                _dataPill(
                  'POD',
                  podReady ? 'Ready' : 'Hold',
                  podReady ? AppTheme.colorFF10B981 : AppTheme.colorFFF59E0B,
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
            const SizedBox(height: 12),
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
    final presentation = WorkflowStatusHelper.invoice(status);
    final color = presentation.color;
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
        presentation.label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color,
          decoration: presentation.strikethrough
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

List<String> _stringList(dynamic raw) {
  if (raw is! List) return [];
  return raw
      .map((item) => item.toString().trim())
      .where((item) => item.isNotEmpty)
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
