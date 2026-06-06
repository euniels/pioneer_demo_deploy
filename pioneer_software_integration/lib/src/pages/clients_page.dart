import 'package:flutter/material.dart';

import '../services/clients_store.dart';
import '../services/crud_permissions.dart';
import '../theme/app_theme.dart';
import '../utils/display_format.dart';
import '../utils/form_validation.dart';
import '../widgets/app_state_widgets.dart';
import '../widgets/dashboard_layout.dart';
import '../widgets/page_skeletons.dart';

class ClientsPage extends StatefulWidget {
  const ClientsPage({super.key});

  @override
  State<ClientsPage> createState() => _ClientsPageState();
}

class _ClientsPageState extends State<ClientsPage> {
  String _search = '';
  String _status = 'All';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    clientsNotifier.addListener(_onClientsChanged);
    _loadClients();
  }

  @override
  void dispose() {
    clientsNotifier.removeListener(_onClientsChanged);
    super.dispose();
  }

  void _onClientsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadClients({bool forceRefresh = false}) async {
    setState(() {
      _loading = clientsNotifier.value.isEmpty;
      _error = null;
    });
    try {
      await refreshClients(forceRefresh: forceRefresh);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Clients could not be refreshed.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _filteredClients {
    final query = _search.trim().toLowerCase();
    return clientsNotifier.value.where((client) {
      final status = client['status']?.toString().toLowerCase() ?? 'active';
      if (_status != 'All' && status != _status.toLowerCase()) return false;
      if (query.isEmpty) return true;
      final haystack = [
        client['companyName'],
        client['contactPersonName'],
        client['erpCustomerId'],
      ].map((value) => value?.toString().toLowerCase() ?? '').join(' ');
      return haystack.contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final canCreate = CrudPermissions.canCreate(CrudEntity.clients);
    return DashboardLayout(
      currentRoute: '/clients',
      title: 'Clients',
      subtitle:
          'Client master records, delivery billing context, and SOA links',
      actions: [
        IconButton(
          tooltip: 'Refresh clients',
          onPressed: () => _loadClients(forceRefresh: true),
          icon: const Icon(Icons.refresh_rounded),
        ),
        if (canCreate)
          FilledButton.icon(
            onPressed: () => _openClientForm(),
            icon: const Icon(Icons.add_business_rounded, size: 18),
            label: const Text('New Client'),
          ),
      ],
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const PioneerRouteSkeletonBody(routeName: '/clients');
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final clients = _filteredClients;
    final canCreate = CrudPermissions.canCreate(CrudEntity.clients);
    final canEdit = CrudPermissions.canEdit(CrudEntity.clients);
    final canDelete = CrudPermissions.canDelete(CrudEntity.clients);
    return RefreshIndicator(
      onRefresh: () => _loadClients(forceRefresh: true),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_error != null) ...[
            PioneerStateCard(
              icon: Icons.cloud_off_rounded,
              title: 'Client refresh paused',
              message: _error!,
              actionLabel: 'Retry',
              onAction: () => _loadClients(forceRefresh: true),
              tone: PioneerStateTone.warning,
            ),
            const SizedBox(height: 12),
          ],
          _ClientHeaderCard(
            clients: clientsNotifier.value,
            isDark: isDark,
            status: _status,
            onSearchChanged: (value) => setState(() => _search = value),
            onStatusChanged: (value) => setState(() => _status = value),
          ),
          const SizedBox(height: 12),
          if (clients.isEmpty)
            PioneerStateCard(
              icon: Icons.business_rounded,
              title: 'No clients found',
              message:
                  'Add client master records so dispatch, billing, and statements use the same account information.',
              actionLabel: canCreate ? 'Add your first client' : null,
              onAction: canCreate ? () => _openClientForm() : null,
            )
          else
            ...clients.map(
              (client) => _ClientCard(
                client: client,
                onView: () => _openClientDetails(client),
                onEdit: canEdit ? () => _openClientForm(client: client) : null,
                onDeactivate: canDelete && _isActive(client)
                    ? () => _confirmDeactivate(client)
                    : null,
              ),
            ),
        ],
      ),
    );
  }

  bool _isActive(Map<String, dynamic> client) {
    return (client['status']?.toString().toLowerCase() ?? 'active') == 'active';
  }

  Future<void> _openClientForm({Map<String, dynamic>? client}) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ClientFormDialog(
        client: client,
        onSave: (payload) async {
          if (client == null) {
            await createClient(payload);
          } else {
            final id = client['localId']?.toString() ?? client['id'].toString();
            await updateClient(id, payload);
          }
        },
      ),
    );
  }

  Future<void> _confirmDeactivate(Map<String, dynamic> client) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Deactivate ${formatValue(client['companyName'])}?'),
        content: const Text(
          'This keeps historical trips and invoices visible, but removes the client from new trip creation.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Deactivate'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final id = client['localId']?.toString() ?? client['id'].toString();
      await deactivateClient(id);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Client could not be deactivated.')),
      );
    }
  }

  void _openClientDetails(Map<String, dynamic> client) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.transparent,
      builder: (_) => _ClientDetailsSheet(client: client),
    );
  }
}

