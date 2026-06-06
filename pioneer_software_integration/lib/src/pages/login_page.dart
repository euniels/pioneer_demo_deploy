import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/auth.dart';
import '../services/fleet_data_coordinator.dart';
import '../services/realtime_stream_service.dart';
import '../widgets/premium_glass_card.dart';
import '../widgets/pioneer_logo.dart';
import '../services/route_guard.dart';
import '../services/push_notification_service.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  String? _error;
  bool _obscurePass = true;
  bool _rememberMe = false;
  bool _showAccounts = false;

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    AuthService.getRememberedUser().then((u) {
      if (!mounted) return;
      if (u != null && u.isNotEmpty) {
        setState(() {
          _userCtrl.text = u;
          _rememberMe = true;
        });
      } else if (kDebugMode) {
        setState(() {
          _userCtrl.text = 'admin@pioneerpath.local';
          _passCtrl.text = 'Pioneer@12345';
        });
      }
    });
  }

  Future<void> _doLogin() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final ok = await AuthService.login(
      _userCtrl.text.trim(),
      _passCtrl.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
    });
    if (!ok) {
      setState(() {
        _error = AuthService.lastAuthError ?? 'Invalid email or password.';
      });
      return;
    }
    if (_rememberMe) {
      await AuthService.setRememberedUser(_userCtrl.text.trim());
    } else {
      await AuthService.setRememberedUser('');
    }
    if (!mounted) return;

    unawaited(
      PushNotificationService.registerAfterAuthenticatedLogin().catchError(
        (_) {},
      ),
    );

    // â”€â”€ Route to the correct home page based on role â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    unawaited(
      FleetDataCoordinator.initialize()
          .then(
            (_) => FleetDataCoordinator.startPriorityQueue(forceRefresh: true),
          )
          .catchError((_) {}),
    );
    RealtimeStreamService.start();

    final homeRoute = AuthService.mustChangePassword
        ? '/change-password'
        : RouteGuard.getHomeRoute();
    Navigator.pushReplacementNamed(context, homeRoute);
  }

  Future<void> _showForgotPasswordDialog() async {
    final emailCtrl = TextEditingController(text: _userCtrl.text.trim());
    final formKey = GlobalKey<FormState>();
    var submitting = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final isDark = Theme.of(dialogContext).brightness == Brightness.dark;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: isDark ? AppTheme.colorFF111827 : AppTheme.white,
              title: const Text('Reset password'),
              content: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Enter your account email. We will send a reset link that expires in 60 minutes.',
                      style: TextStyle(
                        color: isDark ? AppTheme.white70 : AppTheme.black54,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'Email address',
                        prefixIcon: Icon(Icons.email_rounded),
                      ),
                      validator: (value) {
                        final text = (value ?? '').trim();
                        if (text.isEmpty) {
                          return 'Email address is required.';
                        }
                        if (!text.contains('@')) {
                          return 'Enter a valid email address.';
                        }
                        return null;
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: submitting
                      ? null
                      : () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: submitting
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;
                          setDialogState(() => submitting = true);
                          final ok = await AuthService.requestPasswordReset(
                            emailCtrl.text.trim(),
                          );
                          if (!mounted) return;
                          Navigator.pop(dialogContext);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                ok
                                    ? 'If that account exists, a reset link has been sent.'
                                    : AuthService.lastAuthError ??
                                          'Unable to send reset link.',
                              ),
                            ),
                          );
                        },
                  child: submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Send link'),
                ),
              ],
            );
          },
        );
      },
    );

    emailCtrl.dispose();
  }

  Widget _accountRow({
    required bool isDark,
    required String username,
    required String label,
    required String description,
    required Color color,
    required IconData icon,
    required VoidCallback onFill,
    bool isLast = false,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 8),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 17),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppTheme.white : AppTheme.colorFF2C3E50,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$username - $description',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? AppTheme.white54 : AppTheme.black45,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: onFill,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                  color: color.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: Text(
                'Fill',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sw = MediaQuery.of(context).size.width;
    final isVerySmall = sw < 360;
    final baseMedia = MediaQuery.of(context);
    return MediaQuery(
      data: baseMedia.copyWith(textScaler: TextScaler.noScaling),
      child: Scaffold(
        backgroundColor: AppTheme.getBackgroundColor(context),
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [AppTheme.darkBg, AppTheme.colorFF0F1A30, AppTheme.darkBg]
                  : [AppTheme.lightBg, AppTheme.white, AppTheme.lightBg],
            ),
          ),
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: isVerySmall ? 12 : 16,
                  ),
                  child: Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: PremiumGlassCard(
                      elevation: 32,
                      padding: EdgeInsets.symmetric(
                        horizontal: isVerySmall ? 14 : 20,
                        vertical: isVerySmall ? 18 : 24,
                      ),
                      child: DefaultTextStyle.merge(
                        style: TextStyle(
                          color: isDark ? AppTheme.white : AppTheme.black87,
                          fontFamily: 'Arial',
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // Logo
                            PioneerPathLogo(
                              size: isVerySmall ? 52 : 64,
                              variant: isDark
                                  ? PioneerPathLogoVariant.lightOnDark
                                  : PioneerPathLogoVariant.darkOnLight,
                            ),
                            SizedBox(height: isVerySmall ? 16 : 24),

                            // Heading
                            Text(
                              'Welcome to PioneerPath',
                              style: TextStyle(
                                fontSize: isVerySmall ? 20 : 26,
                                fontWeight: FontWeight.w900,
                                color: isDark
                                    ? AppTheme.white
                                    : AppTheme.black87,
                                fontFamily: 'Arial',
                              ),
                            ),
                            const SizedBox(height: 8),

                            // Subtitle
                            Text(
                              'Sign in to your account',
                              style: TextStyle(
                                fontSize: isVerySmall ? 13 : 15,
                                color: isDark
                                    ? AppTheme.white60
                                    : AppTheme.black45,
                                fontWeight: FontWeight.w500,
                                fontFamily: 'Arial',
                              ),
                            ),
                            SizedBox(height: isVerySmall ? 20 : 32),

                            // Error message
                            if (_error != null)
                              Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: AppTheme.errorRed.withValues(
                                    alpha: (31 / 255),
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: AppTheme.errorRed.withValues(
                                      alpha: ((128) / 255),
                                    ),
                                    width: 1.5,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.error_rounded,
                                      color: AppTheme.errorRed,
                                      size: 22,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        _error!,
                                        style: TextStyle(
                                          color: AppTheme.errorRed,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          fontFamily: 'Arial',
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                            if (_error != null) const SizedBox(height: 24),

                            // Form
                            Form(
                              key: _formKey,
                              child: Column(
                                children: [
                                  // Username field
                                  TextFormField(
                                    controller: _userCtrl,
                                    style: TextStyle(
                                      color: isDark
                                          ? AppTheme.white
                                          : AppTheme.black87,
                                      fontWeight: FontWeight.w500,
                                      fontSize: 15,
                                      fontFamily: 'Arial',
                                    ),
                                    decoration: InputDecoration(
                                      labelText: 'Email or username',
                                      hintText: 'admin@pioneerpath.local',
                                      labelStyle: TextStyle(
                                        color: isDark
                                            ? AppTheme.white60
                                            : AppTheme.black54,
                                        fontWeight: FontWeight.w500,
                                        fontFamily: 'Arial',
                                      ),
                                      prefixIcon: const Icon(
                                        Icons.person_rounded,
                                        color: AppTheme.errorRed,
                                        size: 22,
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(14),
                                        borderSide: BorderSide(
                                          color:
                                              (isDark
                                                      ? AppTheme.white
                                                      : AppTheme.black26)
                                                  .withValues(
                                                    alpha: ((80) / 255),
                                                  ),
                                          width: 1.5,
                                        ),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(14),
                                        borderSide: const BorderSide(
                                          color: AppTheme.errorRed,
                                          width: 2.5,
                                        ),
                                      ),
                                      errorBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(14),
                                        borderSide: BorderSide(
                                          color: AppTheme.errorRed,
                                          width: 1.5,
                                        ),
                                      ),
                                      focusedErrorBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(14),
                                        borderSide: BorderSide(
                                          color: AppTheme.errorRed,
                                          width: 2.5,
                                        ),
                                      ),
                                      filled: true,
                                      fillColor:
                                          (isDark
                                                  ? AppTheme.white
                                                  : AppTheme.black12)
                                              .withValues(alpha: ((20) / 255)),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            vertical: 18,
                                            horizontal: 16,
                                          ),
                                    ),
                                    validator: (v) => (v == null || v.isEmpty)
                                        ? 'Email or username is required'
                                        : null,
                                  ),

                                  const SizedBox(height: 18),

                                  // Password field
                                  TextFormField(
                                    controller: _passCtrl,
                                    style: TextStyle(
                                      color: isDark
                                          ? AppTheme.white
                                          : AppTheme.black87,
                                      fontWeight: FontWeight.w500,
                                      fontSize: 15,
                                      fontFamily: 'Arial',
                                    ),
                                    obscureText: _obscurePass,
                                    decoration: InputDecoration(
                                      labelText: 'Password',
                                      hintText: 'Enter your password',
                                      labelStyle: TextStyle(
                                        color: isDark
                                            ? AppTheme.white60
                                            : AppTheme.black54,
                                        fontWeight: FontWeight.w500,
                                        fontFamily: 'Arial',
                                      ),
                                      prefixIcon: const Icon(
                                        Icons.lock_rounded,
                                        color: AppTheme.errorRed,
                                        size: 22,
                                      ),
                                      suffixIcon: MouseRegion(
                                        cursor: SystemMouseCursors.click,
                                        child: GestureDetector(
                                          onTap: () => setState(
                                            () => _obscurePass = !_obscurePass,
                                          ),
                                          child: Icon(
                                            _obscurePass
                                                ? Icons.visibility_off_rounded
                                                : Icons.visibility_rounded,
                                            color: AppTheme.errorRed,
                                            size: 22,
                                          ),
                                        ),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(14),
                                        borderSide: BorderSide(
                                          color:
                                              (isDark
                                                      ? AppTheme.white
                                                      : AppTheme.black26)
                                                  .withValues(
                                                    alpha: ((80) / 255),
                                                  ),
                                          width: 1.5,
                                        ),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(14),
                                        borderSide: const BorderSide(
                                          color: AppTheme.errorRed,
                                          width: 2.5,
                                        ),
                                      ),
                                      errorBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(14),
                                        borderSide: BorderSide(
                                          color: AppTheme.errorRed,
                                          width: 1.5,
                                        ),
                                      ),
                                      focusedErrorBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(14),
                                        borderSide: BorderSide(
                                          color: AppTheme.errorRed,
                                          width: 2.5,
                                        ),
                                      ),
                                      filled: true,
                                      fillColor:
                                          (isDark
                                                  ? AppTheme.white
                                                  : AppTheme.black12)
                                              .withValues(alpha: ((20) / 255)),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            vertical: 18,
                                            horizontal: 16,
                                          ),
                                    ),
                                    validator: (v) => (v == null || v.isEmpty)
                                        ? 'Password is required'
                                        : null,
                                  ),

                                  const SizedBox(height: 16),

                                  // Remember me & Forgot password
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Row(
                                        children: [
                                          Checkbox(
                                            value: _rememberMe,
                                            onChanged: (v) => setState(
                                              () => _rememberMe = v ?? false,
                                            ),
                                            fillColor:
                                                WidgetStateProperty.resolveWith(
                                                  (states) =>
                                                      states.contains(
                                                        WidgetState.selected,
                                                      )
                                                      ? AppTheme.errorRed
                                                      : AppTheme.transparent,
                                                ),
                                            side: BorderSide(
                                              color:
                                                  (isDark
                                                          ? AppTheme.white
                                                          : AppTheme.black38)
                                                      .withValues(
                                                        alpha: ((100) / 255),
                                                      ),
                                              width: 1.5,
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                          ),
                                          Text(
                                            'Remember me',
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: isDark
                                                  ? AppTheme.white60
                                                  : AppTheme.black54,
                                              fontWeight: FontWeight.w500,
                                              fontFamily: 'Arial',
                                            ),
                                          ),
                                        ],
                                      ),
                                      TextButton(
                                        onPressed: _loading
                                            ? null
                                            : _showForgotPasswordDialog,
                                        child: const Text(
                                          'Forgot password?',
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: AppTheme.errorRed,
                                            fontWeight: FontWeight.w600,
                                            fontFamily: 'Arial',
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),

                                  const SizedBox(height: 28),

                                  // Sign in button
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton(
                                      onPressed: _loading ? null : _doLogin,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppTheme.errorRed,
                                        disabledBackgroundColor: AppTheme
                                            .errorRed
                                            .withValues(alpha: ((150) / 255)),
                                        elevation: _loading ? 0 : 12,
                                        shadowColor: AppTheme.errorRed
                                            .withValues(alpha: ((128) / 255)),
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 18,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                        ),
                                      ),
                                      child: _loading
                                          ? const SizedBox(
                                              width: 22,
                                              height: 22,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2.5,
                                                valueColor:
                                                    AlwaysStoppedAnimation(
                                                      AppTheme.white,
                                                    ),
                                              ),
                                            )
                                          : const Text(
                                              'Sign In',
                                              style: TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.w700,
                                                color: AppTheme.white,
                                                fontFamily: 'Arial',
                                              ),
                                            ),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            SizedBox(height: isVerySmall ? 14 : 20),

                            // Demo accounts panel (collapsible dropdown)
                            Container(
                              decoration: BoxDecoration(
                                color: AppTheme.errorRed.withValues(
                                  alpha: ((26) / 255),
                                ),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: AppTheme.errorRed.withValues(
                                    alpha: ((102) / 255),
                                  ),
                                  width: 1.5,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // â”€â”€ Tappable header â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                                  GestureDetector(
                                    onTap: () => setState(
                                      () => _showAccounts = !_showAccounts,
                                    ),
                                    behavior: HitTestBehavior.opaque,
                                    child: Padding(
                                      padding: EdgeInsets.all(
                                        isVerySmall ? 12 : 14,
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.all(6),
                                            decoration: BoxDecoration(
                                              color: AppTheme.errorRed
                                                  .withValues(
                                                    alpha: ((51) / 255),
                                                  ),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: const Icon(
                                              Icons.info_rounded,
                                              color: AppTheme.errorRed,
                                              size: 18,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          const Text(
                                            'Demo Accounts',
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: AppTheme.errorRed,
                                              fontWeight: FontWeight.w800,
                                              fontFamily: 'Arial',
                                            ),
                                          ),
                                          const Spacer(),
                                          if (!_showAccounts)
                                            Text(
                                              'Tap to expand',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: isDark
                                                    ? AppTheme.white38
                                                    : AppTheme.black38,
                                                fontWeight: FontWeight.w500,
                                                fontFamily: 'Arial',
                                              ),
                                            ),
                                          const SizedBox(width: 6),
                                          AnimatedRotation(
                                            turns: _showAccounts ? 0.5 : 0,
                                            duration: const Duration(
                                              milliseconds: 250,
                                            ),
                                            child: Icon(
                                              Icons.keyboard_arrow_down_rounded,
                                              color: AppTheme.errorRed,
                                              size: 20,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),

                                  // â”€â”€ Animated body â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                                  AnimatedSize(
                                    duration: const Duration(milliseconds: 300),
                                    curve: Curves.easeInOut,
                                    child: _showAccounts
                                        ? Padding(
                                            padding: EdgeInsets.fromLTRB(
                                              isVerySmall ? 12 : 14,
                                              0,
                                              isVerySmall ? 12 : 14,
                                              isVerySmall ? 12 : 14,
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Divider(
                                                  height: 1,
                                                  color: AppTheme.errorRed
                                                      .withValues(
                                                        alpha: ((40) / 255),
                                                      ),
                                                ),
                                                const SizedBox(height: 10),
                                                Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.end,
                                                  children: [
                                                    Text(
                                                      'Demo password for all accounts: Pioneer@12345',
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        color: isDark
                                                            ? AppTheme.white54
                                                            : AppTheme.black45,
                                                        fontWeight:
                                                            FontWeight.w500,
                                                        fontFamily: 'Arial',
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 8),
                                                _accountRow(
                                                  isDark: isDark,
                                                  username:
                                                      'system@pioneerpath.local',
                                                  label: 'System Administrator',
                                                  description:
                                                      'User accounts and role-based permissions',
                                                  color: AppTheme.errorRed,
                                                  icon: Icons
                                                      .admin_panel_settings_rounded,
                                                  onFill: () {
                                                    _userCtrl.text =
                                                        'system@pioneerpath.local';
                                                    _passCtrl.text =
                                                        'Pioneer@12345';
                                                    setState(
                                                      () =>
                                                          _showAccounts = false,
                                                    );
                                                  },
                                                ),
                                                _accountRow(
                                                  isDark: isDark,
                                                  username:
                                                      'fleet@pioneerpath.local',
                                                  label: 'Fleet Manager',
                                                  description:
                                                      'Vehicles, drivers, tracking, maintenance, and analytics',
                                                  color: AppTheme.infoBlue,
                                                  icon: Icons
                                                      .local_shipping_rounded,
                                                  onFill: () {
                                                    _userCtrl.text =
                                                        'fleet@pioneerpath.local';
                                                    _passCtrl.text =
                                                        'Pioneer@12345';
                                                    setState(
                                                      () =>
                                                          _showAccounts = false,
                                                    );
                                                  },
                                                ),
                                                _accountRow(
                                                  isDark: isDark,
                                                  username:
                                                      'dispatcher@pioneerpath.local',
                                                  label: 'Dispatcher',
                                                  description:
                                                      'Trip requests, assignments, and dispatch monitoring',
                                                  color: AppTheme.warningOrange,
                                                  icon: Icons.send_rounded,
                                                  onFill: () {
                                                    _userCtrl.text =
                                                        'dispatcher@pioneerpath.local';
                                                    _passCtrl.text =
                                                        'Pioneer@12345';
                                                    setState(
                                                      () =>
                                                          _showAccounts = false,
                                                    );
                                                  },
                                                ),
                                                _accountRow(
                                                  isDark: isDark,
                                                  username:
                                                      'accounting@pioneerpath.local',
                                                  label: 'Accounting Staff',
                                                  description:
                                                      'Invoices, billing records, payments, and audit trail',
                                                  color: AppTheme.successGreen,
                                                  icon: Icons
                                                      .account_balance_rounded,
                                                  onFill: () {
                                                    _userCtrl.text =
                                                        'accounting@pioneerpath.local';
                                                    _passCtrl.text =
                                                        'Pioneer@12345';
                                                    setState(
                                                      () =>
                                                          _showAccounts = false,
                                                    );
                                                  },
                                                ),
                                                _accountRow(
                                                  isDark: isDark,
                                                  username:
                                                      'admin@pioneerpath.local',
                                                  label: 'Company Executives',
                                                  description:
                                                      'High-level KPI, revenue, and operational dashboards',
                                                  color: AppTheme.purpleAccent,
                                                  icon: Icons
                                                      .business_center_rounded,
                                                  onFill: () {
                                                    _userCtrl.text =
                                                        'admin@pioneerpath.local';
                                                    _passCtrl.text =
                                                        'Pioneer@12345';
                                                    setState(
                                                      () =>
                                                          _showAccounts = false,
                                                    );
                                                  },
                                                ),
                                                _accountRow(
                                                  isDark: isDark,
                                                  username:
                                                      'driver@pioneerpath.local',
                                                  label: 'Truck Driver',
                                                  description:
                                                      'Assignments, trip status updates, and proof of delivery',
                                                  color: AppTheme.accentCyan,
                                                  icon: Icons
                                                      .person_pin_circle_rounded,
                                                  isLast: true,
                                                  onFill: () {
                                                    _userCtrl.text =
                                                        'driver@pioneerpath.local';
                                                    _passCtrl.text =
                                                        'Pioneer@12345';
                                                    setState(
                                                      () =>
                                                          _showAccounts = false,
                                                    );
                                                  },
                                                ),
                                              ],
                                            ),
                                          )
                                        : const SizedBox.shrink(),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
