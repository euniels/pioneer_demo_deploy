// lib/src/services/maintenance_store.dart
import 'package:flutter/material.dart';

final ValueNotifier<List<Map<String, dynamic>>> maintenanceNotifier =
    ValueNotifier<List<Map<String, dynamic>>>(_initialMaintenance());

List<Map<String, dynamic>> _initialMaintenance() => [];

void addMaintenanceRecord(Map<String, dynamic> record) {
  maintenanceNotifier.value = [record, ...maintenanceNotifier.value];
}

void updateMaintenanceRecord(
  String vehiclePlate,
  Map<String, dynamic> updates,
) {
  maintenanceNotifier.value = maintenanceNotifier.value.map((record) {
    if (record['vehicle'] == vehiclePlate) {
      return {...record, ...updates};
    }
    return record;
  }).toList();
}

void deleteMaintenanceRecord(String vehiclePlate) {
  maintenanceNotifier.value = maintenanceNotifier.value
      .where((record) => record['vehicle'] != vehiclePlate)
      .toList();
}
