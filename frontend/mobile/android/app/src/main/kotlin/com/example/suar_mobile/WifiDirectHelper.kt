package com.example.suar_mobile

import android.content.Context
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets

private const val TAG = "WifiDirectHelper"
private const val WIFI_DIRECT_PORT = 8988

/// Wraps Android's WifiP2pManager (no mature Flutter plugin exists) and the
/// transfer ServerSocket/Socket, exposed to Dart via "suar/wifi_direct".
class WifiDirectHelper(
    private val context: Context,
    private val manager: WifiP2pManager,
    private val channel: WifiP2pManager.Channel
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private var serverSocket: ServerSocket? = null
    private var serverThread: Thread? = null

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    fun discoverPeers(result: MethodChannel.Result) {
        try {
            manager.discoverPeers(channel, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    try {
                        manager.requestPeers(channel) { peers ->
                            Log.d(TAG, "discoverPeers found ${peers.deviceList.size} peer(s)")
                            val list = peers.deviceList.map { d: WifiP2pDevice ->
                                mapOf("deviceAddress" to d.deviceAddress, "deviceName" to d.deviceName)
                            }
                            mainHandler.post { result.success(list) }
                        }
                    } catch (e: SecurityException) {
                        mainHandler.post { result.error("PERMISSION_DENIED", e.message, null) }
                    }
                }

                override fun onFailure(reason: Int) {
                    Log.e(TAG, "discoverPeers failed: reason=$reason")
                    mainHandler.post { result.error("DISCOVER_FAILED", "reason=$reason", null) }
                }
            })
        } catch (e: SecurityException) {
            mainHandler.post { result.error("PERMISSION_DENIED", e.message, null) }
        }
    }

    fun connect(deviceAddress: String, result: MethodChannel.Result) {
        val config = WifiP2pConfig().apply { this.deviceAddress = deviceAddress }
        try {
            Log.d(TAG, "connect() requested to $deviceAddress")
            manager.connect(channel, config, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    manager.requestConnectionInfo(channel) { info: WifiP2pInfo ->
                        Log.d(TAG, "connectionInfo: groupFormed=${info.groupFormed} isGroupOwner=${info.isGroupOwner} groupOwnerAddress=${info.groupOwnerAddress}")
                        if (info.groupFormed && info.groupOwnerAddress != null) {
                            mainHandler.post {
                                result.success(
                                    mapOf(
                                        "groupOwnerAddress" to info.groupOwnerAddress.hostAddress,
                                        "isGroupOwner" to info.isGroupOwner
                                    )
                                )
                            }
                        } else {
                            mainHandler.post { result.error("NO_GROUP", "Group not formed", null) }
                        }
                    }
                }

                override fun onFailure(reason: Int) {
                    Log.e(TAG, "connect() failed: reason=$reason")
                    mainHandler.post { result.error("CONNECT_FAILED", "reason=$reason", null) }
                }
            })
        } catch (e: SecurityException) {
            mainHandler.post { result.error("PERMISSION_DENIED", e.message, null) }
        }
    }

    fun disconnect(result: MethodChannel.Result) {
        try {
            manager.removeGroup(channel, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    mainHandler.post { result.success(null) }
                }

                override fun onFailure(reason: Int) {
                    mainHandler.post { result.error("DISCONNECT_FAILED", "reason=$reason", null) }
                }
            })
        } catch (e: SecurityException) {
            mainHandler.post { result.error("PERMISSION_DENIED", e.message, null) }
        }
    }

    fun startServer(result: MethodChannel.Result) {
        try {
            stopServerInternal()
            val socket = ServerSocket(WIFI_DIRECT_PORT)
            serverSocket = socket
            serverThread = Thread {
                Log.d(TAG, "ServerSocket listening on port $WIFI_DIRECT_PORT")
                while (!socket.isClosed) {
                    try {
                        val client = socket.accept()
                        Log.d(TAG, "Accepted connection from ${client.inetAddress}")
                        val reader = BufferedReader(InputStreamReader(client.getInputStream(), StandardCharsets.UTF_8))
                        val json = reader.readText()
                        client.close()
                        Log.d(TAG, "Received bundle JSON (${json.length} bytes)")
                        mainHandler.post { eventSink?.success(mapOf("event" to "bundleReceived", "json" to json)) }
                    } catch (e: Exception) {
                        if (!socket.isClosed) Log.e(TAG, "Server accept failed: $e")
                    }
                }
            }
            serverThread?.start()
            mainHandler.post { result.success(null) }
        } catch (e: Exception) {
            mainHandler.post { result.error("SERVER_START_FAILED", e.message, null) }
        }
    }

    fun stopServer(result: MethodChannel.Result) {
        stopServerInternal()
        mainHandler.post { result.success(null) }
    }

    private fun stopServerInternal() {
        try {
            serverSocket?.close()
        } catch (_: Exception) {
        }
        serverSocket = null
        serverThread = null
    }

    fun sendBundle(address: String, json: String, result: MethodChannel.Result) {
        Thread {
            try {
                Log.d(TAG, "Connecting to $address:$WIFI_DIRECT_PORT to send bundle (${json.length} bytes)")
                val socket = Socket()
                socket.connect(InetSocketAddress(address, WIFI_DIRECT_PORT), 3000)
                socket.getOutputStream().use { out ->
                    out.write(json.toByteArray(StandardCharsets.UTF_8))
                    out.flush()
                }
                socket.close()
                Log.d(TAG, "Bundle sent to $address")
                mainHandler.post { result.success(null) }
            } catch (e: Exception) {
                Log.e(TAG, "sendBundle failed: $e")
                mainHandler.post { result.error("SEND_FAILED", e.message, null) }
            }
        }.start()
    }
}
