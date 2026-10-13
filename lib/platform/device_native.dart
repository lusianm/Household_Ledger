import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../domain/value.dart';

Json? readCheckpoint() => null;
Json deviceInfo() => {'folder': '네이티브 테스트 저장소', 'notice': ''};
void markDirty() {}
Future<void> saveCheckpoint(Json data) async {}
Future<String> backup(String directory, Json data, String purpose) async {
  final folder = Directory(p.join(directory, 'backups'));
  await folder.create(recursive: true);
  final file = File(
    p.join(
      folder.path,
      'before-$purpose-${DateTime.now().microsecondsSinceEpoch}.json',
    ),
  );
  await file.writeAsString(jsonEncode(data), flush: true);
  return file.path;
}

Future<void> erase() async => throw UnsupportedError('웹 앱에서만 사용할 수 있어요.');
Future<String> install() async => '웹 앱에서만 사용할 수 있어요.';
Future<bool> checkUpdate() async => false;
Future<void> applyUpdate() async {}
