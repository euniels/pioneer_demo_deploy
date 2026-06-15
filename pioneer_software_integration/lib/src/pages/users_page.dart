import 'package:flutter/material.dart';

import '../services/auth.dart';
import '../services/backend_api.dart';
import '../services/crud_permissions.dart';
import '../services/role_service.dart';
import '../services/user_account_policy.dart';
import '../theme/app_theme.dart';
import '../utils/form_validation.dart';
import '../widgets/dashboard_layout.dart';

class UsersPage extends StatefulWidget {
  const UsersPage({super.key});

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  static const _roleOptions = <String, String>{
    'super_administrator': 'Super Administrator',
    'system_administrator': 'System Administrator',
    'fleet_manager': 'Fleet Manager',
    'dispatcher': 'Dispatcher',
    'driver': 'Driver',
    'accounting_staff': 'Accounting Staff',
  };

  List<Map<String, dynamic>> _users = const [];
  String _searchQuery = '';
  String _roleFilter = 'all';
  String _statusFilter = 'all';
  String _sortMode = 'Role A-Z';
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers({bool forceRefresh = false}) async {
    setState(() {
      _loading = _users.isEmpty;
      _error = null;
    });
    try {
      final users = await BackendApiService.getManagedUsers(
        forceRefresh: forceRefresh,
        role: _roleFilter,
        status: _statusFilter,
      );
      if (!mounted) return;
      setState(() => _users = users);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Unable to load user accounts.');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _openUserForm([Map<String, dynamic>? user]) async {
    if (user != null) {
      final policy = _accountPolicy(user);
      if (!policy.canEdit) {
        _showSnack(policy.editDisabledReason);
        return;
      }
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UserFormDialog(
        user: user,
        roleOptions: _roleOptions,
        actorPayload: _actorPayload(),
        onSave: (payload) async {
          final response = user == null
              ? await BackendApiService.createManagedUser(payload)
              : await BackendApiService.updateManagedUser(
                  user['id']?.toString() ?? '',
                  payload,
                );
          await _loadUsers(forceRefresh: true);
          return (response['temporaryPassword']?.toString() ?? '').isEmpty
              ? null
              : response['temporaryPassword'].toString();
        },
      ),
    );
  }

  Future<void> _viewUser(Map<String, dynamic> user) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _UserDetailDialog(user: user),
    );
  }

  Future<void> _resetPassword(Map<String, dynamic> user) async {
    final policy = _accountPolicy(user);
    if (!policy.canResetPassword) {
      _showSnack(policy.resetPasswordDisabledReason);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Temporary Password'),
        content: Text(
          'Generate a one-time temporary password for ${user['fullName']}? The value is shown once and must be changed at the next sign-in.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset Password'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _saving = true);
    try {
      final response = await BackendApiService.resetManagedUserPassword(
        user['id']?.toString() ?? '',
        _actorPayload(),
      );
      await _loadUsers(forceRefresh: true);
      if (!mounted) return;
      await _showTemporaryPassword(response['temporaryPassword'].toString());
    } catch (_) {
      if (!mounted) return;
      _showSnack('Unable to reset password.');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _deactivateUser(Map<String, dynamic> user) async {
    final policy = _accountPolicy(user);
    if (!policy.canDeactivate) {
      _showSnack(policy.deactivateDisabledReason);
      return;
    }

    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Deactivate User'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Deactivate ${user['fullName']}? Their login access will stop, but audit history and operational records stay preserved.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Reason',
                hintText: 'Required for audit history',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) {
                Navigator.pop(context, value);
              }
            },
            child: const Text('Deactivate'),
          ),
        ],
      ),
    );
    controller.dispose();
    if ((reason ?? '').isEmpty) return;

    setState(() => _saving = true);
    try {
      await BackendApiService.deactivateManagedUser(
        user['id']?.toString() ?? '',
        {..._actorPayload(), 'reason': reason},
      );
      await _loadUsers(forceRefresh: true);
      if (!mounted) return;
      _showSnack('User account deactivated.');
    } catch (error) {
      if (!mounted) return;
      _showSnack(
        'Unable to deactivate user. Active driver trips may still exist.',
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _deleteUser(Map<String, dynamic> user) async {
    final policy = _accountPolicy(user);
    if (!policy.canHardDelete) {
      _showSnack(policy.deleteDisabledReason);
      return;
    }

    final name = user['fullName']?.toString() ?? 'this user';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete User'),
        content: Text(
          'Permanently delete $name? This is only for unused accounts. Deactivate instead when history must remain visible.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.errorRed),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final userId = user['id']?.toString() ?? '';
    setState(() => _saving = true);
    try {
      await BackendApiService.deleteManagedUserPermanently(
        userId,
        _actorPayload(),
      );
      if (!mounted) return;
      setState(() {
        _users = _users
            .where((candidate) => candidate['id']?.toString() != userId)
            .toList(growable: false);
      });
      _showSnack('User account deleted.');
    } catch (error) {
      if (!mounted) return;
      _showSnack(
        FormValidation.backendError(error, 'Unable to delete user account.'),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _showTemporaryPassword(String password) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Temporary Password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Shown once. Record it securely and require the user to change it at first sign-in.',
            ),
            const SizedBox(height: 12),
            SelectableText(
              password,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('I have recorded it'),
          ),
        ],
      ),
    );
  }

  Map<String, dynamic> _actorPayload() {
    final user = AuthService.currentUserData;
    return {
      'actor': user?.email ?? user?.fullName ?? 'frontend-admin',
      'actorRole': AuthService.currentRole == UserRole.admin
          ? 'super_administrator'
          : 'system_administrator',
    };
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  UserAccountPolicy _accountPolicy(Map<String, dynamic> user) {
    return UserAccountPolicy.forUser(
      user,
      currentUser: AuthService.currentUserData,
      canEditUsers: CrudPermissions.canEdit(CrudEntity.users),
      canDeleteUsers: CrudPermissions.canDelete(CrudEntity.users),
    );
  }

  List<Map<String, dynamic>> get _visibleUsers {
    final query = _searchQuery.trim().toLowerCase();
    final filtered = query.isEmpty
        ? _users
        : _users.where((user) {
            final searchable = [
              user['fullName'],
              user['email'],
              user['phone'],
              user['status'],
              _roleDisplayName(user),
            ].map((value) => value?.toString().toLowerCase() ?? '').join(' ');
            return searchable.contains(query);
          }).toList();
    final sorted = List<Map<String, dynamic>>.from(filtered);
    sorted.sort((a, b) {
      return switch (_sortMode) {
        'Role Z-A' => _compareUserRole(b, a),
        'Status A-Z' => _compareUserText(a, b, 'status'),
        'Status Z-A' => _compareUserText(b, a, 'status'),
        'Name A-Z' => _compareUserText(a, b, 'fullName'),
        'Name Z-A' => _compareUserText(b, a, 'fullName'),
        _ => _compareUserRole(a, b),
      };
    });
    return sorted;
  }

  int _compareUserRole(Map<String, dynamic> a, Map<String, dynamic> b) {
    return _roleDisplayName(
      a,
    ).toLowerCase().compareTo(_roleDisplayName(b).toLowerCase());
  }

  int _compareUserText(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
    String field,
  ) {
    final valueA = a[field];
    final valueB = b[field];
    return (valueA?.toString().toLowerCase() ?? '').compareTo(
      valueB?.toString().toLowerCase() ?? '',
    );
  }

  static String _roleDisplayName(Map<String, dynamic> user) {
    return _normalizeRoleDisplayName(
      user['roleLabel'] ?? user['roleDescription'] ?? user['role'],
    );
  }

  static String _normalizeRoleDisplayName(dynamic raw) {
    final value = raw?.toString().trim() ?? '';
    final normalized = value.toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
    return switch (normalized) {
      'super_admin' ||
      'superadministrator' ||
      'super_administrator' => 'Super Administrator',
      'admin' ||
      'administrator' ||
      'system_admin' ||
      'systemadministrator' ||
      'system_administrator' => 'System Administrator',
      'fleet' ||
      'manager' ||
      'fleetmanager' ||
      'fleet_manager' => 'Fleet Manager',
      'dispatch' || 'dispatch_coordinator' || 'dispatcher' => 'Dispatcher',
      'finance' ||
      'accounting' ||
      'accountingstaff' ||
      'accounting_staff' => 'Accounting Staff',
      'driver' => 'Driver',
      _ => _roleOptions[value] ?? (value.isEmpty ? 'Driver' : value),
    };
  }

  bool get _hasActiveUserFilters =>
      _searchQuery.isNotEmpty ||
      _roleFilter != 'all' ||
      _statusFilter != 'all' ||
      _sortMode != 'Role A-Z';

  void _clearUserFilters() {
    setState(() {
      _searchQuery = '';
      _roleFilter = 'all';
      _statusFilter = 'all';
      _sortMode = 'Role A-Z';
    });
    _loadUsers(forceRefresh: true);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AuthService.themeMode.value == ThemeMode.dark;
    final cardColor = isDark ? AppTheme.darkCardBg : AppTheme.lightCardBg;
    final borderColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;

    return DashboardLayout(
      currentRoute: '/users',
      title: 'Users & Roles',
      subtitle: 'Create accounts, control roles, and preserve audit history',
      child: Column(
        children: [
          _toolbar(isDark),
          if (_saving) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: _statePanel(
                icon: Icons.error_outline_rounded,
                title: _error!,
                actionLabel: 'Retry',
                onAction: () => _loadUsers(forceRefresh: true),
              ),
            ),
          Expanded(
            child: Container(
              color: isDark ? AppTheme.colorFF0A0E1A : AppTheme.colorFFF5F6F8,
              child: _loading
                  ? _statePanel(
                      icon: Icons.manage_accounts_rounded,
                      title: 'Loading user accounts...',
                    )
                  : _visibleUsers.isEmpty
                  ? _statePanel(
                      icon: Icons.person_add_alt_1_rounded,
                      title: _users.isEmpty
                          ? 'Add your first user'
                          : 'No users match the current filters',
                      actionLabel:
                          _users.isEmpty &&
                              CrudPermissions.canCreate(CrudEntity.users)
                          ? 'Create User'
                          : null,
                      onAction:
                          _users.isEmpty &&
                              CrudPermissions.canCreate(CrudEntity.users)
                          ? () => _openUserForm()
                          : null,
                    )
                  : RefreshIndicator(
                      onRefresh: () => _loadUsers(forceRefresh: true),
                      child: ListView.separated(
                        padding: const EdgeInsets.all(24),
                        itemCount: _visibleUsers.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (context, index) => _userCard(
                          _visibleUsers[index],
                          cardColor,
                          borderColor,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolbar(bool isDark) {
    final canCreate = CrudPermissions.canCreate(CrudEntity.users);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
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
          final addButton = _UsersActionButton(
            label: compact ? 'Add' : 'Create User',
            icon: Icons.person_add_alt_1_rounded,
            color: AppTheme.successGreen,
            onTap: () => _openUserForm(),
          );
          final search = _UsersSearchField(
            value: _searchQuery,
            isDark: isDark,
            onChanged: (value) => setState(() => _searchQuery = value),
            onClear: () => setState(() => _searchQuery = ''),
          );

          return Column(
            children: [
              if (compact)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    search,
                    if (canCreate) ...[
                      const SizedBox(height: 12),
                      addButton,
                    ],
                  ],
                )
              else
                Row(
                  children: [
                    Expanded(child: search),
                    if (canCreate) ...[
                      const SizedBox(width: 14),
                      addButton,
                    ],
                  ],
                ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _UsersResultCount(count: _visibleUsers.length),
                      const SizedBox(width: 10),
                      _UsersFilterChip(
                        label: 'Role',
                        value: _roleFilter,
                        activeWhen: 'all',
                        displayValue: _roleFilter == 'all'
                            ? 'All roles'
                            : (_roleOptions[_roleFilter] ?? _roleFilter),
                        options: {
                          'all': 'All roles',
                          ..._roleOptions,
                        },
                        onSelected: (value) {
                          setState(() => _roleFilter = value);
                          _loadUsers(forceRefresh: true);
                        },
                        onClear: () {
                          setState(() => _roleFilter = 'all');
                          _loadUsers(forceRefresh: true);
                        },
                      ),
                      const SizedBox(width: 8),
                      _UsersFilterChip(
                        label: 'Status',
                        value: _statusFilter,
                        activeWhen: 'all',
                        displayValue: switch (_statusFilter) {
                          'active' => 'Active',
                          'inactive' => 'Inactive',
                          _ => 'All statuses',
                        },
                        options: const {
                          'all': 'All statuses',
                          'active': 'Active',
                          'inactive': 'Inactive',
                        },
                        onSelected: (value) {
                          setState(() => _statusFilter = value);
                          _loadUsers(forceRefresh: true);
                        },
                        onClear: () {
                          setState(() => _statusFilter = 'all');
                          _loadUsers(forceRefresh: true);
                        },
                      ),
                      const SizedBox(width: 8),
                      _UsersFilterChip(
                        label: 'Sort',
                        value: _sortMode,
                        activeWhen: 'Role A-Z',
                        displayValue: _sortMode,
                        options: const {
                          'Role A-Z': 'Role A-Z',
                          'Role Z-A': 'Role Z-A',
                          'Status A-Z': 'Status A-Z',
                          'Status Z-A': 'Status Z-A',
                          'Name A-Z': 'Name A-Z',
                          'Name Z-A': 'Name Z-A',
                        },
                        onSelected: (value) =>
                            setState(() => _sortMode = value),
                        onClear: () => setState(() => _sortMode = 'Role A-Z'),
                      ),
                      if (_hasActiveUserFilters) ...[
                        const SizedBox(width: 10),
                        TextButton.icon(
                          onPressed: _clearUserFilters,
                          icon: const Icon(
                            Icons.filter_alt_off_rounded,
                            size: 16,
                          ),
                          label: const Text('Clear filters'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _userCard(
    Map<String, dynamic> user,
    Color cardColor,
    Color borderColor,
  ) {
    final status = user['status']?.toString() ?? 'active';
    final active = status == 'active';
    final roleLabel = _roleDisplayName(user);
    final canEdit = CrudPermissions.canEdit(CrudEntity.users);
    final canDelete = CrudPermissions.canDelete(CrudEntity.users);
    final policy = _accountPolicy(user);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 820;
          final details = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: AppTheme.pioneerDeepBlue.withValues(
                      alpha: 0.16,
                    ),
                    child: Icon(
                      Icons.person_rounded,
                      color: AppTheme.pioneerDeepBlue,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user['fullName']?.toString() ?? 'User',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            Text(user['email']?.toString() ?? 'No email'),
                            Text(
                              user['phone']?.toString() ?? 'No phone',
                              style: const TextStyle(
                                color: AppTheme.neutralGray,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _badge(roleLabel, AppTheme.pioneerDeepBlue),
                  _badge(
                    policy.isLocked
                        ? 'Locked'
                        : active
                        ? 'Active'
                        : 'Inactive',
                    policy.isLocked
                        ? AppTheme.errorRed
                        : active
                        ? AppTheme.successGreen
                        : AppTheme.neutralGray,
                  ),
                  ...policy.chips.map(_policyChip),
                  _badge(
                    'Last login: ${_dateLabel(user['lastLoginAt'])}',
                    AppTheme.infoBlue,
                  ),
                ],
              ),
            ],
          );
          final actions = _userActionsMenu(
            user: user,
            canEdit: canEdit,
            canDelete: canDelete,
            policy: policy,
            active: active,
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [details, const SizedBox(height: 12), actions],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: details),
              const SizedBox(width: 12),
              actions,
            ],
          );
        },
      ),
    );
  }

  Widget _userActionsMenu({
    required Map<String, dynamic> user,
    required bool canEdit,
    required bool canDelete,
    required UserAccountPolicy policy,
    required bool active,
  }) {
    return Tooltip(
      message: 'User actions',
      child: PopupMenuButton<String>(
        tooltip: 'User actions',
        position: PopupMenuPosition.under,
        constraints: const BoxConstraints(minWidth: 210, maxWidth: 280),
        icon: const Icon(Icons.more_horiz_rounded),
        onSelected: (value) {
          switch (value) {
            case 'view':
              _viewUser(user);
              break;
            case 'edit':
              _openUserForm(user);
              break;
            case 'reset':
              _resetPassword(user);
              break;
            case 'deactivate':
              _deactivateUser(user);
              break;
            case 'delete':
              _deleteUser(user);
              break;
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'view',
            child: _UserActionMenuItem(
              icon: Icons.visibility_rounded,
              label: 'View Details',
            ),
          ),
          PopupMenuItem(
            value: 'edit',
            enabled: canEdit && policy.canEdit,
            child: _UserActionMenuItem(
              icon: Icons.edit_rounded,
              label: canEdit && policy.canEdit ? 'Edit' : 'Edit - unavailable',
            ),
          ),
          PopupMenuItem(
            value: 'reset',
            enabled: canEdit && policy.canResetPassword,
            child: _UserActionMenuItem(
              icon: Icons.key_rounded,
              label: policy.canResetPassword
                  ? 'Reset Password'
                  : 'Reset Password - unavailable',
            ),
          ),
          PopupMenuItem(
            value: 'deactivate',
            enabled: canDelete && policy.canDeactivate && !_saving,
            child: _UserActionMenuItem(
              icon: Icons.block_rounded,
              label: policy.canDeactivate
                  ? 'Deactivate'
                  : 'Deactivate - protected',
            ),
          ),
          PopupMenuItem(
            value: 'delete',
            enabled: policy.canHardDelete && !_saving,
            child: Tooltip(
              message: policy.canHardDelete
                  ? 'Permanently delete an unused account'
                  : policy.deleteDisabledReason,
              child: const _UserActionMenuItem(
                icon: Icons.delete_outline_rounded,
                label: 'Delete',
                destructive: true,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.34)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _policyChip(UserAccountStatusChip chip) {
    return Tooltip(
      message: chip.label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: chip.color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: chip.color.withValues(alpha: 0.34)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(chip.icon, size: 14, color: chip.color),
            const SizedBox(width: 5),
            Text(
              chip.label,
              style: TextStyle(color: chip.color, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statePanel({
    required IconData icon,
    required String title,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: AppTheme.neutralGray),
            const SizedBox(height: 12),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 12),
              FilledButton(onPressed: onAction, child: Text(actionLabel)),
            ],
          ],
        ),
      ),
    );
  }

  String _dateLabel(dynamic raw) {
    final value = raw?.toString() ?? '';
    if (value.isEmpty) return 'Never';
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return value;
    return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
  }
}

class _UsersSearchField extends StatelessWidget {
  const _UsersSearchField({
    required this.value,
    required this.isDark,
    required this.onChanged,
    required this.onClear,
  });

  final String value;
  final bool isDark;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return TextField(
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: 'Search by name, email, phone, or role...',
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: value.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                onPressed: onClear,
                icon: const Icon(Icons.close_rounded),
              ),
        filled: true,
        fillColor: isDark ? AppTheme.colorFF1A1D23 : AppTheme.colorFFF8FAFD,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
            color: isDark
                ? AppTheme.white.withAlpha(18)
                : AppTheme.black.withAlpha(12),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
            color: isDark
                ? AppTheme.white.withAlpha(18)
                : AppTheme.black.withAlpha(12),
          ),
        ),
      ),
      style: TextStyle(
        fontSize: 14,
        color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
      ),
    );
  }
}

class _UsersActionButton extends StatelessWidget {
  const _UsersActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          constraints: const BoxConstraints(minWidth: 172),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.22),
                blurRadius: 16,
                spreadRadius: -10,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: AppTheme.white, size: 18),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  color: AppTheme.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UsersResultCount extends StatelessWidget {
  const _UsersResultCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppTheme.infoBlue.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.infoBlue.withValues(alpha: 0.22)),
      ),
      child: Text(
        '$count users shown',
        style: const TextStyle(
          color: AppTheme.infoBlue,
          fontWeight: FontWeight.w900,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _UsersFilterChip extends StatelessWidget {
  const _UsersFilterChip({
    required this.label,
    required this.value,
    required this.activeWhen,
    required this.displayValue,
    required this.options,
    required this.onSelected,
    required this.onClear,
  });

  final String label;
  final String value;
  final String activeWhen;
  final String displayValue;
  final Map<String, String> options;
  final ValueChanged<String> onSelected;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final active = value != activeWhen;
    return PopupMenuButton<String>(
      initialValue: value,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final entry in options.entries)
          PopupMenuItem(value: entry.key, child: Text(entry.value)),
      ],
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: active
              ? AppTheme.successGreen.withValues(alpha: 0.13)
              : AppTheme.white.withAlpha(8),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active
                ? AppTheme.successGreen.withValues(alpha: 0.34)
                : AppTheme.white.withAlpha(18),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 190),
              child: Text(
                active ? '$label: $displayValue' : displayValue,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active ? AppTheme.successGreen : AppTheme.gray300,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 16,
              color: active ? AppTheme.successGreen : AppTheme.gray400,
            ),
            if (active) ...[
              const SizedBox(width: 4),
              InkWell(
                onTap: onClear,
                borderRadius: BorderRadius.circular(999),
                child: const Icon(Icons.close_rounded, size: 15),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _UserActionMenuItem extends StatelessWidget {
  const _UserActionMenuItem({
    required this.icon,
    required this.label,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? AppTheme.errorRed : null;
    return SizedBox(
      width: 192,
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _UserFormDialog extends StatefulWidget {
  const _UserFormDialog({
    required this.user,
    required this.roleOptions,
    required this.actorPayload,
    required this.onSave,
  });

  final Map<String, dynamic>? user;
  final Map<String, String> roleOptions;
  final Map<String, dynamic> actorPayload;
  final Future<String?> Function(Map<String, dynamic> payload) onSave;

  @override
  State<_UserFormDialog> createState() => _UserFormDialogState();
}

class _UserFormDialogState extends State<_UserFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _email;
  late final TextEditingController _phone;
  late final TextEditingController _password;
  late String? _role;
  late String? _status;
  bool _saving = false;
  bool _saved = false;

  bool get _editing => widget.user != null;

  @override
  void initState() {
    super.initState();
    final user = widget.user;
    _name = TextEditingController(text: user?['fullName']?.toString() ?? '');
    _email = TextEditingController(text: user?['email']?.toString() ?? '');
    _phone = TextEditingController(text: user?['phone']?.toString() ?? '');
    _password = TextEditingController();
    _role = user?['role']?.toString();
    _status = user?['status']?.toString();
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          decoration: BoxDecoration(
            color: isDark ? AppTheme.colorFF111827 : AppTheme.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.getBorderColor(context)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(18),
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
                    Icon(
                      _editing
                          ? Icons.manage_accounts_rounded
                          : Icons.person_add_alt_1_rounded,
                      color: AppTheme.white,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _editing ? 'Edit User' : 'Create User',
                        style: const TextStyle(
                          color: AppTheme.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
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
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextFormField(
                          controller: _name,
                          decoration: const InputDecoration(
                            labelText: 'Full name',
                          ),
                          validator: (value) =>
                              FormValidation.requiredField('Full name', value),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _email,
                          decoration: const InputDecoration(
                            labelText: 'Email address',
                          ),
                          validator: (value) {
                            return FormValidation.email(
                              'email address',
                              value,
                              required: true,
                            );
                          },
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _phone,
                          decoration: const InputDecoration(
                            labelText: 'Phone number',
                          ),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          initialValue: widget.roleOptions.containsKey(_role)
                              ? _role
                              : null,
                          hint: const Text('Select...'),
                          decoration: const InputDecoration(labelText: 'Role'),
                          items: widget.roleOptions.entries
                              .map(
                                (entry) => DropdownMenuItem(
                                  value: entry.key,
                                  child: Text(entry.value),
                                ),
                              )
                              .toList(),
                          onChanged: (value) => setState(() => _role = value),
                          validator: (value) =>
                              FormValidation.requiredSelection('role', value),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          initialValue: ['active', 'inactive'].contains(_status)
                              ? _status
                              : null,
                          hint: const Text('Select...'),
                          decoration: const InputDecoration(
                            labelText: 'Status',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'active',
                              child: Text('Active'),
                            ),
                            DropdownMenuItem(
                              value: 'inactive',
                              child: Text('Inactive'),
                            ),
                          ],
                          onChanged: (value) =>
                              setState(() => _status = value),
                          validator: (value) =>
                              FormValidation.requiredSelection(
                                'status',
                                value,
                              ),
                        ),
                        if (!_editing) ...[
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _password,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: 'Temporary password',
                              helperText:
                                  'Shown once and must be changed on first login.',
                            ),
                            validator: (value) {
                              if ((value ?? '').length < 8) {
                                return 'Use at least 8 characters';
                              }
                              return null;
                            },
                          ),
                        ],
                        const SizedBox(height: 20),
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
                                    : Text(
                                        _saved
                                            ? 'Saved'
                                            : (_editing
                                                  ? 'Save Changes'
                                                  : 'Create User'),
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
            ],
          ),
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
    final payload = <String, dynamic>{
      ...widget.actorPayload,
      'fullName': _name.text.trim(),
      'email': _email.text.trim(),
      'phone': _phone.text.trim(),
      'role': _role,
      'status': _status,
      if (!_editing) 'temporaryPassword': _password.text,
    };
    try {
      final temporaryPassword = await widget.onSave(payload);
      if (!mounted) return;
      setState(() => _saved = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _editing ? 'User account updated.' : 'User account created.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      if (temporaryPassword != null && mounted) {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('Temporary Password'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Shown once. Record it securely and require the user to change it at first sign-in.',
                ),
                const SizedBox(height: 12),
                SelectableText(
                  temporaryPassword,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('I have recorded it'),
              ),
            ],
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            FormValidation.backendError(error, 'Unable to save user account.'),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _UserDetailDialog extends StatelessWidget {
  const _UserDetailDialog({required this.user});

  final Map<String, dynamic> user;

  @override
  Widget build(BuildContext context) {
    final activity = (user['activityLog'] is List)
        ? (user['activityLog'] as List).whereType<Map>().toList()
        : const <Map>[];
    return AlertDialog(
      title: Text(user['fullName']?.toString() ?? 'User Details'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _row('Email', user['email']),
              _row('Phone', user['phone']),
              _row('Role', _UsersPageState._roleDisplayName(user)),
              _row('Status', user['status']),
              _row('Last login', user['lastLoginAt'] ?? 'Never'),
              _row('Created', user['createdAt']),
              const SizedBox(height: 16),
              const Text(
                'Activity Log',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              if (activity.isEmpty)
                const Text('No activity recorded yet.')
              else
                ...activity.reversed.map(
                  (entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '${entry['timestamp'] ?? ''} • ${entry['action'] ?? 'updated'} by ${entry['actor'] ?? 'system'}',
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _row(String label, dynamic value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(child: SelectableText(value?.toString() ?? 'N/A')),
        ],
      ),
    );
  }
}
