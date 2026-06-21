package com.example.suar_mobile

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets
import java.util.UUID

private const val TAG = "BlePeripheralHelper"
// Must match constants.dart's suarServiceUuid / suarGattAckCharacteristicUuid.
private val SERVICE_UUID = UUID.fromString("0000F00D-0000-1000-8000-00805F9B34FB")
private val ACK_CHARACTERISTIC_UUID = UUID.fromString("0000FEED-0000-1000-8000-00805F9B34FB")
// Read-only: 2 bytes — [0] non-zero means "this device's chipset can't
// initiate Wi-Fi Direct discovery — connect to it instead", [1] is this
// device's current Dart-side role (0=victim, 1=helper), letting a scanner
// branch between the RSSI-ack handshake and the DTN relay handshake using the
// same brief connection. Lives on the same GATT service/connection as the ack
// write, so it costs nothing extra in the 31-byte advertisement payload
// (which is already at its hard cap, see below).
private val STATUS_CHARACTERISTIC_UUID = UUID.fromString("0000BEEF-0000-1000-8000-00805F9B34FB")

/// Victim-side BLE role: advertise + host a GATT server for the ACK
/// characteristic. flutter_blue_plus has no peripheral API, so this lives
/// natively and is exposed to Dart via "suar/ble_peripheral".
class BlePeripheralHelper(private val context: Context) {

    private val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private var advertiser: BluetoothLeAdvertiser? = null
    private var gattServer: BluetoothGattServer? = null
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var needsPull: Boolean = false
    @Volatile private var role: Int = 0
    // This device's own app deviceId (the UUID string), served on the status
    // characteristic read so a peer Helper can run a deterministic Wi-Fi Direct
    // group-owner election against it (see onCharacteristicReadRequest). It does
    // NOT fit in the 31-byte advertisement (see startAdvertising's comment), so
    // GATT — the reliable connection-oriented channel already opened for the ack
    // — is where it travels.
    @Volatile private var deviceId: String = ""
    // No persistent "is advertising" getter exists on Android's BLE API —
    // AdvertiseCallback is fire-and-forget, so this is tracked explicitly to
    // let a Dart-side watchdog notice if advertising silently died (some
    // OEMs are known to kill BLE background activity without any callback)
    // and restart it instead of looking active while actually invisible.
    @Volatile private var advertising: Boolean = false

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    fun setNeedsPull(value: Boolean) {
        needsPull = value
    }

    fun setRole(value: Int) {
        role = value
    }

    fun isAdvertising(result: MethodChannel.Result) {
        result.success(advertising)
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            advertising = true
            Log.d(TAG, "Advertising started")
        }

