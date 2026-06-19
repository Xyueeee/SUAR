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
import android.os.ParcelUuid
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

private const val TAG = "BlePeripheralHelper"
// Must match constants.dart's suarServiceUuid / suarGattAckCharacteristicUuid.
private val SERVICE_UUID = UUID.fromString("0000F00D-0000-1000-8000-00805F9B34FB")
private val ACK_CHARACTERISTIC_UUID = UUID.fromString("0000FEED-0000-1000-8000-00805F9B34FB")

/// Victim-side BLE role: advertise + host a GATT server for the ACK
/// characteristic. flutter_blue_plus has no peripheral API, so this lives
/// natively and is exposed to Dart via "suar/ble_peripheral".
class BlePeripheralHelper(private val context: Context) {

    private val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private var advertiser: BluetoothLeAdvertiser? = null
    private var gattServer: BluetoothGattServer? = null
    private var eventSink: EventChannel.EventSink? = null

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            Log.d(TAG, "Advertising started")
        }

        override fun onStartFailure(errorCode: Int) {
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
            if (characteristic.uuid == ACK_CHARACTERISTIC_UUID && value.size >= 4) {
                val rssi = ByteBuffer.wrap(value).order(ByteOrder.LITTLE_ENDIAN).int
                Log.d(TAG, "ACK decoded: helperDeviceId=${device.address} rssi=$rssi")
                eventSink?.success(mapOf("helperDeviceId" to device.address, "rssi" to rssi))
            }
            if (responseNeeded) {
                try {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
                } catch (e: SecurityException) {
                    Log.e(TAG, "sendResponse denied: $e")
                }
            }
        }
    }

    fun startAdvertising(deviceId: String) {
        try {
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
            gattServer?.addService(service)

            // TODO(battery): spec wants LOW_POWER/LOW for NFR battery conservation.
            // Using LOW_LATENCY/HIGH for now to rule out slow advertising interval
            // as a factor while the BLE handshake is unverified on real hardware.
            // Dial back once the mesh handshake is confirmed reliable.
            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
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
    }
}
