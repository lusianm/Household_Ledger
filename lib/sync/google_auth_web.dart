import 'dart:js_interop';

const driveScope = 'https://www.googleapis.com/auth/drive';
@JS('chagok.token')
external JSPromise<JSString> _token(
  JSString client,
  JSBoolean interactive,
  JSBoolean refresh,
);
@JS('chagok.disconnect')
external JSPromise<JSAny?> _disconnect();
@JS('chagok.hint')
external void _hint(JSString hint);

class GoogleAuth {
  final String clientId;
  GoogleAuth({
    this.clientId = const String.fromEnvironment('GOOGLE_WEB_CLIENT_ID'),
  });
  bool get configured => clientId.isNotEmpty;
  set loginHint(String value) => _hint(value.toJS);
  Future<String> token({
    bool interactive = false,
    bool refresh = false,
  }) async => (await _token(
    clientId.toJS,
    interactive.toJS,
    refresh.toJS,
  ).toDart).toDart;
  Future<void> disconnect() async {
    await _disconnect().toDart;
  }
}
