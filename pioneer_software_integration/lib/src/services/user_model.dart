import 'role_service.dart';

class UserModel {
  final String id;
  final String username;
  final String fullName;
  final String email;
  final String? avatarUrl;
  final UserRole role;
  final DateTime createdAt;
  final String? phone;
  final String? assignedVehicle;
  final DateTime? joinDate;
  final String? roleDescription;
  final String? managedRole;
  final bool mustChangePassword;
  final Map<String, dynamic>? driverProfile;

  // Convenience getter — derived from role
  String get roleName =>
      roleDescription ?? RolePermissions.getRoleDisplayName(role);

  const UserModel({
    required this.id,
    required this.username,
    required this.fullName,
    required this.email,
    this.avatarUrl,
    required this.role,
    required this.createdAt,
    this.phone,
    this.assignedVehicle,
    this.joinDate,
    this.roleDescription,
    this.managedRole,
    this.mustChangePassword = false,
    this.driverProfile,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'username': username,
    'fullName': fullName,
    'email': email,
    'avatarUrl': avatarUrl,
    'role': role.name,
    'createdAt': createdAt.toIso8601String(),
    if (phone != null) 'phone': phone,
    if (assignedVehicle != null) 'assignedVehicle': assignedVehicle,
    if (joinDate != null) 'joinDate': joinDate!.toIso8601String(),
    if (roleDescription != null) 'roleDescription': roleDescription,
    if (managedRole != null) 'managedRole': managedRole,
    'mustChangePassword': mustChangePassword,
    if (driverProfile != null) 'driverProfile': driverProfile,
  };

  factory UserModel.fromJson(Map<String, dynamic> json) {
    final rawRole = json['managedRole'] ?? json['role'];
    final driverProfile = json['driverProfile'] is Map
        ? Map<String, dynamic>.from(json['driverProfile'] as Map)
        : null;
    return UserModel(
      id: json['id'] as String,
      username: json['username'] as String,
      fullName: json['fullName'] as String,
      email: json['email'] as String,
      avatarUrl: json['avatarUrl'] as String?,
      role: _roleFromJson(rawRole),
      createdAt: DateTime.parse(json['createdAt'] as String),
      phone: json['phone'] as String?,
      assignedVehicle: json['assignedVehicle'] as String?,
      joinDate: json['joinDate'] != null
          ? DateTime.parse(json['joinDate'] as String)
          : null,
      roleDescription:
          json['roleLabel'] as String? ?? json['roleDescription'] as String?,
      managedRole: _managedRoleFromJson(rawRole),
      mustChangePassword: json['mustChangePassword'] == true,
      driverProfile: driverProfile,
    );
  }

  UserModel copyWith({
    String? id,
    String? username,
    String? fullName,
    String? email,
    String? avatarUrl,
    UserRole? role,
    DateTime? createdAt,
    Object? phone = _sentinel,
    Object? assignedVehicle = _sentinel,
    Object? joinDate = _sentinel,
    Object? roleDescription = _sentinel,
    Object? managedRole = _sentinel,
    bool? mustChangePassword,
    Object? driverProfile = _sentinel,
  }) => UserModel(
    id: id ?? this.id,
    username: username ?? this.username,
    fullName: fullName ?? this.fullName,
    email: email ?? this.email,
    avatarUrl: avatarUrl ?? this.avatarUrl,
    role: role ?? this.role,
    createdAt: createdAt ?? this.createdAt,
    phone: phone == _sentinel ? this.phone : phone as String?,
    assignedVehicle: assignedVehicle == _sentinel
        ? this.assignedVehicle
        : assignedVehicle as String?,
    joinDate: joinDate == _sentinel ? this.joinDate : joinDate as DateTime?,
    roleDescription: roleDescription == _sentinel
        ? this.roleDescription
        : roleDescription as String?,
    managedRole: managedRole == _sentinel
        ? this.managedRole
        : managedRole as String?,
    mustChangePassword: mustChangePassword ?? this.mustChangePassword,
    driverProfile: driverProfile == _sentinel
        ? this.driverProfile
        : driverProfile as Map<String, dynamic>?,
  );

  String? get driverProfileId =>
      driverProfile?['driverId']?.toString().trim().isNotEmpty == true
      ? driverProfile!['driverId'].toString()
      : driverProfile?['id']?.toString();

  String? get manualDriverId => driverProfile?['id']?.toString();

  String? get driverProfileName => driverProfile?['name']?.toString();

  String? get driverProfileEmail => driverProfile?['email']?.toString();

  String? get driverAssignedVehicle =>
      driverProfile?['assignedVehicle']?.toString().trim().isNotEmpty == true
      ? driverProfile!['assignedVehicle'].toString()
      : assignedVehicle;
}

// Sentinel for copyWith nullable fields
const Object _sentinel = Object();

UserRole _roleFromJson(Object? rawRole) {
  final role =
      rawRole?.toString().split('.').last.toLowerCase().replaceAll('-', '_') ??
      '';

  switch (role) {
    case 'super_administrator':
    case 'system_administrator':
    case 'administrator':
    case 'admin':
      return UserRole.admin;
    case 'fleet_manager':
    case 'dispatcher':
    case 'manager':
      return UserRole.manager;
    case 'accounting_staff':
    case 'finance':
      return UserRole.finance;
  }

  return UserRole.values.firstWhere(
    (candidate) => candidate.name == role,
    orElse: () => UserRole.driver,
  );
}

String? _managedRoleFromJson(Object? rawRole) {
  final role =
      rawRole?.toString().split('.').last.toLowerCase().replaceAll('-', '_') ??
      '';
  if (role.isEmpty) return null;
  return switch (role) {
    'admin' || 'administrator' || 'superadmin' => 'super_administrator',
    'systemadmin' => 'system_administrator',
    'manager' => 'fleet_manager',
    'finance' => 'accounting_staff',
    _ => role,
  };
}
