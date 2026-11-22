package com.swiftdrop.android.core

import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import javax.net.ssl.HttpsURLConnection
import org.json.JSONObject

/** LocalSend HTTP(S) client. Streams uploads; accepts self-signed certificates. */
object Client {
    private fun open(url: String, timeout: Int): HttpURLConnection {
        val c = URL(url).openConnection() as HttpURLConnection
        if (c is HttpsURLConnection) {
            c.sslSocketFactory = Tls.trustAll.socketFactory
            c.hostnameVerifier = javax.net.ssl.HostnameVerifier { _, _ -> true }
        }
        c.connectTimeout = minOf(timeout, 5000)
        c.readTimeout = timeout
        c.useCaches = false
        return c
    }

    fun qs(vararg p: Pair<String, String>) = p.joinToString("&") { "${it.first}=${URLEncoder.encode(it.second, "UTF-8")}" }

    /** Returns status + body. */
    fun postJson(url: String, json: JSONObject?, timeout: Int = 10_000): Pair<Int, String> {
        val c = open(url, timeout)
        try {
            c.requestMethod = "POST"
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/json")
            val bytes = (json?.toString() ?: "").toByteArray()
            c.setFixedLengthStreamingMode(bytes.size)
            c.outputStream.use { it.write(bytes) }
            val code = c.responseCode
            val body = runCatching { (if (code < 400) c.inputStream else c.errorStream)?.readBytes()?.toString(Charsets.UTF_8) }
                .getOrNull() ?: ""
            return code to body
        } finally { c.disconnect() }
    }

    fun upload(url: String, input: InputStream, size: Long, cancelled: () -> Boolean, progress: (Long) -> Unit): Int {
        val c = open(url, 120_000)
        try {
            c.requestMethod = "POST"
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/octet-stream")
            if (size >= 0) c.setFixedLengthStreamingMode(size) else c.setChunkedStreamingMode(256 * 1024)
            c.outputStream.use { out ->
                val buf = ByteArray(256 * 1024)
                var sent = 0L
                input.use { inp ->
                    while (true) {
                        if (cancelled()) throw TransferException(Phase.CANCELLED, "Cancelled")
                        val n = inp.read(buf); if (n < 0) break
                        out.write(buf, 0, n); sent += n; progress(sent)
                    }
                }
            }
            return c.responseCode
        } finally { c.disconnect() }
    }

    fun probe(host: String, port: Int, me: DeviceInfo): Pair<DeviceInfo, String>? {
        for (scheme in listOf("https", "http")) {
            val r = runCatching { postJson("$scheme://$host:$port/api/localsend/v2/register", me.toJson(), 1500) }.getOrNull()
            if (r?.first == 200) return runCatching { DeviceInfo.from(JSONObject(r.second)) to scheme }.getOrNull()
        }
        return null
    }
}
