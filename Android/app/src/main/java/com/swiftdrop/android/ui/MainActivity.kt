package com.swiftdrop.android.ui

import android.Manifest
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import com.swiftdrop.android.ReceiverService
import com.swiftdrop.android.core.*
import java.text.DateFormat

/** SwiftDrop's one screen, modelled on iOS Settings ▸ General ▸ AirDrop. */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        Engine.init(this)
        if (Engine.mode.value != ReceiveMode.OFF) ReceiverService.start(this)
        val perms = mutableListOf(Manifest.permission.POST_NOTIFICATIONS)
        if (android.os.Build.VERSION.SDK_INT >= 31) perms += listOf(Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT)
        else perms += Manifest.permission.ACCESS_FINE_LOCATION
        if (android.os.Build.VERSION.SDK_INT >= 33) perms += Manifest.permission.NEARBY_WIFI_DEVICES
        else if (android.os.Build.VERSION.SDK_INT >= 31) perms += Manifest.permission.ACCESS_FINE_LOCATION
        requestPermissions(perms.toTypedArray(), 1)
        // Receiving with the screen off needs SwiftDrop exempt from battery optimisation (Doze).
        val pm = getSystemService(android.os.PowerManager::class.java)
        if (!pm.isIgnoringBatteryOptimizations(packageName)) runCatching {
            startActivity(android.content.Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                android.net.Uri.parse("package:$packageName")))
        }
        setContent { MaterialTheme(colorScheme = lightColorScheme(primary = IOS.blue)) { Home() } }
        testSend(intent)
    }

    override fun onResume() { super.onResume(); Engine.refresh() }

    override fun onNewIntent(intent: android.content.Intent) { super.onNewIntent(intent); testSend(intent) }

    /** Debug builds only: am start ... --es testSendTo "<alias>" --es testFiles "<path>|<path>" --es testText "…" */
    private fun testSend(i: android.content.Intent) {
        if (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE == 0) return
        val to = i.getStringExtra("testSendTo") ?: return
        val files = i.getStringExtra("testFiles")?.split('|')?.filter { it.isNotBlank() } ?: emptyList()
        val text = i.getStringExtra("testText")
        Thread {
            repeat(60) {
                val p = Engine.peers.value.firstOrNull { it.alias == to }
                if (p != null) {
                    val items = files.map { path -> val f = java.io.File(path)
                        OutItem(f.name, f.length(), "application/octet-stream", { f.inputStream() }) } +
                        listOfNotNull(text?.let { textItem(it) })
                    Engine.send(p, items); return@Thread
                }
                Thread.sleep(500)
            }
        }.start()
    }

    override fun onRequestPermissionsResult(code: Int, perms: Array<String>, results: IntArray) {
        super.onRequestPermissionsResult(code, perms, results)
        Engine.restartBluetooth()
    }
}

@Composable
private fun Home() {
    val ctx = LocalContext.current
    val mode by Engine.mode.collectAsState()
    val peers by Engine.peers.collectAsState()
    val transfers by Engine.transfers.collectAsState()
    val history by Engine.history.collectAsState()
    val favorites by Engine.favorites.collectAsState()
    var target by remember { mutableStateOf<Peer?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        target?.let { t -> if (uris.isNotEmpty()) Engine.send(t, uris.map { outItem(ctx, it) }) }
        target = null
    }

    LazyColumn(Modifier.fillMaxSize().background(IOS.groupedBg).statusBarsPadding(), contentPadding = PaddingValues(bottom = 40.dp)) {
        item { Text("SwiftDrop", fontSize = 34.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = 20.dp, top = 24.dp)) }
        item {
            Column(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Radar(120.dp, active = mode != ReceiveMode.OFF)
                Text("SwiftDrop lets you share instantly with people nearby — Macs, iPhones, Windows and Linux.",
                    fontSize = 13.sp, color = IOS.secondary, textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 40.dp))
            }
        }
        item { SectionHeader("Allow me to be discovered by") }
        item {
            Card {
                ReceiveMode.entries.forEachIndexed { i, m ->
                    Row(Modifier.fillMaxWidth().clickable {
                        Engine.setMode(m)
                        if (m == ReceiveMode.OFF) ReceiverService.stop(ctx) else ReceiverService.start(ctx)
                    }.padding(horizontal = 16.dp, vertical = 13.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(m.title, fontSize = 17.sp, modifier = Modifier.weight(1f))
                        if (mode == m) Text("✓", color = IOS.blue, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                    }
                    if (i < 2) HorizontalDivider(Modifier.padding(start = 16.dp), color = IOS.separator, thickness = 0.5.dp)
                }
            }
            Text("Receives in the background — use the SwiftDrop Quick Settings tile to switch it on or off without opening anything.",
                fontSize = 13.sp, color = IOS.secondary, modifier = Modifier.padding(horizontal = 32.dp, vertical = 6.dp))
        }
        item { SectionHeader("Nearby") }
        item {
            Card {
                if (peers.isEmpty()) Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = IOS.secondary)
                    Text("  Looking for people nearby…", color = IOS.secondary, fontSize = 15.sp)
                } else LazyRow(contentPadding = PaddingValues(12.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    items(peers, key = { it.id }) { p ->
                        val t = transfers[p.id]
                        DeviceTile(p.alias + if (favorites.containsKey(p.id)) " ★" else "", p.caption,
                            t?.first ?: Phase.IDLE, t?.second ?: 0f) { target = p; picker.launch(arrayOf("*/*")) }
                    }
                }
            }
            Row(Modifier.padding(horizontal = 32.dp, vertical = 6.dp)) {
                Text("Search again", color = IOS.blue, fontSize = 13.sp, modifier = Modifier.clickable { Engine.refresh(deep = true) })
                Spacer(Modifier.width(16.dp))
                val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                if (peers.isNotEmpty()) Text("Send clipboard to ${peers.first().alias}", color = IOS.blue, fontSize = 13.sp,
                    modifier = Modifier.clickable {
                        cm.primaryClip?.getItemAt(0)?.coerceToText(ctx)?.toString()?.let { txt -> Engine.send(peers.first(), listOf(textItem(txt))) }
                    })
            }
        }
        if (history.isNotEmpty()) {
            item { SectionHeader("Recent") }
            item {
                Card {
                    history.take(8).forEachIndexed { i, h ->
                        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(if (h.sent) "↑" else "↓", color = IOS.blue, fontSize = 20.sp, modifier = Modifier.width(26.dp))
                            Column(Modifier.weight(1f)) {
                                Text(h.title, fontSize = 16.sp, maxLines = 1)
                                Text("${if (h.sent) "To" else "From"} ${h.device} · ${DateFormat.getTimeInstance(DateFormat.SHORT).format(h.time)}",
                                    fontSize = 13.sp, color = IOS.secondary)
                            }
                        }
                        if (i < minOf(7, history.size - 1)) HorizontalDivider(Modifier.padding(start = 58.dp), color = IOS.separator, thickness = 0.5.dp)
                    }
                }
            }
        }
        item { SectionHeader("Name") }
        item {
            var name by remember { mutableStateOf(Engine.deviceName) }
            Card {
                androidx.compose.foundation.text.BasicTextField(name, { name = it; Engine.deviceName = it },
                    singleLine = true, textStyle = LocalTextStyle.current.copy(fontSize = 17.sp),
                    modifier = Modifier.fillMaxWidth().padding(16.dp))
            }
        }
    }
    IncomingOverlay()
}