        override fun onStartFailure(errorCode: Int) {
            advertising = false
            Log.e(TAG, "Advertising failed: $errorCode")
        }
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            Log.d(TAG, "GATT connection state change: device=${device.address} status=$status newState=$newState")
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            Log.d(TAG, "Write request from ${device.address}: uuid=${characteristic.uuid} size=${value.size}")
            // This callback runs on a Binder thread, not the main thread.
            // sendResponse() is a plain BLE-stack/Binder call and is safe to
            // make from here — send it FIRST and immediately, since the
            // central is blocked waiting on it. eventSink.success() is a
            // Flutter platform-channel call which REQUIRES the main thread;
            // calling it directly from here used to throw
            // ("Methods marked with @UiThread must be executed on the main
            // thread"), and Android's BluetoothGattServer swallows
            // exceptions from this callback as a bare warning log — so the
            // throw silently skipped sendResponse() below it on every single
            // write, which is the entire reason the central's write() always
            // timed out after 15s regardless of any GATT-cache/timing fix.
            if (responseNeeded) {
                try {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
                } catch (e: Exception) {
                    // Catching only SecurityException here used to let any
                    // OTHER exception (NPE on a torn-down gattServer, etc.)
                    // propagate out of this Binder callback uncaught — which
                    // Android's BluetoothGattServer swallows as a bare
                    // warning log (see comment above), silently skipping
                    // sendResponse() with no trace and leaving the central
                    // blocked on a write() that times out 15s later for an
                    // unrelated-looking reason.
                    Log.e(TAG, "sendResponse failed: $e")
                }
            }
            if (characteristic.uuid == ACK_CHARACTERISTIC_UUID && value.size >= 4) {
                val rssi = ByteBuffer.wrap(value).order(ByteOrder.LITTLE_ENDIAN).int
                Log.d(TAG, "ACK decoded: helperDeviceId=${device.address} rssi=$rssi")
                mainHandler.post {
                    eventSink?.success(mapOf("helperDeviceId" to device.address, "rssi" to rssi))
                }
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            if (characteristic.uuid == STATUS_CHARACTERISTIC_UUID) {
                try {
                    // [0]=needsPull, [1]=role, [2..]=this device's app deviceId
                    // (UTF-8). The deviceId lets a peer Helper run a
                    // deterministic group-owner election (lower id = GO) so
                    // exactly ONE side calls connect() over Wi-Fi Direct —
                    // eliminating the simultaneous-connect "glare" that made
                    // Helper-Helper relay fail NO_GROUP/BUSY on real hardware.
                    // Sliced by offset so the value survives the default 23-byte
                    // ATT MTU: a UUID string alone is 36 bytes, so the Android
                    // stack issues READ_BLOB requests for the remainder and the
                    // central reassembles the full value — no MTU renegotiation
                    // needed on the (proven-reliable) ack connection.
                    val header = byteArrayOf(if (needsPull) 1 else 0, role.toByte())
                    val full = header + deviceId.toByteArray(StandardCharsets.UTF_8)
                    val slice = if (offset >= full.size) {
                        ByteArray(0)
                    } else {
                        full.copyOfRange(offset, full.size)
                    }
                    gattServer?.sendResponse(
                        device, requestId, BluetoothGatt.GATT_SUCCESS, offset, slice
                    )
                } catch (e: Exception) {
                    Log.e(TAG, "sendResponse (status read) failed: $e")
                }
            }
        }
    }

    fun startAdvertising(deviceId: String) {
        try {
            // Cache it for the status-characteristic read (the GO-election id) —
            // see the deviceId field's doc and onCharacteristicReadRequest.
            this.deviceId = deviceId
            // Without this, calling startAdvertising() twice without an
            // intervening stop (the Dart side now guards against this, but a
            // hot-restart or a caller bug could still trigger it) leaked the
            // previous GATT server/advertiser — mirrors the same defensive
            // cleanup WifiDirectHelper.startServer() already does.
            stopAdvertising()

            val adapter: BluetoothAdapter = bluetoothManager.adapter
            advertiser = adapter.bluetoothLeAdvertiser

            gattServer = bluetoothManager.openGattServer(context, gattServerCallback)
            val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            val ackCharacteristic = BluetoothGattCharacteristic(
                ACK_CHARACTERISTIC_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE,
                BluetoothGattCharacteristic.PERMISSION_WRITE
            )
            service.addCharacteristic(ackCharacteristic)
            val statusCharacteristic = BluetoothGattCharacteristic(
                STATUS_CHARACTERISTIC_UUID,
                BluetoothGattCharacteristic.PROPERTY_READ,
                BluetoothGattCharacteristic.PERMISSION_READ
            )
            service.addCharacteristic(statusCharacteristic)
            gattServer?.addService(service)

            // Dialed back from LOW_LATENCY/HIGH now that the mesh handshake is
            // confirmed reliable on real hardware (this was deliberately left
            // maxed-out earlier specifically to rule out slow advertising
            // interval as a factor while the handshake itself was unverified —
            // see git history). BALANCED (~250ms interval) is still well
            // inside the ≤5s discovery NFR even allowing for several missed
            // intervals, and MEDIUM tx power still has solid real-world range
            // — full LOW_LATENCY/HIGH cost meaningfully more battery for no
            // measurable benefit at this interval/range scale.
            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                .setConnectable(true)
                .build()

            // Legacy advertising caps out at 31 bytes total. Flags (3) + a 128-bit
            // service UUID (18) already leaves ~6 bytes spare — nowhere near enough
            // to also fit a UUID-string deviceId in manufacturer data (was causing
            // ADVERTISE_FAILED_DATA_TOO_LARGE, silently, since AdvertiseCallback
            // failures never reach Dart). The Helper identifies the Victim by BLE
            // remoteId instead; the real deviceId travels inside the bundle JSON.
            val data = AdvertiseData.Builder()
                .addServiceUuid(ParcelUuid(SERVICE_UUID))
                .setIncludeDeviceName(false)
                .build()

            advertiser?.startAdvertising(settings, data, advertiseCallback)
        } catch (e: SecurityException) {
            Log.e(TAG, "startAdvertising denied: $e")
        }
    }

    fun stopAdvertising() {
        try {
            advertiser?.stopAdvertising(advertiseCallback)
            gattServer?.close()
        } catch (e: SecurityException) {
            Log.e(TAG, "stopAdvertising denied: $e")
        }
        gattServer = null
        advertiser = null
        advertising = false
    }
}
