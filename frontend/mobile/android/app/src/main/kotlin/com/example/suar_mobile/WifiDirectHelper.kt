package com.example.suar_mobile

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.location.LocationManager
import android.net.wifi.WifiManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import org.json.JSONArray
import org.json.JSONObject

private const val TAG = "WifiDirectHelper"
private const val WIFI_DIRECT_PORT = 8988
private const val MAX_SYNC_IDS = 1000

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

    // Last known P2P hardware-enabled state, from the OS broadcast — null
    // until the first broadcast arrives (shortly after registration).
    private var p2pEnabled: Boolean? = null

    // Held only so shutdown() can unregister it — this object is a
    // singleton for MainActivity's lifetime, but if that Activity is ever
    // recreated outside the configChanges the manifest already declares
    // (orientation/screenSize/etc. are covered — see AndroidManifest.xml),
    // a fresh WifiDirectHelper would register a second receiver while this
    // one was never released.
    private var p2pStateReceiver: BroadcastReceiver? = null

    init {
        // The official Android Wi-Fi Direct guide always pairs discoverPeers()
        // with a registered receiver for these two actions; this codebase never
        // had one. WIFI_P2P_STATE_CHANGED_ACTION is the only way to learn
        // whether the OS/chipset has P2P enabled at all (no synchronous query
        // exists) — if it's disabled, discoverPeers() will silently return
        // nothing forever, which is indistinguishable from "no peers nearby"
        // without this.
        val filter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
        }
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                when (intent.action) {
                    WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                        val state = intent.getIntExtra(WifiP2pManager.EXTRA_WIFI_STATE, -1)
                        p2pEnabled = state == WifiP2pManager.WIFI_P2P_STATE_ENABLED
                        emitDebug("Wi-Fi Direct P2P state changed: enabled=$p2pEnabled")
                    }
                    WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                        emitDebug("Wi-Fi Direct peers-changed broadcast received")
                    }
                    WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                        // Fires on BOTH ends of a P2P connection regardless of
                        // who called connect() — the only reliable way for the
                        // side that DIDN'T initiate to learn the group formed
                        // and find out its own GO/client role. groupOwnerIntent
                        // biases negotiation but doesn't guarantee an outcome
                        // (confirmed on real hardware: the connecting side can
                        // still end up as GO), so neither side can assume its
                        // role from who called connect() — both must query.
                        manager.requestConnectionInfo(channel) { info: WifiP2pInfo ->
                            if (info.groupFormed) {
                                emitDebug(
                                    "Wi-Fi Direct connection formed: isGroupOwner=${info.isGroupOwner} " +
                                        "groupOwnerAddress=${info.groupOwnerAddress}"
                                )
                                mainHandler.post {
                                    eventSink?.success(
                                        mapOf(
                                            "event" to "connectionFormed",
                                            "isGroupOwner" to info.isGroupOwner,
                                            "groupOwnerAddress" to info.groupOwnerAddress?.hostAddress
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
        p2pStateReceiver = receiver
    }

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    /// Surfaces a line straight into the on-screen activity log (via the
    /// existing "bundleReceived"-style EventChannel) so diagnosing a future
    /// failure doesn't require pulling logcat off the device again.
    private fun emitDebug(message: String) {
        Log.d(TAG, message)
        mainHandler.post { eventSink?.success(mapOf("event" to "debugLog", "message" to message)) }
    }

    /// Wi-Fi Direct (P2P) shares the same radio/driver as regular Wi-Fi
    /// (station) on most chipsets. Cheaper chipsets can't run STA + P2P
    /// concurrently — if the device is associated with a regular AP,
    /// discoverPeers() silently returns nothing, no error, ever. Logging the
    /// connection state up front turns "0 peers, no idea why" into a clear
    /// yes/no on this specific theory.
    private fun logWifiState() {
        try {
            val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val info = wifiManager.connectionInfo
            val ssid = info?.ssid ?: "none"
            val networkId = info?.networkId ?: -1
            emitDebug(
                "WiFi state: staEnabled=${wifiManager.isWifiEnabled} " +
                    "associatedSsid=$ssid networkId=$networkId " +
                    "(networkId=-1 means not associated to any AP)"
            )
        } catch (e: Exception) {
            Log.e(TAG, "logWifiState failed: $e")
        }
    }

    /// Confirmed via real-device testing (CLAUDE.md test devices): Wi-Fi
    /// Direct shares the same radio/driver as regular Wi-Fi (station mode).
    /// While associated to a real access point, peer discovery and/or group
    /// formation become unreliable or outright fail — flaky on a flagship
    /// chipset, never works at all on a budget one. Exposed to Dart so the
    /// app can warn the user proactively instead of failing silently.
    fun getStaInfo(result: MethodChannel.Result) {
        try {
            val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val info = wifiManager.connectionInfo
            val networkId = info?.networkId ?: -1
            mainHandler.post {
                result.success(
                    mapOf(
                        "enabled" to wifiManager.isWifiEnabled,
                        "associated" to (networkId != -1),
                        "ssid" to (info?.ssid ?: ""),
                        // null until the first WIFI_P2P_STATE_CHANGED_ACTION
                        // broadcast arrives (shortly after registration) —
                        // there's no synchronous query for this on Android.
                        "p2pEnabled" to p2pEnabled
                    )
                )
            }
        } catch (e: Exception) {
            mainHandler.post { result.error("WIFI_INFO_FAILED", e.message, null) }
        }
    }

    /// Sets the Wi-Fi Direct device name this phone broadcasts — the name the
    /// OTHER phone sees in its system "Allow Wi-Fi Direct connection?" prompt.
    /// By default Android shows the raw hardware name (e.g. "Galaxy S24+"),
    /// which both leaks the model/owner and means nothing to the person being
    /// asked to accept. Setting it to a neutral, role-tagged label like
    /// "Helper-1A2B" / "SOS-1A2B" makes the prompt understandable (the user can
    /// see it's a legitimate SUAR peer) AND anonymous (no real device name).
    ///
    /// setDeviceName is a hidden WifiP2pManager API with no public replacement,
    /// so it's called by reflection. On newer Android the hidden-API policy can
    /// block it — that's fine: this is purely cosmetic, so on failure the
    /// prompt just falls back to the default name. Never fails mode start.
    fun setDeviceName(name: String, result: MethodChannel.Result) {
        try {
            val method = manager.javaClass.getMethod(
                "setDeviceName",
                WifiP2pManager.Channel::class.java,
                String::class.java,
                WifiP2pManager.ActionListener::class.java
            )
            method.invoke(
                manager,
                channel,
                name,
                object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        Log.d(TAG, "setDeviceName('$name'): success")
                        mainHandler.post { result.success(true) }
                    }

                    override fun onFailure(reason: Int) {
                        Log.d(TAG, "setDeviceName('$name') failed: reason=$reason")
                        mainHandler.post { result.success(false) }
                    }
                }
            )
        } catch (e: Exception) {
            Log.d(TAG, "setDeviceName('$name') unavailable on this device: $e")
            mainHandler.post { result.success(false) }
        }
    }

    fun openWifiSettings(result: MethodChannel.Result) {
        try {
            context.startActivity(
                Intent(Settings.ACTION_WIFI_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            mainHandler.post { result.success(null) }
        } catch (e: Exception) {
            mainHandler.post { result.error("OPEN_SETTINGS_FAILED", e.message, null) }
        }
    }

    private fun isLocationEnabled(): Boolean {
        val locationManager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            locationManager.isLocationEnabled
        } else {
            locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        }
    }

    fun discoverPeers(result: MethodChannel.Result) {
        logWifiState()
        emitDebug("Wi-Fi Direct P2P enabled (last known): ${p2pEnabled ?: "unknown — no state broadcast received yet"}")
        if (p2pEnabled == false) {
            Log.e(TAG, "discoverPeers: Wi-Fi Direct P2P is disabled on this device/chipset")
            mainHandler.post {
                result.error("P2P_DISABLED", "Wi-Fi Direct (P2P) is disabled on this device", null)
            }
            return
        }
        // Android's WifiP2pManager peer discovery requires Location Services
        // (the system toggle, not just the runtime permission) to be on — this
        // is separate from BLE, which we exempted via neverForLocation in the
        // manifest. Without it, discoverPeers()/requestPeers() silently return
        // an empty list forever; failing fast here instead of retrying for
        // 7.5s gives an actionable error instead of a dead end.
        if (!isLocationEnabled()) {
            Log.e(TAG, "discoverPeers: Location Services are off — Wi-Fi Direct discovery cannot work")
            mainHandler.post {
                result.error(
                    "LOCATION_DISABLED",
                    "Location Services must be ON for Wi-Fi Direct peer discovery",
                    null
                )
            }
            return
        }
        try {
            manager.discoverPeers(channel, object : WifiP2pManager.ActionListener {
                // onSuccess() only means the scan request was accepted, not that
                // the peer list is populated yet — the OS finds peers
                // asynchronously over the following seconds. Calling
                // requestPeers() once right here was racing that and almost
                // always read a still-empty cache; poll like connect() does.
                override fun onSuccess() {
                    pollPeers(result, attempt = 1)
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

    private fun pollPeers(result: MethodChannel.Result, attempt: Int) {
        try {
            manager.requestPeers(channel) { peers ->
                Log.d(TAG, "discoverPeers found ${peers.deviceList.size} peer(s) (attempt $attempt)")
                // Successful real-device runs consistently resolved by
                // attempt 3-4 (~4.5-6s) — this ceiling only ever gets fully
                // spent on the genuinely-empty case, where it's pure wasted
                // latency feeding into the capability-learning retry loop.
                // 8 attempts (12s) still comfortably covers the slower
                // chipset's documented ~12s discovery cycle without paying
                // the full 18s every single time discovery fails.
                if (peers.deviceList.isNotEmpty() || attempt >= 8) {
                    val list = peers.deviceList.map { d: WifiP2pDevice ->
                        mapOf("deviceAddress" to d.deviceAddress, "deviceName" to d.deviceName)
                    }
                    mainHandler.post { result.success(list) }
                } else {
                    mainHandler.postDelayed({ pollPeers(result, attempt + 1) }, 1500)
                }
            }
        } catch (e: SecurityException) {
            mainHandler.post { result.error("PERMISSION_DENIED", e.message, null) }
        }
    }

    fun connect(deviceAddress: String, result: MethodChannel.Result) {
        // A low intent only *biases* negotiation away from this side becoming
        // group owner — it's not a guarantee (confirmed on real hardware: the
        // connecting side can still end up GO). Both ends must independently
        // discover their actual role via WIFI_P2P_CONNECTION_CHANGED_ACTION +
        // requestConnectionInfo() (see the receiver in init{}) rather than
        // assuming a role from who called connect().
        val config = WifiP2pConfig().apply {
            this.deviceAddress = deviceAddress
            this.groupOwnerIntent = 0
        }
        try {
            // NOTE: do NOT call stopPeerDiscovery() before connect() on this
            // hardware. It was tried (to give the WPS negotiation a settled
            // state) and confirmed to make things strictly worse: stopping
            // discovery CLEARS the peer cache on this chipset (a burst of
            // peers-changed broadcasts fires immediately), so connect() then
            // ran against a peer the framework no longer knew and failed
            // instantly with reason=0 (ERROR) on every single attempt —
            // turning the old slow NO_GROUP into an immediate hard reject.
            // connect() already stops discovery implicitly; leave it to do so.
            Log.d(TAG, "connect() requested to $deviceAddress")
            manager.connect(channel, config, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    // onSuccess() here only means Android accepted the connect
                    // *request* — the actual group negotiation (WPS exchange
                    // etc.) can still take a moment to finish. Querying
                    // connection info immediately was racing that and reporting
                    // "no group" on attempts that would have succeeded a beat
                    // later; poll a few times before actually giving up.
                    pollConnectionInfo(result, attempt = 1)
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

    /// Becomes an autonomous Wi-Fi Direct Group Owner (a soft-AP at the fixed
    /// GO address 192.168.49.1). This is the documented Android pattern for
    /// "one device hosts, others join", and it fixes the single biggest
    /// real-hardware failure found this whole testing arc: a device that only
    /// opened a TCP ServerSocket and waited was INVISIBLE to a peer's
    /// discoverPeers() — in Wi-Fi P2P a device is only discoverable while it
    /// is itself actively discovering OR is a group owner, so a purely passive
    /// "pull-mode" Victim could never be found (Helper's discoverPeers
    /// returned 0 peers forever). An autonomous GO is reliably discoverable
    /// AND gives a deterministic role split: whoever joins is ALWAYS the
    /// client (no groupOwnerIntent lottery, no simultaneous-connect glare),
    /// and the client→GO socket is the only direction confirmed to work on
    /// this hardware. The existing accept-loop ServerSocket already binds all
    /// interfaces on port 8988, so it serves the GO subnet with no change.
    fun createGroup(result: MethodChannel.Result) {
        try {
            // If a group already exists (e.g. this is a re-entry, or a stale
            // group from a previous attempt), reuse it instead of failing —
            // createGroup() on an existing group returns BUSY otherwise.
            manager.requestGroupInfo(channel) { group ->
                if (group != null && group.isGroupOwner) {
                    Log.d(TAG, "createGroup: group already exists, reusing")
                    mainHandler.post { result.success(null) }
                } else if (group != null) {
                    // A group exists but THIS device is a CLIENT in it, not the
                    // owner — WifiP2pGroup is returned to every member, GO or
                    // not, so the old `group != null` check here would wrongly
                    // report "I'm the GO, reuse it" while actually being a
                    // client of someone else's group (e.g. the deterministic
                    // relay election picked this device as the intended GO, but
                    // a flaky/one-sided P2P negotiation pulled it into the
                    // peer's group as a client instead — confirmed possible on
                    // real hardware via the groupOwnerIntent caveats elsewhere
                    // in this file). Reporting false success here would leave
                    // BOTH sides passively waiting for the other to act —
                    // a "double-passive" deadlock distinct from the glare this
                    // function already fixed. Leave the wrong-role group first,
                    // then fall through to a fresh createGroup() as the actual
                    // owner.
                    Log.d(TAG, "createGroup: existing group is NOT owned by this device — leaving before recreating")
                    manager.removeGroup(channel, object : WifiP2pManager.ActionListener {
                        override fun onSuccess() = createGroup(result)
                        override fun onFailure(reason: Int) = createGroup(result)
                    })
                } else {
                    manager.createGroup(channel, object : WifiP2pManager.ActionListener {
                        override fun onSuccess() {
                            Log.d(TAG, "createGroup: success (now autonomous group owner)")
                            mainHandler.post { result.success(null) }
                        }

                        override fun onFailure(reason: Int) {
                            // BUSY (reason=2) typically means a group is already
                            // mid-creation — not a real failure for our intent
                            // ("be a discoverable GO"), so don't fail the whole
                            // Victim session over it.
                            if (reason == WifiP2pManager.BUSY) {
                                Log.d(TAG, "createGroup: BUSY, assuming group already forming")
                                mainHandler.post { result.success(null) }
                            } else {
                                Log.e(TAG, "createGroup failed: reason=$reason")
                                mainHandler.post {
                                    result.error("CREATE_GROUP_FAILED", "reason=$reason", null)
                                }
                            }
                        }
                    })
                }
            }
        } catch (e: SecurityException) {
            mainHandler.post { result.error("PERMISSION_DENIED", e.message, null) }
        }
    }

    // Stock Android requires the user to manually accept a system "Allow
    // Wi-Fi Direct connection?" prompt for a new (not-yet-trusted) P2P pairing
    // — confirmed against Android's own connect() documentation, and not
    // something a normal app can suppress or auto-accept via public API. The
    // old 4 attempts * 800ms (~3.2s) ceiling here was tuned only against
    // already-trusted/fast group formation and gave a human no realistic
    // chance to notice and tap that prompt on either phone before this gave
    // up as NO_GROUP — which is exactly the failure mode confirmed on real
    // hardware (every single attempt failed once this prompt started
    // appearing). 14 attempts * 1000ms (~14s) is still well inside the
    // overall handshake's existing tolerances and gives that prompt a real
    // chance to be noticed and accepted.
    private fun pollConnectionInfo(result: MethodChannel.Result, attempt: Int) {
        manager.requestConnectionInfo(channel) { info: WifiP2pInfo ->
            Log.d(TAG, "connectionInfo (attempt $attempt): groupFormed=${info.groupFormed} isGroupOwner=${info.isGroupOwner} groupOwnerAddress=${info.groupOwnerAddress}")
            if (info.groupFormed && info.groupOwnerAddress != null) {
                mainHandler.post {
                    result.success(
                        mapOf(
                            "groupOwnerAddress" to info.groupOwnerAddress.hostAddress,
                            "isGroupOwner" to info.isGroupOwner
                        )
                    )
                }
            } else if (attempt < 14) {
                mainHandler.postDelayed({ pollConnectionInfo(result, attempt + 1) }, 1000)
            } else {
                mainHandler.post { result.error("NO_GROUP", "Group not formed", null) }
            }
        }
    }

    fun disconnect(result: MethodChannel.Result) {
        try {
            disconnectInternal { mainHandler.post { result.success(null) } }
        } catch (e: SecurityException) {
            mainHandler.post { result.error("PERMISSION_DENIED", e.message, null) }
        }
    }

    /// Shared by disconnect() (reports back to Dart via Result) and
    /// shutdown() (fire-and-forget, called when there's no Dart caller left
    /// to report to — see shutdown()'s docs).
    ///
    /// stopPeerDiscovery()/cancelConnect()/removeGroup() are chained
    /// strictly one after another, each waiting for the previous one's
    /// callback, rather than fired concurrently. Confirmed on real
    /// hardware this was NOT optional: firing all three at once (the first
    /// version of this fix) made the WifiP2pManager framework start
    /// returning BUSY (reason=2) on the very next discoverPeers()/
    /// connect() call — undocumented Android API reference pages
    /// generally describe BUSY as exactly this: the framework is still
    /// processing a previous request and can't service an overlapping
    /// one. The P2P framework is effectively single-threaded internally;
    /// this respects that instead of fighting it.
    private fun disconnectInternal(onDone: () -> Unit) {
        // Per Android's own WifiP2pManager docs: an active discovery
        // request stays running only until the device starts
        // connecting/forms a group — connect() implicitly stops it.
        // Nothing here ever explicitly restarted it afterward, which
        // matches a real-hardware symptom seen this session: the FIRST
        // contact with a peer connects and transfers fine, but every
        // discoverPeers() call after that disconnect()/removeGroup()
        // finds 0 peers for the rest of the session, even though the
        // peer is still right there (confirmed via its BLE beacon
        // continuing to be detected/ACKed the whole time — only the
        // P2P-layer discovery state was stuck). stopPeerDiscovery()
        // explicitly resets that internal state before the next
        // discoverPeers() call gets a fair chance.
        manager.stopPeerDiscovery(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() = cancelThenRemoveGroup(onDone)
            override fun onFailure(reason: Int) = cancelThenRemoveGroup(onDone)
        })
    }

    private fun cancelThenRemoveGroup(onDone: () -> Unit) {
        // cancelConnect() stops an in-flight negotiation that hasn't
        // formed a group yet (e.g. the user switched modes/screens
        // mid-attempt) — without it, that negotiation keeps running
        // detached with nothing left listening to its result, and can
        // leave the P2P stack busy for the next discoverPeers()/connect()
        // call. removeGroup() only tears down an already-formed group,
        // it doesn't touch a pending one, so both are needed.
        manager.cancelConnect(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() = removeGroupThen(onDone)
            override fun onFailure(reason: Int) = removeGroupThen(onDone)
        })
    }

    private fun removeGroupThen(onDone: () -> Unit, attempt: Int = 1) {
        // removeGroup() only tears down an *already-formed* group, so check
        // first: if this device owns no group there's nothing to remove and
        // we're already in the clean state disconnect() wants. This is the
        // common case after a connect() that failed NO_GROUP, and returning
        // here both avoids a pointless BUSY-retry loop on a group that doesn't
        // exist and kills the misleading "removeGroup failed" log that used to
        // fire on every such cleanup.
        try {
            manager.requestGroupInfo(channel) { group ->
                if (group == null) {
                    onDone()
                    return@requestGroupInfo
                }
                manager.removeGroup(channel, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        Log.d(TAG, "removeGroup: success (group torn down)")
                        onDone()
                    }

                    // reason=2 is BUSY — "the framework is busy and unable to
                    // service the request" per Android's WifiP2pManager docs,
                    // NOT "no group existed" (requestGroupInfo above already
                    // confirmed a group IS present). The group is still there,
                    // so a device that gives up here stays a stale group owner.
                    // On real hardware that wedged Helper-Helper relay: the
                    // elected *client* still owned its prior (Victim-era)
                    // autonomous group, so its connect() was a no-op (it stayed
                    // GO) and two group owners can never join each other ->
                    // permanent deadlock. Retry a bounded number of times so the
                    // group is actually gone before the caller proceeds.
                    override fun onFailure(reason: Int) {
                        if (reason == WifiP2pManager.BUSY && attempt < 5) {
                            Log.d(TAG, "removeGroup BUSY (attempt $attempt) — retrying")
                            mainHandler.postDelayed(
                                { removeGroupThen(onDone, attempt + 1) }, 500
                            )
                        } else {
                            Log.d(TAG, "removeGroup gave up after $attempt attempt(s): reason=$reason")
                            onDone()
                        }
                    }
                })
            }
        } catch (e: SecurityException) {
            // Same permission class (NEARBY_WIFI_DEVICES/location) the
            // stopPeerDiscovery/cancelConnect that just ran needed — if it's
            // somehow gone now there's nothing to clean up anyway, so don't
            // strand the disconnect chain.
            Log.e(TAG, "removeGroupThen: requestGroupInfo denied: $e")
            onDone()
        }
    }

    /// Native-triggered cleanup with no Dart caller to report back to —
    /// see MainActivity.onDestroy()'s docs for when this runs. Tears down
    /// the same things disconnect()+stopServer() do, just without a
    /// MethodChannel.Result, since the Flutter engine (and any Dart code
    /// that would have awaited one) may already be gone by the time this
    /// fires (task removed from recents, process about to die).
    fun shutdown() {
        stopServerInternal()
        try {
            disconnectInternal {}
        } catch (e: SecurityException) {
            Log.e(TAG, "shutdown: disconnect denied: $e")
        }
        try {
            p2pStateReceiver?.let { context.unregisterReceiver(it) }
        } catch (e: IllegalArgumentException) {
            // Already unregistered (or never successfully registered) —
            // not an error worth surfacing.
            Log.d(TAG, "shutdown: receiver already unregistered: $e")
        }
        p2pStateReceiver = null
    }

    // Cached so the accept loop can answer a "pull" request without
    // round-tripping back to Dart from a background thread. Set only by the
    // Victim side, right after it builds its bundle.
    @Volatile private var localBundleJson: String? = null

    // Cached so the accept loop can answer a "manifest" request the same
    // way — the bundleIds this device currently holds, kept in sync by
    // DTNManager (Dart) calling setManifest() whenever its stored-bundle set
    // changes. Lets a Helper ask "what do you already have" *before*
    // sending anything, instead of blindly re-sending everything on every
    // contact and relying on the receiver's dedupe to absorb the waste.
    @Volatile private var manifestIds: List<String> = emptyList()

    // Cached so the accept loop can answer a "sync" request's pull half
    // without round-tripping to Dart — the full bundle objects (not just
    // ids, see manifestIds above) this device is currently carrying for
    // relay, kept in sync by DTNManager calling setRelayBundles() alongside
    // setManifest(). "sync" exists specifically so the Wi-Fi Direct *client*
    // can pull from this device within the same connection it's already
    // pushing through — see connectClientSocket's docs for why the group
    // owner (this device, when it's the GO) can never reliably dial out on
    // its own to do the reverse.
    @Volatile private var relayBundlesJson: String = "[]"

    fun setLocalBundle(json: String?) {
        localBundleJson = json
    }

    fun setManifest(ids: List<String>) {
        manifestIds = ids
    }

    fun setRelayBundles(json: String) {
        relayBundlesJson = json
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
                        // client.use{} guarantees close() even if the request
                        // handling below throws (connection reset mid-transfer,
                        // malformed request, etc.) — leaking the client socket's
                        // fd on every failed exchange added up fast across this
                        // app's connect-retry-heavy test pattern.
                        socket.accept().use { client ->
                            Log.d(TAG, "Accepted connection from ${client.inetAddress}")
                            handleRequest(client)
                        }
                    } catch (e: Exception) {
                        // Always log, just at a severity that matches whether
                        // this was expected — stopServerInternal() closing the
                        // socket from another thread makes accept() throw on
                        // every single stop, and that one is noise. Silently
                        // dropping it ENTIRELY (the old `if (!socket.isClosed)`
                        // guard) meant a genuine error that raced with a
                        // concurrent close — e.g. "address already in use"
                        // right after a restart — could go completely
                        // unlogged too, since isClosed had no way to tell the
                        // two cases apart by the time this catch runs.
                        if (socket.isClosed) {
                            Log.d(TAG, "Server accept stopped (socket closed): $e")
                        } else {
                            Log.e(TAG, "Server accept failed: $e")
                        }
                    }
                }
            }
            serverThread?.start()
            mainHandler.post { result.success(null) }
        } catch (e: Exception) {
            mainHandler.post { result.error("SERVER_START_FAILED", e.message, null) }
        }
    }

    /// Lets a Dart-side watchdog notice if the accept-loop thread died (or
    /// was never actually running despite startServer() reporting success)
    /// and restart it, instead of looking active while actually unreachable.
    fun isServerRunning(result: MethodChannel.Result) {
        result.success(serverSocket?.isClosed == false && serverThread?.isAlive == true)
    }

    /// Every accepted connection now starts with exactly one line of JSON —
    /// {"type": "push"|"pull"|"manifest", ...} — read and answered here,
    /// replacing the old "whatever's cached gets served on ANY connection"
    /// design. That older design couldn't support "ask what you have first,
    /// only send what's missing" (manifest), since a server with a cached
    /// bundle would serve it to literally any incoming connection regardless
    /// of what the connector actually wanted.
    private fun handleRequest(client: Socket) {
        val reader = BufferedReader(InputStreamReader(client.getInputStream(), StandardCharsets.UTF_8))
        val line = reader.readLine() ?: return
        val request = JSONObject(line)
        when (request.optString("type")) {
            "push" -> {
                // payload is already a parsed JSONObject/JSONArray (org.json
                // picks the right type) — toString() round-trips it back to
                // valid JSON text, which is all the Dart side (jsonDecode in
                // HelperController._onBundleJsonReceived) needs, regardless
                // of whether it's a single bundle object or a relay batch
                // array.
                val json = request.get("payload").toString()
                Log.d(TAG, "Received push (${json.length} bytes) from ${client.inetAddress}")
                mainHandler.post { eventSink?.success(mapOf("event" to "bundleReceived", "json" to json)) }
            }
            "pull" -> {
                val bundle = localBundleJson ?: ""
                client.getOutputStream().write((bundle + "\n").toByteArray(StandardCharsets.UTF_8))
                client.getOutputStream().flush()
                Log.d(TAG, "Answered pull (${bundle.length} bytes) to ${client.inetAddress}")
                // A passive group-owner device (e.g. a Victim waiting to be
                // pulled) otherwise gets no signal that its bundle actually
                // left — it just sits silent. Tell the Dart side a non-empty
                // pull was served so the user can see a real "picked up"
                // confirmation. An empty pull means nothing was cached to hand
                // over, so it isn't a delivery.
                if (bundle.isNotEmpty()) {
                    mainHandler.post { eventSink?.success(mapOf("event" to "bundleDelivered")) }
                }
            }
            "manifest" -> {
                val response = JSONObject().put("bundleIds", JSONArray(manifestIds)).toString()
                client.getOutputStream().write((response + "\n").toByteArray(StandardCharsets.UTF_8))
                client.getOutputStream().flush()
                Log.d(TAG, "Answered manifest (${manifestIds.size} id(s)) to ${client.inetAddress}")
            }
            "sync" -> {
                // Push half: identical to "push" above, just folded into the
                // same round trip instead of a separate connection.
                val pushedPayload = request.optJSONArray("payload")
                if (pushedPayload != null && pushedPayload.length() > 0) {
                    val json = pushedPayload.toString()
                    Log.d(TAG, "Received sync push (${json.length} bytes) from ${client.inetAddress}")
                    mainHandler.post { eventSink?.success(mapOf("event" to "bundleReceived", "json" to json)) }
                }
                // Pull half: the connector tells us what it already has
                // (clientHas) so we only return bundles it's actually
                // missing, same dedupe-avoidance reasoning as "manifest".
                // Capped — this array comes straight off the socket before
                // any sanity check, and this loop runs on the shared
                // accept-loop thread, so an unbounded peer-controlled array
                // would stall every other connection behind it.
                val clientHasIds = request.optJSONArray("clientHas")
                val clientHasSet = mutableSetOf<String>()
                if (clientHasIds != null) {
                    val count = minOf(clientHasIds.length(), MAX_SYNC_IDS)
                    if (clientHasIds.length() > MAX_SYNC_IDS) {
                        Log.e(TAG, "sync clientHas truncated: ${clientHasIds.length()} > $MAX_SYNC_IDS")
                    }
                    for (i in 0 until count) clientHasSet.add(clientHasIds.getString(i))
                }
                val allBundles = JSONArray(relayBundlesJson)
                val toReturn = JSONArray()
                for (i in 0 until allBundles.length()) {
                    val bundle = allBundles.getJSONObject(i)
                    if (!clientHasSet.contains(bundle.optString("bundleId"))) toReturn.put(bundle)
                }
                client.getOutputStream().write((toReturn.toString() + "\n").toByteArray(StandardCharsets.UTF_8))
                client.getOutputStream().flush()
                Log.d(TAG, "Answered sync: returned ${toReturn.length()} bundle(s) to ${client.inetAddress}")
            }
            else -> Log.e(TAG, "Unknown request type from ${client.inetAddress}: $line")
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

    /// Two different "fixes" for the group owner's outbound socket — plain
    /// local-address binding to 192.168.49.1, then routing via
    /// ConnectivityManager.requestNetwork()/bindSocket() — were each tried
    /// and each confirmed broken on real hardware across two separate
    /// sessions (the latter request never resolved a Network at all,
    /// 100% of attempts, on both GO and client roles, timing out every
    /// single time). Given that, this gave up trying to make the GO's
    /// outbound socket work at all: relayMissing() (DTNManager) now always
    /// pushes AND pulls within the connection the *client* opens — see its
    /// docs — so the GO never has to dial out, sidestepping whatever this
    /// device/chipset's actual routing problem is entirely.
    private fun connectClientSocket(address: String): Socket {
        val socket = Socket()
        socket.connect(InetSocketAddress(address, WIFI_DIRECT_PORT), 3000)
        return socket
    }

    /// Opens its own short-lived connection (does not reuse startServer()'s
    /// socket) — consistent with requestBundle/requestManifest below; the
    /// already-formed Wi-Fi Direct group makes a fresh TCP connect to it
    /// cheap, so there's no need to thread a persistent connection across
    /// multiple platform-channel calls.
    fun sendBundle(address: String, json: String, result: MethodChannel.Result) {
        Thread {
            try {
                Log.d(TAG, "Connecting to $address:$WIFI_DIRECT_PORT to push (${json.length} bytes)")
                // String concatenation (not org.json) is enough here: json is
                // already valid, compact JSON straight from Dart's jsonEncode,
                // so embedding it directly as the "payload" value is safe and
                // avoids a pointless parse-then-reserialize round trip.
                val envelope = """{"type":"push","payload":$json}"""
                // Socket().use{} guarantees close() even if connect() itself
                // throws (timeout, refused) — the previous code only closed on
                // the success path, leaking the socket's fd on every failed
                // send. With this app's connect-retry-heavy test pattern that's
                // a real, accumulating leak, not just a theoretical one.
                connectClientSocket(address).use { socket ->
                    val out = socket.getOutputStream()
                    out.write((envelope + "\n").toByteArray(StandardCharsets.UTF_8))
                    out.flush()
                }
                Log.d(TAG, "Bundle pushed to $address")
                mainHandler.post { result.success(null) }
            } catch (e: Exception) {
                Log.e(TAG, "sendBundle failed: $e")
                mainHandler.post { result.error("SEND_FAILED", e.message, null) }
            }
        }.start()
    }

    /// Active-pull counterpart to handleRequest()'s "pull" branch — used
    /// when this device ends up the P2P client and needs to fetch a bundle
    /// from a Victim that can't initiate discovery itself, rather than
    /// waiting to be pushed one.
    fun requestBundle(address: String, result: MethodChannel.Result) {
        Thread {
            try {
                Log.d(TAG, "Requesting pull from $address:$WIFI_DIRECT_PORT")
                // See sendBundle's comment — same close()-only-on-success leak,
                // same fix.
                val json = connectClientSocket(address).use { socket ->
                    val out = socket.getOutputStream()
                    out.write(("""{"type":"pull"}""" + "\n").toByteArray(StandardCharsets.UTF_8))
                    out.flush()
                    BufferedReader(
                        InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8)
                    ).readLine() ?: ""
                }
                Log.d(TAG, "Pulled bundle (${json.length} bytes) from $address")
                mainHandler.post { result.success(json) }
            } catch (e: Exception) {
                Log.e(TAG, "requestBundle failed: $e")
                mainHandler.post { result.error("PULL_FAILED", e.message, null) }
            }
        }.start()
    }

    /// Asks the peer at [address] which bundleIds it already holds, so the
    /// caller (DTNManager.relayMissing) can compute and send only what's
    /// actually missing instead of blindly re-sending everything on every
    /// Helper-Helper contact.
    fun requestManifest(address: String, result: MethodChannel.Result) {
        Thread {
            try {
                Log.d(TAG, "Requesting manifest from $address:$WIFI_DIRECT_PORT")
                val response = connectClientSocket(address).use { socket ->
                    val out = socket.getOutputStream()
                    out.write(("""{"type":"manifest"}""" + "\n").toByteArray(StandardCharsets.UTF_8))
                    out.flush()
                    BufferedReader(
                        InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8)
                    ).readLine() ?: "{}"
                }
                val ids = JSONObject(response).optJSONArray("bundleIds") ?: JSONArray()
                val list = (0 until ids.length()).map { ids.getString(it) }
                Log.d(TAG, "Received manifest (${list.size} id(s)) from $address")
                mainHandler.post { result.success(list) }
            } catch (e: Exception) {
                Log.e(TAG, "requestManifest failed: $e")
                mainHandler.post { result.error("MANIFEST_FAILED", e.message, null) }
            }
        }.start()
    }

    /// Combines a push (this device's missing-from-peer bundles, already
    /// computed by the caller via requestManifest) with a pull (bundles
    /// this device is missing, identified by [ownBundleIds] which the peer
    /// diffs against its own relay set) into one round trip — see
    /// connectClientSocket's docs for why this exists: the connection here
    /// is always opened by whichever side is the Wi-Fi Direct *client*, so
    /// folding both directions into it means the group owner never has to
    /// dial out on its own. Returns the peer's response (a JSON array of
    /// bundles it sent back) as a string, or "[]" on failure/nothing.
    fun sync(
        address: String,
        ownBundleIds: List<String>,
        pushPayloadJson: String,
        result: MethodChannel.Result
    ) {
        Thread {
            try {
                Log.d(
                    TAG,
                    "Syncing with $address:$WIFI_DIRECT_PORT " +
                        "(ownIds=${ownBundleIds.size}, pushing ${pushPayloadJson.length} bytes)"
                )
                val envelope =
                    """{"type":"sync","clientHas":${JSONArray(ownBundleIds)},"payload":$pushPayloadJson}"""
                val response = connectClientSocket(address).use { socket ->
                    val out = socket.getOutputStream()
                    out.write((envelope + "\n").toByteArray(StandardCharsets.UTF_8))
                    out.flush()
                    BufferedReader(
                        InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8)
                    ).readLine() ?: "[]"
                }
                Log.d(TAG, "Sync response (${response.length} bytes) from $address")
                mainHandler.post { result.success(response) }
            } catch (e: Exception) {
                Log.e(TAG, "sync failed: $e")
                mainHandler.post { result.error("SYNC_FAILED", e.message, null) }
            }
        }.start()
    }
}
