import 'dart:async';
import 'package:flutter/foundation.dart';
import 'data/ledger_store.dart';
import 'domain/ledger_service.dart';
import 'domain/value.dart';
import 'platform/device.dart' as device;
import 'sync/drive_sync.dart';
import 'sync/google_auth.dart';

class AppController extends ChangeNotifier {
  final LedgerStore store;
  final String directory;
  late final service = LedgerService(store);
  final GoogleAuth auth;
  late final DriveTransport drive;
  final Future<void> Function(Json)? checkpointWriter;
  bool syncing = false, saving = false, dirty = false;
  bool _started = false, _disposed = false, _deleting = false;
  Future<void>? _writing;
  String? syncError, storageError;
  AppController(
    this.store,
    this.directory, {
    GoogleAuth? auth,
    DriveTransport? drive,
    Future<void> Function(Json)? checkpointWriter,
  }) : auth = auth ?? GoogleAuth(),
       checkpointWriter =
           checkpointWriter ?? (kIsWeb ? device.saveCheckpoint : null) {
    this.drive =
        drive ??
        DriveTransport(
          this.auth,
          folderId: () => store.local('drive_folder_id'),
          knownChanges: () =>
              store.events.map((e) => e['id'] as String).toSet(),
        );
    store.onChanged = _changedLocally;
    store.beforeWrite = () {
      require(!_deleting, '기기 데이터를 삭제하고 있어요.');
      require(storageError == null, '기기 저장을 재시도한 뒤 입력해 주세요.');
    };
    this.auth.loginHint = store.local('drive_email') ?? '';
  }
  bool get connected =>
      store.local('drive_owner') != null &&
      store.local('drive_folder_id') != null;
  String get theme =>
      store.get('settings', 'preferences')?['theme'] as String? ?? 'system';
  String get storageStatus => storageError != null
      ? '기기 저장 실패'
      : saving || dirty
      ? '기기에 저장 중…'
      : '기기에 저장됨';
  void initialize() {
    service.seedCategories();
    service.generateDue();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _changedLocally() {
    if (checkpointWriter == null || _disposed) return;
    dirty = true;
    device.markDirty();
    scheduleMicrotask(() {
      if (!_disposed) {
        _persist();
        _notify();
      }
    });
  }

  Future<void> _persist() {
    if (_writing != null) return _writing!;
    if (!dirty || checkpointWriter == null || storageError != null) {
      return Future.value();
    }
    saving = true;
    // Capture only after synchronous SQL transactions have committed.
    final future = Future<void>(() async {
      try {
        while (dirty && !_disposed) {
          dirty = false;
          await checkpointWriter!(store.checkpoint());
          if (dirty) device.markDirty();
        }
      } catch (e) {
        dirty = true;
        device.markDirty();
        storageError = '$e';
      } finally {
        saving = false;
        _writing = null;
        _notify();
      }
    });
    _writing = future;
    return future;
  }

  Future<void> flush() async {
    await _persist();
    require(
      storageError == null && !dirty,
      storageError ?? '기기 저장을 완료하지 못했어요.',
    );
  }

  Future<void> retryStorage() async {
    storageError = null;
    await _persist();
    _notify();
  }

  void changed() {
    _notify();
  }

  void preferences(String theme) {
    store.save('settings', {'id': 'preferences', 'theme': theme});
    changed();
  }

  Future<void> resume() async {
    final initial = !_started;
    _started = true;
    try {
      service.generateDue();
      await flush();
      if (initial) await sync();
      _notify();
    } catch (e) {
      syncError = '$e';
      _notify();
    }
  }

  Future<void> sync({bool interactive = false}) async {
    if (!connected || syncing || _deleting) return;
    syncing = true;
    syncError = null;
    _notify();
    try {
      // Launch authorization from a user click before any disk/network awaits.
      await auth.token(interactive: interactive);
      await flush();
      final user = await drive.identity();
      if (user['permissionId'] != store.local('drive_owner')) {
        await auth.disconnect();
        auth.loginHint = store.local('drive_email') ?? '';
      }
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
      await flush();
    } catch (e) {
      syncError = '$e';
    } finally {
      syncing = false;
      _notify();
    }
  }

  Future<String> safetyBackup({String purpose = 'restore'}) async =>
      device.backup(directory, store.exportBackup(), purpose);
  Future<void> restore(Json backup, {bool asNew = true}) async {
    require(!syncing, '동기화가 끝난 뒤 복원해 주세요.');
    await flush();
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
    await flush();
    _notify();
  }

  Future<void> bind(Json user, Json folder) async {
    require(!syncing && !connected, '기존 Drive 연결을 먼저 해제해 주세요.');
    final currentUser = await drive.identity();
    require(
      currentUser['permissionId'] == user['permissionId'],
      'Google 계정이 변경되었어요. 다시 연결해 주세요.',
    );
    final checkedFolder = await drive.folder(folder['id'] as String);
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
    auth.loginHint = store.local('drive_email') ?? '';
    await flush();
    await sync();
  }

  Future<void> disconnect() async {
    require(!syncing, '동기화가 끝난 뒤 연결을 해제해 주세요.');
    await auth.disconnect();
    for (final key in [
      'drive_owner',
      'drive_email',
      'drive_folder_id',
      'drive_folder_name',
      'last_sync',
    ]) {
      store.removeLocal(key);
    }
    syncError = null;
    await flush();
    _notify();
  }

  Future<void> eraseDevice() async {
    require(!syncing, '동기화가 끝난 뒤 삭제해 주세요.');
    await flush();
    _deleting = true;
    try {
      await device.erase();
    } catch (_) {
      _deleting = false;
      rethrow;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    store.onChanged = null;
    store.beforeWrite = null;
    drive.close();
    super.dispose();
  }
}
