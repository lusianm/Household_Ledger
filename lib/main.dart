import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'app_controller.dart';
import 'data/ledger_store.dart';
import 'ui/ledger_home.dart';
import 'updates/app_updater.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final package = await PackageInfo.fromPlatform();
    final app = AppController(
      LedgerStore(p.join(directory.path, 'ledger.db')),
      directory.path,
      version: AppVersion.parse('${package.version}+${package.buildNumber}'),
      releaseBuild: kReleaseMode,
    );
    app.initialize();
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
      fontFamily: Platform.isWindows ? 'Malgun Gothic' : null,
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
