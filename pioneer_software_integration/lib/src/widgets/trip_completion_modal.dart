import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../services/backend_api.dart';
import '../services/trips_store.dart';
import '../theme/app_theme.dart';
import '../utils/form_validation.dart';
import 'signature_pad.dart';

Future<bool?> showTripCompletionModal(
  BuildContext context, {
  required String tripId,
  required Map<String, dynamic> tripData,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _TripCompletionModal(tripId: tripId, tripData: tripData),
  );
}

class _TripCompletionModal extends StatefulWidget {
  final String tripId;
  final Map<String, dynamic> tripData;

  const _TripCompletionModal({required this.tripId, required this.tripData});

  @override
  State<_TripCompletionModal> createState() => _TripCompletionModalState();
}

class _TripCompletionModalState extends State<_TripCompletionModal> {
  final _signatureKey = GlobalKey<SignaturePadState>();
  final _recipientController = TextEditingController();
  final _notesController = TextEditingController();
  bool _signatureEmpty = true;
  bool _submitting = false;

  @override
  void dispose() {
    _recipientController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_signatureEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please capture the client signature first.'),
        ),
      );
      return;
    }

    setState(() => _submitting = true);

    final signaturePayload = jsonEncode({
      'strokes': _signatureKey.currentState?.exportStrokes() ?? const [],
    });

    try {
      await BackendApiService.submitProofOfDelivery(
        widget.tripId,
        recipientName: _recipientController.text.trim(),
        notes: _notesController.text.trim(),
        signatureDataUrl: signaturePayload,
        status: 'submitted',
        deliveredAt: DateTime.now(),
      );
      await requestTripCompletion(
        widget.tripId,
        driverNotes: _notesController.text.trim(),
      );
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            FormValidation.backendError(
              error,
              'Proof of delivery could not be saved.',
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final trip = widget.tripData;

    return Dialog(
      backgroundColor: AppTheme.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: AppTheme.getCardBg(context),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppTheme.getBorderColor(context)),
          boxShadow: AppTheme.getElevatedShadow(context),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AppTheme.goldAccent, AppTheme.primaryBlue],
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.assignment_turned_in_rounded,
                      color: AppTheme.white,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Proof of delivery',
                          style: AppTheme.getHeadingStyle(
                            context,
                            fontSize: 22,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.tripId,
                          style: AppTheme.getSubtitleStyle(context),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _submitting
                        ? null
                        : () => Navigator.pop(context, false),
                    icon: Icon(
                      Icons.close_rounded,
                      color: AppTheme.getSubtleTextColor(context),
                    ),
                  ),
                ],
              ).animate().fadeIn(duration: 220.ms),
              const SizedBox(height: 22),
              _SectionCard(
                title: 'Trip summary',
                child: Column(
                  children: [
                    _SummaryRow(label: 'Client', value: trip['customer']),
                    _SummaryRow(label: 'From', value: trip['origin']),
                    _SummaryRow(label: 'To', value: trip['destination']),
                    _SummaryRow(label: 'Amount', value: trip['amount']),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _SectionCard(
                title: 'Recipient',
                child: TextField(
                  controller: _recipientController,
                  decoration: const InputDecoration(
                    labelText: 'Who received the delivery?',
                  ),
                ),
              ),
              const SizedBox(height: 18),
              _SectionCard(
                title: 'Client signature',
                trailing: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.errorRed.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'Required',
                    style: TextStyle(
                      color: AppTheme.errorRed,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Capture the receiver signature below. It will be stored with this trip as proof-of-delivery.',
                      style: AppTheme.getSubtitleStyle(context),
                    ),
                    const SizedBox(height: 12),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: _signatureEmpty
                              ? AppTheme.getBorderColor(context)
                              : AppTheme.successGreen.withValues(alpha: 0.35),
                          width: 1.5,
                        ),
                      ),
                      child: SignaturePad(
                        key: _signatureKey,
                        height: 180,
                        onChanged: (isEmpty) {
                          setState(() => _signatureEmpty = isEmpty);
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () => _signatureKey.currentState?.clear(),
                        icon: const Icon(Icons.refresh_rounded, size: 16),
                        label: const Text('Clear signature'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _SectionCard(
                title: 'Delivery remarks',
                child: TextField(
                  controller: _notesController,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Optional notes',
                    hintText:
                        'Describe handoff notes, access instructions, or special circumstances.',
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _submitting
                          ? null
                          : () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _submitting ? null : _submit,
                      child: Text(
                        _submitting ? 'Submitting...' : 'Submit for approval',
                      ),
                    ),
                  ),
                ],
              ),
              if (!isDark) const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;

  const _SectionCard({required this.title, required this.child, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.getSecondaryBg(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.getBorderColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: AppTheme.getHeadingStyle(context, fontSize: 16),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final dynamic value;

  const _SummaryRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(label, style: AppTheme.getCaptionStyle(context)),
          ),
          Expanded(
            child: Text(
              value?.toString().trim().isNotEmpty == true
                  ? value.toString()
                  : 'N/A',
              style: AppTheme.getBodyStyle(context),
            ),
          ),
        ],
      ),
    );
  }
}
