package com.swiftdrop.android.core

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.MediaStore
import java.io.File
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import org.json.JSONArray
import org.json.JSONObject

data class OutItem(val name: String, val size: Long, val mime: String, val open: () -> java.io.InputStream, val preview: String? = null)

data class Incoming(
    val id: String, val senderId: String, val senderAlias: String, val senderModel: String?, val senderType: String?,
    val files: List<FileDto>, val state: State = State.ASKING, val progress: Float = 0f,
    val saved: List<Uri> = emptyList(), val error: String? = null, val alwaysAccept: Boolean = false,
) {
    enum class State { ASKING, RECEIVING, DONE, FAILED }
    val total get() = files.sumOf { it.size }
    val isMessage get() = files.isNotEmpty() && files.all { it.fileType.startsWith("text/plain") && it.preview != null }
    val noun: String get() {
        val n = files.size
        return when {
            files.all { it.fileType.startsWith("image/") } -> if (n == 1) "a photo" else "$n photos"
            files.all { it.fileType.startsWith("video/") } -> if (n == 1) "a video" else "$n videos"
            n == 1 -> "“${files[0].fileName.substringAfterLast('/')}”"
            else -> "$n items"
        }
    }
}

data class HistoryEntry(val sent: Boolean, val title: String, val device: String, val time: Long, val uri: String?)

/** Process-wide SwiftDrop engine: discovery, LocalSend server, send/receive. */
object Engine {
    lateinit var app: Context
    val peers = MutableStateFlow<List<Peer>>(emptyList())
    val transfers = MutableStateFlow<Map<String, Pair<Phase, Float>>>(emptyMap())
    val mode = MutableStateFlow(ReceiveMode.EVERYONE)
    val incoming = MutableStateFlow<Incoming?>(null)
    val message = MutableStateFlow<Pair<String, String>?>(null)
    val history = MutableStateFlow<List<HistoryEntry>>(emptyList())
    val favorites = MutableStateFlow<Map<String, Boolean>>(emptyMap())   // id -> autoAccept

    var onIncoming: ((Incoming) -> Unit)? = null      // notification hook (service)
    var onIncomingChanged: ((Incoming?) -> Unit)? = null

    private lateinit var fingerprint: String
    private var scheme = "https"
    private var port = LS.PORT
    private var server: HttpServer? = null
    private var discovery: Discovery? = null
    private var mcLock: WifiManager.MulticastLock? = null
    private val io = Executors.newCachedThreadPool()
    private val sendTasks = ConcurrentHashMap<String, Future<*>>()
    private val decisions = ConcurrentHashMap<String, CompletableFuture<Boolean>>()
    private val sessions = ConcurrentHashMap<String, Session>()
    @Volatile private var started = false
    @Volatile private var browsingUntil = 0L
    private val misses = ConcurrentHashMap<String, Int>()
    private var ble: Ble? = null
    private var wifiDirect: WifiDirect? = null

    private val prefs get() = app.getSharedPreferences("swiftdrop", Context.MODE_PRIVATE)
    var deviceName: String
        get() = prefs.getString("name", null) ?: (Build.MODEL ?: "Android")
        set(v) { prefs.edit().putString("name", v).apply(); announce() }

    fun init(ctx: Context) {
        if (::app.isInitialized) return
        app = ctx.applicationContext
        mode.value = runCatching { ReceiveMode.valueOf(prefs.getString("mode", "EVERYONE")!!) }.getOrDefault(ReceiveMode.EVERYONE)
        favorites.value = runCatching {
            val j = JSONObject(prefs.getString("favorites", "{}")!!); j.keys().asSequence().associateWith { j.getBoolean(it) }
        }.getOrDefault(emptyMap())
        history.value = runCatching {
            val a = JSONArray(prefs.getString("history", "[]")!!)
            (0 until a.length()).map { a.getJSONObject(it).let { o ->
                HistoryEntry(o.getBoolean("s"), o.getString("t"), o.getString("d"), o.getLong("w"), o.optString("u").ifEmpty { null }) } }
        }.getOrDefault(emptyList())
        port = prefs.getInt("port", LS.PORT)
    }

    fun setMode(m: ReceiveMode) { mode.value = m; prefs.edit().putString("mode", m.name).apply(); announce() }

