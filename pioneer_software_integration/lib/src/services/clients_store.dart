import 'package:flutter/foundation.dart';

import 'backend_api.dart';

final ValueNotifier<List<Map<String, dynamic>>> clientsNotifier =
    ValueNotifier<List<Map<String, dynamic>>>(const []);

Future<void> refreshClients({bool forceRefresh = false}) async {
  final clients = await BackendApiService.getFleetClients(
    forceRefresh: forceRefresh,
  );
  clientsNotifier.value = clients;
}

Future<Map<String, dynamic>> createClient(Map<String, dynamic> payload) async {
  final response = await BackendApiService.createFleetClient(payload);
  await refreshClients(forceRefresh: true);
  return response;
}

Future<Map<String, dynamic>> updateClient(
  String clientId,
  Map<String, dynamic> payload,
) async {
  final response = await BackendApiService.updateFleetClient(clientId, payload);
  await refreshClients(forceRefresh: true);
  return response;
}

Future<Map<String, dynamic>> deactivateClient(
  String clientId, {
  String reason = 'Deactivated from PioneerPath clients page.',
}) async {
  final response = await BackendApiService.deactivateFleetClient(
    clientId,
    reason: reason,
  );
  await refreshClients(forceRefresh: true);
  return response;
}

List<String> activeClientNames() {
  final names =
      clientsNotifier.value
          .where((client) {
            final status =
                client['status']?.toString().toLowerCase() ?? 'active';
            return status == 'active';
          })
          .map((client) => client['companyName']?.toString().trim() ?? '')
          .where((name) => name.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
  return names;
}
