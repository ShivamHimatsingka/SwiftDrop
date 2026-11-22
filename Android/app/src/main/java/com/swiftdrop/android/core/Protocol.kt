package com.swiftdrop.android.core

import org.json.JSONObject

/** LocalSend v2 wire format (https://github.com/localsend/protocol). */
object LS {
    const val VERSION = "2.1"
    const val MULTICAST = "224.0.0.167"
    const val PORT = 53317
}

data class DeviceInfo(
    val alias: String,
    val fingerprint: String,
    val deviceModel: String? = null,
    val deviceType: String? = null,
    val port: Int? = null,
    val protocol: String? = null,
    val announce: Boolean? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("alias", alias); put("version", LS.VERSION); put("fingerprint", fingerprint)
        deviceModel?.let { put("deviceModel", it) }; deviceType?.let { put("deviceType", it) }
        port?.let { put("port", it) }; protocol?.let { put("protocol", it) }
        put("download", false)
        announce?.let { put("announce", it); put("announcement", it) }
    }

    companion object {
        fun from(j: JSONObject) = DeviceInfo(
            alias = j.optString("alias", "Unknown"),
            fingerprint = j.optString("fingerprint"),
            deviceModel = j.optString("deviceModel").ifEmpty { null },
            deviceType = j.optString("deviceType").ifEmpty { null },
            port = if (j.has("port")) j.optInt("port") else null,
            protocol = j.optString("protocol").ifEmpty { null },
            announce = if (j.has("announce")) j.optBoolean("announce")
                       else if (j.has("announcement")) j.optBoolean("announcement") else null,
        )
    }
}

data class FileDto(val id: String, val fileName: String, val size: Long, val fileType: String, val preview: String? = null) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id); put("fileName", fileName); put("size", size); put("fileType", fileType)
        preview?.let { put("preview", it) }
    }
    companion object {
        fun from(j: JSONObject) = FileDto(j.getString("id"), j.getString("fileName"), j.optLong("size"),
            j.optString("fileType", "application/octet-stream"), j.optString("preview").ifEmpty { null })
    }
}

data class Peer(
    val id: String, val alias: String, val deviceModel: String?, val deviceType: String?,
    val host: String, val port: Int, val scheme: String, val lastSeen: Long = System.currentTimeMillis(),
    /** Found over Bluetooth but not on our network: reachable through Wi‑Fi Direct. */
    val bleAddress: String? = null, val wifiDirect: Boolean = false,
) {
    val hasLan get() = host.isNotEmpty()
    val baseUrl get() = "$scheme://${if (host.contains(':')) "[$host]" else host}:$port"
    val caption get() = deviceModel ?: when (deviceType) { "mobile" -> "Phone"; "web" -> "Browser"; else -> "Computer" }
}

enum class Phase { IDLE, WAITING, SENDING, DONE, DECLINED, FAILED, CANCELLED;
    val active get() = this == WAITING || this == SENDING
    val terminal get() = this == DONE || this == DECLINED || this == FAILED || this == CANCELLED
}

enum class ReceiveMode(val title: String) { OFF("Receiving Off"), FAVORITES("Favorites Only"), EVERYONE("Everyone") }

class TransferException(val kind: Phase, message: String) : Exception(message)
