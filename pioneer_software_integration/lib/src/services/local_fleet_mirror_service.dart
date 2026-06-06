import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import 'local_fleet_database.dart';

class LocalFleetMirrorState {
  const LocalFleetMirrorState({
    required this.vehicles,
    required this.drivers,
    required this.trips,
    required this.dispatchQueue,
    required this.clients,
    required this.notifications,
    required this.dashboardSummary,
    required this.loadedAt,
  });

  final List<Map<String, dynamic>> vehicles;
  final List<Map<String, dynamic>> drivers;
  final List<Map<String, dynamic>> trips;
  final List<Map<String, dynamic>> dispatchQueue;
  final List<Map<String, dynamic>> clients;
  final List<Map<String, dynamic>> notifications;
  final Map<String, dynamic>? dashboardSummary;
  final DateTime loadedAt;

  bool get hasStableFleetData {
    return vehicles.isNotEmpty ||
        drivers.isNotEmpty ||
        trips.isNotEmpty ||
        dispatchQueue.isNotEmpty ||
        clients.isNotEmpty ||
        notifications.isNotEmpty ||
        (dashboardSummary?.isNotEmpty ?? false);
  }
}

class LocalFleetMirrorService {
  LocalFleetMirrorService._();

  static const String vehiclesCollection = 'vehicles';
  static const String driversCollection = 'drivers';
  static const String tripsCollection = 'trips';
  static const String dispatchQueueCollection = 'dispatch_queue';
  static const String clientsCollection = 'clients';
  static const String notificationsCollection = 'notifications';
  static const String dashboardSummaryCollection = 'dashboard_summary';

  static const String _dbName = 'pioneer_fleet_mirror.db';
  static const int _dbVersion = 1;
  static Future<Database>? _dbFuture;

  static Future<void> initialize() async {
    await _db();
  }

  static Future<void> mirrorResponse(
    String path,
    Map<String, dynamic> decoded,
  ) async {
    final normalizedPath = (path.startsWith('/') ? path : '/$path')
        .split('?')
        .first;
    if (_isLiveGpsPath(normalizedPath)) {
      return;
    }

    final rawData = decoded['data'];
    if (rawData == null) {
      return;
    }

    if (normalizedPath == '/fleet/summary' && rawData is Map) {
      await _mirrorFleetSummary(_stringMap(rawData));
      return;
    }

    if (normalizedPath == '/vehicles' && rawData is List) {
      await replaceVehicles(_mapList(rawData).map(_stripGpsFields).toList());
      return;
    }

    if (normalizedPath == '/fleet/drivers/manual' && rawData is List) {
      await replaceDrivers(_mapList(rawData));
      return;
    }

    if (normalizedPath == '/fleet/notifications' && rawData is List) {
      await replaceNotifications(_mapList(rawData));
      return;
    }

    if (normalizedPath == '/fleet/clients' && rawData is List) {
      await replaceClients(_mapList(rawData));
      return;
    }

    if (normalizedPath == '/fleet/dashboard/summary' && rawData is Map) {
      await replaceDashboardSummary(_stringMap(rawData));
    }
  }

  static Future<LocalFleetMirrorState> loadState() async {
    final vehicles = await loadCollection(vehiclesCollection);
    final drivers = await loadCollection(driversCollection);
    final trips = await loadCollection(tripsCollection);
    final dispatchQueue = await loadCollection(dispatchQueueCollection);
    final clients = await loadCollection(clientsCollection);
    final notifications = await loadCollection(notificationsCollection);
    final dashboardRows = await loadCollection(dashboardSummaryCollection);

    return LocalFleetMirrorState(
      vehicles: vehicles,
      drivers: drivers,
      trips: trips,
      dispatchQueue: dispatchQueue,
      clients: clients,
      notifications: notifications,
      dashboardSummary: dashboardRows.isEmpty ? null : dashboardRows.first,
      loadedAt: DateTime.now(),
    );
  }

