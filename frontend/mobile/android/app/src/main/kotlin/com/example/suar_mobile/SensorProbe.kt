package com.example.suar_mobile

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Thin SensorManager bridge for the Device Test page (suar/sensors channel).
 *
 * sensors_plus already streams accelerometer / gyroscope / magnetometer /
 * barometer on the Dart side, so this only covers what it does NOT: the two
 * extra sensors the Device Test page lists (proximity, ambient light), plus a
 * uniform hardware-availability check so the UI can accurately show "not
 * available" for any sensor rather than guessing from a silent stream.
 *
 * Kept native (vs. two more single-purpose Flutter plugins) to avoid adding
 * dependencies — matches the app's existing BLE/Wi-Fi native-channel pattern.
 */
class SensorProbe(context: Context) {
    private val sensorManager =
        context.getSystemService(Context.SENSOR_SERVICE) as SensorManager

    private val typeMap = mapOf(
        "accelerometer" to Sensor.TYPE_ACCELEROMETER,
        "gyroscope" to Sensor.TYPE_GYROSCOPE,
        "magnetometer" to Sensor.TYPE_MAGNETIC_FIELD,
        "barometer" to Sensor.TYPE_PRESSURE,
        "proximity" to Sensor.TYPE_PROXIMITY,
        "light" to Sensor.TYPE_LIGHT,
    )

    private val wifiManager =
        context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val appContext = context.applicationContext

    private var eventSink: EventChannel.EventSink? = null
    private val streamListeners = mutableMapOf<String, SensorEventListener>()

    // Bluetooth classic-audio profile proxies, bound once at startup so the
    // connected-device count is ready instantly when the Device Test page asks.
    private val btManager =
        appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private var a2dpProxy: BluetoothProfile? = null
    private var headsetProxy: BluetoothProfile? = null

    init {
        val adapter = btManager?.adapter
        if (adapter != null) {
            val listener = object : BluetoothProfile.ServiceListener {
                override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                    when (profile) {
                        BluetoothProfile.A2DP -> a2dpProxy = proxy
                        BluetoothProfile.HEADSET -> headsetProxy = proxy
                    }
                }

                override fun onServiceDisconnected(profile: Int) {
                    when (profile) {
                        BluetoothProfile.A2DP -> a2dpProxy = null
                        BluetoothProfile.HEADSET -> headsetProxy = null
                    }
                }
            }
            adapter.getProfileProxy(appContext, listener, BluetoothProfile.A2DP)
            adapter.getProfileProxy(appContext, listener, BluetoothProfile.HEADSET)
        }
    }

    /** sensorKey -> whether the hardware exists on this device. */
    fun availability(): Map<String, Boolean> =
        typeMap.mapValues { (_, type) -> sensorManager.getDefaultSensor(type) != null }

    /** Whether the Wi-Fi radio is on — Wi-Fi Direct needs it for the mesh. */
    fun isWifiEnabled(): Boolean = wifiManager.isWifiEnabled

    /**
     * Hardware characteristics of [key], or an empty map if absent. maxRange +
     * resolution let the caller tell a real distance-ranging proximity sensor
     * from a cheap binary (near/far-only) one, which reports its whole range as
     * a single resolution step.
     */
    fun sensorInfo(key: String): Map<String, Any?> {
        val sensor = typeMap[key]?.let { sensorManager.getDefaultSensor(it) }
            ?: return emptyMap()
        return mapOf(
            "maxRange" to sensor.maximumRange.toDouble(),
            "resolution" to sensor.resolution.toDouble(),
            "name" to sensor.name,
            "vendor" to sensor.vendor,
        )
    }

    /**
     * One-shot latest value for [key]: registers a listener, returns the first
     * event's primary reading (`values[0]` — distance in cm for proximity, lux
     * for light), then unregisters. Returns null (not an error) if the sensor
     * is absent or produces nothing within [timeoutMs], so the caller can treat
     * "no reading" and "no hardware" the same way on the diagnostic UI.
     */
    fun readSensor(key: String, timeoutMs: Long, result: MethodChannel.Result) {
        val sensor = typeMap[key]?.let { sensorManager.getDefaultSensor(it) }
        if (sensor == null) {
            result.success(null)
            return
        }
        // Both the sensor callback and the timeout post to the main looper, so
        // the `done` guard needs no locking — they can't run concurrently.
        val handler = Handler(Looper.getMainLooper())
        var done = false
        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                if (done) return
                done = true
                sensorManager.unregisterListener(this)
                result.success(event.values[0].toDouble())
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
        }
        sensorManager.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_UI)
        handler.postDelayed({
            if (!done) {
                done = true
                sensorManager.unregisterListener(listener)
                result.success(null)
            }
        }, timeoutMs)
    }

    // --- Continuous streaming (suar/sensors_events) --------------------------
    // A persistent listener reflects cover/uncover reliably, unlike repeated
    // one-shot reads which can return a stale cached value on some chipsets
    // (e.g. Samsung proximity reading "far" while covered).

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
        if (sink == null) {
            for (l in streamListeners.values) sensorManager.unregisterListener(l)
            streamListeners.clear()
        }
    }

    fun startSensorStream(key: String) {
        if (streamListeners.containsKey(key)) return
        val sensor = typeMap[key]?.let { sensorManager.getDefaultSensor(it) } ?: return
        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                eventSink?.success(
                    mapOf("key" to key, "value" to event.values[0].toDouble())
                )
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
        }
        streamListeners[key] = listener
        sensorManager.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_NORMAL)
    }

    fun stopSensorStream(key: String) {
        streamListeners.remove(key)?.let { sensorManager.unregisterListener(it) }
    }

    // --- Bluetooth connected device count -----------------------------------
    // FlutterBluePlus only sees devices THIS app connected over BLE. To count
    // what the OS has connected (buds, watch — often classic audio profiles),
    // query the system across GATT + A2DP + HEADSET. The audio profiles bind
    // asynchronously, so the proxies are opened ONCE at startup (below) and
    // reused — the first query used to return 0 because the proxy hadn't bound
    // yet within a one-shot timeout. Returns a deduped count (by address).

    fun bluetoothConnectedDevices(result: MethodChannel.Result) {
        val adapter = btManager?.adapter
        if (adapter == null || !adapter.isEnabled) {
            result.success(0)
            return
        }
        val addresses = linkedSetOf<String>()
        fun collect(devices: List<BluetoothDevice>?) {
            if (devices == null) return
            try {
                for (d in devices) addresses.add(d.address)
            } catch (e: SecurityException) {
            }
        }
        try {
            collect(btManager.getConnectedDevices(BluetoothProfile.GATT))
        } catch (e: SecurityException) {
            // BLUETOOTH_CONNECT not granted yet — count what we can.
        }
        collect(a2dpProxy?.connectedDevices)
        collect(headsetProxy?.connectedDevices)
        result.success(addresses.size)
    }
}
