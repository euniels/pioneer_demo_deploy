class OfflineDemoBackend {
  OfflineDemoBackend._();

  static const bool enabled = bool.fromEnvironment(
    'OFFLINE_DEMO',
    defaultValue: false,
  );

  static final DateTime _startedAt = DateTime.now();

  static final List<Map<String, dynamic>> _vehicles = [
    {
      'id': 'demo-device-001',
      'geotabId': 'demo-device-001',
      'geotabDeviceId': 'demo-device-001',
      'source': 'manual',
      'managedLocally': true,
      'plate': 'DEMO-TRK-01',
      'plateNumber': 'DEMO-TRK-01',
      'vehicleType': 'Refrigerated Truck',
      'truckType': 'Refrigerated Truck',
      'makeModel': 'Isuzu Forward Ref Van',
      'year': 2023,
      'fuelType': 'Diesel',
      'cargoCapacityKg': 4200,
      'status': 'active',
      'driver': 'Demo Driver Juan Dela Cruz',
      'latitude': 14.6112,
      'longitude': 121.0202,
      'speed': 38,
      'bearing': 30,
      'isCommunicating': true,
      'healthStatus': 'healthy',
      'healthScore': 96,
      'lastUpdated': '',
      'syncStatus': 'not_staged',
      'syncLabel': 'GeoTab: Demo only',
    },
    {
      'id': 'demo-device-002',
      'geotabId': 'demo-device-002',
      'geotabDeviceId': 'demo-device-002',
      'source': 'manual',
      'managedLocally': true,
      'plate': 'DEMO-TRK-02',
      'plateNumber': 'DEMO-TRK-02',
      'vehicleType': 'Closed Van',
      'truckType': 'Closed Van',
      'makeModel': 'Mitsubishi Fuso Canter',
      'year': 2022,
      'fuelType': 'Diesel',
      'cargoCapacityKg': 3500,
      'status': 'active',
      'driver': 'Demo Driver Ana Lopez',
      'latitude': 14.6760,
      'longitude': 121.0437,
      'speed': 0,
      'bearing': 0,
      'isCommunicating': true,
      'healthStatus': 'healthy',
      'healthScore': 91,
      'lastUpdated': '',
      'syncStatus': 'not_staged',
      'syncLabel': 'GeoTab: Demo only',
    },
    {
      'id': 'demo-device-003',
      'geotabId': 'demo-device-003',
      'geotabDeviceId': 'demo-device-003',
      'source': 'manual',
      'managedLocally': true,
      'plate': 'DEMO-TRK-03',
      'plateNumber': 'DEMO-TRK-03',
      'vehicleType': 'Wing Van',
      'truckType': 'Wing Van',
      'makeModel': 'Hino 500 Wing Van',
      'year': 2021,
      'fuelType': 'Diesel',
      'cargoCapacityKg': 6500,
      'status': 'maintenance',
      'driver': 'Unassigned',
      'latitude': 14.5794,
      'longitude': 121.0359,
      'speed': 0,
      'bearing': 0,
      'isCommunicating': false,
      'healthStatus': 'warning',
      'healthScore': 70,
      'lastUpdated': '',
      'syncStatus': 'not_staged',
      'syncLabel': 'GeoTab: Demo only',
    },
  ];

  static final List<Map<String, dynamic>> _drivers = [
    {
      'id': 'demo-driver-001',
      'localId': 'demo-driver-001',
      'source': 'manual',
      'managedLocally': true,
      'name': 'Demo Driver Juan Dela Cruz',
      'license': 'N01-22-123456',
      'phone': '+63 917 555 0201',
      'email': 'juan.demo@example.com',
      'status': 'on trip',
      'assignedVehicle': 'DEMO-TRK-01',
      'assignedVehiclePlate': 'DEMO-TRK-01',
      'trips': 12,
      'revenue': '₱218,500',
      'score': 94,
    },
    {
      'id': 'demo-driver-002',
      'localId': 'demo-driver-002',
      'source': 'manual',
      'managedLocally': true,
      'name': 'Demo Driver Ana Lopez',
      'license': 'N02-23-654321',
      'phone': '+63 917 555 0202',
      'email': 'ana.demo@example.com',
      'status': 'available',
      'assignedVehicle': 'DEMO-TRK-02',
      'assignedVehiclePlate': 'DEMO-TRK-02',
      'trips': 9,
      'revenue': '₱162,400',
      'score': 91,
    },
    {
      'id': 'demo-driver-003',
      'localId': 'demo-driver-003',
      'source': 'manual',
      'managedLocally': true,
      'name': 'Demo Driver Mark Lim',
      'license': 'N03-21-456789',
      'phone': '+63 917 555 0203',
      'email': 'mark.demo@example.com',
      'status': 'available',
      'assignedVehicle': 'Unassigned',
      'assignedVehiclePlate': '',
      'trips': 7,
      'revenue': '₱118,200',
      'score': 88,
    },
  ];

  static final List<Map<String, dynamic>> _clients = [
    {
      'id': 'demo-client-001',
      'companyName': 'Demo Client - North Distribution',
      'contactPersonName': 'Maria Santos',
      'contactNumber': '+63 917 555 0101',
      'email': 'north.demo@example.com',
      'billingAddress': 'Mandaluyong City, Metro Manila',
      'deliveryAddress': 'Warehouse 4, Caloocan City',
      'clientType': 'regular',
      'paymentTerms': '30 days net',
      'erpCustomerId': 'DEMO-CUST-001',
      'status': 'active',
    },
    {
      'id': 'demo-client-002',
      'companyName': 'Demo Client - Cold Chain Retail',
      'contactPersonName': 'Jose Reyes',
      'contactNumber': '+63 917 555 0102',
      'email': 'coldchain.demo@example.com',
      'billingAddress': 'Pasig City, Metro Manila',
      'deliveryAddress': 'Retail Hub, Quezon City',
      'clientType': 'priority',
      'paymentTerms': 'COD',
      'erpCustomerId': 'DEMO-CUST-002',
      'status': 'active',
    },
  ];

  static final List<Map<String, dynamic>> _routes = [
    {
      'id': 'demo-route-001',
      'routeId': 'demo-route-001',
      'name': 'Demo Route - Metro Manila Northbound',
      'description': 'Client demo route from depot to distribution destinations.',
      'assignedVehiclePlate': 'DEMO-TRK-01',
      'assignedVehicleGeotabId': 'demo-device-001',
      'status': 'active',
      'syncStatus': 'not_staged',
      'stops': [
        {
          'stopSequence': 1,
          'stopName': 'Demo Depot - Mandaluyong',
          'latitude': 14.5794,
          'longitude': 121.0359,
          'estimatedStopDurationMinutes': 15,
        },
        {
          'stopSequence': 2,
          'stopName': 'Demo Stop - Quezon City Hub',
          'latitude': 14.6760,
          'longitude': 121.0437,
          'estimatedStopDurationMinutes': 25,
        },
        {
          'stopSequence': 3,
          'stopName': 'Demo Destination - Caloocan Warehouse',
          'latitude': 14.6507,
          'longitude': 120.9676,
          'estimatedStopDurationMinutes': 35,
        },
      ],
    },
  ];

  static final List<Map<String, dynamic>> _zones = [
    {
      'id': 'demo-zone-001',
      'zoneId': 'demo-zone-001',
      'name': 'Demo Depot Zone',
      'type': 'Depot',
      'status': 'active',
      'center': {'latitude': 14.5794, 'longitude': 121.0359},
      'points': [
        {'latitude': 14.5764, 'longitude': 121.0329},
        {'latitude': 14.5764, 'longitude': 121.0389},
        {'latitude': 14.5824, 'longitude': 121.0389},
        {'latitude': 14.5824, 'longitude': 121.0329},
      ],
    },
  ];

  static List<Map<String, dynamic>> get _trips {
    final now = DateTime.now();
    return [
      _trip('DEMO-TRIP-REQUEST', 'pending', 2, _clients[0], null, null, 0, now.add(const Duration(hours: 6))),
      _trip('DEMO-TRIP-ASSIGNED', 'assigned', 6, _clients[0], _vehicles[1], _drivers[1], 18500, now.add(const Duration(hours: 3))),
      _trip('DEMO-TRIP-LIVE', 'in_progress', 10, _clients[1], _vehicles[0], _drivers[0], 24500, now.subtract(const Duration(hours: 1))),
      _trip('DEMO-TRIP-POD-HOLD', 'pending_approval', 11, _clients[1], _vehicles[1], _drivers[1], 21750, now.subtract(const Duration(days: 1))),
      _trip('DEMO-TRIP-BILLED', 'completed', 12, _clients[0], _vehicles[0], _drivers[0], 32000, now.subtract(const Duration(days: 2))),
    ];
  }

  static List<Map<String, dynamic>> get _invoices => [
    {
      'id': 'INV-DEMO-001',
      'invoiceNumber': 'INV-DEMO-001',
      'tripId': 'DEMO-TRIP-BILLED',
      'client': 'Demo Client - North Distribution',
      'customer': 'Demo Client - North Distribution',
      'route': 'Demo Depot - Mandaluyong to Caloocan Warehouse',
      'origin': 'Demo Depot - Mandaluyong',
      'destination': 'Demo Destination - Caloocan Warehouse',
      'status': 'issued',
      'amount': 32000,
      'subtotal': 28571.43,
      'vat': 3428.57,
      'total': 32000,
      'issueDate': _isoDate(DateTime.now().subtract(const Duration(days: 1))),
      'dueDate': _isoDate(DateTime.now().add(const Duration(days: 29))),
      'podReady': true,
      'podReadiness': 'Ready to bill',
      'podStatus': 'verified',
      'erpReference': 'SO-DEMO-001',
      'poNumber': 'PO-DEMO-001',
      'drNumber': 'DR-DEMO-001',
      'lineItems': [
        {'label': 'Base delivery charge', 'amount': 12000},
        {'label': 'Distance/GPS charge', 'amount': 14500},
        {'label': 'Fuel surcharge', 'amount': 5500},
      ],
      'references': {
        'invoiceNumber': 'INV-DEMO-001',
        'erpReference': 'SO-DEMO-001',
        'poNumber': 'PO-DEMO-001',
        'drNumber': 'DR-DEMO-001',
        'status': 'issued',
        'statusHistory': [
          {'status': 'draft', 'note': 'Demo invoice drafted from completed trip.'},
          {'status': 'approved', 'note': 'Demo invoice approved after POD review.'},
          {'status': 'issued', 'note': 'Demo invoice issued for SOA review.'},
        ],
      },
      'statusHistory': [
        {'status': 'draft', 'note': 'Demo invoice drafted from completed trip.'},
        {'status': 'approved', 'note': 'Demo invoice approved after POD review.'},
        {'status': 'issued', 'note': 'Demo invoice issued for SOA review.'},
      ],
    },
    {
      'id': 'INV-DEMO-HOLD',
      'invoiceNumber': 'INV-DEMO-HOLD',
      'tripId': 'DEMO-TRIP-POD-HOLD',
      'client': 'Demo Client - Cold Chain Retail',
      'customer': 'Demo Client - Cold Chain Retail',
      'status': 'draft',
      'amount': 21750,
      'subtotal': 19419.64,
      'vat': 2330.36,
      'total': 21750,
      'issueDate': _isoDate(DateTime.now()),
      'dueDate': _isoDate(DateTime.now().add(const Duration(days: 30))),
      'podReady': false,
      'podReadiness': 'Hold for POD',
      'podStatus': 'submitted',
      'lineItems': [
        {'label': 'Draft delivery charge', 'amount': 21750},
      ],
      'references': {
        'invoiceNumber': 'INV-DEMO-HOLD',
        'status': 'draft',
        'statusHistory': [
          {'status': 'draft', 'note': 'Demo invoice waiting for POD verification.'},
        ],
      },
      'statusHistory': [
        {'status': 'draft', 'note': 'Demo invoice waiting for POD verification.'},
      ],
    },
  ];

  static Map<String, dynamic> decodedResponse(String path) {
    final uri = Uri.parse(path.startsWith('/') ? path : '/$path');
    final base = uri.path;

    if (base.startsWith('/vehicles/') && base.endsWith('/trail')) {
      return _ok(_gpsTrail());
    }

    if (base.startsWith('/fleet/telemetry/assets/')) {
      final id = base.split('/').last;
      return _ok(_telemetryAssets().firstWhere(
        (asset) => asset['geotabId'] == id,
        orElse: () => _telemetryAssets().first,
      ));
    }

    if (base.startsWith('/fleet/client-tracking/')) {
      final tripId = base.split('/').last;
      return _ok(_clientTracking(tripId));
    }

    return switch (base) {
      '/vehicles' => _list(_vehicles, uri),
      '/vehicles/locations' => _list(_vehicles, uri),
      '/fleet/vehicles/manual' => _list(_vehicles, uri),
      '/fleet/drivers' => _list(_drivers, uri),
      '/fleet/drivers/manual' => _list(_drivers, uri),
      '/fleet/clients' => _list(_clients, uri),
      '/fleet/routes' => _list(_routes, uri),
      '/fleet/trips' => _list(_trips, uri),
      '/fleet/zones' => _list(_zones, uri),
      '/fleet/notifications' => _list(_notifications(), uri),
      '/fleet/maintenance/history' => _list(_maintenanceHistory(), uri),
      '/fleet/maintenance/faults' => _list(_faults(), uri),
      '/fleet/maintenance/dvir' => _list(_dvir(), uri),
      '/fleet/maintenance/work-orders' => _list(_workOrders(), uri),
      '/fleet/fuel/transactions' => _list(_fuelTransactions(), uri),
      '/fleet/energy/charges' => _list([], uri),
      '/fleet/telemetry/assets' => _list(_telemetryAssets(), uri),
      '/fleet/users' => _list(_users(), uri),
      '/fleet/audit-logs' => _list(_auditLogs(), uri),
      '/fleet/geotab/writeback/jobs' => _list(_writebackJobs(), uri),
      '/fleet/reports/unmatched-routes' => _list([], uri),
      '/fleet/reports/driver-congregation' => _list([], uri),
      '/fleet/summary' => _ok(_summary()),
      '/fleet/summary/live' => _ok(_liveSummary()),
      '/fleet/live' => _ok(_liveSummary()),
      '/fleet/dashboard' => _ok(_summary()),
      '/fleet/dashboard/summary' => _ok(_dashboardSummary()),
      '/fleet/summary/analytics' => _ok(_analytics()),
      '/fleet/summary/maintenance' => _ok(_maintenanceSummary()),
      '/fleet/summary/maintenance/predictions' => _ok(_maintenancePredictions()),
      '/fleet/maintenance/predictions' => _ok(_maintenancePredictions()),
      '/fleet/analytics/driver-performance' => _ok(_analytics()),
      '/fleet/analytics/vehicle-health' => _ok(_analytics()),
      '/fleet/analytics/route-efficiency' => _ok(_analytics()),
      '/fleet/analytics/trip-forecast' => _ok(_analytics()),
      '/fleet/analytics/fuel-trend' => _ok(_analytics()),
      '/fleet/maintenance' => _ok(_maintenance()),
      '/fleet/fuel' => _ok(_fuel()),
      '/fleet/telemetry' => _ok({'assets': _telemetryAssets()}),
      '/fleet/temperature' => _ok(_temperature()),
      '/fleet/notification-preferences' => _ok(_notificationPreferences()),
      '/fleet/settings/system' => _ok(_settings()),
      '/fleet/settings/fuel-prices' => _ok(_settings()),
      '/fleet/maps/config' => _ok({'configured': false, 'browserKey': '', 'provider': 'offline_demo'}),
      '/fleet/push/config' => _ok({'configured': false, 'publicKey': ''}),
      '/fleet/geotab/health' => _ok(_health()),
      '/health' => _ok(_health()),
      '/api/health' => _ok(_health()),
      '/billing/invoices' => _ok(_billingPayload(uri)),
      '/billing/soa' => _ok(_soa()),
      '/fleet/reports/vehicle-subscription-coverage' => _ok({
        'coveredVehicles': 0,
        'uncoveredVehicles': _vehicles.length,
        'purpose': 'Offline UI demo data only.',
      }),
      _ => _ok({'offlineDemo': true, 'path': path, 'updated': true}),
    };
  }

  static Map<String, dynamic> mutate(String method, String path, Map<String, dynamic> payload) {
    final uri = Uri.parse(path.startsWith('/') ? path : '/$path');
    final base = uri.path;
    if (base == '/fleet/users/login-check' || base == '/fleet/auth/refresh') {
      return _demoUser(payload['username']?.toString() ?? 'admin@pioneerpath.local');
    }
    if (base == '/fleet/auth/logout') {
      return {'success': true, 'data': {'offlineDemo': true, 'loggedOut': true}};
    }
    return {
      'success': true,
      'data': {
        ...payload,
        'offlineDemo': true,
        'method': method,
        'path': path,
        'updated': true,
        'id': payload['id'] ?? payload['tripId'] ?? 'offline-demo-record',
      },
    };
  }

  static Map<String, dynamic> _summary() => {
    'offlineDemo': true,
    'vehicles': _vehicles.map(_touch).toList(),
    'drivers': _drivers,
    'clients': _clients,
    'routes': _routes,
    'trips': _trips,
    'maintenance': _maintenanceHistory(),
    'billings': _invoices,
    'notifications': _notifications(),
    'fuel': _fuel(),
    'telemetry': {'assets': _telemetryAssets()},
    'temperature': _temperature(),
  };

  static Map<String, dynamic> _liveSummary() => {
    ..._summary(),
    'fleetFreshness': {
      'state': 'fresh',
      'label': 'Offline demo',
      'sourceAgeMs': DateTime.now().difference(_startedAt).inMilliseconds,
    },
    'liveVehicles': _vehicles.map(_touch).toList(),
  };

  static Map<String, dynamic> _dashboardSummary() => {
    'offlineDemo': true,
    'activeVehicles': 2,
    'totalVehicles': 3,
    'activeTrips': 2,
    'completedTrips': 2,
    'pendingTrips': 1,
    'billingReady': 1,
    'podHolds': 1,
    'revenue': 53750,
    'alerts': _notifications(),
    'fleetFreshness': {'state': 'fresh', 'label': 'Offline demo'},
  };

  static Map<String, dynamic> _billingPayload(Uri uri) {
    final invoices = _filter(_invoices, uri);
    return {
      'context': {
        'source': 'offline_demo',
        'scope': 'Delivery trip billing',
        'podGate': 'Completed trips require verified POD before final issue.',
      },
      'overview': {
        'totalBilled': 53750,
        'totalPaid': 0,
        'totalSent': 32000,
        'totalOverdue': 0,
        'invoiceCount': invoices.length,
        'podReadyCount': 1,
        'podHoldCount': 1,
      },
      'invoices': invoices,
      'pagination': _pagination(invoices, uri),
    };
  }

  static Map<String, dynamic> _soa() => {
    'clients': [
      {
        'name': 'Demo Client - North Distribution',
        'invoices': 1,
        'invoiceRows': [_invoices[0]],
        'totalBilled': 32000,
        'paid': 0,
        'overdue': 0,
        'outstanding': 32000,
      },
      {
        'name': 'Demo Client - Cold Chain Retail',
        'invoices': 1,
        'invoiceRows': [_invoices[1]],
        'totalBilled': 21750,
        'paid': 0,
        'overdue': 0,
        'outstanding': 21750,
      },
    ],
    'summary': {
      'totalBilled': 53750,
      'totalPaid': 0,
      'outstandingBalance': 53750,
      'invoiceCount': 2,
    },
  };

  static Map<String, dynamic> _maintenance() => {
    'history': _maintenanceHistory(),
    'faults': _faults(),
    'dvir': _dvir(),
    'workOrders': _workOrders(),
  };

  static List<Map<String, dynamic>> _maintenanceHistory() => [
    {
      'id': 'demo-maint-001',
      'vehicle': 'DEMO-TRK-01',
      'vehiclePlate': 'DEMO-TRK-01',
      'type': 'Preventive Maintenance',
      'description': 'Demo preventive maintenance check.',
      'status': 'recorded',
      'recordedAt': _iso(DateTime.now().subtract(const Duration(days: 10))),
      'nextDueAt': _iso(DateTime.now().add(const Duration(days: 35))),
      'cost': 4500,
      'provider': 'Demo Service Center',
    },
    {
      'id': 'demo-maint-002',
      'vehicle': 'DEMO-TRK-03',
      'vehiclePlate': 'DEMO-TRK-03',
      'type': 'Corrective Repair',
      'description': 'Demo cooling unit inspection.',
      'status': 'in_progress',
      'recordedAt': _iso(DateTime.now().subtract(const Duration(days: 2))),
      'nextDueAt': _iso(DateTime.now().add(const Duration(days: 7))),
      'cost': 9800,
      'provider': 'Demo Service Center',
    },
  ];

  static Map<String, dynamic> _maintenanceSummary() => {
    'history': _maintenanceHistory(),
    'dueSoon': 1,
    'underMaintenance': 1,
    'totalCost': 14300,
  };

  static Map<String, dynamic> _maintenancePredictions() => {
    'predictions': [
      {'vehicle': 'DEMO-TRK-03', 'risk': 'medium', 'nextDueLabel': 'Due within 7 days'},
    ],
  };

  static Map<String, dynamic> _analytics() => {
    'driverPerformanceTop': _drivers.take(2).toList(),
    'driverPerformanceBottom': [_drivers.last],
    'vehicleHealthRisk': [_vehicles.last],
    'routeEfficiency': [{'route': 'Demo Route - Metro Manila Northbound', 'score': 91}],
    'tripVolumeForecast': [{'label': 'This week', 'value': 8}],
    'fuelTrend': [{'label': 'Diesel', 'value': 64.5}],
  };

  static Map<String, dynamic> _fuel() => {
    'transactions': _fuelTransactions(),
    'summary': {'estimatedCost': 10320, 'liters': 160},
  };

  static List<Map<String, dynamic>> _fuelTransactions() => [
    {
      'id': 'demo-fuel-001',
      'date': _isoDate(DateTime.now().subtract(const Duration(days: 3))),
      'vehicle': 'DEMO-TRK-01',
      'station': 'Demo Fuel Station',
      'volumeLiters': 80,
      'pricePerLiter': 64.5,
      'estimatedCost': 5160,
      'source': 'Manual',
    },
  ];

  static Map<String, dynamic> _temperature() => {
    'assets': [
      {'vehicle': 'DEMO-TRK-01', 'temperatureC': 4.2, 'humidityPercent': 61, 'status': 'normal'},
    ],
  };

  static List<Map<String, dynamic>> _telemetryAssets() => _vehicles.map((vehicle) => {
    'geotabId': vehicle['geotabId'],
    'vehicle': vehicle['plate'],
    'driver': vehicle['driver'],
    'status': vehicle['status'],
    'isCommunicating': vehicle['isCommunicating'],
    'latitude': vehicle['latitude'],
    'longitude': vehicle['longitude'],
    'speed': vehicle['speed'],
    'bearing': vehicle['bearing'],
    'temperatureC': vehicle['plate'] == 'DEMO-TRK-01' ? 4.2 : null,
    'humidityPercent': vehicle['plate'] == 'DEMO-TRK-01' ? 61 : null,
    'lastUpdated': _iso(DateTime.now()),
  }).toList();

  static List<Map<String, dynamic>> _notifications() => [
    {
      'id': 'demo-live-trip',
      'title': 'Demo Live Trip Update',
      'message': 'DEMO-TRIP-LIVE is currently in transit.',
      'category': 'dispatch',
      'status': 'unread',
      'timestamp': _iso(DateTime.now().subtract(const Duration(minutes: 20))),
      'isRead': false,
    },
    {
      'id': 'demo-pod-hold',
      'title': 'Demo POD Review Needed',
      'message': 'DEMO-TRIP-POD-HOLD needs POD verification before billing.',
      'category': 'billing',
      'status': 'unread',
      'timestamp': _iso(DateTime.now().subtract(const Duration(minutes: 35))),
      'isRead': false,
    },
    {
      'id': 'demo-maintenance',
      'title': 'Demo Maintenance Reminder',
      'message': 'DEMO-TRK-03 is marked under maintenance.',
      'category': 'maintenance',
      'status': 'unread',
      'timestamp': _iso(DateTime.now().subtract(const Duration(hours: 1))),
      'isRead': false,
    },
  ];

  static List<Map<String, dynamic>> _users() => [
    _userRow('1', 'Super Administrator', 'admin@pioneerpath.local', 'super_administrator'),
    _userRow('2', 'Demo Fleet Manager', 'demo.fleet@pioneerpath.local', 'fleet_manager'),
    _userRow('3', 'Demo Dispatcher', 'demo.dispatch@pioneerpath.local', 'dispatcher'),
    _userRow('4', 'Demo Accounting Staff', 'demo.accounting@pioneerpath.local', 'accounting_staff'),
  ];

  static List<Map<String, dynamic>> _auditLogs() => [
    {
      'id': 'demo-audit-001',
      'timestamp': _iso(DateTime.now().subtract(const Duration(minutes: 8))),
      'actorName': 'Offline Demo',
      'actorEmail': 'admin@pioneerpath.local',
      'actorRole': 'super_administrator',
      'entityType': 'invoice',
      'entityId': 'DEMO-TRIP-BILLED',
      'entityLabel': 'INV-DEMO-001',
      'actionType': 'issued',
      'description': 'Demo invoice issued after POD verification.',
    },
  ];

  static List<Map<String, dynamic>> _writebackJobs() => [
    {
      'id': 'demo-writeback-001',
      'action': 'vehicle.update',
      'entityType': 'Device',
      'status': 'pending_approval',
      'localId': 'DEMO-TRK-01',
      'createdAt': _iso(DateTime.now().subtract(const Duration(hours: 2))),
      'previewPayload': {'plate': 'DEMO-TRK-01'},
    },
  ];

  static List<Map<String, dynamic>> _gpsTrail() => [
    {'latitude': 14.5794, 'longitude': 121.0359, 'recordedAt': _iso(DateTime.now().subtract(const Duration(minutes: 45)))},
    {'latitude': 14.6112, 'longitude': 121.0202, 'recordedAt': _iso(DateTime.now().subtract(const Duration(minutes: 25)))},
    {'latitude': 14.6507, 'longitude': 120.9676, 'recordedAt': _iso(DateTime.now().subtract(const Duration(minutes: 5)))},
  ];

  static List<Map<String, dynamic>> _faults() => [
    {'id': 'demo-fault-001', 'vehicle': 'DEMO-TRK-03', 'severity': 'warning', 'description': 'Cooling unit requires inspection.'},
  ];

  static List<Map<String, dynamic>> _dvir() => [
    {'id': 'demo-dvir-001', 'vehicle': 'DEMO-TRK-01', 'status': 'passed', 'date': _isoDate(DateTime.now())},
  ];

  static List<Map<String, dynamic>> _workOrders() => [
    {'id': 'demo-wo-001', 'vehicle': 'DEMO-TRK-03', 'status': 'open', 'description': 'Inspect reefer cooling unit.'},
  ];

  static Map<String, dynamic> _settings() => {
    'configured': true,
    'freeDeliveryThreshold': 100000,
    'baseDeliveryChargePerKm': 80,
    'fuelSurchargeRatePercent': 12,
    'vatRatePercent': 12,
    'dieselPricePerLiter': 64.5,
    'humidityAlertMinPercent': 10,
    'humidityAlertMaxPercent': 80,
  };

  static Map<String, dynamic> _notificationPreferences() => {
    'tripAlerts': true,
    'maintenanceAlerts': true,
    'billingAlerts': true,
    'quietHours': '22:00 - 06:00',
  };

  static Map<String, dynamic> _health() => {
    'success': true,
    'healthy': true,
    'status': 'offline_demo',
    'generatedAt': _iso(DateTime.now()),
    'checks': {
      'database': {'ok': true, 'message': 'Skipped in offline UI demo mode'},
      'cache': {'ok': true},
      'scheduler': {'ok': true, 'message': 'Not required for UI demo'},
    },
    'apiPressure': {'status': 'ok', 'recent429Count': 0},
    'emptyDataDiagnosis': {
      'status': 'ok',
      'primaryReason': 'offline_demo',
      'message': 'Flutter is serving built-in demo data without Laravel.',
    },
  };

  static Map<String, dynamic> _clientTracking(String tripId) {
    final trip = _trips.firstWhere(
      (row) => row['tripId'] == tripId,
      orElse: () => _trips.last,
    );
    final billed = trip['tripId'] == 'DEMO-TRIP-BILLED';
    return {
      ...trip,
      'trackingToken': 'offline-demo-token',
      'driverContactMasked': 'Contact through Pioneer dispatch',
      'invoiceSummary': billed ? _invoices.first : null,
      'pod': billed
          ? {
              'status': 'verified',
              'recipientName': 'Demo Receiver',
              'deliveredAt': trip['endedAt'],
            }
          : {
              'status': 'submitted',
              'recipientName': null,
            },
    };
  }

  static Map<String, dynamic> _demoUser(String email) {
    final normalized = email.trim().isEmpty ? 'admin@pioneerpath.local' : email.trim();
    final role = normalized.contains('dispatch')
        ? 'dispatcher'
        : normalized.contains('accounting')
            ? 'accounting_staff'
            : normalized.contains('fleet')
                ? 'fleet_manager'
                : 'super_administrator';
    final name = _users().firstWhere(
      (user) => user['email'] == normalized,
      orElse: () => _userRow('1', 'Super Administrator', normalized, role),
    )['fullName'];

    return {
      'success': true,
      'data': {
        'id': 'offline-$role',
        'username': normalized.split('@').first,
        'fullName': name,
        'email': normalized,
        'role': role,
        'roleLabel': _roleLabel(role),
        'managedRole': role,
        'createdAt': _iso(DateTime.now().subtract(const Duration(days: 30))),
        'mustChangePassword': false,
        'auth': {
          'accessToken': 'offline-demo-access-token',
          'refreshToken': 'offline-demo-refresh-token',
          'expiresAt': _iso(DateTime.now().add(const Duration(hours: 8))),
        },
      },
    };
  }

  static Map<String, dynamic> _trip(
    String tripId,
    String status,
    int phase,
    Map<String, dynamic>? client,
    Map<String, dynamic>? vehicle,
    Map<String, dynamic>? driver,
    double amount,
    DateTime scheduledAt,
  ) {
    final completed = status == 'completed';
    return {
      'tripId': tripId,
      'geotabId': tripId,
      'customer': client?['companyName'] ?? 'Demo Client',
      'client': client?['companyName'] ?? 'Demo Client',
      'phone': client?['contactNumber'] ?? 'N/A',
      'origin': 'Demo Depot - Mandaluyong',
      'destination': tripId == 'DEMO-TRIP-BILLED'
          ? 'Demo Destination - Caloocan Warehouse'
          : 'Demo Stop - Quezon City Hub',
      'cargoType': tripId == 'DEMO-TRIP-LIVE' ? 'Temperature-sensitive cargo' : 'General delivery',
      'vehicle': vehicle?['plate'] ?? '',
      'driver': driver?['name'] ?? '',
      'status': status,
      'amount': amount,
      'orderValue': amount,
      'distanceKm': amount > 0 ? 42.5 : 0,
      'date': _isoDate(scheduledAt),
      'scheduledDepartureAt': _iso(scheduledAt),
      'estimatedArrivalAt': _iso(scheduledAt.add(const Duration(hours: 3))),
      'startedAt': phase >= 10 ? _iso(scheduledAt) : null,
      'endedAt': completed ? _iso(scheduledAt.add(const Duration(hours: 3))) : null,
      'workflowPhaseNumber': phase,
      'workflowPhaseLabel': _phaseLabel(phase),
      'workflowGroup': _phaseGroup(phase),
      'deviceGeotabId': vehicle?['geotabId'],
      'routeName': 'Demo Route - Metro Manila Northbound',
      'arrivalState': phase >= 11 ? 'arrived' : 'pending',
      'arrivedAtDestination': phase >= 11,
      'podReady': completed,
      'podStatus': completed ? 'verified' : phase >= 11 ? 'submitted' : 'missing',
      'billingStatus': tripId == 'DEMO-TRIP-BILLED' ? 'issued' : phase >= 11 ? 'hold' : 'not_ready',
      'startPoint': {'latitude': 14.5794, 'longitude': 121.0359},
      'stopPoint': {'latitude': 14.6507, 'longitude': 120.9676},
    };
  }

  static Map<String, dynamic> _userRow(String id, String name, String email, String role) => {
    'id': id,
    'username': email.split('@').first,
    'fullName': name,
    'name': name,
    'email': email,
    'role': role,
    'roleLabel': _roleLabel(role),
    'managedRole': role,
    'status': 'active',
    'isActive': true,
    'mustChangePassword': false,
    'createdAt': _iso(DateTime.now().subtract(const Duration(days: 30))),
  };

  static Map<String, dynamic> _ok(Object data) => {'success': true, 'data': data};

  static Map<String, dynamic> _list(List<Map<String, dynamic>> rows, Uri uri) {
    final filtered = _filter(rows, uri);
    return {
      'success': true,
      'data': filtered,
      'meta': {'pagination': _pagination(filtered, uri)},
    };
  }

  static List<Map<String, dynamic>> _filter(List<Map<String, dynamic>> rows, Uri uri) {
    final search = (uri.queryParameters['search'] ?? '').trim().toLowerCase();
    if (search.isEmpty) {
      return rows;
    }
    return rows.where((row) => row.values.join(' ').toLowerCase().contains(search)).toList();
  }

  static Map<String, dynamic> _pagination(List<Map<String, dynamic>> rows, Uri uri) {
    final page = int.tryParse(uri.queryParameters['page'] ?? '') ?? 1;
    final perPage = int.tryParse(uri.queryParameters['perPage'] ?? '') ?? rows.length.clamp(1, 100);
    final lastPage = rows.isEmpty ? 1 : (rows.length / perPage).ceil();
    return {
      'total': rows.length,
      'currentPage': page,
      'lastPage': lastPage,
      'perPage': perPage,
      'nextPage': page < lastPage ? page + 1 : null,
      'previousPage': page > 1 ? page - 1 : null,
    };
  }

  static Map<String, dynamic> _touch(Map<String, dynamic> vehicle) => {
    ...vehicle,
    'lastUpdated': _iso(DateTime.now()),
  };

  static String _phaseLabel(int phase) => switch (phase) {
    <= 2 => 'Trip request',
    <= 6 => 'Dispatch assignment',
    <= 9 => 'Ready to dispatch',
    10 => 'In transit',
    11 => 'Arrived / POD needed',
    _ => 'Completed / POD review handoff',
  };

  static String _phaseGroup(int phase) => switch (phase) {
    <= 2 => 'Pending Details',
    <= 6 => 'Pending Assignment',
    <= 9 => 'Ready to Dispatch',
    10 => 'In Transit',
    11 => 'Arrived / POD Needed',
    _ => 'Completed / POD Review Handoff',
  };

  static String _roleLabel(String role) => switch (role) {
    'super_administrator' => 'Super Administrator',
    'system_administrator' => 'System Administrator',
    'fleet_manager' => 'Fleet Manager',
    'dispatcher' => 'Dispatch Coordinator',
    'accounting_staff' => 'Accounting Staff',
    _ => 'Driver',
  };

  static String _iso(DateTime value) => value.toIso8601String();

  static String _isoDate(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
}