class _ClientHeaderCard extends StatelessWidget {
  const _ClientHeaderCard({
    required this.clients,
    required this.isDark,
    required this.status,
    required this.onSearchChanged,
    required this.onStatusChanged,
  });

  final List<Map<String, dynamic>> clients;
  final bool isDark;
  final String status;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String> onStatusChanged;

  @override
  Widget build(BuildContext context) {
    final active = clients
        .where(
          (client) => client['status']?.toString().toLowerCase() == 'active',
        )
        .length;
    final outstanding = clients.fold<double>(0, (sum, client) {
      return sum + (double.tryParse('${client['outstandingBalance']}') ?? 0);
    });
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF111827 : AppTheme.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _Metric(label: 'Active Clients', value: '$active'),
              _Metric(label: 'Client Records', value: '${clients.length}'),
              _Metric(
                label: 'Outstanding',
                value: 'PHP ${outstanding.toStringAsFixed(2)}',
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  onChanged: onSearchChanged,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded),
                    hintText: 'Search by company, contact, or ERP ID',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<String>(
                  initialValue: status,
                  items: const ['All', 'Active', 'Inactive']
                      .map(
                        (item) =>
                            DropdownMenuItem(value: item, child: Text(item)),
                      )
                      .toList(),
                  onChanged: (value) => onStatusChanged(value ?? 'All'),
                  decoration: const InputDecoration(labelText: 'Status'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: isDark
                  ? AppTheme.darkSubtleText
                  : AppTheme.lightSubtleText,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              color: isDark ? AppTheme.white : AppTheme.colorFF111827,
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _ClientCard extends StatelessWidget {
  const _ClientCard({
    required this.client,
    required this.onView,
    this.onEdit,
    this.onDeactivate,
  });

  final Map<String, dynamic> client;
  final VoidCallback onView;
  final VoidCallback? onEdit;
  final VoidCallback? onDeactivate;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final active = client['status']?.toString().toLowerCase() == 'active';
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onView,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor:
                    (active ? AppTheme.primaryBlue : AppTheme.colorFF64748B)
                        .withValues(alpha: 0.14),
                foregroundColor: active
                    ? AppTheme.primaryBlue
                    : AppTheme.colorFF64748B,
                child: const Icon(Icons.business_rounded),
              ),
              const SizedBox(width: 14),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      formatValue(client['companyName']),
                      style: TextStyle(
                        color: isDark ? AppTheme.white : AppTheme.colorFF111827,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${formatValue(client['contactPersonName'])} | ${formatValue(client['contactNumber'])}',
                      style: TextStyle(
                        color: isDark
                            ? AppTheme.darkSubtleText
                            : AppTheme.lightSubtleText,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: Text(formatValue(client['clientTypeLabel']))),
              Expanded(child: Text(formatValue(client['paymentTermsLabel']))),
              Expanded(
                child: Text(formatValue(client['outstandingBalanceLabel'])),
              ),
              _StatusChip(active: active),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'view') onView();
                  if (value == 'edit') onEdit?.call();
                  if (value == 'deactivate') onDeactivate?.call();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'view',
                    child: Text('View details'),
                  ),
                  if (onEdit != null)
                    const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  if (onDeactivate != null)
                    const PopupMenuItem(
                      value: 'deactivate',
                      child: Text('Deactivate'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppTheme.successGreen : AppTheme.colorFF64748B;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        active ? 'Active' : 'Inactive',
        style: TextStyle(color: color, fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _ClientFormDialog extends StatefulWidget {
  const _ClientFormDialog({this.client, required this.onSave});

  final Map<String, dynamic>? client;
  final Future<void> Function(Map<String, dynamic> payload) onSave;

  @override
  State<_ClientFormDialog> createState() => _ClientFormDialogState();
}

class _ClientFormDialogState extends State<_ClientFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _company;
  late final TextEditingController _contact;
  late final TextEditingController _phone;
  late final TextEditingController _email;
  late final TextEditingController _billing;
  late final TextEditingController _delivery;
  late final TextEditingController _threshold;
  late final TextEditingController _erpId;
  String? _clientType;
  String? _paymentTerms;
  String? _status;
  bool _saving = false;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    final client = widget.client ?? const <String, dynamic>{};
    _company = TextEditingController(
      text: client['companyName']?.toString() ?? '',
    );
    _contact = TextEditingController(
      text: client['contactPersonName']?.toString() ?? '',
    );
    _phone = TextEditingController(
      text: client['contactNumber']?.toString() ?? '',
    );
    _email = TextEditingController(text: _nullableText(client['email']));
    _billing = TextEditingController(
      text: client['billingAddress']?.toString() ?? '',
    );
    _delivery = TextEditingController(
      text: _nullableText(client['deliveryAddress']),
    );
    _threshold = TextEditingController(
      text: (client['freeDeliveryThreshold'] ?? 100000).toString(),
    );
    _erpId = TextEditingController(
      text: _nullableText(client['erpCustomerId']),
    );
    _clientType = _labelFromStored(client['clientType']?.toString(), const {
      'priority': 'Priority',
      'one_time': 'One-time',
    }, fallback: 'Regular');
    _paymentTerms = _labelFromStored(client['paymentTerms']?.toString(), const {
      '30_days_net': '30 days net',
      '60_days_net': '60 days net',
    }, fallback: 'COD');
    _status = client['status']?.toString().toLowerCase() == 'inactive'
        ? 'Inactive'
        : 'Active';
  }

  @override
  void dispose() {
    _company.dispose();
    _contact.dispose();
    _phone.dispose();
    _email.dispose();
    _billing.dispose();
    _delivery.dispose();
    _threshold.dispose();
    _erpId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final mobile = width < 720;
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: mobile ? width - 24 : 760),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.client == null ? 'New Client' : 'Edit Client',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 16),
                _row(mobile, [
                  _field(_company, 'Company name', required: true),
                  _field(_contact, 'Contact person', required: true),
                ]),
                const SizedBox(height: 12),
                _row(mobile, [
                  _field(_phone, 'Contact number', required: true),
                  _field(
                    _email,
                    'Email address',
                    keyboardType: TextInputType.emailAddress,
                    validator: (value) =>
                        FormValidation.email('email address', value),
                  ),
                ]),
                const SizedBox(height: 12),
                _field(
                  _billing,
                  'Billing address',
                  required: true,
                  maxLines: 3,
                ),
                const SizedBox(height: 12),
                _field(_delivery, 'Delivery address if different', maxLines: 3),
                const SizedBox(height: 12),
                _row(mobile, [
                  _dropdown(
                    'Client type',
                    _clientType,
                    const ['Regular', 'Priority', 'One-time'],
                    (value) => setState(() => _clientType = value),
                  ),
                  _dropdown(
                    'Payment terms',
                    _paymentTerms,
                    const ['COD', '30 days net', '60 days net'],
                    (value) => setState(() => _paymentTerms = value),
                  ),
                ]),
                const SizedBox(height: 12),
                _row(mobile, [
                  _field(
                    _threshold,
                    'Free delivery threshold override',
                    keyboardType: TextInputType.number,
                    validator: (value) => FormValidation.nonNegativeNumber(
                      'Free delivery threshold override',
                      value,
                    ),
                  ),
                  _field(_erpId, 'ERP Customer ID'),
                  _dropdown('Status', _status, const [
                    'Active',
                    'Inactive',
                  ], (value) => setState(() => _status = value)),
                ]),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _saving
                            ? null
                            : () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _saving ? null : _submit,
                        child: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppTheme.white,
                                ),
                              )
                            : Text(_saved ? 'Saved' : 'Save Client'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(bool mobile, List<Widget> children) {
    if (mobile) {
      return Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i != children.length - 1) const SizedBox(height: 12),
          ],
        ],
      );
    }
    return Row(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          Expanded(child: children[i]),
          if (i != children.length - 1) const SizedBox(width: 12),
        ],
      ],
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool required = false,
    TextInputType? keyboardType,
    int maxLines = 1,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      validator:
          validator ??
          (required
              ? (value) => FormValidation.requiredField(label, value)
              : null),
      decoration: InputDecoration(labelText: required ? '$label *' : label),
    );
  }

  Widget _dropdown(
    String label,
    String? value,
    List<String> values,
    ValueChanged<String> onChanged,
  ) {
    return DropdownButtonFormField<String>(
      initialValue: values.contains(value) ? value : null,
      hint: const Text('Select...'),
      items: values
          .map((item) => DropdownMenuItem(value: item, child: Text(item)))
          .toList(),
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
      validator: (value) =>
          FormValidation.requiredSelection(label.toLowerCase(), value),
      decoration: InputDecoration(labelText: label),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _saved = false;
    });
    final payload = {
      'companyName': _company.text.trim(),
      'contactPersonName': _contact.text.trim(),
      'contactNumber': _phone.text.trim(),
      'email': _email.text.trim(),
      'billingAddress': _billing.text.trim(),
      'deliveryAddress': _delivery.text.trim(),
      'clientType': _clientType,
      'paymentTerms': _paymentTerms,
      'freeDeliveryThreshold':
          double.tryParse(_threshold.text.trim()) ?? 100000,
      'erpCustomerId': _erpId.text.trim(),
      'status': _status,
    };
    try {
      await widget.onSave(payload);
      if (!mounted) return;
      setState(() => _saved = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.client == null ? 'Client saved.' : 'Client updated.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            FormValidation.backendError(
              error,
              'Client changes could not be saved.',
            ),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _ClientDetailsSheet extends StatelessWidget {
  const _ClientDetailsSheet({required this.client});

  final Map<String, dynamic> client;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final trips = (client['tripHistory'] is List)
        ? (client['tripHistory'] as List).whereType<Map>().toList()
        : const <Map>[];
    final soa = client['statementOfAccounts'] is Map
        ? Map<String, dynamic>.from(client['statementOfAccounts'] as Map)
        : const <String, dynamic>{};
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.82,
      maxChildSize: 0.95,
      minChildSize: 0.45,
      builder: (context, controller) => Container(
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkBg : AppTheme.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: ListView(
          controller: controller,
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              formatValue(client['companyName']),
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              '${formatValue(client['clientTypeLabel'])} | ${formatValue(client['paymentTermsLabel'])} | ${formatValue(client['erpCustomerId'])}',
              style: TextStyle(
                color: isDark
                    ? AppTheme.darkSubtleText
                    : AppTheme.lightSubtleText,
              ),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _DetailPill(
                  label: 'Trips this month',
                  value: formatValue(client['totalTripsThisMonth']),
                ),
                _DetailPill(
                  label: 'Invoiced this month',
                  value: formatValue(client['totalInvoicedThisMonthLabel']),
                ),
                _DetailPill(
                  label: 'Outstanding',
                  value: formatValue(client['outstandingBalanceLabel']),
                ),
                _DetailPill(
                  label: 'Free delivery threshold',
                  value: formatValue(client['freeDeliveryThresholdLabel']),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _section('Contact', [
              _line('Contact person', client['contactPersonName']),
              _line('Phone', client['contactNumber']),
              _line('Email', client['email']),
              _line('Billing address', client['billingAddress']),
              _line('Delivery address', client['deliveryAddress']),
            ]),
            _section('Statement of Accounts', [
              _line('Invoices', soa['invoices']),
              _line('Total', soa['total']),
              _line('Outstanding', soa['outstandingLabel']),
              _line('Oldest unpaid', soa['oldestUnpaid']),
            ]),
            _section(
              'Trip History',
              trips.isEmpty
                  ? [_line('Trips', 'No completed or pending trips yet')]
                  : trips.take(12).map((trip) {
                      return _line(
                        formatValue(trip['tripId']),
                        '${formatValue(trip['origin'])} -> ${formatValue(trip['destination'])}',
                      );
                    }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  Widget _line(String label, dynamic value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 180,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(child: Text(formatValue(value))),
        ],
      ),
    );
  }
}

class _DetailPill extends StatelessWidget {
  const _DetailPill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 210,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF111827 : AppTheme.colorFFF8FAFC,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: isDark
                  ? AppTheme.darkSubtleText
                  : AppTheme.lightSubtleText,
            ),
          ),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }
}

String _nullableText(dynamic value) {
  final text = value?.toString().trim() ?? '';
  return text == 'N/A' || text == 'Same as billing address' ? '' : text;
}

String _labelFromStored(
  String? value,
  Map<String, String> labels, {
  required String fallback,
}) {
  final key = value?.toLowerCase().trim() ?? '';
  return labels[key] ?? fallback;
}
