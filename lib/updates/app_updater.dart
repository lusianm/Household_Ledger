import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import '../data/ledger_store.dart';
import '../domain/value.dart';

class AppVersion implements Comparable<AppVersion> {
  final int major, minor, patch, build;
  const AppVersion(this.major, this.minor, this.patch, this.build);
  static AppVersion parse(String value) {
    final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)\+(\d+)$').firstMatch(value);
    require(m != null, '배포 버전 형식이 올바르지 않아요.');
    return AppVersion(
      int.parse(m![1]!),
      int.parse(m[2]!),
      int.parse(m[3]!),
      int.parse(m[4]!),
    );
  }

  @override
  int compareTo(AppVersion other) {
    final a = [major, minor, patch, build],
        b = [other.major, other.minor, other.patch, other.build];
    for (var i = 0; i < a.length; i++) {
      final n = a[i].compareTo(b[i]);
      if (n != 0) return n;
    }
    return 0;
  }

  @override
  String toString() => '$major.$minor.$patch+$build';
}

class AppRelease {
  final AppVersion version;
  final String notes, checksum;
  final Uri url;
  final int size;
  const AppRelease(
    this.version,
    this.notes,
    this.url,
    this.checksum,
    this.size,
  );
}

class AppUpdater extends ChangeNotifier {
  final LedgerStore store;
  final String directory, repository, platform;
  final AppVersion current;
  final bool enabled;
  final http.Client client;
  bool checking = false, downloading = false, _disposed = false;
  String? error;
  double? progress;
  AppRelease? available;
  AppUpdater(
    this.store,
    this.directory, {
    required this.current,
    required this.platform,
    this.repository = const String.fromEnvironment('UPDATE_REPOSITORY'),
    this.enabled = true,
    http.Client? client,
  }) : client = client ?? http.Client() {
    final cached = store.local(cacheKey);
    if (configured && cached != null) {
      try {
        available = parseRelease(jsonDecode(cached) as Json);
      } catch (_) {
        store.removeLocal(cacheKey);
      }
    }
  }
  String get cacheKey => 'update_cache/$repository/$platform';
  bool get configured =>
      enabled &&
      RegExp(r'^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$').hasMatch(repository) &&
      ['android', 'windows'].contains(platform);
  bool get automatic => store.local('update_auto') != 'false';
  bool get showBanner =>
      available != null &&
      store.local('update_dismissed') != '${available!.version}';
  void setAutomatic(bool value) {
    store.setLocal('update_auto', '$value');
    _notify();
  }

  void dismiss() {
    store.setLocal('update_dismissed', '${available?.version}');
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  AppRelease? parseRelease(Json data) {
    if (data['draft'] == true || data['prerelease'] == true) return null;
    final version = AppVersion.parse(data['tag_name'] as String);
    // Build numbers are monotonic on both platforms; never suggest a downgrade.
    if (version.compareTo(current) <= 0 || version.build <= current.build) {
      return null;
    }
    final name = platform == 'windows'
        ? 'chagok-windows-setup.exe'
        : 'chagok-android.apk';
    final asset = rows(
      data['assets'],
    ).where((a) => a['name'] == name).firstOrNull;
    if (asset == null) return null;
    final uri = Uri.parse(asset['browser_download_url'] as String);
    final expected = [
      ...repository.split('/'),
      'releases',
      'download',
      data['tag_name'] as String,
      name,
    ];
    require(
      uri.scheme == 'https' &&
          uri.host == 'github.com' &&
          uri.port == 443 &&
          uri.userInfo.isEmpty &&
          uri.query.isEmpty &&
          uri.fragment.isEmpty &&
          listEquals(uri.pathSegments, expected),
      '업데이트 파일의 배포 주소가 일치하지 않아요.',
    );
    final checksum = asset['digest'] as String? ?? '';
    require(
      RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(checksum),
      '업데이트 파일의 검증 정보가 없어요.',
    );
    final size = asset['size'];
    require(
      size is int && size > 0 && size <= 1024 * 1024 * 1024,
      '업데이트 파일 크기를 확인할 수 없어요.',
    );
    final notes = data['body'] as String? ?? '';
    return AppRelease(
      version,
      notes.length > 4000 ? notes.substring(0, 4000) : notes,
      uri,
      checksum.substring(7).toLowerCase(),
      size as int,
    );
  }

  Future<void> check({bool force = false}) async {
    if (!configured || checking || downloading || !force && !automatic) return;
    final last = store.local('$cacheKey/checked');
    if (!force && last == today()) return;
    checking = true;
    error = null;
    store.setLocal('$cacheKey/checked', today());
    _notify();
    try {
      final response = await client
          .get(
            Uri.https('api.github.com', '/repos/$repository/releases/latest'),
            headers: {
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (_disposed) return;
      if (response.statusCode == 404) {
        available = null;
        store.removeLocal(cacheKey);
        return;
      }
      require(
        response.statusCode == 200,
        '업데이트 확인 실패 (${response.statusCode}). 가계부는 계속 사용할 수 있어요.',
      );
      require(response.bodyBytes.length <= 2 * 1024 * 1024, '배포 정보가 너무 커요.');
      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Json;
      available = parseRelease(data);
      store.setLocal(cacheKey, jsonEncode(data));
    } catch (e) {
      if (!_disposed) error = '$e';
    } finally {
      checking = false;
      _notify();
    }
  }

  Future<File> download() async {
    require(!downloading, '이미 업데이트 파일을 받고 있어요.');
    final release = available;
    require(release != null, '설치할 새 버전이 없어요.');
    downloading = true;
    progress = 0;
    error = null;
    _notify();
    final folder = Directory(p.join(directory, 'updates'));
    final extension = platform == 'windows' ? 'exe' : 'apk';
    final file = File(
      p.join(
        folder.path,
        'chagok-${release!.version.build}-${release.checksum.substring(0, 12)}.$extension',
      ),
    );
    final partial = File('${file.path}.part');
    try {
      await folder.create(recursive: true);
      if (await file.exists() && await _valid(file, release)) {
        progress = 1;
        return file;
      }
      final response = await client
          .send(http.Request('GET', release.url))
          .timeout(const Duration(seconds: 30));
      require(
        response.statusCode == 200,
        '설치 파일을 받지 못했어요 (${response.statusCode}).',
      );
      var length = 0;
      final sink = partial.openWrite();
      try {
        await for (final bytes in response.stream.timeout(
          const Duration(seconds: 45),
        )) {
          length += bytes.length;
          require(length <= release.size, '설치 파일 크기가 배포 정보와 달라요.');
          sink.add(bytes);
          progress = length / release.size;
          _notify();
        }
      } finally {
        await sink.close();
      }
      require(await _valid(partial, release), '설치 파일 검증에 실패했어요. 다시 받아 주세요.');
      if (await file.exists()) await file.delete();
      await partial.rename(file.path);
      progress = 1;
      return file;
    } catch (e) {
      error = '$e';
      if (await partial.exists()) await partial.delete();
      rethrow;
    } finally {
      downloading = false;
      _notify();
    }
  }

  Future<bool> _valid(File file, AppRelease release) async =>
      await file.length() == release.size &&
      '${await sha256.bind(file.openRead()).first}' == release.checksum;
  @override
  void dispose() {
    _disposed = true;
    client.close();
    super.dispose();
  }
}
