import 'package:flutter/material.dart';

abstract class OptimisticSnapshotBase {
  void restore();
}

class OptimisticSnapshot<T> implements OptimisticSnapshotBase {
  OptimisticSnapshot({
    required this.notifier,
    required T Function(T value) clone,
  }) : _value = clone(notifier.value);

  final ValueNotifier<T> notifier;
  final T _value;

  void restore() {
    notifier.value = _value;
  }

  static OptimisticSnapshot<List<Map<String, dynamic>>> mapList(
    ValueNotifier<List<Map<String, dynamic>>> notifier,
  ) {
    return OptimisticSnapshot<List<Map<String, dynamic>>>(
      notifier: notifier,
      clone: (value) => value
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false),
    );
  }
}

class OptimisticMutationService {
  OptimisticMutationService._();

  static Future<T?> run<T>({
    required BuildContext context,
    required List<OptimisticSnapshotBase> snapshots,
    required VoidCallback apply,
    required Future<T> Function() commit,
    String errorMessage =
        'The action could not be saved. Changes were rolled back.',
  }) async {
    apply();

    try {
      return await commit();
    } catch (_) {
      for (final snapshot in snapshots.reversed) {
        snapshot.restore();
      }

      if (context.mounted && Scaffold.maybeOf(context) != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(errorMessage),
          ),
        );
      }
      return null;
    }
  }
}
