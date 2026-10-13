import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'data/database_native.dart'
    if (dart.library.js_interop) 'data/database_web.dart'
    as backend;
import 'platform/device.dart' as device;
import 'app_controller.dart';
import 'data/ledger_store.dart';
import 'ui/ledger_home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await backend.initializeDatabase();
    final directory = kIsWeb
        ? ''
        : (await getApplicationSupportDirectory()).path;
    final store = kIsWeb
        ? LedgerStore.memory()
        : LedgerStore(p.join(directory, 'ledger.db'));
    if (kIsWeb) {
      final snapshot = device.readCheckpoint();
      if (snapshot != null) store.loadCheckpoint(snapshot);
    }
    final app = AppController(store, directory);
    app.initialize();
    await app.flush();
    runApp(ChagokApp(app: app));
  } catch (e) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: SelectableText(
                '가계부를 열지 못했습니다. 기존 파일은 삭제하지 않았습니다.\n앱을 다시 실행하거나 백업 파일을 확인해 주세요.\n\n$e',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ChagokApp extends StatelessWidget {
  final AppController app;
  const ChagokApp({super.key, required this.app});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => MaterialApp(
      title: '차곡',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ko', 'KR'),
      supportedLocales: const [Locale('ko', 'KR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      themeMode: switch (app.theme) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: LedgerHome(app: app),
      builder: (context, child) => Stack(
        children: [
          AbsorbPointer(absorbing: app.storageError != null, child: child!),
          if (app.storageError != null)
            Positioned.fill(
              child: Material(
                color: Theme.of(
                  context,
                ).colorScheme.surface.withValues(alpha: 0.97),
                child: Center(
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 480),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.save_as_outlined, size: 44),
                            const SizedBox(height: 16),
                            const Text(
                              '기기에 저장하지 못했어요',
                              style: TextStyle(fontSize: 22),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '창을 닫지 마세요. 마지막 입력은 아직 메모리에 있습니다. 폴더 권한과 여유 공간을 확인하고 재시도하거나 전체 백업을 내보내 주세요.\n\n${app.storageError}',
                            ),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: app.retryStorage,
                              child: const Text('기기 저장 재시도'),
                            ),
                            TextButton(
                              onPressed: () async {
                                await FilePicker.platform.saveFile(
                                  fileName: 'chagok-recovery.json',
                                  bytes: Uint8List.fromList(
                                    utf8.encode(
                                      jsonEncode(app.store.exportBackup()),
                                    ),
                                  ),
                                );
                              },
                              child: const Text('현재 내역 전체 백업'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
  ThemeData theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff009bc4),
      brightness: brightness,
      primary: brightness == Brightness.light
          ? const Color(0xff007fa6)
          : const Color(0xff69d7f4),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      fontFamily: kIsWeb
          ? 'NotoSansKR'
          : defaultTargetPlatform == TargetPlatform.windows
          ? 'Malgun Gothic'
          : null,
      scaffoldBackgroundColor: brightness == Brightness.light
          ? const Color(0xfff4f8fa)
          : const Color(0xff111a20),
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: const EdgeInsets.all(4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      navigationBarTheme: const NavigationBarThemeData(height: 72),
    );
  }
}
