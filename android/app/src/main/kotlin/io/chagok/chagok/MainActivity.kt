package io.chagok.chagok

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.chagok.chagok/install")
            .setMethodCallHandler { call, result ->
                if (call.method != "installApk") {
                    result.notImplemented()
                } else {
                    try {
                        val path = call.argument<String>("path") ?: error("Missing APK path")
                        val apk = File(path).canonicalFile
                        val updates = File(filesDir, "updates").canonicalFile
                        require(apk.parentFile == updates && apk.extension == "apk" && apk.isFile)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                            result.success("permission_required")
                        } else {
                            val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
                            startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                            result.success("opened")
                        }
                    } catch (e: Exception) {
                        result.error("INSTALL_FAILED", "설치 화면을 열지 못했습니다. 앱 설치 권한을 확인해 주세요.", null)
                    }
                }
            }
    }
}
