package com.swiftdrop.android.core

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.Build
import android.os.ParcelUuid
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import org.json.JSONArray
import org.json.JSONObject

/** Card exchanged over Bluetooth (same format as the Mac/iPhone/Windows apps). */
data class BleCard(val alias: String, val fingerprint: String, val model: String?, val type: String?, val port: Int,
                   val scheme: String, val ips: List<String>, val caps: List<String>) {
    fun toJson() = JSONObject().put("a", alias).put("f", fingerprint).put("m", model).put("t", type).put("p", port)
        .put("s", scheme).put("ip", JSONArray(ips)).put("x", JSONArray(caps)).toString()
    companion object {
        fun from(s: String) = runCatching {
            val j = JSONObject(s)
            BleCard(j.getString("a"), j.getString("f"), j.optString("m").ifEmpty { null }, j.optString("t").ifEmpty { null },
                j.getInt("p"), j.optString("s", "https"),
                j.optJSONArray("ip")?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList(),
                j.optJSONArray("x")?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList())
        }.getOrNull()
    }
}

/**
 * Bluetooth LE discovery: advertise the SwiftDrop service, serve our card over GATT,
 * scan for others and read theirs. Also carries the Wi‑Fi Direct handshake
 * (CONNECT characteristic) between Android phones.
 */
@SuppressLint("MissingPermission")
class Ble(private val ctx: Context) {
    companion object {
        val SERVICE: UUID = UUID.fromString("7A4F0001-5D3F-4B6E-9C2A-53574946544F")
        val INFO: UUID = UUID.fromString("7A4F0002-5D3F-4B6E-9C2A-53574946544F")
        val CONNECT: UUID = UUID.fromString("7A4F0003-5D3F-4B6E-9C2A-53574946544F")
    }

    var card: (() -> BleCard?)? = null
    var onCard: ((BleCard, String) -> Unit)? = null              // card, BLE address
    /** A peer asked (by fingerprint) for a Wi‑Fi Direct group; return the JSON reply or null to refuse. */
    var onConnectRequest: ((String) -> String?)? = null

    private val manager = ctx.getSystemService(BluetoothManager::class.java)
    private val adapter get() = manager?.adapter
    private var server: BluetoothGattServer? = null
    private val lastRead = ConcurrentHashMap<String, Long>()
    private val busy = ConcurrentHashMap.newKeySet<String>()
    private val connectReplies = ConcurrentHashMap<String, String>()  // BLE address -> reply
    private var advertising = false

