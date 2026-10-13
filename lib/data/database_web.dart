import 'package:sqlite3/wasm.dart';

late WasmSqlite3 _sqlite;
Future<void> initializeDatabase({Uri? wasmUri}) async {
  _sqlite = await WasmSqlite3.loadFromUrl(
    wasmUri ?? Uri.base.resolve('sqlite3.wasm'),
  );
  _sqlite.registerVirtualFileSystem(InMemoryFileSystem(), makeDefault: true);
}

CommonDatabase openDatabase(String? path) => _sqlite.openInMemory();
