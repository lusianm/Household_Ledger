import 'dart:convert';
import 'dart:js_interop';
import '../domain/value.dart';

@JS('chagok.read')
external JSString? _read();
@JS('chagok.info')
external JSString _info();
@JS('chagok.markDirty')
external void markDirty();
@JS('chagok.save')
external JSPromise<JSAny?> _save(JSString value);
@JS('chagok.backup')
external JSPromise<JSString> _backup(JSString value, JSString purpose);
@JS('chagok.erase')
external JSPromise<JSAny?> _erase();
@JS('chagok.install')
external JSPromise<JSString> _install();
@JS('chagok.checkUpdate')
external JSPromise<JSBoolean> _checkUpdate();
@JS('chagok.applyUpdate')
external JSPromise<JSAny?> _applyUpdate();
@JS('chagok.readConnectionRequest')
external JSPromise<JSString?> _readConnectionRequest();
@JS('chagok.writeConnection')
external JSPromise<JSAny?> _writeConnection(JSString name, JSString payload);

Future<String?> readConnectionRequest() async =>
    (await _readConnectionRequest().toDart)?.toDart;
Future<void> writeConnection(String name, Json payload) async {
  await _writeConnection(name.toJS, jsonEncode(payload).toJS).toDart;
}

Json? readCheckpoint() {
  final text = _read()?.toDart;
  return text == null ? null : jsonDecode(text) as Json;
}

Json deviceInfo() => jsonDecode(_info().toDart) as Json;
Future<void> saveCheckpoint(Json data) async {
  await _save(jsonEncode(data).toJS).toDart;
}

Future<String> backup(String directory, Json data, String purpose) async =>
    (await _backup(jsonEncode(data).toJS, purpose.toJS).toDart).toDart;
Future<void> erase() async {
  await _erase().toDart;
}

Future<String> install() async => (await _install().toDart).toDart;
Future<bool> checkUpdate() async => (await _checkUpdate().toDart).toDart;
Future<void> applyUpdate() async {
  await _applyUpdate().toDart;
}
