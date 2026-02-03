package com.joopos.pos70one

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.joopos.posprint.UsbPrintConnection
import com.joopos.posprint.notification.NotificationHelper

class MainActivity : FlutterActivity() {
    private var deeplinkChannel: MethodChannel? = null
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        NotificationHelper.createChannel(this)
        sendDeepLink(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        deeplinkChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.joopos/deeplink")
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.joopos/escpos").setMethodCallHandler { call, result ->
            when (call.method) {
                "printUsbBytes" -> {
                    val bytes: ByteArray? = call.arguments as? ByteArray
                    if (bytes == null) {
                        result.error("ARG", "bytes null", null)
                        return@setMethodCallHandler
                    }
                    val usb = UsbPrintConnection(this)
                    usb.printBytes(bytes) { success, msg ->
                        if (success) result.success(true) else result.error("USB", msg, null)
                    }
                }
                "printUsbText" -> {
                    val text: String? = call.arguments as? String
                    if (text == null) {
                        result.error("ARG", "text null", null)
                        return@setMethodCallHandler
                    }
                    val usb = UsbPrintConnection(this)
                    usb.printText(text) { success, msg ->
                        if (success) result.success(true) else result.error("USB", msg, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        sendDeepLink(intent)
    }

    private fun sendDeepLink(intent: Intent?) {
        val data = intent?.data?.toString() ?: return
        if (data.startsWith("app://")) {
            deeplinkChannel?.invokeMethod("open", data)
        }
    }
}
