import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import '../domain/value.dart';

const driveScope = 'https://www.googleapis.com/auth/drive.appdata';

class GoogleAuth {
  final FlutterSecureStorage secure;
  final String androidClientId;
  final String desktopClientId;
  final String desktopClientSecret;
  GoogleSignInAccount? _androidAccount;
  bool _initialized = false;
  Json? _desktop;
  GoogleAuth({
    this.secure = const FlutterSecureStorage(),
    this.androidClientId = const String.fromEnvironment(
      'GOOGLE_ANDROID_SERVER_CLIENT_ID',
    ),
    this.desktopClientId = const String.fromEnvironment(
      'GOOGLE_DESKTOP_CLIENT_ID',
    ),
    this.desktopClientSecret = const String.fromEnvironment(
      'GOOGLE_DESKTOP_CLIENT_SECRET',
    ),
  });
  bool get configured => Platform.isAndroid
      ? androidClientId.isNotEmpty
      : desktopClientId.isNotEmpty;
  Future<String> token({bool interactive = false, bool refresh = false}) async {
    require(
      configured,
      'Google 연결 설정이 필요합니다. README의 OAuth 설정 후 다시 빌드해 주세요. 로컬 가계부는 계속 사용할 수 있어요.',
    );
    if (Platform.isAndroid) {
      final signIn = GoogleSignIn.instance;
      if (!_initialized) {
        await signIn.initialize(serverClientId: androidClientId);
        _initialized = true;
      }
      _androidAccount ??= await signIn.attemptLightweightAuthentication();
      if (_androidAccount == null && interactive) {
        _androidAccount = await signIn.authenticate(scopeHint: [driveScope]);
      }
      require(_androidAccount != null, 'Google 로그인이 필요해요. 설정에서 연결해 주세요.');
      final client = _androidAccount!.authorizationClient;
      var authorization = await client.authorizationForScopes([driveScope]);
      if (refresh && authorization != null) {
        await client.clearAuthorizationToken(
          accessToken: authorization.accessToken,
        );
        authorization = null;
      }
      authorization ??= interactive
          ? await client.authorizeScopes([driveScope])
          : await client.authorizationForScopes([driveScope]);
      require(authorization != null, 'Google Drive 접근을 승인해 주세요.');
      return authorization!.accessToken;
    }
    _desktop ??= await _readDesktop();
    if (_desktop == null && interactive) await _loginDesktop();
    require(_desktop != null, 'Google 로그인이 필요해요.');
    if (refresh ||
        DateTime.parse(
          _desktop!['expires_at'] as String,
        ).isBefore(DateTime.now().toUtc().add(const Duration(minutes: 1)))) {
      final refreshToken = _desktop!['refresh_token'];
      require(refreshToken != null, 'Google 연결을 해제한 뒤 다시 로그인해 주세요.');
      final response = await http
          .post(
            Uri.https('oauth2.googleapis.com', '/token'),
            body: {
              'client_id': desktopClientId,
              if (desktopClientSecret.isNotEmpty)
                'client_secret': desktopClientSecret,
              'refresh_token': refreshToken as String,
              'grant_type': 'refresh_token',
            },
          )
          .timeout(const Duration(seconds: 30));
      require(
        response.statusCode == 200,
        'Google 로그인 유효기간이 만료되었어요. 다시 연결해 주세요.',
      );
      await _saveDesktop(jsonDecode(response.body) as Json);
    }
    return _desktop!['access_token'] as String;
  }

  Future<Json?> _readDesktop() async {
    final raw = await secure.read(key: 'chagok.oauth');
    if (raw == null) return null;
    final value = jsonDecode(raw) as Json;
    return value['client_id'] == desktopClientId ? value : null;
  }

  Future<void> _saveDesktop(Json response) async {
    _desktop = {
      ...?_desktop,
      ...response,
      'client_id': desktopClientId,
      'expires_at': DateTime.now()
          .toUtc()
          .add(Duration(seconds: response['expires_in'] as int))
          .toIso8601String(),
    };
    await secure.write(key: 'chagok.oauth', value: jsonEncode(_desktop));
  }

  String _random() {
    final random = Random.secure();
    return base64UrlEncode(
      List.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
  }

  Future<void> _loginDesktop() async {
    final verifier = _random(), state = _random();
    final challenge = base64UrlEncode(
      sha256.convert(utf8.encode(verifier)).bytes,
    ).replaceAll('=', '');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://127.0.0.1:${server.port}/callback';
    final result = Completer<String>();
    final subscription = server.listen((request) async {
      if (request.uri.path != '/callback' ||
          request.uri.queryParameters['state'] != state) {
        request.response.statusCode = 400;
        await request.response.close();
        return;
      }
      final code = request.uri.queryParameters['code'];
      request.response.headers.contentType = ContentType.text;
      request.response.write('Chagok: return to the app.');
      await request.response.close();
      if (!result.isCompleted) {
        if (code == null) {
          result.completeError(const LedgerException('Google 연결이 취소되었어요.'));
        } else {
          result.complete(code);
        }
      }
    });
    try {
      final uri = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': desktopClientId,
        'redirect_uri': redirect,
        'response_type': 'code',
        'scope': driveScope,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        'access_type': 'offline',
        'prompt': 'consent select_account',
      });
      require(
        await launchUrl(uri, mode: LaunchMode.externalApplication),
        '로그인 브라우저를 열 수 없어요.',
      );
      final code = await result.future.timeout(
        const Duration(minutes: 3),
        onTimeout: () =>
            throw const LedgerException('로그인 시간이 초과되었어요. 다시 연결해 주세요.'),
      );
      final response = await http
          .post(
            Uri.https('oauth2.googleapis.com', '/token'),
            body: {
              'client_id': desktopClientId,
              if (desktopClientSecret.isNotEmpty)
                'client_secret': desktopClientSecret,
              'code': code,
              'code_verifier': verifier,
              'redirect_uri': redirect,
              'grant_type': 'authorization_code',
            },
          )
          .timeout(const Duration(seconds: 30));
      require(
        response.statusCode == 200,
        'Google 인증을 완료하지 못했어요. OAuth 설정을 확인해 주세요.',
      );
      await _saveDesktop(jsonDecode(response.body) as Json);
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  }

  Future<void> disconnect() async {
    if (Platform.isAndroid && _initialized) {
      await GoogleSignIn.instance.signOut();
    }
    _androidAccount = null;
    _desktop = null;
    await secure.delete(key: 'chagok.oauth');
  }
}