    /** "Pixel 9", "Galaxy S24" stay as-is; codes like "SM-S918B" become the brand ("Samsung"). */
    private val friendlyModel: String = Build.MODEL.let { m ->
        if (m.startsWith("Pixel") || m.startsWith("Galaxy") || m.startsWith("OnePlus") || m.startsWith("Nothing")) m
        else Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
    }

    fun me(announce: Boolean? = null) = DeviceInfo(deviceName, fingerprint, friendlyModel, "mobile", port, scheme, announce)

    @Synchronized fun ensureStarted() {
        if (started) return
        started = true
        val ssl = runCatching { Tls.serverContext() }.getOrNull()
        if (ssl != null) { fingerprint = ssl.second; scheme = "https" }
        else { fingerprint = prefs.getString("fp", null) ?: UUID.randomUUID().toString().replace("-", "").also { prefs.edit().putString("fp", it).apply() }; scheme = "http" }
        server = HttpServer(port, ssl?.first, ::route).also { runCatching { it.start() } }
        val wifi = app.getSystemService(Context.WIFI_SERVICE) as WifiManager
        mcLock = wifi.createMulticastLock("swiftdrop").apply { setReferenceCounted(false); acquire() }
        discovery = Discovery(::onMulticast).also { runCatching { it.start() } }
        wifiDirect = WifiDirect(app)
        ble = Ble(app).also { b ->
            b.card = {
                if (!isDiscoverable(null)) null
                else BleCard(deviceName, fingerprint, friendlyModel, "mobile", port, scheme, ipv4s(),
                             if (wifiDirect?.supported == true) listOf("wfd") else emptyList())
            }
            b.onCard = ::onBleCard
            b.onConnectRequest = { fp -> if (canReceive(fp)) wifiDirect?.hostGroup(port) else null }
            b.start()
        }
        announce()
        io.execute { Thread.sleep(1500); announce() }
    }

    fun announce() {
        ble?.updateAdvertising()
        if (started && isDiscoverable(null)) discovery?.send(me(true))
    }

    /** Restart Bluetooth after permissions are granted. */
    fun restartBluetooth() { ble?.stop(); ble?.start() }

