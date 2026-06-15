// Temporarily ignore deprecation warnings from newer Flutter SDK APIs.
// This is a short-term suppression; migrate MaterialState usages later.
// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/auth.dart';
import '../services/backend_api.dart';
import '../services/crud_permissions.dart';
import '../services/role_service.dart';
import '../widgets/dashboard_layout.dart';
import '../widgets/geotab_push_preview.dart';
import '../widgets/role_guard.dart';
import '../theme/app_theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with RoleChecks {
  static const _writeBackExpandedPreference =
      'settings_writeback_approval_expanded';

  final _profileFormKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _quietHoursController = TextEditingController();
  final _billingRateController = TextEditingController();
  final _humidityThresholdController = TextEditingController();
  final _vehicleCategoriesController = TextEditingController();
  final _dieselPriceController = TextEditingController();
  final _gasolinePriceController = TextEditingController();
  final _vatRateController = TextEditingController();
  final _fuelPriceSourceController = TextEditingController();
  final _freeDeliveryThresholdController = TextEditingController();
  final _baseDeliveryChargeController = TextEditingController();
  final _fuelSurchargeRateController = TextEditingController();
  final _geotabServerController = TextEditingController();
  final _geotabUsernameController = TextEditingController();
  final _geotabCompanyGroupIdController = TextEditingController();
  final _feedSeedWindowController = TextEditingController();
  final _feedSyncIntervalController = TextEditingController();
  final _gpsTrailMaxPointsController = TextEditingController();
  final _humidityMinController = TextEditingController();
  final _humidityMaxController = TextEditingController();
  final _idleAlertThresholdController = TextEditingController();
  final _maintenanceWarningController = TextEditingController();
  final _registrationWarningController = TextEditingController();
  final _licenseWarningController = TextEditingController();
  final _gpsLogRetentionController = TextEditingController();
  final _rawFeedRetentionController = TextEditingController();
  final _notificationRetentionController = TextEditingController();
  final _auditLogRetentionController = TextEditingController();
  final _depotLatitudeController = TextEditingController();
  final _depotLongitudeController = TextEditingController();
  final _defaultMapLatitudeController = TextEditingController();
  final _defaultMapLongitudeController = TextEditingController();

  bool _notifyTrips = true;
  bool _notifyMaintenance = true;
  bool _notifyBilling = true;
  String _dateFormat = 'yyyy-MM-dd';
  String _distanceUnit = 'km';
  String _timezone = 'Asia/Manila';
  String _fuelPriceLastUpdated = 'Not configured';
  bool _googleMapsServerKeyConfigured = false;
  List<Map<String, dynamic>> _settingsAuditLog = const [];
  bool _isSaving = false;
  bool _writeBackLoading = false;
  List<Map<String, dynamic>> _writeBackJobs = const [];
  bool _writeBackExpanded = true;
  bool _geotabCompanyGroupConfigured = false;
  bool _backendHealthLoading = false;
  Map<String, dynamic>? _backendHealth;
  Map<String, dynamic>? _geotabDiagnosis;
  DateTime? _backendHealthLoadedAt;
  String? _backendHealthError;
  final Map<String, String> _writeBackInlineErrors = {};

  bool get _canEditSystemSettings =>
      CrudPermissions.canEdit(CrudEntity.settings);

  bool get _canReviewWriteBack => CrudPermissions.canReviewGeoTabWriteBack;

  @override
  void initState() {
    super.initState();
    _loadWriteBackExpansionPreference();
    _loadState();
  }

  Future<void> _loadWriteBackExpansionPreference() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) {
      return;
    }
    setState(() {
      _writeBackExpanded = prefs.getBool(_writeBackExpandedPreference) ?? true;
    });
  }

  Future<void> _toggleWriteBackExpanded() async {
    final expanded = !_writeBackExpanded;
    setState(() => _writeBackExpanded = expanded);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_writeBackExpandedPreference, expanded);
  }

  Future<void> _loadState() async {
    final user = AuthService.currentUserData;
    final prefs = await AuthService.getPreferences();
    Map<String, dynamic> backendPrefs = {};
    try {
      backendPrefs = await BackendApiService.getNotificationPreferences();
    } catch (_) {}
    final merged = {...prefs};
    if (backendPrefs.isNotEmpty) {
      merged['notifyTrips'] =
          backendPrefs['tripAlerts'] ?? merged['notifyTrips'];
      merged['notifyMaintenance'] =
          backendPrefs['maintenanceAlerts'] ?? merged['notifyMaintenance'];
      merged['notifyBilling'] =
          backendPrefs['billingAlerts'] ?? merged['notifyBilling'];
      merged['quietHours'] =
          _quietHoursTextFrom(backendPrefs['quietHours']) ??
          merged['quietHours'];
    }
    Map<String, dynamic> fuelSettings = {};
    Map<String, dynamic> geotabHealth = {};
    Map<String, dynamic>? backendHealth;
    String? backendHealthError;
    if (_canEditSystemSettings || _canReviewWriteBack) {
      try {
        backendHealth = await BackendApiService.getApiHealth(
          forceRefresh: true,
        );
      } catch (_) {
        backendHealthError = 'Backend readiness could not be checked.';
      }
    }
    if (_canEditSystemSettings) {
      try {
        fuelSettings = await BackendApiService.getFuelPriceSettings();
      } catch (_) {}
      try {
        geotabHealth = await BackendApiService.getGeotabHealth(
          forceRefresh: true,
        );
      } catch (_) {}
    }
    if (_canReviewWriteBack) {
      try {
        _writeBackJobs = await BackendApiService.getGeotabWriteBackJobs();
      } catch (_) {}
    }
    if (!mounted) {
      return;
    }

    _nameController.text = user?.fullName ?? '';
    _phoneController.text = user?.phone ?? '';
    _quietHoursController.text =
        merged['quietHours']?.toString() ?? '22:00 - 06:00';
    _billingRateController.text = merged['billingRate']?.toString() ?? '1250';
    _humidityThresholdController.text =
        merged['humidityThreshold']?.toString() ?? '75';
    _vehicleCategoriesController.text =
        merged['vehicleCategories']?.toString() ?? '6W, 10W, Trailer, Reefer';
    _notifyTrips = merged['notifyTrips'] != false;
    _notifyMaintenance = merged['notifyMaintenance'] != false;
    _notifyBilling = merged['notifyBilling'] != false;
    _dateFormat = merged['dateFormat']?.toString() ?? 'yyyy-MM-dd';
    _distanceUnit = merged['distanceUnit']?.toString() ?? 'km';
    _timezone = merged['timezone']?.toString() ?? 'Asia/Manila';
    _dieselPriceController.text =
        fuelSettings['dieselPricePerLiter']?.toString() ?? '0.00';
    _gasolinePriceController.text =
        fuelSettings['gasolinePricePerLiter']?.toString() ?? '0.00';
    _vatRateController.text =
        fuelSettings['vatRatePercent']?.toString() ?? '12';
    _fuelPriceSourceController.text =
        fuelSettings['priceSourceLabel']?.toString() ?? '';
    _fuelPriceLastUpdated =
        fuelSettings['priceLastUpdated']?.toString() ?? 'Not configured';
    _freeDeliveryThresholdController.text =
        fuelSettings['freeDeliveryThreshold']?.toString() ?? '100000';
    _baseDeliveryChargeController.text =
        fuelSettings['baseDeliveryChargePerKm']?.toString() ?? '65';
    _fuelSurchargeRateController.text =
        fuelSettings['fuelSurchargeRatePercent']?.toString() ?? '15';
    _geotabServerController.text =
        fuelSettings['geotabServerUrl']?.toString() ?? 'https://my.geotab.com';
    _geotabUsernameController.text =
        fuelSettings['geotabUsername']?.toString() ?? '';
    _geotabCompanyGroupIdController.text =
        fuelSettings['geotabCompanyGroupId']?.toString() ?? '';
    _geotabCompanyGroupConfigured =
        _geotabCompanyGroupIdController.text.trim().isNotEmpty ||
        _writeBackJobs.any(
          (job) => job['geotabCompanyGroupConfigured'] == true,
        );
    _feedSeedWindowController.text =
        fuelSettings['feedSeedWindowDays']?.toString() ?? '30';
    _feedSyncIntervalController.text =
        fuelSettings['feedSyncIntervalMinutes']?.toString() ?? '2';
    _gpsTrailMaxPointsController.text =
        fuelSettings['gpsTrailMaxPoints']?.toString() ?? '200';
    _humidityMinController.text =
        fuelSettings['humidityAlertMinPercent']?.toString() ?? '0';
    _humidityMaxController.text =
        fuelSettings['humidityAlertMaxPercent']?.toString() ?? '75';
    _idleAlertThresholdController.text =
        fuelSettings['idleTimeAlertThresholdMinutes']?.toString() ?? '30';
    _maintenanceWarningController.text =
        fuelSettings['maintenanceDueWarningDays']?.toString() ?? '14';
    _registrationWarningController.text =
        fuelSettings['registrationExpiryWarningDays']?.toString() ?? '30';
    _licenseWarningController.text =
        fuelSettings['licenseExpiryWarningDays']?.toString() ?? '30';
    _gpsLogRetentionController.text =
        fuelSettings['gpsLogRetentionDays']?.toString() ?? '90';
    _rawFeedRetentionController.text =
        fuelSettings['rawGeotabFeedRetentionDays']?.toString() ?? '30';
    _notificationRetentionController.text =
        fuelSettings['notificationHistoryRetentionDays']?.toString() ?? '90';
    _auditLogRetentionController.text =
        fuelSettings['auditLogRetentionDays']?.toString() ?? '365';
    _depotLatitudeController.text =
        fuelSettings['depotLatitude']?.toString() ?? '';
    _depotLongitudeController.text =
        fuelSettings['depotLongitude']?.toString() ?? '';
    _defaultMapLatitudeController.text =
        fuelSettings['defaultMapCenterLatitude']?.toString() ?? '14.5995';
    _defaultMapLongitudeController.text =
        fuelSettings['defaultMapCenterLongitude']?.toString() ?? '120.9842';
    _googleMapsServerKeyConfigured =
        fuelSettings['googleMapsServerKeyConfigured'] == true;
    _settingsAuditLog = ((fuelSettings['auditLog'] as List?) ?? const [])
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
    _geotabDiagnosis = geotabHealth['emptyDataDiagnosis'] is Map
        ? Map<String, dynamic>.from(geotabHealth['emptyDataDiagnosis'] as Map)
        : null;
    _backendHealth = backendHealth;
    _backendHealthError = backendHealthError;
    _backendHealthLoadedAt = backendHealth == null ? null : DateTime.now();

    setState(() {});
  }

  Future<void> _refreshBackendHealth() async {
    if (!(_canEditSystemSettings || _canReviewWriteBack)) {
      return;
    }
    setState(() {
      _backendHealthLoading = true;
      _backendHealthError = null;
    });
    try {
      final health = await BackendApiService.getApiHealth(forceRefresh: true);
      if (!mounted) {
        return;
      }
      setState(() {
        _backendHealth = health;
        _backendHealthLoadedAt = DateTime.now();
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _backendHealthError = 'Backend readiness could not be checked.';
      });
    } finally {
      if (mounted) {
        setState(() => _backendHealthLoading = false);
      }
    }
  }

  Future<void> _toggleTheme(bool dark) async {
    final mode = dark ? ThemeMode.dark : ThemeMode.light;
    await AuthService.setTheme(mode);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _saveSettings() async {
    if (!_profileFormKey.currentState!.validate()) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      await AuthService.updateCurrentUser(
        fullName: _nameController.text.trim(),
        phone: _phoneController.text.trim(),
      );
      await AuthService.savePreferences({
        'notifyTrips': _notifyTrips,
        'notifyMaintenance': _notifyMaintenance,
        'notifyBilling': _notifyBilling,
        'quietHours': _quietHoursController.text.trim(),
        'dateFormat': _dateFormat,
        'distanceUnit': _distanceUnit,
        'timezone': _timezone,
        'billingRate': _billingRateController.text.trim(),
        'humidityThreshold': _humidityThresholdController.text.trim(),
        'vehicleCategories': _vehicleCategoriesController.text.trim(),
      });
      try {
        await BackendApiService.saveNotificationPreferences({
          'browserEnabled': true,
          'emailEnabled': false,
          'tripAlerts': _notifyTrips,
          'maintenanceAlerts': _notifyMaintenance,
          'billingAlerts': _notifyBilling,
          'systemAlerts': true,
          'quietHours': _quietHoursPayload(_quietHoursController.text.trim()),
        });
      } catch (_) {}
      if (_canEditSystemSettings) {
        await BackendApiService.saveFuelPriceSettings({
          'actor':
              AuthService.currentUserData?.email ?? AuthService.currentUser,
          'freeDeliveryThreshold':
              double.tryParse(_freeDeliveryThresholdController.text.trim()) ??
              100000,
          'baseDeliveryChargePerKm':
              double.tryParse(_baseDeliveryChargeController.text.trim()) ?? 65,
          'fuelSurchargeRatePercent':
              double.tryParse(_fuelSurchargeRateController.text.trim()) ?? 15,
          'dieselPricePerLiter':
              double.tryParse(_dieselPriceController.text.trim()) ?? 0,
          'gasolinePricePerLiter':
              double.tryParse(_gasolinePriceController.text.trim()) ?? 0,
          'vatRatePercent':
              double.tryParse(_vatRateController.text.trim()) ?? 12,
          'priceSourceLabel': _fuelPriceSourceController.text.trim(),
          'dieselPriceSourceLabel': _fuelPriceSourceController.text.trim(),
          'gasolinePriceSourceLabel': _fuelPriceSourceController.text.trim(),
          'geotabServerUrl': _geotabServerController.text.trim(),
          'geotabUsername': _geotabUsernameController.text.trim(),
          'geotabCompanyGroupId': _geotabCompanyGroupIdController.text.trim(),
          'feedSeedWindowDays':
              int.tryParse(_feedSeedWindowController.text.trim()) ?? 30,
          'feedSyncIntervalMinutes':
              int.tryParse(_feedSyncIntervalController.text.trim()) ?? 2,
          'gpsTrailMaxPoints':
              int.tryParse(_gpsTrailMaxPointsController.text.trim()) ?? 200,
          'humidityAlertMinPercent':
              double.tryParse(_humidityMinController.text.trim()) ?? 0,
          'humidityAlertMaxPercent':
              double.tryParse(_humidityMaxController.text.trim()) ?? 75,
          'idleTimeAlertThresholdMinutes':
              int.tryParse(_idleAlertThresholdController.text.trim()) ?? 30,
          'maintenanceDueWarningDays':
              int.tryParse(_maintenanceWarningController.text.trim()) ?? 14,
          'registrationExpiryWarningDays':
              int.tryParse(_registrationWarningController.text.trim()) ?? 30,
          'licenseExpiryWarningDays':
              int.tryParse(_licenseWarningController.text.trim()) ?? 30,
          'gpsLogRetentionDays':
              int.tryParse(_gpsLogRetentionController.text.trim()) ?? 90,
          'rawGeotabFeedRetentionDays':
              int.tryParse(_rawFeedRetentionController.text.trim()) ?? 30,
          'notificationHistoryRetentionDays':
              int.tryParse(_notificationRetentionController.text.trim()) ?? 90,
          'auditLogRetentionDays':
              int.tryParse(_auditLogRetentionController.text.trim()) ?? 365,
          if (_depotLatitudeController.text.trim().isNotEmpty)
            'depotLatitude': double.tryParse(
              _depotLatitudeController.text.trim(),
            ),
          if (_depotLongitudeController.text.trim().isNotEmpty)
            'depotLongitude': double.tryParse(
              _depotLongitudeController.text.trim(),
            ),
          'defaultMapCenterLatitude':
              double.tryParse(_defaultMapLatitudeController.text.trim()) ??
              14.5995,
          'defaultMapCenterLongitude':
              double.tryParse(_defaultMapLongitudeController.text.trim()) ??
              120.9842,
        });
        final updatedFuelSettings =
            await BackendApiService.getFuelPriceSettings(forceRefresh: true);
        _fuelPriceLastUpdated =
            updatedFuelSettings['priceLastUpdated']?.toString() ??
            'Not configured';
        _googleMapsServerKeyConfigured =
            updatedFuelSettings['googleMapsServerKeyConfigured'] == true;
        _geotabCompanyGroupIdController.text =
            updatedFuelSettings['geotabCompanyGroupId']?.toString() ?? '';
        _geotabCompanyGroupConfigured = _geotabCompanyGroupIdController.text
            .trim()
            .isNotEmpty;
        _settingsAuditLog =
            ((updatedFuelSettings['auditLog'] as List?) ?? const [])
                .whereType<Map>()
                .map((entry) => Map<String, dynamic>.from(entry))
                .toList();
      }

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PioneerPath settings saved.')),
      );
      setState(() {});
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _loadWriteBackJobs({bool forceRefresh = false}) async {
    if (!_canReviewWriteBack) {
      return;
    }
    setState(() => _writeBackLoading = true);
    try {
      final jobs = await BackendApiService.getGeotabWriteBackJobs(
        forceRefresh: forceRefresh,
      );
      if (mounted) {
        setState(() {
          _writeBackJobs = jobs;
          if (!_canEditSystemSettings) {
            _geotabCompanyGroupConfigured = jobs.any(
              (job) => job['geotabCompanyGroupConfigured'] == true,
            );
          }
        });
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Unable to load write-back jobs: $error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _writeBackLoading = false);
      }
    }
  }

  Future<void> _approveWriteBackJob(Map<String, dynamic> job) async {
    final id = job['id']?.toString() ?? '';
    if (id.isEmpty) {
      return;
    }

    String? password;
    if (job['action'] == 'driver.create' ||
        job['requiresTemporaryPassword'] == true) {
      password = await _promptTemporaryPassword();
      if ((password ?? '').trim().isEmpty) {
        return;
      }
    }

    setState(() => _writeBackLoading = true);
    try {
      await BackendApiService.approveGeotabWriteBackJob(
        id,
        temporaryPassword: password,
      );
      await _loadWriteBackJobs(forceRefresh: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('GeoTab write-back job approved.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _writeBackLoading = false);
      }
    }
  }

  Future<void> _retryWriteBackJob(String id) async {
    if (id.isEmpty) {
      return;
    }
    setState(() => _writeBackLoading = true);
    try {
      await BackendApiService.retryGeotabWriteBackJob(id);
      await _loadWriteBackJobs(forceRefresh: true);
    } finally {
      if (mounted) {
        setState(() => _writeBackLoading = false);
      }
    }
  }

  Future<void> _rejectWriteBackJob(Map<String, dynamic> job) async {
    final id = job['id']?.toString() ?? '';
    if (id.isEmpty) {
      return;
    }

    final reason = await _promptWriteBackRejectionReason(job);
    if ((reason ?? '').trim().isEmpty) {
      return;
    }

    setState(() => _writeBackLoading = true);
    try {
      await BackendApiService.cancelGeotabWriteBackJob(
        id,
        reason: reason!.trim(),
      );
      await _loadWriteBackJobs(forceRefresh: true);
      if (mounted) {
        setState(() => _writeBackInlineErrors.remove(id));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('GeoTab write-back job rejected.')),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _writeBackInlineErrors[id] =
              'Unable to reject this request: ${error.toString()}';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _writeBackLoading = false);
      }
    }
  }

  Future<void> _deleteWriteBackJob(Map<String, dynamic> job) async {
    final id = job['id']?.toString() ?? '';
    if (id.isEmpty) {
      return;
    }

    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete pending job?'),
            content: const Text(
              'Delete this pending job? The GeoTab change will not be applied.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.errorRed,
                ),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) {
      return;
    }

    setState(() => _writeBackLoading = true);
    try {
      await BackendApiService.deleteGeotabWriteBackJob(id);
      await _loadWriteBackJobs(forceRefresh: true);
      if (mounted) {
        setState(() => _writeBackInlineErrors.remove(id));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Pending GeoTab write-back job deleted.'),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _writeBackInlineErrors[id] =
              'Unable to delete this request: ${error.toString()}';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _writeBackLoading = false);
      }
    }
  }

  Future<String?> _promptWriteBackRejectionReason(
    Map<String, dynamic> job,
  ) async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final title = _writeBackActionLabel(job['action']?.toString() ?? '');
    final reason = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Reject GeoTab push?'),
        content: Form(
          key: formKey,
          child: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Tell the requester what needs to be fixed before they push $title again.',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: controller,
                  autofocus: true,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Required rejection reason',
                    hintText:
                        'Example: Plate number does not match the route plan.',
                  ),
                  validator: (value) => (value?.trim().isEmpty ?? true)
                      ? 'Rejection reason is required'
                      : null,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Keep pending'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() != true) {
                return;
              }
              Navigator.pop(context, controller.text.trim());
            },
            child: const Text('Reject job'),
          ),
        ],
      ),
    );
    controller.dispose();
    return reason;
  }

  Future<String?> _promptTemporaryPassword() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Temporary MyGeotab Password'),
          content: TextField(
            controller: controller,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Temporary password',
              helperText: 'Used once for MyGeotab driver creation.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Approve'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    return result;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _quietHoursController.dispose();
    _billingRateController.dispose();
    _humidityThresholdController.dispose();
    _vehicleCategoriesController.dispose();
    _dieselPriceController.dispose();
    _gasolinePriceController.dispose();
    _vatRateController.dispose();
    _fuelPriceSourceController.dispose();
    _freeDeliveryThresholdController.dispose();
    _baseDeliveryChargeController.dispose();
    _fuelSurchargeRateController.dispose();
    _geotabServerController.dispose();
    _geotabUsernameController.dispose();
    _geotabCompanyGroupIdController.dispose();
    _feedSeedWindowController.dispose();
    _feedSyncIntervalController.dispose();
    _gpsTrailMaxPointsController.dispose();
    _humidityMinController.dispose();
    _humidityMaxController.dispose();
    _idleAlertThresholdController.dispose();
    _maintenanceWarningController.dispose();
    _registrationWarningController.dispose();
    _licenseWarningController.dispose();
    _gpsLogRetentionController.dispose();
    _rawFeedRetentionController.dispose();
    _notificationRetentionController.dispose();
    _auditLogRetentionController.dispose();
    _depotLatitudeController.dispose();
    _depotLongitudeController.dispose();
    _defaultMapLatitudeController.dispose();
    _defaultMapLongitudeController.dispose();
    super.dispose();
  }

  String? _quietHoursTextFrom(dynamic value) {
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
    if (value is Map) {
      final start = value['start']?.toString().trim();
      final end = value['end']?.toString().trim();
      if ((start ?? '').isNotEmpty && (end ?? '').isNotEmpty) {
        return '$start - $end';
      }
    }
    return null;
  }

  Map<String, dynamic> _quietHoursPayload(String value) {
    final parts = value.split('-');
    if (parts.length == 2) {
      return {'start': parts.first.trim(), 'end': parts.last.trim()};
    }
    return {'start': value.trim(), 'end': value.trim()};
  }

  String? _numberValidator(
    String? value, {
    double min = 0,
    double? max,
    bool allowEmpty = false,
  }) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return allowEmpty ? null : 'Required';
    final parsed = double.tryParse(text);
    if (parsed == null) return 'Enter a number';
    if (parsed < min) return 'Must be at least $min';
    if (max != null && parsed > max) return 'Must be $max or lower';
    return null;
  }

  String? _integerValidator(String? value, {int min = 0, int? max}) {
    final text = (value ?? '').trim();
    final parsed = int.tryParse(text);
    if (parsed == null) return 'Enter a whole number';
    if (parsed < min) return 'Must be at least $min';
    if (max != null && parsed > max) return 'Must be $max or lower';
    return null;
  }

  Color _roleColor(UserRole? role) {
    switch (role) {
      case UserRole.admin:
      case UserRole.ceo:
        return AppTheme.colorFFC0392B;
      case UserRole.finance:
        return AppTheme.colorFF8B5CF6;
      case UserRole.manager:
        return AppTheme.colorFF1A3A6B;
      case UserRole.driver:
        return AppTheme.colorFF27AE60;
      case UserRole.client:
        return AppTheme.colorFF14B8A6;
      default:
        return AppTheme.colorFF1A3A6B;
    }
  }

  IconData _roleIcon(UserRole? role) {
    switch (role) {
      case UserRole.admin:
        return Icons.admin_panel_settings_rounded;
      case UserRole.ceo:
        return Icons.business_center_rounded;
      case UserRole.finance:
        return Icons.account_balance_rounded;
      case UserRole.manager:
        return Icons.manage_accounts_rounded;
      case UserRole.driver:
        return Icons.drive_eta_rounded;
      case UserRole.client:
        return Icons.public_rounded;
      default:
        return Icons.person_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AuthService.themeMode.value == ThemeMode.dark;
    final role = AuthService.currentRole;
    final user = AuthService.currentUserData;
    final roleColor = _roleColor(role);

    return DashboardLayout(
      currentRoute: '/settings',
      title: 'Settings',
      subtitle: 'Account preferences, runtime health, and controlled system setup',
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
        child: Form(
          key: _profileFormKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSettingsOverview(isDark, role, roleColor),
              const SizedBox(height: 18),
              _responsiveSettingsLayout(
                left: Column(
                  children: [
                    _buildAccountCard(isDark, user, role, roleColor),
                    const SizedBox(height: 16),
                    _buildNotificationCard(isDark, roleColor),
                  ],
                ),
                right: Column(
                  children: [
                    _buildDisplayCard(isDark),
                    const SizedBox(height: 16),
                    _buildAppearanceCard(isDark),
                    const SizedBox(height: 16),
                    _buildAboutCard(isDark),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              if (_canEditSystemSettings || _canReviewWriteBack) ...[
                _buildBackendReadinessCard(isDark, roleColor),
                const SizedBox(height: 16),
              ],
              if (_canEditSystemSettings || _canReviewWriteBack) ...[
                _buildAdminCard(isDark, roleColor),
                const SizedBox(height: 18),
              ],
              _buildSaveBar(isDark, roleColor),
            ],
          ),
        ),
      ),
    );
  }

  Widget _responsiveSettingsLayout({
    required Widget left,
    required Widget right,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 980) {
          return Column(
            children: [
              left,
              const SizedBox(height: 16),
              right,
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 6, child: left),
            const SizedBox(width: 16),
            Expanded(flex: 5, child: right),
          ],
        );
      },
    );
  }

  Widget _buildSettingsOverview(
    bool isDark,
    UserRole? role,
    Color accent,
  ) {
    final status = _backendHealth?['status']?.toString() ?? 'unknown';
    final healthy = _backendHealth?['healthy'] == true || status == 'ok';
    final geotabStatus = _geotabDiagnosis?['status']?.toString() ?? 'unknown';
    final geotabReason =
        _geotabDiagnosis?['primaryReason']?.toString() ?? 'not checked';
    final pendingWriteBack = _writeBackJobs
        .where((job) => job['status']?.toString() == 'pending_approval')
        .length;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [
                  AppTheme.colorFF111827,
                  AppTheme.colorFF1A3A6B.withValues(alpha: 0.62),
                ]
              : [
                  AppTheme.colorFFF8FAFC,
                  const Color(0xFFEFF6FF),
                ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: AppTheme.colorFF4B7BE5.withValues(alpha: isDark ? 0.28 : 0.18),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 860;
          final summary = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: accent.withValues(alpha: 0.3)),
                    ),
                    child: Icon(Icons.tune_rounded, color: accent),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Operations Settings',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            color: isDark
                                ? AppTheme.white
                                : AppTheme.colorFF111827,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Manage only what affects account access, alerts, billing rules, fleet data, and GeoTab operations.',
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.45,
                            color: isDark
                                ? AppTheme.gray300
                                : AppTheme.colorFF475569,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _statusPill(
                    isDark,
                    icon: _roleIcon(role),
                    label: role != null
                        ? RolePermissions.getRoleDisplayName(role)
                        : 'Unknown role',
                    color: accent,
                  ),
                  _statusPill(
                    isDark,
                    icon: healthy
                        ? Icons.verified_rounded
                        : Icons.warning_amber_rounded,
                    label: healthy ? 'Backend ready' : 'Backend needs review',
                    color: healthy
                        ? AppTheme.colorFF27AE60
                        : AppTheme.warningOrange,
                  ),
                  _statusPill(
                    isDark,
                    icon: geotabStatus == 'ok'
                        ? Icons.cloud_done_rounded
                        : Icons.cloud_sync_rounded,
                    label: 'GeoTab: $geotabReason',
                    color: _backendStatusColor(geotabStatus, geotabStatus == 'ok'),
                  ),
                  _statusPill(
                    isDark,
                    icon: _googleMapsServerKeyConfigured
                        ? Icons.map_rounded
                        : Icons.key_off_rounded,
                    label: _googleMapsServerKeyConfigured
                        ? 'Maps key configured'
                        : 'Maps key missing',
                    color: _googleMapsServerKeyConfigured
                        ? AppTheme.colorFF27AE60
                        : AppTheme.warningOrange,
                  ),
                ],
              ),
            ],
          );

          final actions = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _overviewMetric(
                isDark,
                label: 'Write-back approvals',
                value: '$pendingWriteBack',
                detail: pendingWriteBack == 1 ? 'pending job' : 'pending jobs',
                color: pendingWriteBack > 0
                    ? AppTheme.warningOrange
                    : AppTheme.colorFF27AE60,
                icon: Icons.cloud_sync_rounded,
              ),
              const SizedBox(height: 10),
              _overviewMetric(
                isDark,
                label: 'Readiness refreshed',
                value: _backendHealthLoadedAt == null
                    ? 'Never'
                    : _shortDateTime(_backendHealthLoadedAt!),
                detail: 'runtime health snapshot',
                color: AppTheme.colorFF3498DB,
                icon: Icons.health_and_safety_rounded,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: compact ? WrapAlignment.start : WrapAlignment.end,
                children: [
                  OutlinedButton.icon(
                    onPressed:
                        _backendHealthLoading ? null : _refreshBackendHealth,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Check Health'),
                  ),
                  FilledButton.icon(
                    onPressed: _isSaving ? null : _saveSettings,
                    icon: _isSaving
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_rounded, size: 16),
                    label: Text(_isSaving ? 'Saving...' : 'Save'),
                  ),
                ],
              ),
            ],
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                summary,
                const SizedBox(height: 16),
                actions,
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 6, child: summary),
              const SizedBox(width: 18),
              Expanded(flex: 4, child: actions),
            ],
          );
        },
      ),
    );
  }

  Widget _statusPill(
    bool isDark, {
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.16 : 0.09),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: isDark ? AppTheme.gray200 : AppTheme.colorFF1F2937,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _overviewMetric(
    bool isDark, {
    required String label,
    required String value,
    required String detail,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark
            ? AppTheme.black.withValues(alpha: 0.18)
            : AppTheme.white.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppTheme.gray400 : AppTheme.colorFF64748B,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: value.length > 10 ? 14 : 20,
                    fontWeight: FontWeight.w900,
                    color: isDark ? AppTheme.white : AppTheme.colorFF111827,
                  ),
                ),
                Text(
                  detail,
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? AppTheme.gray500 : AppTheme.colorFF64748B,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSaveBar(bool isDark, Color accent) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF111827 : AppTheme.colorFFF8FAFC,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: accent.withValues(alpha: isDark ? 0.26 : 0.16),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, color: accent, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Changes affect your account immediately. System configuration changes are audited.',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: isDark ? AppTheme.gray300 : AppTheme.colorFF334155,
              ),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: _isSaving ? null : _saveSettings,
            icon: _isSaving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_rounded),
            label: Text(_isSaving ? 'Saving...' : 'Save Settings'),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountCard(
    bool isDark,
    dynamic user,
    UserRole? role,
    Color roleColor,
  ) {
    return _settingsCard(
      isDark,
      title: 'Profile',
      icon: Icons.person_rounded,
      subtitle: 'Your account details and current access level.',
      accent: roleColor,
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: roleColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: roleColor.withValues(alpha: 0.3)),
                ),
                child: Center(
                  child: Text(
                    (user?.fullName?.isNotEmpty == true)
                        ? user!.fullName[0].toUpperCase()
                        : 'P',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: roleColor,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user?.fullName ?? 'PioneerPath User',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: isDark ? AppTheme.white : AppTheme.colorFF1A1D23,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      user?.email ?? 'N/A',
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: roleColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_roleIcon(role), size: 12, color: roleColor),
                          const SizedBox(width: 4),
                          Text(
                            role != null
                                ? RolePermissions.getRoleDisplayName(role)
                                : 'Unknown',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: roleColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 760;
              if (compact) {
                return Column(
                  children: [
                    _textField(
                      isDark,
                      controller: _nameController,
                      label: 'Full name',
                      icon: Icons.badge_rounded,
                      validator: (value) =>
                          (value == null || value.trim().isEmpty)
                          ? 'Full name is required.'
                          : null,
                    ),
                    const SizedBox(height: 12),
                    _textField(
                      isDark,
                      controller: _phoneController,
                      label: 'Contact number',
                      icon: Icons.phone_rounded,
                    ),
                    const SizedBox(height: 12),
                    _readOnlyField(
                      isDark,
                      label: 'Role',
                      value: role != null
                          ? RolePermissions.getRoleDisplayName(role)
                          : 'N/A',
                      icon: _roleIcon(role),
                    ),
                  ],
                );
              }

              return Row(
                children: [
                  Expanded(
                    child: _textField(
                      isDark,
                      controller: _nameController,
                      label: 'Full name',
                      icon: Icons.badge_rounded,
                      validator: (value) =>
                          (value == null || value.trim().isEmpty)
                          ? 'Full name is required.'
                          : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _textField(
                      isDark,
                      controller: _phoneController,
                      label: 'Contact number',
                      icon: Icons.phone_rounded,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _readOnlyField(
                      isDark,
                      label: 'Role',
                      value: role != null
                          ? RolePermissions.getRoleDisplayName(role)
                          : 'N/A',
                      icon: _roleIcon(role),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildNotificationCard(bool isDark, Color accent) {
    return _settingsCard(
      isDark,
      title: 'Notifications',
      icon: Icons.notifications_active_rounded,
      subtitle: 'Choose the operational alerts you want to see.',
      accent: accent,
      child: Column(
        children: [
          _toggleRow(
            isDark,
            title: 'Trip updates',
            subtitle: 'Dispatch, ETA, trip completion, and POD events',
            value: _notifyTrips,
            onChanged: (value) => setState(() => _notifyTrips = value),
            accent: accent,
          ),
          const SizedBox(height: 10),
          _toggleRow(
            isDark,
            title: 'Maintenance alerts',
            subtitle: 'Due, overdue, and active maintenance notices',
            value: _notifyMaintenance,
            onChanged: (value) => setState(() => _notifyMaintenance = value),
            accent: accent,
          ),
          const SizedBox(height: 10),
          _toggleRow(
            isDark,
            title: 'Billing and finance',
            subtitle: 'Invoices, SOA readiness, and payment visibility',
            value: _notifyBilling,
            onChanged: (value) => setState(() => _notifyBilling = value),
            accent: accent,
          ),
          const SizedBox(height: 14),
          _textField(
            isDark,
            controller: _quietHoursController,
            label: 'Quiet hours',
            icon: Icons.bedtime_rounded,
          ),
        ],
      ),
    );
  }

  Widget _buildDisplayCard(bool isDark) {
    return _settingsCard(
      isDark,
      title: 'Display Preferences',
      icon: Icons.tune_rounded,
      subtitle: 'Units, dates, and timezone shown across the app.',
      accent: AppTheme.colorFF3498DB,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 760;
          final children = [
            _dropdownField(
              isDark,
              label: 'Date format',
              value: _dateFormat,
              icon: Icons.event_rounded,
              items: const ['yyyy-MM-dd', 'MM/dd/yyyy', 'dd/MM/yyyy'],
              onChanged: (value) => setState(() => _dateFormat = value!),
            ),
            _dropdownField(
              isDark,
              label: 'Distance unit',
              value: _distanceUnit,
              icon: Icons.straighten_rounded,
              items: const ['km', 'miles'],
              onChanged: (value) => setState(() => _distanceUnit = value!),
            ),
            _dropdownField(
              isDark,
              label: 'Timezone',
              value: _timezone,
              icon: Icons.schedule_rounded,
              items: const ['Asia/Manila', 'UTC', 'Asia/Singapore'],
              onChanged: (value) => setState(() => _timezone = value!),
            ),
          ];

          if (compact) {
            return Column(
              children: [
                children[0],
                const SizedBox(height: 12),
                children[1],
                const SizedBox(height: 12),
                children[2],
              ],
            );
          }

          return Row(
            children: [
              Expanded(child: children[0]),
              const SizedBox(width: 12),
              Expanded(child: children[1]),
              const SizedBox(width: 12),
              Expanded(child: children[2]),
            ],
          );
        },
      ),
    );
  }

  Widget _buildAppearanceCard(bool isDark) {
    return _settingsCard(
      isDark,
      title: 'Appearance',
      icon: Icons.palette_rounded,
      subtitle: 'Theme preference for the current browser session.',
      accent: AppTheme.colorFF8B5CF6,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isDark ? 'Dark Mode Active' : 'Light Mode Active',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: isDark ? AppTheme.white : AppTheme.colorFF1A1D23,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'PioneerPath keeps your current theme preference across sessions.',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                ),
              ),
            ],
          ),
          Switch(
            value: isDark,
            onChanged: _toggleTheme,
            thumbColor: MaterialStateProperty.resolveWith<Color?>((states) {
              if (states.contains(MaterialState.selected))
                return AppTheme.colorFF1A3A6B;
              return null;
            }),
            trackColor: MaterialStateProperty.resolveWith<Color?>((states) {
              if (states.contains(MaterialState.selected))
                return AppTheme.colorFF1A3A6B.withAlpha(61);
              return null;
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildBackendReadinessCard(bool isDark, Color accent) {
    final health = _backendHealth;
    final checks = health?['checks'] is Map
        ? Map<String, dynamic>.from(health!['checks'] as Map)
        : const <String, dynamic>{};
    final status = health?['status']?.toString() ?? 'unknown';
    final healthy = health?['healthy'] == true || status == 'ok';
    final statusColor = _backendStatusColor(status, healthy);
    final loadedLabel = _backendHealthLoadedAt == null
        ? 'Not checked yet'
        : _shortDateTime(_backendHealthLoadedAt!);

    return _settingsCard(
      isDark,
      title: 'Backend readiness',
      icon: Icons.verified_user_rounded,
      subtitle: 'Production health signals for API, cache, queue, and scheduler.',
      accent: statusColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: isDark ? 0.18 : 0.1),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: statusColor.withValues(alpha: 0.4),
                  ),
                ),
                child: Text(
                  healthy ? 'READY' : status.toUpperCase(),
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _backendHealthError ??
                      (healthy
                          ? 'API, database, cache, queue, scheduler, disk, and PHP checks are reporting healthy.'
                          : 'One or more backend runtime checks need attention before production deployment.'),
                  style: TextStyle(
                    color: isDark ? AppTheme.gray200 : AppTheme.colorFF334155,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: _backendHealthLoading ? null : _refreshBackendHealth,
                icon: _backendHealthLoading
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Refresh readiness'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _backendCheckChip(
                isDark,
                'API',
                healthy,
                status == 'unknown' ? 'Unknown' : status,
              ),
              ...[
                'database',
                'cache',
                'queue',
                'scheduler',
                'disk',
                'php',
              ].map((name) => _backendCheckChip(
                    isDark,
                    _backendCheckLabel(name),
                    _checkOk(checks[name]),
                    _checkDetail(checks[name]),
                  )),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Last readiness refresh: $loadedLabel',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
            ),
          ),
          if (checks['scheduler'] is Map) ...[
            const SizedBox(height: 8),
            Text(
              'Production scheduler command: ${_schedulerCommand(checks['scheduler'])}',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? AppTheme.gray400 : AppTheme.gray600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _backendCheckChip(
    bool isDark,
    String label,
    bool ok,
    String detail,
  ) {
    final color = ok ? AppTheme.colorFF27AE60 : AppTheme.colorFFE74C3C;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.16 : 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            ok ? Icons.check_circle_rounded : Icons.error_rounded,
            size: 15,
            color: color,
          ),
          const SizedBox(width: 6),
          Text(
            '$label: ${ok ? 'OK' : 'Check'}',
            style: TextStyle(
              color: isDark ? AppTheme.gray200 : AppTheme.colorFF1A1D23,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(
              detail,
              style: TextStyle(
                color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _backendStatusColor(String status, bool healthy) {
    if (healthy) {
      return AppTheme.colorFF27AE60;
    }
    return switch (status) {
      'degraded' => AppTheme.colorFFFFD166,
      'failed' => AppTheme.colorFFE74C3C,
      _ => AppTheme.colorFF3498DB,
    };
  }

  String _backendCheckLabel(String name) {
    return switch (name) {
      'php' => 'PHP',
      _ => name[0].toUpperCase() + name.substring(1),
    };
  }

  bool _checkOk(dynamic raw) {
    return raw is Map && raw['ok'] == true;
  }

  String _checkDetail(dynamic raw) {
    if (raw is! Map) {
      return 'missing';
    }
    final detail = raw['connection'] ?? raw['store'] ?? raw['version'];
    if (detail == null || detail.toString().trim().isEmpty) {
      return '';
    }
    return detail.toString();
  }

  String _schedulerCommand(dynamic raw) {
    if (raw is Map) {
      return raw['productionCron']?.toString() ??
          '* * * * * php /path/to/artisan schedule:run >> /dev/null 2>&1';
    }
    return '* * * * * php /path/to/artisan schedule:run >> /dev/null 2>&1';
  }

  String _shortDateTime(DateTime value) {
    final local = value.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildAdminCard(bool isDark, Color accent) {
    return _settingsCard(
      isDark,
      title: _canEditSystemSettings
          ? 'System Configuration'
          : 'GeoTab Write-Back Approval',
      icon: Icons.admin_panel_settings_rounded,
      subtitle: _canEditSystemSettings
          ? 'Advanced operational rules. Edit carefully; changes are audited.'
          : 'Review staged GeoTab changes without exposing global configuration.',
      accent: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_canEditSystemSettings) ...[
            _settingsInfoBanner(
              isDark,
              icon: Icons.rule_folder_rounded,
              title: 'Advanced settings are grouped by operational impact',
              body:
                  'Billing affects invoice computation, GeoTab controls fleet data freshness, alert thresholds drive notifications, and retention settings control how long operational history is kept.',
              color: accent,
            ),
            const SizedBox(height: 16),
            _settingsSectionTitle(isDark, accent, 'Billing settings'),
            _responsiveFields([
              _textField(
                isDark,
                controller: _freeDeliveryThresholdController,
                label: 'Free delivery threshold (PHP)',
                icon: Icons.price_check_rounded,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: _numberValidator,
              ),
              _textField(
                isDark,
                controller: _vatRateController,
                label: 'VAT rate (%)',
                icon: Icons.percent_rounded,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: (value) => _numberValidator(value, max: 100),
              ),
              _textField(
                isDark,
                controller: _baseDeliveryChargeController,
                label: 'Base delivery charge / km',
                icon: Icons.route_rounded,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: _numberValidator,
              ),
            ]),
            const SizedBox(height: 12),
            _responsiveFields([
              _textField(
                isDark,
                controller: _fuelSurchargeRateController,
                label: 'Fuel surcharge rate (%)',
                icon: Icons.local_fire_department_rounded,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: (value) => _numberValidator(value, max: 100),
              ),
              _textField(
                isDark,
                controller: _dieselPriceController,
                label: 'Diesel price / liter',
                icon: Icons.local_gas_station_rounded,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: _numberValidator,
              ),
              _textField(
                isDark,
                controller: _gasolinePriceController,
                label: 'Gasoline price / liter',
                icon: Icons.oil_barrel_rounded,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: _numberValidator,
              ),
            ]),
            const SizedBox(height: 12),
            _textField(
              isDark,
              controller: _fuelPriceSourceController,
              label: 'Fuel price source label',
              icon: Icons.label_rounded,
            ),
            const SizedBox(height: 16),
            _settingsSectionTitle(isDark, accent, 'GeoTab settings'),
            _geotabDiagnosisBanner(isDark),
            const SizedBox(height: 12),
            _responsiveFields([
              _textField(
                isDark,
                controller: _geotabServerController,
                label: 'GeoTab server URL',
                icon: Icons.cloud_rounded,
              ),
              _textField(
                isDark,
                controller: _geotabUsernameController,
                label: 'GeoTab username',
                icon: Icons.person_rounded,
              ),
            ]),
            const SizedBox(height: 12),
            _responsiveFields([
              _textField(
                isDark,
                controller: _feedSeedWindowController,
                label: 'Feed seed window (days)',
                icon: Icons.history_rounded,
                keyboardType: TextInputType.number,
                validator: (value) =>
                    _integerValidator(value, min: 1, max: 365),
              ),
              _textField(
                isDark,
                controller: _feedSyncIntervalController,
                label: 'Feed sync interval (minutes)',
                icon: Icons.sync_rounded,
                keyboardType: TextInputType.number,
                validator: (value) =>
                    _integerValidator(value, min: 1, max: 1440),
              ),
              _textField(
                isDark,
                controller: _gpsTrailMaxPointsController,
                label: 'GPS trail max points',
                icon: Icons.timeline_rounded,
                keyboardType: TextInputType.number,
                validator: (value) =>
                    _integerValidator(value, min: 10, max: 5000),
              ),
            ]),
            const SizedBox(height: 16),
            _settingsSectionTitle(isDark, accent, 'Notification settings'),
            _responsiveFields([
              _textField(
                isDark,
                controller: _humidityMinController,
                label: 'Humidity min threshold (%)',
                icon: Icons.water_drop_outlined,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: (value) => _numberValidator(value, max: 100),
              ),
              _textField(
                isDark,
                controller: _humidityMaxController,
                label: 'Humidity max threshold (%)',
                icon: Icons.water_drop_rounded,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: (value) => _numberValidator(value, max: 100),
              ),
              _textField(
                isDark,
                controller: _idleAlertThresholdController,
                label: 'Idle alert threshold (minutes)',
                icon: Icons.timer_rounded,
                keyboardType: TextInputType.number,
                validator: (value) => _integerValidator(value, min: 1),
              ),
            ]),
            const SizedBox(height: 12),
            _responsiveFields([
              _textField(
                isDark,
                controller: _maintenanceWarningController,
                label: 'Maintenance warning days',
                icon: Icons.build_circle_rounded,
                keyboardType: TextInputType.number,
                validator: (value) =>
                    _integerValidator(value, min: 0, max: 365),
              ),
              _textField(
                isDark,
                controller: _registrationWarningController,
                label: 'Registration warning days',
                icon: Icons.badge_rounded,
                keyboardType: TextInputType.number,
                validator: (value) =>
                    _integerValidator(value, min: 0, max: 365),
              ),
              _textField(
                isDark,
                controller: _licenseWarningController,
                label: 'License warning days',
                icon: Icons.drive_eta_rounded,
                keyboardType: TextInputType.number,
                validator: (value) =>
                    _integerValidator(value, min: 0, max: 365),
              ),
            ]),
            const SizedBox(height: 16),
            _settingsSectionTitle(isDark, accent, 'Data retention settings'),
            _responsiveFields([
              _textField(
                isDark,
                controller: _gpsLogRetentionController,
                label: 'GPS log retention (days)',
                icon: Icons.route_rounded,
                keyboardType: TextInputType.number,
                validator: (value) =>
                    _integerValidator(value, min: 30, max: 3650),
              ),
              _textField(
                isDark,
                controller: _rawFeedRetentionController,
                label: 'Raw GeoTab feed retention (days)',
                icon: Icons.storage_rounded,
                keyboardType: TextInputType.number,
                validator: (value) =>
                    _integerValidator(value, min: 1, max: 3650),
              ),
              _textField(
                isDark,
                controller: _notificationRetentionController,
                label: 'Notification retention (days)',
                icon: Icons.notifications_active_rounded,
                keyboardType: TextInputType.number,
                validator: (value) =>
                    _integerValidator(value, min: 30, max: 3650),
              ),
            ]),
            const SizedBox(height: 12),
            _responsiveFields([
              _textField(
                isDark,
                controller: _auditLogRetentionController,
                label: 'Audit log retention (days)',
                icon: Icons.verified_user_rounded,
                keyboardType: TextInputType.number,
                validator: (value) =>
                    _integerValidator(value, min: 365, max: 3650),
              ),
            ]),
            const SizedBox(height: 16),
            _settingsSectionTitle(isDark, accent, 'Map settings'),
            _keyIndicator(isDark),
            const SizedBox(height: 12),
            _textField(
              isDark,
              controller: _geotabCompanyGroupIdController,
              label: 'GeoTab Company Group ID',
              icon: Icons.account_tree_rounded,
              helperText:
                  'Required for zone and device assignment write-backs. Find it in MyGeotab: Administration > Groups > Company Group > Properties.',
            ),
            const SizedBox(height: 12),
            _responsiveFields([
              _textField(
                isDark,
                controller: _depotLatitudeController,
                label: 'Depot latitude',
                icon: Icons.place_rounded,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: (value) => _numberValidator(
                  value,
                  min: -90,
                  max: 90,
                  allowEmpty: true,
                ),
              ),
              _textField(
                isDark,
                controller: _depotLongitudeController,
                label: 'Depot longitude',
                icon: Icons.place_outlined,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: (value) => _numberValidator(
                  value,
                  min: -180,
                  max: 180,
                  allowEmpty: true,
                ),
              ),
            ]),
            const SizedBox(height: 12),
            _responsiveFields([
              _textField(
                isDark,
                controller: _defaultMapLatitudeController,
                label: 'Default map center latitude',
                icon: Icons.my_location_rounded,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: (value) =>
                    _numberValidator(value, min: -90, max: 90),
              ),
              _textField(
                isDark,
                controller: _defaultMapLongitudeController,
                label: 'Default map center longitude',
                icon: Icons.explore_rounded,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: (value) =>
                    _numberValidator(value, min: -180, max: 180),
              ),
            ]),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: accent.withValues(alpha: 0.2)),
              ),
              child: Text(
                'Settings are stored in system_settings and apply to new backend computations immediately. Fuel prices last updated: $_fuelPriceLastUpdated',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  color: isDark ? AppTheme.gray300 : AppTheme.colorFF334155,
                ),
              ),
            ),
            const SizedBox(height: 16),
            _settingsAuditLogCard(isDark),
            const SizedBox(height: 16),
          ],
          if (!_canEditSystemSettings) ...[
            _settingsSectionTitle(isDark, accent, 'Approval center'),
            _writeBackReviewerNotice(isDark, accent),
            const SizedBox(height: 16),
          ],
          _buildRouteWriteBackGuidance(isDark, accent),
          const SizedBox(height: 16),
          _buildWriteBackApprovalCenter(isDark, accent),
        ],
      ),
    );
  }

  Widget _settingsSectionTitle(bool isDark, Color accent, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 18,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: isDark ? AppTheme.white : AppTheme.colorFF111827,
            ),
          ),
        ],
      ),
    );
  }

  Widget _responsiveFields(List<Widget> fields) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 760) {
          return Column(
            children: [
              for (var i = 0; i < fields.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                fields[i],
              ],
            ],
          );
        }

        return Row(
          children: [
            for (var i = 0; i < fields.length; i++) ...[
              if (i > 0) const SizedBox(width: 12),
              Expanded(child: fields[i]),
            ],
          ],
        );
      },
    );
  }

  Widget _writeBackReviewerNotice(bool isDark, Color accent) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.verified_user_rounded, color: accent, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'System Administrators can review, approve, reject, and retry GeoTab write-back jobs here. System configuration fields remain Super Administrator only.',
              style: TextStyle(
                fontSize: 12,
                height: 1.45,
                fontWeight: FontWeight.w700,
                color: isDark ? AppTheme.gray200 : AppTheme.colorFF1A3A6B,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _keyIndicator(bool isDark) {
    final color = _googleMapsServerKeyConfigured
        ? AppTheme.successGreen
        : AppTheme.warningOrange;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: [
          Icon(
            _googleMapsServerKeyConfigured
                ? Icons.verified_rounded
                : Icons.key_off_rounded,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _googleMapsServerKeyConfigured
                  ? 'Google Maps server key is configured. The actual key is hidden.'
                  : 'Google Maps server key is not configured. Add it through environment variables.',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: isDark ? AppTheme.gray200 : AppTheme.colorFF334155,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _geotabDiagnosisBanner(bool isDark) {
    final diagnosis = _geotabDiagnosis;
    if (diagnosis == null) {
      return const SizedBox.shrink();
    }

    final status = diagnosis['status']?.toString() ?? 'unknown';
    final reason = diagnosis['primaryReason']?.toString() ?? 'unknown';
    final actions = ((diagnosis['recommendedActions'] as List?) ?? const [])
        .map((action) => action.toString())
        .where((action) => action.trim().isNotEmpty)
        .toList();
    final color = switch (status) {
      'ok' => AppTheme.colorFF27AE60,
      'warning' => AppTheme.colorFFFFD166,
      'blocked' => AppTheme.colorFFE74C3C,
      _ => AppTheme.colorFF3498DB,
    };
    final textColor = isDark ? AppTheme.white : AppTheme.colorFF1A1D23;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.16 : 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.health_and_safety_rounded, size: 18, color: color),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  status.toUpperCase(),
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  reason,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            SelectableText(
              actions.join('\n'),
              style: TextStyle(
                color: isDark ? AppTheme.gray300 : AppTheme.colorFF334155,
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _settingsAuditLogCard(bool isDark) {
    final entries = _settingsAuditLog.reversed.take(5).toList();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark
            ? AppTheme.white.withValues(alpha: 0.04)
            : AppTheme.colorFFF8FAFC,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Settings Change Log',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: isDark ? AppTheme.white : AppTheme.colorFF111827,
            ),
          ),
          TextButton.icon(
            onPressed: () => Navigator.pushNamed(context, '/audit-logs'),
            icon: const Icon(Icons.history_rounded, size: 16),
            label: const Text('View full administrative audit trail'),
          ),
          const SizedBox(height: 8),
          if (entries.isEmpty)
            Text(
              'No system setting changes have been recorded yet.',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? AppTheme.gray400 : AppTheme.colorFF64748B,
              ),
            )
          else
            ...entries.map((entry) {
              final fields = ((entry['changedFields'] as List?) ?? const [])
                  .map((value) => value.toString())
                  .join(', ');
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${entry['timestamp'] ?? ''} - ${entry['actor'] ?? 'system'} changed ${fields.isEmpty ? 'settings' : fields}',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? AppTheme.gray300 : AppTheme.colorFF475569,
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildRouteWriteBackGuidance(bool isDark, Color accent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.alt_route_rounded, size: 16, color: accent),
            const SizedBox(width: 8),
            Text(
              'GeoTab Route Push Flow',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: isDark ? AppTheme.white : AppTheme.colorFF111827,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isDark
                ? AppTheme.primaryBlue.withValues(alpha: 0.12)
                : AppTheme.primaryBlue.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: AppTheme.primaryBlue.withValues(alpha: 0.25),
            ),
          ),
          child: Text(
            'Create and save routes locally from the Routes page first. '
            'When the local route is correct, use Push to GeoTab there to '
            'review the exact payload before staging it for admin approval. '
            'Direct route staging from Settings has been disabled to protect '
            'the preview-first write-back workflow.',
            style: TextStyle(
              height: 1.45,
              color: isDark ? AppTheme.gray200 : AppTheme.colorFF1A3A6B,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWriteBackApprovalCenter(bool isDark, Color accent) {
    final jobs = _writeBackJobs.take(8).toList();
    final pendingCount = _writeBackJobs
        .where((job) => job['status']?.toString() == 'pending_approval')
        .length;
    final needsCompanyGroupWarning =
        !_geotabCompanyGroupConfigured &&
        jobs.any((job) => job['requiresGeotabCompanyGroup'] == true);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.cloud_sync_rounded, size: 16, color: accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'GeoTab Write-Back Approval',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: isDark ? AppTheme.white : AppTheme.colorFF111827,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              ),
              child: Text(
                '$pendingCount pending',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: accent,
                ),
              ),
            ),
            IconButton(
              tooltip: _writeBackExpanded
                  ? 'Collapse approval section'
                  : 'Expand approval section',
              onPressed: _toggleWriteBackExpanded,
              icon: Icon(
                _writeBackExpanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
              ),
            ),
            IconButton(
              tooltip: 'Refresh write-back jobs',
              onPressed: _writeBackLoading
                  ? null
                  : () => _loadWriteBackJobs(forceRefresh: true),
              icon: _writeBackLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        if (_writeBackExpanded) ...[
          const SizedBox(height: 8),
          if (needsCompanyGroupWarning) ...[
            _writeBackCompanyGroupWarning(isDark),
            const SizedBox(height: 8),
          ],
          if (jobs.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark
                    ? AppTheme.white.withValues(alpha: 0.04)
                    : AppTheme.colorFFF8FAFC,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'No GeoTab write-back jobs are waiting for review.',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? AppTheme.gray400 : AppTheme.colorFF64748B,
                ),
              ),
            )
          else
            Column(
              children: jobs.map((job) {
                final id = job['id']?.toString() ?? '';
                final status = job['status']?.toString() ?? 'pending_approval';
                final statusColor = _writeBackStatusColor(status);
                final error = job['lastError']?.toString() ?? '';
                final inlineError = _writeBackInlineErrors[id] ?? '';
                final canDelete = !const {
                  'approved',
                  'processing',
                  'succeeded',
                }.contains(status);
                final nextAttemptAt = job['nextAttemptAt']?.toString() ?? '';
                final auditTrail = ((job['auditTrail'] as List?) ?? const [])
                    .whereType<Map>()
                    .map((entry) => Map<String, dynamic>.from(entry))
                    .toList();
                final summary = job['payloadSummary'] is Map
                    ? Map<String, dynamic>.from(job['payloadSummary'] as Map)
                    : <String, dynamic>{};
                final jobName = summary['name']?.toString().trim() ?? '';
                final title = jobName.isNotEmpty
                    ? jobName
                    : _writeBackActionLabel(job['action']?.toString() ?? '');

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark
                        ? AppTheme.white.withValues(alpha: 0.04)
                        : AppTheme.colorFFF8FAFC,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: statusColor.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 44,
                            decoration: BoxDecoration(
                              color: statusColor,
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                    color: isDark
                                        ? AppTheme.white
                                        : AppTheme.colorFF111827,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '${_writeBackActionLabel(job['action']?.toString() ?? '')} - $status',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark
                                        ? AppTheme.gray400
                                        : AppTheme.colorFF64748B,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  'Staged by ${job['createdBy'] ?? 'system'} on ${job['createdAt'] ?? 'N/A'}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark
                                        ? AppTheme.gray400
                                        : AppTheme.colorFF64748B,
                                  ),
                                ),
                                if (nextAttemptAt.isNotEmpty) ...[
                                  const SizedBox(height: 3),
                                  Text(
                                    'Next retry: $nextAttemptAt',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isDark
                                          ? AppTheme.gray400
                                          : AppTheme.colorFF64748B,
                                    ),
                                  ),
                                ],
                                if (error.isNotEmpty) ...[
                                  const SizedBox(height: 3),
                                  Text(
                                    status == 'rejected'
                                        ? 'Rejection reason: $error'
                                        : error,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.colorFFEF4444,
                                    ),
                                  ),
                                ],
                                if (inlineError.isNotEmpty) ...[
                                  const SizedBox(height: 3),
                                  Text(
                                    inlineError,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.errorRed,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (status == 'pending_approval' ||
                              status == 'failed')
                            IconButton(
                              tooltip: 'Approve',
                              onPressed: _writeBackLoading
                                  ? null
                                  : () => _approveWriteBackJob(job),
                              icon: const Icon(Icons.check_circle_rounded),
                              color: AppTheme.colorFF16A34A,
                            ),
                          if (status == 'failed' ||
                              status == 'cancelled' ||
                              status == 'permanently_failed')
                            IconButton(
                              tooltip: 'Retry',
                              onPressed: _writeBackLoading
                                  ? null
                                  : () => _retryWriteBackJob(id),
                              icon: const Icon(Icons.restart_alt_rounded),
                            ),
                          if (status != 'succeeded' &&
                              status != 'processing' &&
                              status != 'rejected')
                            IconButton(
                              tooltip: 'Reject',
                              onPressed: _writeBackLoading
                                  ? null
                                  : () => _rejectWriteBackJob(job),
                              icon: const Icon(Icons.cancel_rounded),
                              color: AppTheme.colorFFEF4444,
                            ),
                          IconButton(
                            tooltip: canDelete
                                ? 'Delete pending job'
                                : 'Executed or approved jobs cannot be deleted',
                            onPressed: _writeBackLoading || !canDelete
                                ? null
                                : () => _deleteWriteBackJob(job),
                            icon: const Icon(Icons.delete_outline_rounded),
                            color: AppTheme.errorRed,
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _writeBackPreviewPanel(isDark, job),
                      if (auditTrail.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        _writeBackAuditTrail(isDark, auditTrail),
                      ],
                    ],
                  ),
                );
              }).toList(),
            ),
        ],
      ],
    );
  }

  Widget _writeBackCompanyGroupWarning(bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.warningOrange.withValues(alpha: isDark ? 0.14 : 0.1),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(
          color: AppTheme.warningOrange.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: AppTheme.warningOrange,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Zone push requires GeoTab Company Group ID to be configured in Settings -> Map Settings before zones can be pushed.',
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                fontWeight: FontWeight.w600,
                color: isDark ? AppTheme.gray200 : AppTheme.colorFF334155,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _writeBackStatusColor(String status) {
    switch (status) {
      case 'succeeded':
        return AppTheme.colorFF16A34A;
      case 'failed':
      case 'permanently_failed':
      case 'rejected':
        return AppTheme.colorFFEF4444;
      case 'processing':
      case 'approved':
        return AppTheme.colorFF2563EB;
      case 'cancelled':
        return AppTheme.colorFF64748B;
      default:
        return AppTheme.colorFFF59E0B;
    }
  }

  Widget _writeBackPreviewPanel(bool isDark, Map<String, dynamic> job) {
    final preview = job['previewPayload'] is Map
        ? Map<String, dynamic>.from(job['previewPayload'] as Map)
        : <String, dynamic>{};
    final payload = preview['payload'] ?? job['payload'];
    final snapshot = preview['snapshot'];
    final rows = ((preview['rows'] as List?) ?? const [])
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    final groups = ((preview['groups'] as List?) ?? const [])
        .whereType<Map>()
        .map((group) => Map<String, dynamic>.from(group))
        .toList();
    final entityType =
        preview['entityType']?.toString() ??
        job['entityType']?.toString() ??
        'GeoTab entity';
    final entityName =
        preview['entityName']?.toString() ??
        (job['payloadSummary'] is Map
            ? (job['payloadSummary'] as Map)['name']?.toString()
            : null) ??
        entityType;

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: AppTheme.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Text(
          'Review before/after GeoTab preview',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: isDark ? AppTheme.white : AppTheme.colorFF111827,
          ),
        ),
        subtitle: Text(
          'Approvers see the same payload review the requester confirmed.',
          style: TextStyle(
            fontSize: 12,
            color: isDark ? AppTheme.gray400 : AppTheme.colorFF64748B,
          ),
        ),
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: GeotabPushPreviewContent(
              entityType: entityType,
              entityName: entityName,
              payload: payload,
              snapshot: snapshot,
              previewRows: rows,
              previewGroups: groups,
              isFirstPushOverride: preview['isFirstPush'] == true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _writeBackAuditTrail(
    bool isDark,
    List<Map<String, dynamic>> auditTrail,
  ) {
    final entries = auditTrail.reversed.take(4).toList();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark
            ? AppTheme.black.withValues(alpha: 0.18)
            : AppTheme.white.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: entries.map((entry) {
          final event = entry['event']?.toString() ?? 'updated';
          final actor = entry['actor']?.toString() ?? 'system';
          final timestamp = entry['timestamp']?.toString() ?? '';
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '$event by $actor${timestamp.isEmpty ? '' : ' - $timestamp'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? AppTheme.gray400 : AppTheme.colorFF64748B,
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  String _writeBackActionLabel(String action) {
    switch (action) {
      case 'driver.create':
        return 'Create driver in MyGeotab';
      case 'driver.update':
        return 'Update MyGeotab driver';
      case 'driver.deactivate':
        return 'Deactivate MyGeotab driver';
      case 'route.create':
        return 'Create MyGeotab route';
      case 'route.assign_device':
        return 'Assign vehicle to route';
      default:
        return action.isEmpty ? 'GeoTab write-back' : action;
    }
  }

  Widget _buildAboutCard(bool isDark) {
    return _settingsCard(
      isDark,
      title: 'About',
      icon: Icons.info_rounded,
      subtitle: 'Version and architecture reference.',
      accent: AppTheme.colorFF14B8A6,
      child: Column(
        children: [
          _aboutRow(isDark, Icons.apps_rounded, 'Application', 'PioneerPath'),
          const SizedBox(height: 8),
          _aboutRow(
            isDark,
            Icons.route_rounded,
            'Tagline',
            'Chart the route. Lead the way.',
          ),
          const SizedBox(height: 8),
          _aboutRow(isDark, Icons.tag_rounded, 'Version', '1.0.0'),
          const SizedBox(height: 8),
          _aboutRow(
            isDark,
            Icons.architecture_rounded,
            'Architecture',
            'MyGeotab -> Laravel -> Flutter',
          ),
        ],
      ),
    );
  }

  Widget _settingsCard(
    bool isDark, {
    required String title,
    required IconData icon,
    required Widget child,
    String? subtitle,
    Color? accent,
  }) {
    final cardAccent = accent ?? AppTheme.colorFF4B7BE5;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF111827 : AppTheme.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? cardAccent.withValues(alpha: 0.18)
              : AppTheme.black.withValues(alpha: 0.06),
        ),
        boxShadow: [
          BoxShadow(
            color: AppTheme.black.withValues(alpha: isDark ? 0.18 : 0.04),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: cardAccent.withValues(alpha: isDark ? 0.18 : 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 18, color: cardAccent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: isDark ? AppTheme.white : AppTheme.colorFF111827,
                      ),
                    ),
                    if (subtitle != null && subtitle.trim().isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: isDark
                              ? AppTheme.gray400
                              : AppTheme.colorFF64748B,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  Widget _settingsInfoBanner(
    bool isDark, {
    required IconData icon,
    required String title,
    required String body,
    required Color color,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.14 : 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    color: isDark ? AppTheme.white : AppTheme.colorFF111827,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: isDark ? AppTheme.gray300 : AppTheme.colorFF475569,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _textField(
    bool isDark, {
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? Function(String?)? validator,
    int maxLines = 1,
    TextInputType? keyboardType,
    String? helperText,
  }) {
    return TextFormField(
      controller: controller,
      validator: validator,
      maxLines: maxLines,
      keyboardType: keyboardType,
      style: TextStyle(color: isDark ? AppTheme.white : AppTheme.colorFF1A1D23),
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        prefixIcon: Icon(icon),
        filled: true,
        fillColor: isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF8FAFC,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _readOnlyField(
    bool isDark, {
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF8FAFC,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: isDark ? AppTheme.gray400 : AppTheme.materialGrey,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? AppTheme.gray500 : AppTheme.gray600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppTheme.white : AppTheme.colorFF1A1D23,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dropdownField(
    bool isDark, {
    required String label,
    required String value,
    required IconData icon,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        filled: true,
        fillColor: isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF8FAFC,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      items: items
          .map((item) => DropdownMenuItem(value: item, child: Text(item)))
          .toList(),
    );
  }

  Widget _toggleRow(
    bool isDark, {
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    required Color accent,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF0F1117 : AppTheme.colorFFF8FAFC,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppTheme.white : AppTheme.colorFF1A1D23,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: isDark ? AppTheme.gray500 : AppTheme.gray600,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            thumbColor: MaterialStateProperty.resolveWith<Color?>((states) {
              if (states.contains(MaterialState.selected)) return accent;
              return null;
            }),
            trackColor: MaterialStateProperty.resolveWith<Color?>((states) {
              if (states.contains(MaterialState.selected))
                return accent.withAlpha(56);
              return null;
            }),
          ),
        ],
      ),
    );
  }

  Widget _aboutRow(bool isDark, IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(
          icon,
          size: 14,
          color: isDark ? AppTheme.gray500 : AppTheme.materialGrey,
        ),
        const SizedBox(width: 8),
        Text(
          '$label:',
          style: TextStyle(
            fontSize: 12,
            color: isDark ? AppTheme.gray500 : AppTheme.gray600,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.gray300 : AppTheme.colorFF1A1D23,
            ),
          ),
        ),
      ],
    );
  }
}
