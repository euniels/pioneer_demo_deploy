import 'dart:async';

import 'package:flutter/foundation.dart';

import 'local_fleet_mirror_service.dart';

class NotificationItem {
  final String id;
  final String title;
  final String message;
  final String time;
  final DateTime timestamp;
  final NotificationCategory category;
  bool isRead;

  NotificationItem({
    required this.id,
    required this.title,
    required this.message,
    required this.time,
    required this.timestamp,
    required this.category,
    this.isRead = false,
  });

  NotificationItem copyWith({bool? isRead}) {
    return NotificationItem(
      id: id,
      title: title,
      message: message,
      time: time,
      timestamp: timestamp,
      category: category,
      isRead: isRead ?? this.isRead,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'message': message,
      'time': time,
      'timestamp': timestamp.toIso8601String(),
      'category': category.label.toLowerCase(),
      'isRead': isRead,
    };
  }
}

enum NotificationCategory {
  maintenance,
  trip,
  fuel,
  driver,
  billing,
  alert,
  system,
}

extension NotificationCategoryExt on NotificationCategory {
  String get label {
    switch (this) {
      case NotificationCategory.maintenance:
        return 'Maintenance';
      case NotificationCategory.trip:
        return 'Trip';
      case NotificationCategory.fuel:
        return 'Fuel';
      case NotificationCategory.driver:
        return 'Driver';
      case NotificationCategory.billing:
        return 'Billing';
      case NotificationCategory.alert:
        return 'Alert';
      case NotificationCategory.system:
        return 'System';
    }
  }
}

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final ValueNotifier<List<NotificationItem>> notifications = ValueNotifier([]);

  int get unreadCount => notifications.value.where((n) => !n.isRead).length;

  void markAsRead(String id) {
    final updated = notifications.value.map((n) {
      return n.id == id ? n.copyWith(isRead: true) : n;
    }).toList();
    notifications.value = updated;
    _persistMirror();
  }

  void markAllAsRead() {
    notifications.value = notifications.value
        .map((n) => n.copyWith(isRead: true))
        .toList();
    _persistMirror();
  }

  void deleteNotification(String id) {
    notifications.value = notifications.value.where((n) => n.id != id).toList();
    _persistMirror();
  }

  void deleteAll() {
    notifications.value = [];
    _persistMirror();
  }

  void addNotification(NotificationItem item) {
    notifications.value = [item, ...notifications.value];
    _persistMirror();
  }

  void upsertNotification(NotificationItem item) {
    final existingIndex = notifications.value.indexWhere(
      (n) => n.id == item.id,
    );
    if (existingIndex == -1) {
      addNotification(item);
      return;
    }

    final updated = [...notifications.value];
    updated[existingIndex] = item;
    notifications.value = updated;
    _persistMirror();
  }

  void upsertFromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    if (id.isEmpty) {
      return;
    }

    final timestamp =
        DateTime.tryParse(json['timestamp']?.toString() ?? '') ??
        DateTime.now();
    upsertNotification(
      NotificationItem(
        id: id,
        title: json['title']?.toString() ?? 'PioneerPath',
        message: json['message']?.toString() ?? 'New fleet notification',
        time: json['time']?.toString() ?? 'Just now',
        timestamp: timestamp,
        category: _categoryFromJson(json['category']),
        isRead: json['isRead'] == true,
      ),
    );
  }

  void replaceNotifications(List<NotificationItem> items) {
    notifications.value = items;
    _persistMirror();
  }

  String nextId() => 'NOT-${DateTime.now().millisecondsSinceEpoch}';

  void _persistMirror() {
    unawaited(
      LocalFleetMirrorService.replaceNotifications(
        notifications.value.map((item) => item.toJson()).toList(),
      ).catchError((_) {}),
    );
  }
}

NotificationCategory _categoryFromJson(dynamic value) {
  final raw = value?.toString().trim().toLowerCase() ?? '';
  return switch (raw) {
    'maintenance' => NotificationCategory.maintenance,
    'trip' || 'dispatch' => NotificationCategory.trip,
    'fuel' => NotificationCategory.fuel,
    'driver' => NotificationCategory.driver,
    'billing' => NotificationCategory.billing,
    'alert' || 'alerts' => NotificationCategory.alert,
    _ => NotificationCategory.system,
  };
}
