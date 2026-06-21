package com.example.suar_mobile

import android.content.Intent
import android.net.wifi.p2p.WifiP2pManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

private const val WIFI_DIRECT_CHANNEL = "suar/wifi_direct"
private const val WIFI_DIRECT_EVENTS = "suar/wifi_direct_events"
private const val BLE_PERIPHERAL_CHANNEL = "suar/ble_peripheral"
private const val BLE_PERIPHERAL_EVENTS = "suar/ble_peripheral_events"

class MainActivity : FlutterActivity() {

    private lateinit var wifiDirectHelper: WifiDirectHelper
    private lateinit var blePeripheralHelper: BlePeripheralHelper

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val wifiP2pManager = getSystemService(WIFI_P2P_SERVICE) as WifiP2pManager
        val wifiP2pChannel = wifiP2pManager.initialize(this, mainLooper, null)
        wifiDirectHelper = WifiDirectHelper(this, wifiP2pManager, wifiP2pChannel)
        blePeripheralHelper = BlePeripheralHelper(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WIFI_DIRECT_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "discoverPeers" -> wifiDirectHelper.discoverPeers(result)
                    "connect" -> {
                        val address = call.argument<String>("deviceAddress")
                        if (address == null) {
                            result.error("BAD_ARGS", "deviceAddress required", null)
                        } else {
                            wifiDirectHelper.connect(address, result)
                        }
                    }
                    "sendBundle" -> {
                        val address = call.argument<String>("address")
                        val json = call.argument<String>("json")
                        if (address == null || json == null) {
                            result.error("BAD_ARGS", "address and json required", null)
                        } else {
                            wifiDirectHelper.sendBundle(address, json, result)
                        }
                    }
                    "startServer" -> {
                        startMeshService("Helper scanning...")
                        wifiDirectHelper.startServer(result)
                    }
                    "stopServer" -> {
                        wifiDirectHelper.stopServer(result)
                        stopMeshService()
                    }
                    "createGroup" -> wifiDirectHelper.createGroup(result)
                    "disconnect" -> wifiDirectHelper.disconnect(result)
                    "getStaInfo" -> wifiDirectHelper.getStaInfo(result)
                    "updateMeshStatus" -> {
                        // Refreshes the persistent foreground notification text only —
                        // startForegroundService() on an already-running service just
                        // updates its notification, no radio is touched. Lets Dart push
                        // radio-health warnings (e.g. "connected to a Wi-Fi AP") into
                        // chrome that's visible even with the app backgrounded/screen
                        // off, instead of relying on an in-app banner nobody's looking
                        // at — confirmed on real hardware that the in-app-only banner
                        // was missed during testing.
                        startMeshService(call.argument<String>("text") ?: "Mesh radio active...")
                        result.success(null)
                    }
                    "openWifiSettings" -> wifiDirectHelper.openWifiSettings(result)
                    "setLocalBundle" -> {
                        wifiDirectHelper.setLocalBundle(call.argument<String>("json"))
                        result.success(null)
                    }
                    "requestBundle" -> {
                        val address = call.argument<String>("address")
                        if (address == null) {
                            result.error("BAD_ARGS", "address required", null)
                        } else {
                            wifiDirectHelper.requestBundle(address, result)
                        }
                    }
                    "setManifest" -> {
                        @Suppress("UNCHECKED_CAST")
                        val ids = call.argument<List<String>>("ids") ?: emptyList()
                        wifiDirectHelper.setManifest(ids)
                        result.success(null)
                    }
                    "requestManifest" -> {
                        val address = call.argument<String>("address")
                        if (address == null) {
                            result.error("BAD_ARGS", "address required", null)
                        } else {
                            wifiDirectHelper.requestManifest(address, result)
                        }
                    }
                    "isServerRunning" -> wifiDirectHelper.isServerRunning(result)
                    "setRelayBundles" -> {
                        val json = call.argument<String>("json") ?: "[]"
                        wifiDirectHelper.setRelayBundles(json)
                        result.success(null)
                    }
                    "sync" -> {
                        val address = call.argument<String>("address")
                        @Suppress("UNCHECKED_CAST")
                        val ownIds = call.argument<List<String>>("ownIds") ?: emptyList()
                        val payload = call.argument<String>("payload")
                        if (address == null || payload == null) {
                            result.error("BAD_ARGS", "address and payload required", null)
                        } else {
                            wifiDirectHelper.sync(address, ownIds, payload, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, WIFI_DIRECT_EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    wifiDirectHelper.setEventSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    wifiDirectHelper.setEventSink(null)
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BLE_PERIPHERAL_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startAdvertising" -> {
                        val deviceId = call.argument<String>("deviceId") ?: ""
                        // Used by both Victim (broadcasting its own beacon) and Helper
                        // (advertising itself so other Helpers can find it for DTN
                        // relay) — kept role-agnostic rather than hardcoding "Victim".
                        startMeshService("Mesh radio active...")
                        blePeripheralHelper.startAdvertising(deviceId)
                        result.success(null)
                    }
                    "stopAdvertising" -> {
                        blePeripheralHelper.stopAdvertising()
                        stopMeshService()
                        result.success(null)
                    }
                    "setNeedsPull" -> {
                        blePeripheralHelper.setNeedsPull(call.argument<Boolean>("value") ?: false)
                        result.success(null)
                    }
                    "setRole" -> {
                        blePeripheralHelper.setRole(call.argument<Int>("value") ?: 0)
                        result.success(null)
                    }
                    "isAdvertising" -> blePeripheralHelper.isAdvertising(result)
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, BLE_PERIPHERAL_EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    blePeripheralHelper.setEventSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    blePeripheralHelper.setEventSink(null)
                }
            })
    }

    private fun startMeshService(statusText: String) {
        val intent = Intent(this, MeshForegroundService::class.java)
            .putExtra(MeshForegroundService.EXTRA_STATUS_TEXT, statusText)
        startForegroundService(intent)
    }

    private fun stopMeshService() {
        stopService(Intent(this, MeshForegroundService::class.java))
    }

    /// All the normal stop paths (stopServer/stopAdvertising/disconnect)
    /// are Dart-initiated MethodChannel calls — they never run if the
    /// Flutter engine is gone before Dart gets a chance to call them. That
    /// happens whenever the user swipes this app away from the recent-apps
    /// list: Android tears down the Activity (onDestroy fires reliably,
    /// even though the foreground service and process can keep running)
    /// well before any Dart shutdown code would. Calling the native
    /// cleanup directly here, in plain Kotlin, guarantees the GATT
    /// server/advertiser and Wi-Fi Direct server/group actually get torn
    /// down instead of being orphaned — running, broadcasting, holding the
    /// port — with no Dart code left listening to ever stop them.
    override fun onDestroy() {
        if (::blePeripheralHelper.isInitialized) blePeripheralHelper.stopAdvertising()
        if (::wifiDirectHelper.isInitialized) wifiDirectHelper.shutdown()
        stopMeshService()
        super.onDestroy()
    }
}
