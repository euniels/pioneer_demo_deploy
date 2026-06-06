import '../services/backend_api.dart';

class FormValidation {
  const FormValidation._();

  static String? requiredField(String label, String? value) {
    final text = value?.trim() ?? '';
    return text.isEmpty ? '$label is required' : null;
  }

  static String? requiredSelection(String label, String? value) {
    final text = value?.trim() ?? '';
    return text.isEmpty ? 'Select $label' : null;
  }

  static String? email(String label, String? value, {bool required = false}) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) {
      return required ? '$label is required' : null;
    }
    return text.contains('@') && text.contains('.')
        ? null
        : 'Enter a valid $label';
  }

  static String? nonNegativeNumber(
    String label,
    String? value, {
    bool required = false,
  }) {
    final text = _cleanNumber(value);
    if (text.isEmpty) {
      return required ? '$label is required' : null;
    }
    final parsed = double.tryParse(text);
    if (parsed == null) return 'Enter a valid number for $label';
    if (parsed < 0) return '$label cannot be negative';
    return null;
  }

  static String? positiveNumber(String label, String? value) {
    final text = _cleanNumber(value);
    if (text.isEmpty) return '$label is required';
    final parsed = double.tryParse(text);
    if (parsed == null) return 'Enter a valid number for $label';
    if (parsed <= 0) return '$label must be greater than zero';
    return null;
  }

  static String? futureOrTodayDateText(
    String label,
    String? value, {
    bool required = false,
  }) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) {
      return required ? '$label is required' : null;
    }
    final parsed = DateTime.tryParse(text);
    if (parsed == null) return 'Select a valid $label';
    final today = DateTime.now();
    final todayOnly = DateTime(today.year, today.month, today.day);
    final parsedOnly = DateTime(parsed.year, parsed.month, parsed.day);
    if (parsedOnly.isBefore(todayOnly)) return '$label cannot be before today';
    return null;
  }

  static String backendError(Object error, String fallback) {
    if (error is BackendApiException && error.message.trim().isNotEmpty) {
      return error.message.trim();
    }
    final text = error.toString().trim();
    if (text.isEmpty) return fallback;
    return text
        .replaceFirst('Exception: ', '')
        .replaceFirst('BackendApiException: ', '');
  }

  static String _cleanNumber(String? value) =>
      (value ?? '').replaceAll(',', '').trim();
}