    private fun ipv4s() = runCatching {
        java.net.NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList() }.filterIsInstance<java.net.Inet4Address>().mapNotNull { it.hostAddress }
    }.getOrDefault(emptyList())

    /** A Bluetooth card: reach the device over Wi‑Fi if we can, otherwise offer Wi‑Fi Direct. */
    private fun onBleCard(card: BleCard, address: String) {
        if (card.fingerprint == fingerprint || peers.value.any { it.id == card.fingerprint && it.hasLan }) return
        io.execute {
            val me = me()
            for (ip in card.ips) {
                val hit = Client.probe(ip, card.port, me)
                if (hit != null) { ingest(hit.first, ip, card.port, hit.second); return@execute }
            }
            if ("wfd" in card.caps && wifiDirect?.supported == true) {
                val p = Peer(card.fingerprint, card.alias, card.model, card.type, "", card.port, card.scheme,
                             bleAddress = address, wifiDirect = true)
                peers.update { l -> (l.filterNot { it.id == p.id } + p).sortedWith(compareBy({ !isFavorite(it.id) }, { it.alias.lowercase() })) }
            }
        }
    }

    /** Called while a sending UI is visible: announce + re-check peers (+ subnet scan). */
    fun refresh(deep: Boolean = false) {
        ensureStarted()
        browsingUntil = System.currentTimeMillis() + 120_000
        ble?.refresh()
        discovery?.joinAll()
        discovery?.send(me(true))
        val known = peers.value.filter { it.hasLan }
        io.execute {
            known.forEach { p -> io.execute {
                val ok = runCatching { Client.postJson("${p.baseUrl}/api/localsend/v2/register", me().toJson(), 4000) }.getOrNull()?.first == 200
                if (ok) misses.remove(p.id)
                // Drop only after two consecutive misses, so a slow handshake doesn't hide a nearby device.
                else if ((misses.merge(p.id, 1, Int::plus) ?: 0) >= 2) {
                    misses.remove(p.id)
                    peers.update { l -> if (transfers.value[p.id]?.first?.active == true) l else l.filterNot { it.id == p.id } }
                }
            } }
            if (deep || peers.value.isEmpty()) scan()
        }
    }

    private fun scan() {
        val pool = Executors.newFixedThreadPool(64)
        val me = me()
        for (h in Discovery.subnetHosts()) pool.execute { Client.probe(h, LS.PORT, me)?.let { (info, sch) -> ingest(info, h, LS.PORT, sch) } }
        pool.shutdown(); pool.awaitTermination(20, TimeUnit.SECONDS)
    }

    fun isFavorite(id: String?) = id != null && favorites.value.containsKey(id)
    fun isDiscoverable(id: String?) = System.currentTimeMillis() < browsingUntil || when (mode.value) {
        ReceiveMode.EVERYONE -> true; ReceiveMode.FAVORITES -> isFavorite(id); ReceiveMode.OFF -> false }
    private fun canReceive(id: String) = when (mode.value) {
        ReceiveMode.EVERYONE -> true; ReceiveMode.FAVORITES -> isFavorite(id); ReceiveMode.OFF -> false }

    fun toggleFavorite(p: Peer) = setFavorite(p.id, if (isFavorite(p.id)) null else false)
    fun setFavorite(id: String, autoAccept: Boolean?) {
        favorites.update { if (autoAccept == null) it - id else it + (id to autoAccept) }
        prefs.edit().putString("favorites", JSONObject(favorites.value as Map<*, *>).toString()).apply()
    }

    private fun ingest(info: DeviceInfo, host: String, port: Int? = null, sch: String? = null): Peer? {
        if (!::fingerprint.isInitialized || info.fingerprint == fingerprint || info.fingerprint.isEmpty()) return null
        val p = Peer(info.fingerprint, info.alias, info.deviceModel, info.deviceType, host,
            port ?: info.port ?: LS.PORT, sch ?: info.protocol ?: "https")
        peers.update { l -> (l.filterNot { it.id == p.id } + p).sortedWith(compareBy({ !isFavorite(it.id) }, { it.alias.lowercase() })) }
        return p
    }

    private fun onMulticast(info: DeviceInfo, ip: String) {
        val p = ingest(info, ip) ?: return
        if (info.announce == true && isDiscoverable(info.fingerprint)) io.execute {
            val r = runCatching { Client.postJson("${p.baseUrl}/api/localsend/v2/register", me().toJson(), 3000) }.getOrNull()
            if (r?.first != 200) discovery?.send(me(false))
        }
    }

    // ---------------------------------------------------------------- server

    private fun route(r: Request): Response {
        val path = r.path.replace("/api/localsend/v1/", "/api/localsend/v2/")
        return when ("${r.method} $path") {
            "POST /api/localsend/v2/register" -> {
                val info = runCatching { DeviceInfo.from(JSONObject(r.text())) }.getOrNull() ?: return Response.bad
                ingest(info, r.remote)
                if (isDiscoverable(info.fingerprint)) Response.json(me().toJson()) else Response.forbidden
            }
            "GET /api/localsend/v2/info" -> if (isDiscoverable(r.query["fingerprint"])) Response.json(me().toJson()) else Response.forbidden
            "POST /api/localsend/v2/prepare-upload" -> prepare(r)
            "POST /api/localsend/v2/upload" -> upload(r)
            "POST /api/localsend/v2/cancel" -> {
                sessions.remove(r.query["sessionId"])?.let { it.cancelled = true; finishIncoming(it, "Cancelled by sender") }
                Response.ok
            }
            else -> Response.notFound
        }
    }

    private class Session(val offer: Incoming, val tokens: Map<String, String>) {
        val received = AtomicLong(0)
        val pending = ConcurrentHashMap.newKeySet<String>().apply { addAll(tokens.keys) }
        val saved = java.util.Collections.synchronizedList(mutableListOf<Uri>())
        val folders = ConcurrentHashMap<String, String>()   // sender's top folder -> unique local name
        @Volatile var cancelled = false
        @Volatile var lastActivity = System.currentTimeMillis()
        @Volatile var lastReport = 0L
    }

    private fun prepare(r: Request): Response {
        val j = runCatching { JSONObject(r.text()) }.getOrNull() ?: return Response.bad
        val info = DeviceInfo.from(j.getJSONObject("info"))
        val sender = ingest(info, r.remote)
        if (!canReceive(info.fingerprint)) return Response.forbidden
        val fj = j.getJSONObject("files")
        val files = fj.keys().asSequence().map { FileDto.from(fj.getJSONObject(it)) }.sortedBy { it.fileName }.toList()
        if (files.isEmpty()) return Response.bad
        val offer = Incoming(UUID.randomUUID().toString(), info.fingerprint, info.alias, info.deviceModel ?: sender?.deviceModel,
            info.deviceType, files)
        if (offer.isMessage) {
            val text = files.mapNotNull { it.preview }.joinToString("\n\n")
            message.value = info.alias to text
            addHistory(HistoryEntry(false, text.take(80), info.alias, System.currentTimeMillis(), null))
            onIncoming?.invoke(offer)
            return Response.noContent
        }
        // Evict abandoned sessions (idle 45 s) or an older one from the same sender.
        sessions.values.filter { it.offer.senderId == info.fingerprint || System.currentTimeMillis() - it.lastActivity > 45_000 }
            .forEach { sessions.remove(it.offer.id); it.cancelled = true }
        if (sessions.isNotEmpty() || incoming.value?.state == Incoming.State.ASKING) return Response(409, """{"message":"Busy"}""")

        val free = runCatching { android.os.StatFs(android.os.Environment.getExternalStorageDirectory().path).availableBytes }.getOrDefault(Long.MAX_VALUE)
        if (free < offer.total + 50_000_000) return Response(403, """{"message":"Not enough storage"}""")
        val auto = favorites.value[info.fingerprint] == true
        val accepted = if (auto) true else {
            val f = CompletableFuture<Boolean>()
            decisions[offer.id] = f
            setIncoming(offer)
            onIncoming?.invoke(offer)
            runCatching { f.get(120, TimeUnit.SECONDS) }.getOrDefault(false).also { decisions.remove(offer.id) }
        }
        if (!accepted) { setIncoming(null); return Response.forbidden }
        val current = incoming.value?.takeIf { it.id == offer.id } ?: offer
        if (current.alwaysAccept) setFavorite(info.fingerprint, true)
        val s = Session(current.copy(state = Incoming.State.RECEIVING), files.associate { it.id to UUID.randomUUID().toString() })
        sessions[offer.id] = s
        setIncoming(s.offer)
        if (auto) onIncoming?.invoke(s.offer)
        return Response.json(JSONObject().put("sessionId", offer.id).put("files", JSONObject(s.tokens as Map<*, *>)))
    }

    fun respond(id: String, accept: Boolean, always: Boolean = false) {
        if (always) incoming.update { it?.copy(alwaysAccept = true) }
        decisions[id]?.complete(accept)
    }

    private fun setIncoming(i: Incoming?) { incoming.value = i; onIncomingChanged?.invoke(i) }

    private fun upload(r: Request): Response {
        val s = sessions[r.query["sessionId"]] ?: return Response.forbidden
        val fid = r.query["fileId"] ?: return Response.bad
        if (s.tokens[fid] != r.query["token"]) return Response.forbidden
        val dto = s.offer.files.first { it.id == fid }
        val uri = runCatching { Storage.create(app, Storage.uniqueRoot(app, dto.fileName, s.folders), dto.fileType) }.getOrNull()
            ?: return Response(500, """{"message":"Cannot write"}""")
        try {
            app.contentResolver.openOutputStream(uri)!!.buffered(1 shl 20).use { out ->
                val buf = ByteArray(256 * 1024)
                while (true) {
                    if (s.cancelled) throw TransferException(Phase.CANCELLED, "Cancelled")
                    val n = r.body.read(buf); if (n < 0) break
                    out.write(buf, 0, n)
                    val got = s.received.addAndGet(n.toLong())
                    s.lastActivity = System.currentTimeMillis()
                    if (s.lastActivity - s.lastReport > 100) {
                        s.lastReport = s.lastActivity
                        setIncoming(s.offer.copy(progress = got.toFloat() / maxOf(1L, s.offer.total)))
                    }
                }
            }
            Storage.publish(app, uri)
            s.saved += uri
        } catch (e: Exception) {
            runCatching { app.contentResolver.delete(uri, null, null) }
            if (!s.cancelled) { sessions.remove(s.offer.id); finishIncoming(s, "Transfer interrupted") }
            return Response(500, """{"message":"Upload failed"}""")
        }
        s.pending.remove(fid)
        if (s.pending.isEmpty() && sessions.remove(s.offer.id) != null) finishIncoming(s, null)
        return Response.ok
    }

    private fun finishIncoming(s: Session, error: String?) {
        val done = s.offer.copy(state = if (error == null) Incoming.State.DONE else Incoming.State.FAILED,
            progress = 1f, saved = s.saved.toList(), error = error)
        setIncoming(done)
        onIncoming?.invoke(done)
        if (error == null) addHistory(HistoryEntry(false,
            if (done.files.size == 1) done.files[0].fileName.substringAfterLast('/') else "${done.files.size} items",
            done.senderAlias, System.currentTimeMillis(), done.saved.firstOrNull()?.toString()))
    }

    // ---------------------------------------------------------------- send

    fun send(peer: Peer, items: List<OutItem>) {
        if (items.isEmpty() || transfers.value[peer.id]?.first?.active == true) return
        setPhase(peer.id, Phase.WAITING, 0f)
        sendTasks[peer.id] = io.submit {
            val phase = try { doSend(peer, items); Phase.DONE }
            catch (e: TransferException) { android.util.Log.w("SwiftDrop", "send to ${peer.alias}: ${e.message}"); e.kind }
            catch (e: InterruptedException) { Phase.CANCELLED }
            catch (e: Exception) { android.util.Log.w("SwiftDrop", "send to ${peer.alias} failed", e); Phase.FAILED }
            setPhase(peer.id, phase, if (phase == Phase.DONE) 1f else 0f, force = true)
            if (phase == Phase.DONE) addHistory(HistoryEntry(true,
                if (items.size == 1) items[0].name.substringAfterLast('/') else "${items.size} items", peer.alias, System.currentTimeMillis(), null))
            io.execute { Thread.sleep(8000); transfers.update { m -> if (m[peer.id]?.first?.terminal == true) m - peer.id else m } }
        }
    }

    fun cancel(peerId: String) { sendTasks[peerId]?.cancel(true) }

    private fun setPhase(id: String, p: Phase, f: Float, force: Boolean = false) =
        transfers.update { m -> if (!force && m[id]?.first?.terminal == true) m else m + (id to (p to f)) }

    /** Peers found only over Bluetooth: set up Wi‑Fi Direct first, then talk LocalSend over it. */
    private fun resolve(peer: Peer): Peer {
        if (peer.hasLan || !peer.wifiDirect || peer.bleAddress == null) return peer
        val reply = ble?.requestConnect(peer.bleAddress, fingerprint)
            ?: throw TransferException(Phase.FAILED, "Couldn’t reach ${peer.alias} over Bluetooth")
        if (reply.contains("\"wait\"")) throw TransferException(Phase.DECLINED, "${peer.alias} isn’t accepting")
        val ip = wifiDirect?.join(reply) ?: throw TransferException(Phase.FAILED, "Wi‑Fi Direct connection failed")
        val port = runCatching { JSONObject(reply).getInt("p") }.getOrDefault(peer.port)
        android.util.Log.i("SwiftDrop", "sending to ${peer.alias} over Wi‑Fi Direct ($ip)")
        return peer.copy(host = ip, port = port)
    }

    private fun doSend(original: Peer, items: List<OutItem>) {
        val peer = resolve(original)
        val ids = items.map { UUID.randomUUID().toString() }
        val files = JSONObject()
        items.forEachIndexed { i, it -> files.put(ids[i], FileDto(ids[i], it.name, maxOf(0, it.size), it.mime, it.preview).toJson()) }
        val (code, body) = try { Client.postJson("${peer.baseUrl}/api/localsend/v2/prepare-upload",
            JSONObject().put("info", me().toJson()).put("files", files), 600_000) }
            catch (e: Exception) { throw TransferException(Phase.FAILED, "${e.javaClass.simpleName}: ${e.message}") }
        when (code) {
            200 -> {}
            204 -> return
            403 -> throw TransferException(Phase.DECLINED, "Declined")
            else -> throw TransferException(Phase.FAILED, "Error $code")
        }
        val resp = JSONObject(body)
        val sid = resp.getString("sessionId")
        val tokens = resp.getJSONObject("files")
        val total = maxOf(1L, items.sumOf { maxOf(0, it.size) })
        val sent = ConcurrentHashMap<Int, Long>()
        var last = 0L
        setPhase(peer.id, Phase.SENDING, 0f)
        val pool = Executors.newFixedThreadPool(4)
        val order = items.indices.filter { tokens.has(ids[it]) }.sortedByDescending { items[it].size }
        val futures = order.map { i -> pool.submit {
            val url = "${peer.baseUrl}/api/localsend/v2/upload?" + Client.qs("sessionId" to sid, "fileId" to ids[i], "token" to tokens.getString(ids[i]))
            val c = Client.upload(url, items[i].open(), items[i].size, { Thread.currentThread().isInterrupted }) { n ->
                sent[i] = n
                val now = System.currentTimeMillis()
                if (now - last > 50) { last = now; setPhase(peer.id, Phase.SENDING, sent.values.sum().toFloat() / total) }
            }
            if (c != 200) throw TransferException(Phase.FAILED, "Error $c")
        } }
        try { futures.forEach { it.get() } }
        catch (e: Exception) {
            futures.forEach { it.cancel(true) }
            runCatching { Client.postJson("${peer.baseUrl}/api/localsend/v2/cancel?sessionId=$sid", null, 3000) }
            val cause = (e as? java.util.concurrent.ExecutionException)?.cause ?: e
            throw cause as? TransferException ?: TransferException(if (e is InterruptedException) Phase.CANCELLED else Phase.FAILED, cause.message ?: "")
        } finally { pool.shutdownNow() }
    }

    // ---------------------------------------------------------------- history

    private fun addHistory(h: HistoryEntry) {
        history.update { (listOf(h) + it).take(50) }
        val a = JSONArray()
        history.value.forEach { a.put(JSONObject().put("s", it.sent).put("t", it.title).put("d", it.device).put("w", it.time).put("u", it.uri ?: "")) }
        prefs.edit().putString("history", a.toString()).apply()
    }

    fun clearHistory() { history.value = emptyList(); prefs.edit().remove("history").apply() }
}

