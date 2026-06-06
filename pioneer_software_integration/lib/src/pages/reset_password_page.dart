import 'package:flutter/material.dart';

import '../services/auth.dart';
import '../services/route_guard.dart';
import '../theme/app_theme.dart';

class ResetPasswordPage extends StatefulWidget {
  const ResetPasswordPage({super.key, this.email = '', this.token = ''});

  final String email;
  final String token;

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _emailCtrl;
  late final TextEditingController _passwordCtrl;
  late final TextEditingController _confirmCtrl;
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _emailCtrl = TextEditingController(text: widget.email);
    _passwordCtrl = TextEditingController();
    _confirmCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    final ok = await AuthService.resetPasswordWithToken(
      email: _emailCtrl.text.trim(),
      token: widget.token,
      password: _passwordCtrl.text,
    );

    if (!mounted) return;
    setState(() => _loading = false);
    if (!ok) {
      setState(() {
        _error = AuthService.lastAuthError ?? 'Unable to reset password.';
      });
      return;
    }

    Navigator.pushReplacementNamed(context, RouteGuard.getHomeRoute());
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final missingToken = widget.token.trim().isEmpty;

    return Scaffold(
      backgroundColor: AppTheme.getBackgroundColor(context),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 480),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.colorFF111827 : AppTheme.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark ? AppTheme.white12 : AppTheme.black12,
              ),
              boxShadow: AppTheme.getCardShadow(context),
            ),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.lock_reset_rounded,
                    color: AppTheme.primaryBlue,
                    size: 44,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Set a new password',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: isDark ? AppTheme.white : AppTheme.black87,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    missingToken
                        ? 'This reset link is missing its token. Request a new password reset link.'
                        : 'Use at least 8 characters. This link expires 60 minutes after it was sent.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: isDark ? AppTheme.white60 : AppTheme.black54,
                      height: 1.35,
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    _messageBox(_error!, AppTheme.errorRed, isDark),
                  ],
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: _emailCtrl,
                    enabled: !missingToken,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Email address',
                      prefixIcon: Icon(Icons.email_rounded),
                    ),
                    validator: (value) {
                      final text = (value ?? '').trim();
                      if (text.isEmpty) return 'Email address is required.';
                      if (!text.contains('@')) return 'Enter a valid email.';
                      return null;
                    },
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _passwordCtrl,
                    enabled: !missingToken,
                    obscureText: _obscure,
                    decoration: InputDecoration(
                      labelText: 'New password',
                      prefixIcon: const Icon(Icons.lock_rounded),
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => _obscure = !_obscure),
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded,
                        ),
                      ),
                    ),
                    validator: (value) {
                      if ((value ?? '').length < 8) {
                        return 'Password must be at least 8 characters.';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _confirmCtrl,
                    enabled: !missingToken,
                    obscureText: _obscure,
                    decoration: const InputDecoration(
                      labelText: 'Confirm password',
                      prefixIcon: Icon(Icons.lock_outline_rounded),
                    ),
                    validator: (value) {
                      if (value != _passwordCtrl.text) {
                        return 'Passwords do not match.';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 22),
                  ElevatedButton(
                    onPressed: _loading || missingToken ? null : _submit,
                    child: _loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Reset password'),
                  ),
                  TextButton(
                    onPressed: _loading
                        ? null
                        : () =>
                              Navigator.pushReplacementNamed(context, '/login'),
                    child: const Text('Back to sign in'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _messageBox(String message, Color color, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        message,
        style: TextStyle(
          color: isDark ? AppTheme.white : color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
