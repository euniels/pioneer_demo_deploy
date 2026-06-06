import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

Future<Database> openLocalFleetDatabase(
  String name, {
  required int version,
  required OnDatabaseCreateFn onCreate,
  OnDatabaseVersionChangeFn? onUpgrade,
}) {
  databaseFactory = databaseFactoryFfiWeb;
  return databaseFactoryFfiWeb.openDatabase(
    name,
    options: OpenDatabaseOptions(
      version: version,
      onCreate: onCreate,
      onUpgrade: onUpgrade,
    ),
  );
}
