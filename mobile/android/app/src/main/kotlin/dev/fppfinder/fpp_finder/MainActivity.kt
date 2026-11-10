package dev.fppfinder.fpp_finder

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var lock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.fppfinder/multicast")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        try {
                            if (lock == null) {
                                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                                lock = wm.createMulticastLock("fpp-finder-mdns").apply { setReferenceCounted(false) }
                            }
                            lock?.acquire()
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "release" -> {
                        try { if (lock?.isHeld == true) lock?.release() } catch (e: Exception) { }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        try { if (lock?.isHeld == true) lock?.release() } catch (e: Exception) { }
        super.onDestroy()
    }
}