  static Future<List<Map<String, dynamic>>> loadCollection(
    String collection,
  ) async {
    final database = await _db();
    final rows = await database.query(
      'fleet_mirror_records',
      columns: const ['payload'],
      where: 'collection = ?',
      whereArgs: [collection],
      orderBy: 'sort_at DESC, updated_at DESC',
    );

    final items = <Map<String, dynamic>>[];
    for (final row in rows) {
      final raw = row['payload']?.toString() ?? '';
      if (raw.isEmpty) {
        continue;
      }
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          items.add(_stringMap(decoded));
        }
      } catch (_) {}
    }
    return items;
  }

  static Future<void> replaceVehicles(List<Map<String, dynamic>> vehicles) {
    return _replaceCollection(
      vehiclesCollection,
      vehicles.map(_stripGpsFields).toList(),
    );
  }

  static Future<void> replaceDrivers(List<Map<String, dynamic>> drivers) {
    return _replaceCollection(driversCollection, drivers);
  }

  static Future<void> replaceTrips(List<Map<String, dynamic>> trips) {
    final recentTrips = trips.where(_isRecentTrip).toList();
    final dispatchTrips = recentTrips.where(_isDispatchTrip).toList();
    return _withDb((database) async {
      await database.transaction((txn) async {
        await _replaceCollectionInTxn(txn, tripsCollection, recentTrips);
        await _replaceCollectionInTxn(
          txn,
          dispatchQueueCollection,
          dispatchTrips,
        );
      });
    });
  }

  static Future<void> replaceNotifications(
    List<Map<String, dynamic>> notifications,
  ) {
    return _replaceCollection(notificationsCollection, notifications);
  }

  static Future<void> replaceClients(List<Map<String, dynamic>> clients) {
    return _replaceCollection(clientsCollection, clients);
  }

  static Future<void> replaceDashboardSummary(Map<String, dynamic> summary) {
    return _replaceCollection(dashboardSummaryCollection, [
      {'id': 'dashboard_summary', ...summary},
    ]);
  }

  static Future<void> queueMutation(Map<String, dynamic> mutation) async {
    final database = await _db();
    final id = mutation['id']?.toString().trim().isNotEmpty == true
        ? mutation['id'].toString()
        : 'mutation-${DateTime.now().microsecondsSinceEpoch}';
    final queuedAt =
        mutation['queuedAt']?.toString() ?? DateTime.now().toIso8601String();

    await database.insert('fleet_write_queue', {
      'id': id,
      'payload': jsonEncode(_toJsonSafe({...mutation, 'id': id})),
      'queued_at': queuedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<Map<String, dynamic>>> loadMutationQueue() async {
    final database = await _db();
    final rows = await database.query(
      'fleet_write_queue',
      columns: const ['payload'],
      orderBy: 'queued_at ASC',
    );

    final queue = <Map<String, dynamic>>[];
    for (final row in rows) {
      try {
        final decoded = jsonDecode(row['payload']?.toString() ?? '');
        if (decoded is Map) {
          queue.add(_stringMap(decoded));
        }
      } catch (_) {}
    }
    return queue;
  }

  static Future<void> replaceMutationQueue(
    List<Map<String, dynamic>> queue,
  ) async {
    final database = await _db();
    await database.transaction((txn) async {
      await txn.delete('fleet_write_queue');
      for (final mutation in queue) {
        final id = mutation['id']?.toString().trim().isNotEmpty == true
            ? mutation['id'].toString()
            : 'mutation-${DateTime.now().microsecondsSinceEpoch}';
        await txn.insert('fleet_write_queue', {
          'id': id,
          'payload': jsonEncode(_toJsonSafe({...mutation, 'id': id})),
          'queued_at':
              mutation['queuedAt']?.toString() ??
              DateTime.now().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  static Future<void> resetForTesting() async {
    final database = await _db();
    await database.delete('fleet_mirror_records');
    await database.delete('fleet_mirror_meta');
    await database.delete('fleet_write_queue');
  }

  static Future<void> _mirrorFleetSummary(Map<String, dynamic> summary) async {
    final hasVehicles = summary['vehicles'] is List;
    final hasDrivers = summary['drivers'] is List;
    final hasTrips = summary['trips'] is List;
    final hasNotifications = summary['notifications'] is List;
    final hasClients = summary['clients'] is List;
    final vehicles = _mapList(
      summary['vehicles'],
    ).map(_stripGpsFields).toList();
    final drivers = _mapList(summary['drivers']);
    final trips = _mapList(summary['trips']).where(_isRecentTrip).toList();
    final dispatchTrips = trips.where(_isDispatchTrip).toList();
    final notifications = _mapList(summary['notifications']);
    final clients = _mapList(summary['clients']);

    await _withDb((database) async {
      await database.transaction((txn) async {
        if (hasVehicles) {
          await _replaceCollectionInTxn(txn, vehiclesCollection, vehicles);
        }
        if (hasDrivers) {
          await _replaceCollectionInTxn(txn, driversCollection, drivers);
        }
        if (hasTrips) {
          await _replaceCollectionInTxn(txn, tripsCollection, trips);
          await _replaceCollectionInTxn(
            txn,
            dispatchQueueCollection,
            dispatchTrips,
          );
        }
        if (hasNotifications) {
          await _replaceCollectionInTxn(
            txn,
            notificationsCollection,
            notifications,
          );
        }
        if (hasClients) {
          await _replaceCollectionInTxn(txn, clientsCollection, clients);
        }
      });
    });
  }

  static Future<void> _replaceCollection(
    String collection,
    List<Map<String, dynamic>> items,
  ) async {
    await _withDb((database) async {
      await database.transaction((txn) async {
        await _replaceCollectionInTxn(txn, collection, items);
      });
    });
  }

  static Future<void> _replaceCollectionInTxn(
    Transaction txn,
    String collection,
    List<Map<String, dynamic>> items,
  ) async {
    final now = DateTime.now().toIso8601String();
    await txn.delete(
      'fleet_mirror_records',
      where: 'collection = ?',
      whereArgs: [collection],
    );

    for (var index = 0; index < items.length; index++) {
      final item = _stringMap(_toJsonSafe(items[index]));
      final id = _recordId(collection, item, index);
      await txn.insert('fleet_mirror_records', {
        'collection': collection,
        'record_id': id,
        'payload': jsonEncode(item),
        'updated_at': now,
        'sort_at': _sortAt(item) ?? now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    await txn.insert('fleet_mirror_meta', {
      'key': 'collection:$collection:last_synced_at',
      'value': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _withDb(Future<void> Function(Database db) work) async {
    final database = await _db();
    await work(database);
  }

  static Future<Database> _db() {
    return _dbFuture ??= openLocalFleetDatabase(
      _dbName,
      version: _dbVersion,
      onCreate: _createSchema,
    );
  }

  static Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE fleet_mirror_records (
        collection TEXT NOT NULL,
        record_id TEXT NOT NULL,
        payload TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        sort_at TEXT,
        PRIMARY KEY (collection, record_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_fleet_mirror_collection_updated '
      'ON fleet_mirror_records(collection, updated_at)',
    );
    await db.execute(
      'CREATE INDEX idx_fleet_mirror_collection_sort '
      'ON fleet_mirror_records(collection, sort_at)',
    );
    await db.execute('''
      CREATE TABLE fleet_mirror_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE fleet_write_queue (
        id TEXT PRIMARY KEY,
        payload TEXT NOT NULL,
        queued_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_fleet_write_queue_queued_at '
      'ON fleet_write_queue(queued_at)',
    );
  }

  static bool _isLiveGpsPath(String path) {
    return path == '/fleet/live' ||
        path == '/fleet/summary/live' ||
        path == '/vehicles/locations' ||
        path.contains('/trail') ||
        path.startsWith('/fleet/trips/') ||
        path.startsWith('/fleet/client-tracking/');
  }

  static List<Map<String, dynamic>> _mapList(dynamic raw) {
    if (raw is! List) {
      return const [];
    }
    return raw.whereType<Map>().map(_stringMap).toList();
  }

  static Map<String, dynamic> _stringMap(dynamic raw) {
    if (raw is! Map) {
      return <String, dynamic>{};
    }
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }

  static Map<String, dynamic> _stripGpsFields(Map<String, dynamic> vehicle) {
    final stripped = Map<String, dynamic>.from(vehicle);
    for (final key in const [
      'latitude',
      'longitude',
      'speed',
      'bearing',
      'lastGeotabAt',
      'sourceAgeMs',
      'currentLocationLabel',
    ]) {
      stripped.remove(key);
    }
    return stripped;
  }

  static bool _isDispatchTrip(Map<String, dynamic> trip) {
    final status = trip['status']?.toString().trim().toLowerCase() ?? '';
    return status.isEmpty ||
        status == 'pending' ||
        status == 'dispatched' ||
        status == 'in transit' ||
        status == 'in progress' ||
        status == 'on trip' ||
        status == 'pending_approval';
  }

  static bool _isRecentTrip(Map<String, dynamic> trip) {
    final date = _tripDate(trip);
    if (date == null) {
      return true;
    }
    return !date.isBefore(DateTime.now().subtract(const Duration(days: 30)));
  }

  static DateTime? _tripDate(Map<String, dynamic> trip) {
    for (final key in const [
      'date',
      'createdAt',
      'created_at',
      'scheduledAt',
      'scheduled_at',
      'startedAt',
      'endedAt',
      'timestamp',
    ]) {
      final parsed = DateTime.tryParse(trip[key]?.toString() ?? '');
      if (parsed != null) {
        return parsed;
      }
    }
    return null;
  }

  static String _recordId(
    String collection,
    Map<String, dynamic> item,
    int index,
  ) {
    for (final key in const [
      'id',
      'tripId',
      'trip_id',
      'geotabId',
      'geotab_id',
      'plate',
      'name',
      'invoiceNumber',
    ]) {
      final value = item[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) {
        return value;
      }
    }
    return '$collection-$index-${jsonEncode(item).hashCode}';
  }

  static String? _sortAt(Map<String, dynamic> item) {
    for (final key in const [
      'timestamp',
      'createdAt',
      'created_at',
      'date',
      'scheduledAt',
      'scheduled_at',
      'updatedAt',
      'updated_at',
    ]) {
      final value = item[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  static dynamic _toJsonSafe(dynamic value) {
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    if (value is DateTime) {
      return value.toIso8601String();
    }
    if (value is Color) {
      return value.toARGB32();
    }
    if (value is Map) {
      return value.map(
        (key, nested) => MapEntry(key.toString(), _toJsonSafe(nested)),
      );
    }
    if (value is Iterable) {
      return value.map(_toJsonSafe).toList();
    }
    return value.toString();
  }
}