    private val advertiseCallback = object : AdvertiseCallback() {}
    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(type: Int, r: ScanResult) = read(r.device)
        override fun onBatchScanResults(results: MutableList<ScanResult>) = results.forEach { read(it.device) }
    }

    fun start() = runCatching {
        val a = adapter ?: return@runCatching
        if (!a.isEnabled) return@runCatching
        openServer()
        updateAdvertising()
        a.bluetoothLeScanner?.startScan(listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build()),
            ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build(), scanCallback)
    }

    fun stop() = runCatching {
        adapter?.bluetoothLeScanner?.stopScan(scanCallback)
        adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
        server?.close(); server = null; advertising = false
    }

    fun refresh() = runCatching { lastRead.clear(); updateAdvertising() }

    fun updateAdvertising() = runCatching {
        val adv = adapter?.bluetoothLeAdvertiser ?: return@runCatching
        val visible = card?.invoke() != null
        if (visible && !advertising) {
            adv.startAdvertising(AdvertiseSettings.Builder().setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
                .setConnectable(true).setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM).build(),
                AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE)).setIncludeDeviceName(false).build(), advertiseCallback)
            advertising = true
        } else if (!visible && advertising) {
            adv.stopAdvertising(advertiseCallback); advertising = false
        }
    }

    // ---------------------------------------------------------------- GATT server

    private fun openServer() {
        if (server != null) return
        val s = manager?.openGattServer(ctx, object : BluetoothGattServerCallback() {
            override fun onCharacteristicReadRequest(d: BluetoothDevice, id: Int, offset: Int, ch: BluetoothGattCharacteristic) {
                val body = when (ch.uuid) {
                    INFO -> card?.invoke()?.toJson()
                    CONNECT -> connectReplies[d.address] ?: """{"wait":true}"""
                    else -> null
                }?.toByteArray()
                if (body == null || offset > body.size) { server?.sendResponse(d, id, BluetoothGatt.GATT_FAILURE, offset, null); return }
                server?.sendResponse(d, id, BluetoothGatt.GATT_SUCCESS, offset, body.copyOfRange(offset, body.size))
            }

            override fun onCharacteristicWriteRequest(d: BluetoothDevice, id: Int, ch: BluetoothGattCharacteristic, prepared: Boolean,
                                                      needsResponse: Boolean, offset: Int, value: ByteArray?) {
                if (ch.uuid == CONNECT && value != null) {
                    val fp = String(value)
                    connectReplies.remove(d.address)
                    Thread { onConnectRequest?.invoke(fp)?.let { connectReplies[d.address] = it } }.start()
                }
                if (needsResponse) server?.sendResponse(d, id, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }) ?: return
        val svc = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        svc.addCharacteristic(BluetoothGattCharacteristic(INFO, BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ))
        svc.addCharacteristic(BluetoothGattCharacteristic(CONNECT,
            BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_WRITE,
            BluetoothGattCharacteristic.PERMISSION_READ or BluetoothGattCharacteristic.PERMISSION_WRITE))
        s.addService(svc)
        server = s
    }

    // ---------------------------------------------------------------- GATT client

    private fun read(device: BluetoothDevice) {
        val now = System.currentTimeMillis()
        if ((lastRead[device.address] ?: 0) > now - 60_000 || !busy.add(device.address)) return
        lastRead[device.address] = now
        gattOp(device, write = null) { value -> value?.let { BleCard.from(it) }?.let { onCard?.invoke(it, device.address) } }
    }

    /** Ask a peer phone for a Wi‑Fi Direct group. Blocks up to ~15 s; returns its JSON reply. */
    fun requestConnect(address: String, myFingerprint: String): String? {
        val device = adapter?.getRemoteDevice(address) ?: return null
        val result = java.util.concurrent.CompletableFuture<String?>()
        gattOp(device, write = myFingerprint.toByteArray(), char = CONNECT, poll = true) { result.complete(it) }
        return runCatching { result.get(20, java.util.concurrent.TimeUnit.SECONDS) }.getOrNull()
    }

    private fun gattOp(device: BluetoothDevice, write: ByteArray?, char: UUID = INFO, poll: Boolean = false, done: (String?) -> Unit) {
        var finished = false
        var attempts = 0
        fun finish(g: BluetoothGatt, v: String?) {
            if (finished) return; finished = true
            busy.remove(device.address); runCatching { g.close() }; done(v)
        }
        device.connectGatt(ctx, false, object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, state: Int) {
                if (state == BluetoothProfile.STATE_CONNECTED) g.requestMtu(517)
                else if (state == BluetoothProfile.STATE_DISCONNECTED) finish(g, null)
            }
            override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) { g.discoverServices() }
            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                val ch = g.getService(SERVICE)?.getCharacteristic(char) ?: return finish(g, null)
                if (write != null) {
                    if (Build.VERSION.SDK_INT >= 33) g.writeCharacteristic(ch, write, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
                    else @Suppress("DEPRECATION") { ch.value = write; g.writeCharacteristic(ch) }
                } else g.readCharacteristic(ch)
            }
            override fun onCharacteristicWrite(g: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int) { g.readCharacteristic(ch) }
            override fun onCharacteristicRead(g: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray, status: Int) =
                handle(g, ch, String(value))
            @Deprecated("API < 33") override fun onCharacteristicRead(g: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int) =
                handle(g, ch, String(@Suppress("DEPRECATION") ch.value ?: ByteArray(0)))
            private fun handle(g: BluetoothGatt, ch: BluetoothGattCharacteristic, v: String) {
                // The peer creates its Wi‑Fi Direct group asynchronously: poll until ready.
                if (poll && v.contains("\"wait\"") && attempts++ < 15) {
                    Thread { Thread.sleep(1000); g.readCharacteristic(ch) }.start(); return
                }
                finish(g, v)
            }
        }, BluetoothDevice.TRANSPORT_LE)
        Thread { Thread.sleep(25_000); busy.remove(device.address) }.start()
    }
}
