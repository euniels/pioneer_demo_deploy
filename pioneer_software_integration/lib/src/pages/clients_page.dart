import 'package:flutter/material.dart';

import '../services/clients_store.dart';
import '../services/crud_permissions.dart';
import '../theme/app_theme.dart';
import '../utils/display_format.dart';
import '../utils/form_validation.dart';
import '../widgets/admin_page_controls.dart';
import '../widgets/app_state_widgets.dart';
import '../widgets/dashboard_layout.dart';
import '../widgets/page_skeletons.dart';

class ClientsPage extends StatefulWidget {
  const ClientsPage({super.key});

  @override
  State<ClientsPage> createState() => _ClientsPageState();
}

class _ClientsPageState extends State<ClientsPage> {
  final TextEditingController _searchController = TextEditingController();
  String _search = '';
  String _status = 'All';
  String _sortMode = 'Company A-Z';
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
    _searchController.dispose();
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
    final filtered = clientsNotifier.value.where((client) {
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

    final sorted = List<Map<String, dynamic>>.from(filtered);
    sorted.sort((a, b) {
      return switch (_sortMode) {
        'Company Z-A' => _compareClientText(b, a, 'companyName'),
        'Outstanding High' => _clientBalance(
          b,
        ).compareTo(_clientBalance(a)),
        'Outstanding Low' => _clientBalance(
          a,
        ).compareTo(_clientBalance(b)),
        'Trips High' => _clientTrips(b).compareTo(_clientTrips(a)),
        'Trips Low' => _clientTrips(a).compareTo(_clientTrips(b)),
        _ => _compareClientText(a, b, 'companyName'),
      };
    });
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      currentRoute: '/clients',
      title: 'Clients',
      subtitle:
          'Client master records, delivery billing context, and SOA links',
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const PioneerRouteSkeletonBody(routeName: '/clients');
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 850;
    final clients = _filteredClients;
    final canCreate = CrudPermissions.canCreate(CrudEntity.clients);
    final canEdit = CrudPermissions.canEdit(CrudEntity.clients);
    final canDelete = CrudPermissions.canDelete(CrudEntity.clients);
    return Column(
      children: [
        _buildClientToolbar(isDark, isMobile, canCreate),
        _buildClientFilterBar(isDark, isMobile),
        Expanded(
          child: Container(
            color: isDark ? AppTheme.colorFF0A0E1A : AppTheme.colorFFF5F6F8,
            child: RefreshIndicator(
              onRefresh: () => _loadClients(forceRefresh: true),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.all(isMobile ? 16 : 24),
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
                    const SizedBox(height: 16),
                  ],
                  _buildClientSummaryCards(isDark, isMobile),
                  SizedBox(height: isMobile ? 14 : 20),
                  if (clients.isEmpty)
                    SizedBox(
                      height: 360,
                      child: PioneerStateCard(
                        icon: Icons.business_rounded,
                        title: 'No clients found',
                        message:
                            'Add client master records so dispatch, billing, and statements use the same account information.',
                        actionLabel: canCreate ? 'Add your first client' : null,
                        onAction: canCreate ? () => _openClientForm() : null,
                      ),
                    )
                  else
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final gap = isMobile ? 12.0 : 20.0;
                        final width = constraints.maxWidth;
                        final columns = width >= 1040
                            ? 3
                            : width >= 680
                            ? 2
                            : 1;
                        final cardWidth =
                            (width - (gap * (columns - 1))) / columns;

                        return Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          children: [
                            for (final client in clients)
                              SizedBox(
                                width: cardWidth,
                                child: _ClientCard(
                                  client: client,
                                  onView: () => _openClientDetails(client),
                                  onEdit: canEdit
                                      ? () => _openClientForm(client: client)
                                      : null,
                                  onDeactivate: canDelete && _isActive(client)
                                      ? () => _confirmDeactivate(client)
                                      : null,
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildClientToolbar(bool isDark, bool isMobile, bool canCreate) {
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
          final addButton = _clientAddButton(
            label: compact ? 'Add' : 'New Client',
            enabled: canCreate,
          );
          final search = _clientSearchField(isDark);

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                search,
                if (canCreate) ...[const SizedBox(height: 12), addButton],
              ],
            );
          }

          return Row(
            children: [
              Expanded(child: search),
              if (canCreate) ...[const SizedBox(width: 14), addButton],
            ],
          );
        },
      ),
    );
  }

  Widget _buildClientFilterBar(bool isDark, bool isMobile) {
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
      child: Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _ClientResultCount(count: _filteredClients.length),
              const SizedBox(width: 10),
              _ClientFilterChip(
                label: 'Status',
                value: _status,
                activeWhen: 'All',
                options: const ['All', 'Active', 'Inactive'],
                onSelected: (value) => setState(() => _status = value),
                onClear: () => setState(() => _status = 'All'),
              ),
              const SizedBox(width: 8),
              _ClientFilterChip(
                label: 'Sort',
                value: _sortMode,
                activeWhen: 'Company A-Z',
                options: const [
                  'Company A-Z',
                  'Company Z-A',
                  'Outstanding High',
                  'Outstanding Low',
                  'Trips High',
                  'Trips Low',
                ],
                onSelected: (value) => setState(() => _sortMode = value),
                onClear: () => setState(() => _sortMode = 'Company A-Z'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _clientSearchField(bool isDark) {
    return AdminSearchField(
      controller: _searchController,
      hintText: 'Search by company, contact, or ERP ID...',
      onChanged: (value) => setState(() => _search = value),
      onClear: () => setState(() {
        _searchController.clear();
        _search = '';
      }),
    );
  }

  Widget _clientAddButton({required String label, required bool enabled}) {
    if (!enabled) return const SizedBox.shrink();
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _openClientForm(),
        child: Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          constraints: const BoxConstraints(minWidth: 172),
          decoration: BoxDecoration(
            color: AppTheme.successGreen,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: AppTheme.successGreen.withValues(alpha: 0.22),
                blurRadius: 16,
                spreadRadius: -10,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.add_rounded, color: AppTheme.white, size: 18),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  color: AppTheme.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClientSummaryCards(bool isDark, bool isMobile) {
    final all = clientsNotifier.value;
    final active = all.where(_isActive).length;
    final inactive = all.length - active;
    final outstanding = all.fold<double>(
      0,
      (sum, client) => sum + _clientBalance(client),
    );
    final trips = all.fold<int>(0, (sum, client) => sum + _clientTrips(client));

    final cards = [
      _ClientSummaryCard(
        icon: Icons.business_rounded,
        label: 'Client Records',
        value: '${all.length}',
        detail: '$active active accounts',
        accent: AppTheme.colorFF4B7BE5,
        isDark: isDark,
      ),
      _ClientSummaryCard(
        icon: Icons.verified_rounded,
        label: 'Active Clients',
        value: '$active',
        detail: '$inactive inactive',
        accent: AppTheme.successGreen,
        isDark: isDark,
      ),
      _ClientSummaryCard(
        icon: Icons.route_rounded,
        label: 'Client Trips',
        value: '$trips',
        detail: 'linked trip history',
        accent: AppTheme.infoBlue,
        isDark: isDark,
      ),
      _ClientSummaryCard(
        icon: Icons.account_balance_wallet_rounded,
        label: 'Outstanding',
        value: _peso(outstanding),
        detail: 'billing balance',
        accent: AppTheme.colorFFF59E0B,
        isDark: isDark,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 920
            ? 4
            : constraints.maxWidth >= 620
            ? 2
            : 1;
        final gap = isMobile ? 12.0 : 16.0;
        final cardWidth = (constraints.maxWidth - (gap * (columns - 1))) /
            columns;

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
    showDialog<void>(
      context: context,
      builder: (_) => _ClientDetailsDialog(client: client),
    );
  }
}

class _ClientSummaryCard extends StatelessWidget {
  const _ClientSummaryCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.detail,
    required this.accent,
    required this.isDark,
  });

  final IconData icon;
  final String label;
  final String value;
  final String detail;
  final Color accent;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 112),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF171B23 : AppTheme.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: accent.withValues(alpha: isDark ? 0.34 : 0.20),
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: isDark ? 0.14 : 0.08),
            blurRadius: 22,
            spreadRadius: -14,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: accent, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? AppTheme.gray300 : AppTheme.colorFF475569,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isDark ? AppTheme.white : AppTheme.colorFF111827,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? AppTheme.white60 : AppTheme.colorFF64748B,
                    fontWeight: FontWeight.w600,
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

class _ClientResultCount extends StatelessWidget {
  const _ClientResultCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return AdminResultCount(count: count, label: 'clients');
  }
}

class _ClientFilterChip extends StatelessWidget {
  const _ClientFilterChip({
    required this.label,
    required this.value,
    required this.options,
    required this.onSelected,
    required this.onClear,
    this.activeWhen = 'All',
  });

  final String label;
  final String value;
  final String activeWhen;
  final List<String> options;
  final ValueChanged<String> onSelected;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return AdminFilterChip(
      label: label,
      value: value,
      activeWhen: activeWhen,
      options: options,
      onSelected: onSelected,
      onClear: onClear,
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
    final accent = active ? AppTheme.successGreen : AppTheme.colorFF64748B;
    return InkWell(
      onTap: onView,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        constraints: const BoxConstraints(minHeight: 252),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.colorFF171B23 : AppTheme.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accent.withValues(alpha: 0.26)),
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
                CircleAvatar(
                  radius: 24,
                  backgroundColor: accent.withValues(alpha: 0.16),
                  foregroundColor: accent,
                  child: const Icon(Icons.business_rounded, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        formatValue(client['companyName']),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isDark
                              ? AppTheme.white
                              : AppTheme.colorFF111827,
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        formatValue(client['contactPersonName']),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? AppTheme.darkSubtleText
                              : AppTheme.lightSubtleText,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _StatusChip(active: active),
                PopupMenuButton<String>(
                  tooltip: 'Client actions',
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
            const SizedBox(height: 14),
            _ClientInfoLine(
              icon: Icons.phone_rounded,
              label: 'Contact',
              value: formatValue(client['contactNumber']),
              isDark: isDark,
            ),
            const SizedBox(height: 8),
            _ClientInfoLine(
              icon: Icons.receipt_long_rounded,
              label: 'Terms',
              value: formatValue(client['paymentTermsLabel']),
              isDark: isDark,
            ),
            const SizedBox(height: 8),
            _ClientInfoLine(
              icon: Icons.badge_rounded,
              label: 'ERP ID',
              value: formatValue(client['erpCustomerId']),
              isDark: isDark,
            ),
            const SizedBox(height: 12),
            Divider(
              height: 20,
              color: isDark
                  ? AppTheme.white.withAlpha(18)
                  : AppTheme.black.withAlpha(14),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ClientDataPill(
                  label: 'Type',
                  value: formatValue(client['clientTypeLabel']),
                  accent: AppTheme.colorFF4B7BE5,
                ),
                _ClientDataPill(
                  label: 'Trips',
                  value: '${_clientTrips(client)}',
                  accent: AppTheme.infoBlue,
                ),
                _ClientDataPill(
                  label: 'Outstanding',
                  value: formatValue(client['outstandingBalanceLabel']),
                  accent: AppTheme.colorFFF59E0B,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ClientInfoLine extends StatelessWidget {
  const _ClientInfoLine({
    required this.icon,
    required this.label,
    required this.value,
    required this.isDark,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          icon,
          size: 17,
          color: isDark ? AppTheme.gray400 : AppTheme.colorFF64748B,
        ),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: TextStyle(
            fontSize: 12,
            color: isDark ? AppTheme.gray400 : AppTheme.colorFF64748B,
            fontWeight: FontWeight.w800,
          ),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: isDark ? AppTheme.white : AppTheme.colorFF111827,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}

class _ClientDataPill extends StatelessWidget {
  const _ClientDataPill({
    required this.label,
    required this.value,
    required this.accent,
  });

  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.20)),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          color: accent,
          fontSize: 11,
          fontWeight: FontWeight.w900,
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
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final width = MediaQuery.of(context).size.width;
    final mobile = width < 720;
    return Dialog(
      backgroundColor: AppTheme.transparent,
      insetPadding: EdgeInsets.symmetric(
        horizontal: width < 640 ? 16 : 48,
        vertical: 24,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: mobile ? width - 24 : 760,
          maxHeight: 820,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: isDark ? AppTheme.colorFF1A1D23 : AppTheme.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isDark
                  ? AppTheme.white.withValues(alpha: 0.08)
                  : AppTheme.black.withValues(alpha: 0.08),
            ),
          ),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppTheme.colorFF1B2A4A, AppTheme.colorFF4B7BE5],
                  ),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.business_rounded,
                      color: AppTheme.white,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.client == null ? 'New Client' : 'Edit Client',
                        style: const TextStyle(
                          color: AppTheme.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _saving ? null : () => Navigator.pop(context),
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
                  padding: const EdgeInsets.all(20),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _sectionLabel('Client Identity', isDark),
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
                        const SizedBox(height: 16),
                        _sectionLabel('Delivery And Billing', isDark),
                        _field(
                          _billing,
                          'Billing address',
                          required: true,
                          maxLines: 3,
                        ),
                        const SizedBox(height: 12),
                        _field(
                          _delivery,
                          'Delivery address if different',
                          maxLines: 3,
                        ),
                        const SizedBox(height: 16),
                        _sectionLabel('Account Rules', isDark),
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
                            validator: (value) =>
                                FormValidation.nonNegativeNumber(
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
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Row(
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
                      child: FilledButton.icon(
                        onPressed: _saving ? null : _submit,
                        icon: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppTheme.white,
                                ),
                              )
                            : const Icon(Icons.save_rounded),
                        label: Text(_saved ? 'Saved' : 'Save Client'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
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

  Widget _sectionLabel(String label, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        label,
        style: TextStyle(
          color: isDark ? AppTheme.gray300 : AppTheme.colorFF233244,
          fontWeight: FontWeight.w900,
        ),
      ),
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

class _ClientDetailsDialog extends StatelessWidget {
  const _ClientDetailsDialog({required this.client});

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
    final size = MediaQuery.sizeOf(context);
    final compact = size.width < 700;
    return Dialog(
      backgroundColor: AppTheme.transparent,
      insetPadding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 48,
        vertical: 20,
      ),
      child: Container(
        width: compact ? size.width - 20 : 820,
        height: (size.height * 0.84).clamp(520.0, 760.0),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: isDark ? AppTheme.colorFF111827 : AppTheme.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.getBorderColor(context)),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppTheme.primaryBlue, AppTheme.colorFF4B7BE5],
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.business_rounded, color: AppTheme.white),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          formatValue(client['companyName']),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${formatValue(client['clientTypeLabel'])} | ${formatValue(client['paymentTermsLabel'])}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.white70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
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
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
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
                        value: formatValue(
                          client['totalInvoicedThisMonthLabel'],
                        ),
                      ),
                      _DetailPill(
                        label: 'Outstanding',
                        value: formatValue(client['outstandingBalanceLabel']),
                      ),
                      _DetailPill(
                        label: 'Free delivery threshold',
                        value: formatValue(
                          client['freeDeliveryThresholdLabel'],
                        ),
                      ),
                    ],
                  ),
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

int _compareClientText(
  Map<String, dynamic> a,
  Map<String, dynamic> b,
  String key,
) {
  return (a[key] ?? '')
      .toString()
      .toLowerCase()
      .compareTo((b[key] ?? '').toString().toLowerCase());
}

double _clientBalance(Map<String, dynamic> client) {
  final raw =
      client['outstandingBalance'] ??
      client['outstanding'] ??
      client['outstandingBalanceLabel'];
  return double.tryParse(
        (raw ?? '').toString().replaceAll(RegExp(r'[^0-9.\-]'), ''),
      ) ??
      0;
}

int _clientTrips(Map<String, dynamic> client) {
  final raw =
      client['totalTripsThisMonth'] ??
      client['tripsThisMonth'] ??
      client['tripCount'];
  if (raw is num) return raw.toInt();
  final history = client['tripHistory'];
  if (history is List) return history.length;
  return int.tryParse((raw ?? '').toString()) ?? 0;
}

String _peso(num value) {
  return '₱${value.toStringAsFixed(2)}';
}

String _labelFromStored(
  String? value,
  Map<String, String> labels, {
  required String fallback,
}) {
  final key = value?.toLowerCase().trim() ?? '';
  return labels[key] ?? fallback;
}
