import 'package:flutter/material.dart';

import '../services/auth.dart';
import '../services/route_guard.dart';
import '../theme/app_theme.dart';

class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final ok = await AuthService.changePassword(
      currentPassword: _current.text,
      newPassword: _next.text,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _saving = false;
      _error = ok ? null : AuthService.lastAuthError;
    });

    if (ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Password updated.')));
      Navigator.pushReplacementNamed(context, RouteGuard.getHomeRoute());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.getBackgroundColor(context),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            color: AppTheme.getCardBg(context),
            child: Padding(
              padding: const EdgeInsets.all(AppTheme.space24),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Change temporary password',
                      style: AppTheme.getHeadingStyle(context),
                    ),
                    const SizedBox(height: AppTheme.space8),
                    Text(
                      'Set a new password before continuing to PioneerPath.',
                      style: AppTheme.getBodyStyle(
                        context,
                      ).copyWith(color: AppTheme.getSubtleTextColor(context)),
                    ),
                    const SizedBox(height: AppTheme.space24),
                    TextFormField(
                      controller: _current,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Current temporary password',
                      ),
                      validator: (value) => (value ?? '').isEmpty
                          ? 'Enter your current password.'
                          : null,
                    ),
                    const SizedBox(height: AppTheme.space16),
                    TextFormField(
                      controller: _next,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'New password',
                      ),
                      validator: (value) {
                        if ((value ?? '').length < 8) {
                          return 'Password must be at least 8 characters.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: AppTheme.space16),
                    TextFormField(
                      controller: _confirm,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Confirm new password',
                      ),
                      validator: (value) => value != _next.text
                          ? 'Passwords do not match.'
                          : null,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: AppTheme.space12),
                      Text(
                        _error!,
                        style: AppTheme.getCaptionStyle(
                          context,
                        ).copyWith(color: AppTheme.errorRed),
                      ),
                    ],
                    const SizedBox(height: AppTheme.space24),
                    ElevatedButton(
                      onPressed: _saving ? null : _submit,
                      child: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Update password'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
