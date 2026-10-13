import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'data/ledger_store.dart';
import 'domain/ledger_service.dart';
import 'domain/value.dart';
import 'sync/drive_sync.dart';
import 'sync/google_auth.dart';
import 'updates/app_updater.dart';

class AppController extends ChangeNotifier {
  final LedgerStore store;
  final String directory;
  late final service = LedgerService(store);
  final GoogleAuth auth;
  late final DriveTransport drive;
  Timer? _syncTimer;
  bool syncing = false;
  String? syncError;
  final AppVersion version;
  final bool releaseBuild;
  late final updates = AppUpdater(
    store,
    directory,
    current: version,
    platform: Platform.isWindows ? 'windows' : 'android',
    enabled: releaseBuild,
  );
  AppController(
    this.store,
    this.directory, {
    this.version = const AppVersion(0, 1, 0, 1),
    this.releaseBuild = false,
    GoogleAuth? auth,
    DriveTransport? drive,
  }) : auth = auth ?? GoogleAuth() {
    this.drive =
        drive ??
        DriveTransport(
          this.auth,
          folderId: () => store.local('drive_folder_id'),
          knownChanges: () =>
              store.events.map((e) => e['id'] as String).toSet(),
        );
  }
  bool get connected =>
      store.local('drive_owner') != null &&
      store.local('drive_folder_id') != null;
  String get theme =>
      store.get('settings', 'preferences')?['theme'] as String? ?? 'system';
  void initialize() {
    updates.addListener(notifyListeners);
    service.seedCategories();
    service.generateDue();
  }

  void changed() {
    notifyListeners();
    _syncTimer?.cancel();
    if (connected) _syncTimer = Timer(const Duration(seconds: 3), () => sync());
  }

  void preferences(String theme) {
    store.save('settings', {'id': 'preferences', 'theme': theme});
    changed();
  }

  Future<void> resume() async {
    unawaited(updates.check());
    try {
      service.generateDue();
      changed();
      await sync();
    } catch (e) {
      syncError = '$e';
      notifyListeners();
    }
  }

  Future<void> sync() async {
    if (!connected || syncing) return;
    syncing = true;
    syncError = null;
    notifyListeners();
    try {
      final user = await drive.identity();
      require(
        user['permissionId'] == store.local('drive_owner'),
        '연결된 Google 계정이 달라요. 설정에서 계정을 확인해 주세요.',
      );
      final folder = await drive.folder(store.local('drive_folder_id')!);
      store.setLocal('drive_folder_name', folder['name'] as String);
      await SyncEngine(store, drive).synchronize();
      if (service.generateDue() > 0) {
        await SyncEngine(store, drive).synchronize();
      }
    } catch (e) {
      syncError = '$e';
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  Future<String> safetyBackup({String purpose = 'restore'}) async {
    final folder = Directory(p.join(directory, 'backups'));
    await folder.create(recursive: true);
    final file = File(
      p.join(
        folder.path,
        'before-$purpose-${DateTime.now().microsecondsSinceEpoch}.json',
      ),
    );
    await file.writeAsString(jsonEncode(store.exportBackup()), flush: true);
    return file.path;
  }

  Future<void> restore(Json backup, {bool asNew = true}) async {
    require(!syncing, '동기화가 끝난 뒤 복원해 주세요.');
    _syncTimer?.cancel();
    await safetyBackup();
    store.restoreBackup(backup, asNew: asNew);
    for (final key in [
      'drive_owner',
      'drive_email',
      'drive_folder_id',
      'drive_folder_name',
      'last_sync',
      'entry_draft',
    ]) {
      store.removeLocal(key);
    }
    service.generateDue();
    notifyListeners();
  }

  Future<void> bind(Json user, Json folder) async {
    require(!syncing && !connected, '기존 Drive 연결을 먼저 해제해 주세요.');
    final currentUser = await drive.identity();
    require(
      currentUser['permissionId'] == user['permissionId'],
      'Google 계정이 변경되었어요. 다시 연결해 주세요.',
    );
    final checkedFolder = await drive.folder(folder['id'] as String);
    // Commit the destination and delivery reset together: an interrupted
    // connection must not reuse another folder's upload acknowledgements.
    store.db.execute('BEGIN IMMEDIATE');
    try {
      store.setLocal('drive_owner', user['permissionId'] as String);
      store.setLocal(
        'drive_email',
        user['emailAddress'] as String? ?? 'Google 계정',
      );
      store.setLocal('drive_folder_id', checkedFolder['id'] as String);
      store.setLocal('drive_folder_name', checkedFolder['name'] as String);
      store.removeLocal('last_sync');
      store.db.execute('UPDATE sync_deliveries SET uploaded=0');
      store.db.execute('COMMIT');
    } catch (_) {
      store.db.execute('ROLLBACK');
      rethrow;
    }
    await sync();
  }

  Future<void> disconnect() async {
    require(!syncing, '동기화가 끝난 뒤 연결을 해제해 주세요.');
    _syncTimer?.cancel();
    await auth.disconnect();
    store.removeLocal('drive_owner');
    store.removeLocal('drive_email');
    store.removeLocal('drive_folder_id');
    store.removeLocal('drive_folder_name');
    store.removeLocal('last_sync');
    syncError = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    drive.close();
    updates.removeListener(notifyListeners);
    updates.dispose();
    super.dispose();
  }
}
