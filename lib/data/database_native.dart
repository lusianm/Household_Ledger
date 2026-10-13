import 'package:sqlite3/sqlite3.dart';

Future<void> initializeDatabase() async {}
Database openDatabase(String? path) =>
    path == null ? sqlite3.openInMemory() : sqlite3.open(path);
