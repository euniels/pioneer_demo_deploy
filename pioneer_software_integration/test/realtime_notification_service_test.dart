import 'package:flutter_test/flutter_test.dart';
import 'package:pioneerpath/src/services/notification_service.dart';
import 'package:pioneerpath/src/services/realtime_stream_core.dart';

void main() {
  test('notification service upserts realtime notification payloads', () {
    final service = NotificationService.instance;
    service.deleteAll();

    service.upsertFromJson({
      'id': 'sse-1',
      'title': 'Route assigned',
      'message': 'NGO 7290 has a new route order.',
      'category': 'dispatch',
      'timestamp': '2026-05-06T08:00:00Z',
      'isRead': false,
    });

    expect(service.notifications.value, hasLength(1));
    expect(
      service.notifications.value.first.category,
      NotificationCategory.trip,
    );
    expect(service.unreadCount, 1);

    service.upsertFromJson({
      'id': 'sse-1',
      'title': 'Route assigned',
      'message': 'The route order was read.',
      'category': 'dispatch',
      'timestamp': '2026-05-06T08:00:00Z',
      'isRead': true,
    });

    expect(service.notifications.value, hasLength(1));
    expect(service.notifications.value.first.isRead, isTrue);
    expect(service.unreadCount, 0);
  });

  test('realtime stream auto mode uses polling fallback in debug builds', () {
    var connectCalled = false;
    final core = RealtimeStreamCore(
      connect: (_) async {
        connectCalled = true;
      },
      close: () {},
    );

    core.start();

    expect(connectCalled, isFalse);
    expect(core.isConnected, isFalse);

    core.stop();
  });

  test('realtime notification event increments unread badge source', () {
    final service = NotificationService.instance;
    service.deleteAll();

    final core = RealtimeStreamCore(connect: (_) async {}, close: () {});
    core.handleSseMessage('notification', '''
      {
        "notification": {
          "id": "dispatch-status-1",
          "title": "Dispatch Status Changed",
          "message": "TRP-REAL-DISPATCH is now dispatched.",
          "category": "dispatch",
          "timestamp": "2026-05-09T08:00:00Z",
          "isRead": false,
          "url": "/dispatch-queue"
        },
        "unreadCount": 1
      }
    ''');

    expect(service.notifications.value, hasLength(1));
    expect(service.notifications.value.single.id, 'dispatch-status-1');
    expect(service.unreadCount, 1);
  });

  test('geotab rejection realtime event appears in notification state', () {
    final service = NotificationService.instance;
    service.deleteAll();

    final core = RealtimeStreamCore(connect: (_) async {}, close: () {});
    core.handleSseMessage('notification', '''
      {
        "notification": {
          "id": "geotab-writeback-rejected-7",
          "title": "GeoTab Push Rejected",
          "message": "Your GeoTab push request for Rejected Driver was rejected: License number is missing.",
          "category": "system",
          "timestamp": "2026-05-18T08:00:00Z",
          "isRead": false,
          "url": "/settings"
        },
        "unreadCount": 1
      }
    ''');

    expect(service.notifications.value, hasLength(1));
    expect(service.notifications.value.single.title, 'GeoTab Push Rejected');
    expect(
      service.notifications.value.single.message,
      contains('License number is missing.'),
    );
    expect(
      service.notifications.value.single.category,
      NotificationCategory.system,
    );
    expect(service.unreadCount, 1);
  });
}
