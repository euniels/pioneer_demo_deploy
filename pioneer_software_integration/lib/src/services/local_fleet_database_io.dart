import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<sqflite.Database> openLocalFleetDatabase(
  String name, {
  required int version,
  required sqflite.OnDatabaseCreateFn onCreate,
  sqflite.OnDatabaseVersionChangeFn? onUpgrade,
}) async {
  if (Platform.isAndroid || Platform.isIOS) {
    final path = p.join(await sqflite.getDatabasesPath(), name);
    return sqflite.openDatabase(
      path,
      version: version,
      onCreate: onCreate,
      onUpgrade: onUpgrade,
    );
  }

  sqfliteFfiInit();
  final path = p.join(Directory.systemTemp.path, name);
  return databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: version,
      onCreate: onCreate,
      onUpgrade: onUpgrade,
    ),
  );
}