@Composable
fun Card(content: @Composable ColumnScope.() -> Unit) =
    Column(Modifier.padding(horizontal = 16.dp).fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(IOS.card), content = content)

/** AirDrop accept card + message alert while the app is open. */
@Composable
fun IncomingOverlay() {
    val inc by Engine.incoming.collectAsState()
    val msg by Engine.message.collectAsState()
    val ctx = LocalContext.current
    inc?.takeIf { it.state != Incoming.State.DONE || true }?.let { i ->
        Dialog(onDismissRequest = { if (i.state != Incoming.State.ASKING && i.state != Incoming.State.RECEIVING) Engine.incoming.value = null }) {
            Column(Modifier.clip(RoundedCornerShape(28.dp)).background(Color.White).padding(24.dp).fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Text("SwiftDrop", fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
                Avatar(i.senderAlias, if (i.state == Incoming.State.RECEIVING) Phase.SENDING else Phase.IDLE, i.progress, 72.dp)
                Text(when (i.state) {
                    Incoming.State.ASKING -> "“${i.senderAlias}” would like to share ${i.noun}."
                    Incoming.State.RECEIVING -> "Receiving ${i.noun} from “${i.senderAlias}”…"
                    Incoming.State.DONE -> "Saved ${i.noun} to Downloads/SwiftDrop."
                    Incoming.State.FAILED -> i.error ?: "Transfer failed"
                }, textAlign = TextAlign.Center, fontSize = 15.sp)
                when (i.state) {
                    Incoming.State.ASKING -> {
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            PillButton("Decline", false, Modifier.weight(1f)) { Engine.respond(i.id, false) }
                            PillButton("Accept", true, Modifier.weight(1f)) { Engine.respond(i.id, true) }
                        }
                        Text("Always accept from this device", color = IOS.blue, fontSize = 13.sp,
                            modifier = Modifier.clickable { Engine.respond(i.id, true, always = true) })
                    }
                    Incoming.State.RECEIVING -> {}
                    else -> PillButton("Done", true, Modifier.fillMaxWidth()) { Engine.incoming.value = null }
                }
            }
        }
    }
    msg?.let { (from, text) ->
        AlertDialog(onDismissRequest = { Engine.message.value = null },
            title = { Text("Message from “$from”") }, text = { Text(text) },
            confirmButton = { TextButton({
                (ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
                    .setPrimaryClip(android.content.ClipData.newPlainText("SwiftDrop", text)); Engine.message.value = null }) { Text("Copy") } },
            dismissButton = { TextButton({ Engine.message.value = null }) { Text("Close") } })
    }
}

@Composable
fun PillButton(text: String, primary: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) =
    Box(modifier.clip(RoundedCornerShape(14.dp)).background(if (primary) IOS.blue else Color(0xFFE9E9EB)).clickable(onClick = onClick)
        .padding(vertical = 13.dp, horizontal = 20.dp), contentAlignment = Alignment.Center) {
        Text(text, color = if (primary) Color.White else IOS.blue, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
    }

fun outItem(ctx: Context, uri: Uri): OutItem {
    var name = uri.lastPathSegment ?: "File"
    var size = -1L
    ctx.contentResolver.query(uri, null, null, null, null)?.use { c ->
        if (c.moveToFirst()) {
            val n = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME); if (n >= 0) name = c.getString(n) ?: name
            val s = c.getColumnIndex(android.provider.OpenableColumns.SIZE); if (s >= 0 && !c.isNull(s)) size = c.getLong(s)
        }
    }
    val mime = ctx.contentResolver.getType(uri) ?: "application/octet-stream"
    if (!name.contains('.')) android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)?.let { name = "$name.$it" }
    return OutItem(name, size, mime, { ctx.contentResolver.openInputStream(uri)!! })
}

fun textItem(text: String) = OutItem("${java.util.UUID.randomUUID().toString().take(8)}.txt", text.toByteArray().size.toLong(),
    "text/plain", { text.byteInputStream() }, preview = text)
