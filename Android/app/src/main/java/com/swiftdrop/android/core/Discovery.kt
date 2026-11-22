package com.swiftdrop.android.core

import java.net.DatagramPacket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.MulticastSocket
import java.net.NetworkInterface
import org.json.JSONObject

/** LocalSend multicast discovery on 224.0.0.167:53317. */
class Discovery(private val onMessage: (DeviceInfo, String) -> Unit) {
    private var socket: MulticastSocket? = null
    private val group = InetAddress.getByName(LS.MULTICAST)

    fun start() {
        val s = MulticastSocket(null).apply { reuseAddress = true; bind(InetSocketAddress(LS.PORT)); timeToLive = 4 }
        socket = s
        joinAll()
        Thread({
            val buf = ByteArray(65536)
            while (!s.isClosed) {
                val p = DatagramPacket(buf, buf.size)
                try { s.receive(p) } catch (e: Exception) { if (s.isClosed) break else continue }
                runCatching {
                    val info = DeviceInfo.from(JSONObject(String(p.data, 0, p.length, Charsets.UTF_8)))
                    onMessage(info, p.address.hostAddress ?: return@runCatching)
                }
            }
        }, "swiftdrop-mcast").start()
    }

    fun joinAll() {
        val s = socket ?: return
        for (ni in interfaces()) runCatching { s.joinGroup(InetSocketAddress(group, 0), ni) }
    }

    fun send(info: DeviceInfo) {
        val s = socket ?: return
        val data = info.toJson().toString().toByteArray()
        Thread {
            for (ni in interfaces()) runCatching {
                s.networkInterface = ni
                s.send(DatagramPacket(data, data.size, group, LS.PORT))
            }
        }.start()
    }

    fun stop() { runCatching { socket?.close() } }

    companion object {
        fun interfaces(): List<NetworkInterface> = runCatching {
            NetworkInterface.getNetworkInterfaces().toList().filter {
                it.isUp && !it.isLoopback && it.supportsMulticast() && it.inetAddresses.toList().any { a -> a is Inet4Address }
            }
        }.getOrDefault(emptyList())

        /** Hosts on our /24 (LocalSend's HTTP fallback discovery). */
        fun subnetHosts(): List<String> {
            val out = mutableListOf<String>()
            for (ni in runCatching { NetworkInterface.getNetworkInterfaces().toList() }.getOrDefault(emptyList())) {
                if (!ni.isUp || ni.isLoopback) continue
                for (ia in ni.interfaceAddresses) {
                    val a = ia.address as? Inet4Address ?: continue
                    val b = a.address
                    for (i in 1..254) {
                        if (i == (b[3].toInt() and 0xFF)) continue
                        out += "${b[0].toInt() and 0xFF}.${b[1].toInt() and 0xFF}.${b[2].toInt() and 0xFF}.$i"
                    }
                }
            }
            return out.distinct()
        }
    }
}
