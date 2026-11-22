package com.swiftdrop.android.core

import android.annotation.SuppressLint
import android.content.Context
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pManager
import android.os.Looper
import java.security.SecureRandom
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import org.json.JSONObject

/**
 * Wi‑Fi Direct between Android phones that don't share a network. The receiver
 * creates a temporary group (its normal Wi‑Fi stays connected on phones that support
 * concurrency, which is nearly all); the sender joins it with the name/passphrase it
 * got over Bluetooth. The LocalSend transfer then runs over the direct link (still TLS).
 */
@SuppressLint("MissingPermission")
class WifiDirect(private val ctx: Context) {
    private val mgr = ctx.getSystemService(WifiP2pManager::class.java)
    private val channel = mgr?.initialize(ctx, Looper.getMainLooper(), null)
    @Volatile private var groupUntil = 0L

    val supported get() = mgr != null && channel != null

    /** Receiver side: create (or reuse) a group; returns {"ssid","pass","ip"} JSON or null. */
    fun hostGroup(port: Int): String? {
        if (!supported) return null
        val existing = groupInfo()
        val info = existing ?: run {
            val pass = (1..12).map { "abcdefghjkmnpqrstuvwxyz23456789"[SecureRandom().nextInt(31)] }.joinToString("")
            val cfg = WifiP2pConfig.Builder().setNetworkName("DIRECT-sd-SwiftDrop").setPassphrase(pass)
                .setGroupOperatingBand(WifiP2pConfig.GROUP_OWNER_BAND_AUTO).build()
            val created = CompletableFuture<Boolean>()
            mgr!!.createGroup(channel!!, cfg, listener(created))
            if (runCatching { created.get(10, TimeUnit.SECONDS) }.getOrDefault(false) != true) return null
            var g: Pair<String, String>? = null
            repeat(20) { if (g == null) { Thread.sleep(250); g = groupInfo() } }
            g
        } ?: return null
        groupUntil = System.currentTimeMillis() + 5 * 60_000
        Thread { Thread.sleep(5 * 60_000 + 1000); if (System.currentTimeMillis() > groupUntil) close() }.start()
        // Group owner is always 192.168.49.1 on Android.
        return JSONObject().put("ssid", info.first).put("pass", info.second).put("ip", "192.168.49.1").put("p", port).toString()
    }

    /** Sender side: join the peer's group. Returns the peer's IP on success. */
    fun join(reply: String): String? {
        if (!supported) return null
        val j = runCatching { JSONObject(reply) }.getOrNull() ?: return null
        val ssid = j.optString("ssid").ifEmpty { return null }
        val cfg = WifiP2pConfig.Builder().setNetworkName(ssid).setPassphrase(j.getString("pass")).build()
        val ok = CompletableFuture<Boolean>()
        mgr!!.connect(channel, cfg, listener(ok))
        if (runCatching { ok.get(10, TimeUnit.SECONDS) }.getOrDefault(false) != true) return null
        // Wait for an address on the p2p interface.
        repeat(40) {
            val connected = CompletableFuture<Boolean>()
            mgr.requestConnectionInfo(channel) { connected.complete(it?.groupFormed == true) }
            if (runCatching { connected.get(2, TimeUnit.SECONDS) }.getOrDefault(false)) return j.optString("ip", "192.168.49.1")
            Thread.sleep(500)
        }
        return null
    }

    fun close() { if (supported) mgr!!.removeGroup(channel, null) }

    private fun groupInfo(): Pair<String, String>? {
        val f = CompletableFuture<Pair<String, String>?>()
        mgr?.requestGroupInfo(channel) { g -> f.complete(g?.takeIf { it.isGroupOwner }?.let { it.networkName to (it.passphrase ?: "") }) }
        return runCatching { f.get(3, TimeUnit.SECONDS) }.getOrNull()
    }

    private fun listener(f: CompletableFuture<Boolean>) = object : WifiP2pManager.ActionListener {
        override fun onSuccess() { f.complete(true) }
        override fun onFailure(reason: Int) { f.complete(false) }
    }
}
