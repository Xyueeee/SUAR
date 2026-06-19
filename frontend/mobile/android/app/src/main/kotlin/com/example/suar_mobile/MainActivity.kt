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
                    "disconnect" -> wifiDirectHelper.disconnect(result)
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
                        startMeshService("Victim broadcasting...")
                        blePeripheralHelper.startAdvertising(deviceId)
                        result.success(null)
                    }
                    "stopAdvertising" -> {
                        blePeripheralHelper.stopAdvertising()
                        stopMeshService()
                        result.success(null)
                    }
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
}
