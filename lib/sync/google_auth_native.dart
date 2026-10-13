// Native harness for domain/widget tests. Production authentication is web-only.
const driveScope = 'https://www.googleapis.com/auth/drive';

class GoogleAuth {
  bool get configured => false;
  set loginHint(String value) {}
  Future<String> token({
    bool interactive = false,
    bool refresh = false,
  }) async => throw UnsupportedError('Google 로그인은 웹 앱에서 사용해 주세요.');
  Future<void> disconnect() async {}
}