/** Received files go to Download/SwiftDrop (MediaStore; no storage permission needed). */
object Storage {
    fun create(ctx: Context, rawName: String, mime: String): Uri {
        val parts = rawName.replace('\\', '/').split('/').filter { it.isNotBlank() && it != "." && it != ".." }
        val name = parts.lastOrNull() ?: "File"
        val sub = parts.dropLast(1).joinToString("/")
        val v = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, mime.ifBlank { "application/octet-stream" })
            put(MediaStore.Downloads.RELATIVE_PATH, "Download/SwiftDrop" + if (sub.isEmpty()) "" else "/$sub")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        return ctx.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, v) ?: error("insert failed")
    }

    /** Give each received folder its own name ("Album (2)") instead of merging into an older one. */
    fun uniqueRoot(ctx: Context, rawName: String, map: MutableMap<String, String>): String {
        val parts = rawName.replace('\\', '/').split('/').filter { it.isNotBlank() }
        if (parts.size < 2) return rawName
        val root = parts[0]
        val unique = synchronized(map) {
            map.getOrPut(root) {
                var candidate = root; var i = 2
                while (exists(ctx, "Download/SwiftDrop/$candidate/")) candidate = "$root (${i++})"
                candidate
            }
        }
        return (listOf(unique) + parts.drop(1)).joinToString("/")
    }

    private fun exists(ctx: Context, relPrefix: String): Boolean =
        ctx.contentResolver.query(MediaStore.Downloads.EXTERNAL_CONTENT_URI, arrayOf(MediaStore.Downloads._ID),
            "${MediaStore.Downloads.RELATIVE_PATH} LIKE ?", arrayOf("$relPrefix%"), null)?.use { it.count > 0 } ?: false

    fun publish(ctx: Context, uri: Uri) {
        ctx.contentResolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
    }

    fun stage(ctx: Context, name: String) = File(ctx.cacheDir, "stage/${UUID.randomUUID()}/$name").apply { parentFile?.mkdirs() }
}
