package com.bteuile.moneymanager.money_manager

import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// Handles a single platform-channel call ("installApk") for
/// AndroidApkInstaller (lib/services/android_apk_installer.dart), itself
/// only reached from update_prompt_io.dart's Android update-check branch.
/// Native code is unavoidable for just this one step - constructing a
/// content:// URI via FileProvider.getUriForFile() is a Java/Kotlin-only
/// API, nothing else here needs it (downloading the APK and deciding
/// whether an update exists both stay in Dart).
class MainActivity : FlutterActivity() {
    private val channelName = "com.bteuile.moneymanager.money_manager/apk_installer"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method != "installApk") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("NO_PATH", "Missing 'path' argument", null)
                    return@setMethodCallHandler
                }
                try {
                    val apkUri = FileProvider.getUriForFile(
                        this, "$packageName.fileprovider", File(path)
                    )
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(apkUri, "application/vnd.android.package-archive")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(intent)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("INSTALL_FAILED", e.message, null)
                }
            }
    }
}
