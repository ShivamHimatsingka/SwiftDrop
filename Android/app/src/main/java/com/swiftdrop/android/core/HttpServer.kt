package com.swiftdrop.android.core

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.util.concurrent.Executors
import javax.net.ssl.SSLContext

/** Small streaming HTTP/1.1 server (keep-alive, Content-Length + chunked bodies). */
class HttpServer(private val port: Int, private val ssl: SSLContext?, private val handler: (Request) -> Response) {
    private var server: ServerSocket? = null
    private val pool = Executors.newCachedThreadPool()
    @Volatile private var running = false

    fun start() {
        val ss = ssl?.serverSocketFactory?.createServerSocket() ?: ServerSocket()
        ss.reuseAddress = true
        ss.bind(InetSocketAddress(port), 64)
        server = ss
        running = true
        Thread({
            while (running) {
                val s = try { ss.accept() } catch (e: Exception) { if (!running) break else continue }
                pool.execute { serve(s) }
            }
        }, "swiftdrop-http").start()
    }

    fun stop() { running = false; runCatching { server?.close() } }

    private fun serve(socket: Socket) {
        socket.use { s ->
            s.tcpNoDelay = true
            s.soTimeout = 120_000
            val input = BufferedInputStream(s.getInputStream(), 256 * 1024)
            val out = BufferedOutputStream(s.getOutputStream(), 64 * 1024)
            val remote = s.inetAddress.hostAddress?.removePrefix("::ffff:") ?: "0.0.0.0"
            while (true) {
                val head = readHead(input) ?: return
                val lines = head.split("\r\n")
                val parts = lines[0].split(" ")
                if (parts.size < 2) return
                val headers = HashMap<String, String>()
                for (l in lines.drop(1)) {
                    val i = l.indexOf(':'); if (i > 0) headers[l.substring(0, i).trim().lowercase()] = l.substring(i + 1).trim()
                }
                val target = parts[1]
                val q = target.substringAfter('?', "")
                val query = q.split('&').filter { it.contains('=') }.associate {
                    URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('='), "UTF-8")
                }
                val body = BodyStream(input, headers["content-length"]?.toLongOrNull() ?: 0,
                    headers["transfer-encoding"]?.contains("chunked", true) == true)
                if (headers["expect"].equals("100-continue", true)) { out.write("HTTP/1.1 100 Continue\r\n\r\n".toByteArray()); out.flush() }
                val req = Request(parts[0].uppercase(), target.substringBefore('?'), query, headers, remote, body)
                val resp = try { handler(req) } catch (e: Exception) { Response(500, """{"message":"${e.message}"}""") }
                if (!body.drain(4L shl 20)) { write(out, resp, true); return }
                val close = headers["connection"].equals("close", true)
                write(out, resp, close)
                if (close) return
            }
        }
    }

    private fun write(out: BufferedOutputStream, r: Response, close: Boolean) {
        val bytes = r.body.toByteArray()
        out.write(("HTTP/1.1 ${r.status} ${if (r.status < 400) "OK" else "Error"}\r\n" +
            "Content-Type: application/json\r\nContent-Length: ${bytes.size}\r\n" +
            "Connection: ${if (close) "close" else "keep-alive"}\r\n\r\n").toByteArray())
        out.write(bytes); out.flush()
    }

    private fun readHead(input: InputStream): String? {
        val sb = StringBuilder()
        var state = 0
        while (sb.length < 65536) {
            val c = input.read(); if (c < 0) return null
            sb.append(c.toChar())
            state = when {
                c == '\r'.code && (state == 0 || state == 2) -> state + 1
                c == '\n'.code && (state == 1 || state == 3) -> state + 1
                else -> 0
            }
            if (state == 4) return String(sb.toString().toByteArray(Charsets.ISO_8859_1), Charsets.UTF_8).dropLast(4)
        }
        return null
    }
}

class Request(val method: String, val path: String, val query: Map<String, String>, val headers: Map<String, String>,
              val remote: String, val body: BodyStream) {
    fun text(limit: Int = 64 shl 20): String {
        val bytes = body.readBytes()
        require(bytes.size <= limit)
        return bytes.toString(Charsets.UTF_8)
    }
}

class Response(val status: Int, val body: String = "") {
    companion object {
        fun json(o: Any) = Response(200, o.toString())
        val ok = Response(200)
        val noContent = Response(204)
        val forbidden = Response(403, """{"message":"Forbidden"}""")
        val notFound = Response(404, """{"message":"Not found"}""")
        val bad = Response(400, """{"message":"Bad request"}""")
    }
}

/** Request body view over the socket stream. */
class BodyStream(private val src: InputStream, private var remaining: Long, private val chunked: Boolean) : InputStream() {
    private var chunkLeft = 0L
    private var done = !chunked && remaining <= 0

    private fun line(): String {
        val sb = StringBuilder()
        while (true) { val c = src.read(); if (c < 0 || c == '\n'.code) break; if (c != '\r'.code) sb.append(c.toChar()) }
        return sb.toString()
    }

    private fun ensure(): Boolean {
        if (done) return false
        if (!chunked) return remaining > 0
        if (chunkLeft == 0L) {
            val size = line().substringBefore(';').trim().toLongOrNull(16) ?: 0
            if (size == 0L) { while (line().isNotEmpty()) {}; done = true; return false }
            chunkLeft = size
        }
        return true
    }

    override fun read(): Int { val b = ByteArray(1); return if (read(b, 0, 1) < 0) -1 else b[0].toInt() and 0xFF }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (!ensure()) return -1
        val want = if (chunked) minOf(len.toLong(), chunkLeft) else minOf(len.toLong(), remaining)
        val n = src.read(b, off, want.toInt())
        if (n < 0) { done = true; return -1 }
        if (chunked) { chunkLeft -= n; if (chunkLeft == 0L) line() } else { remaining -= n; if (remaining == 0L) done = true }
        return n
    }

    /** Discard the rest of the body. Returns false if too large to drain (close instead). */
    fun drain(limit: Long): Boolean {
        if (done) return true
        if (!chunked && remaining > limit) return false
        val buf = ByteArray(64 * 1024); var total = 0L
        while (true) { val n = read(buf); if (n < 0) return true; total += n; if (total > limit) return false }
    }
}
