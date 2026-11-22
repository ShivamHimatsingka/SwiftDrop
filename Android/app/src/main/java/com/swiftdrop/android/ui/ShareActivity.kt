package com.swiftdrop.android.ui

import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Size
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.swiftdrop.android.core.*

/** Share ▸ SwiftDrop: an AirDrop-style sheet floating over the app you shared from. */
class ShareActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Engine.init(this)
        val items = collect(intent)
        val thumb = intentUris(intent).firstOrNull()?.let { u ->
            runCatching { contentResolver.loadThumbnail(u, Size(200, 200), null) }.getOrNull()
        }
        Engine.refresh(deep = true)
        setContent { MaterialTheme(colorScheme = lightColorScheme(primary = IOS.blue)) { Sheet(items, thumb) { finish() } } }
    }

    private fun intentUris(i: Intent): List<Uri> = when (i.action) {
        Intent.ACTION_SEND -> listOfNotNull(if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                              else @Suppress("DEPRECATION") i.getParcelableExtra(Intent.EXTRA_STREAM))
        Intent.ACTION_SEND_MULTIPLE -> (if (Build.VERSION.SDK_INT >= 33) i.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                              else @Suppress("DEPRECATION") i.getParcelableArrayListExtra(Intent.EXTRA_STREAM)) ?: emptyList()
        else -> emptyList()
    }

    private fun collect(i: Intent): List<OutItem> {
        val uris = intentUris(i)
        val out = uris.map { outItem(this, it) }.toMutableList()
        if (uris.isEmpty()) i.getStringExtra(Intent.EXTRA_TEXT)?.let { out += textItem(it) }
        return out
    }
}

@Composable
private fun Sheet(items: List<OutItem>, thumb: Bitmap?, close: () -> Unit) {
    val peers by Engine.peers.collectAsState()
    val transfers by Engine.transfers.collectAsState()
    val mine = remember { mutableStateListOf<String>() }
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { shown = true }
    val anySent = mine.any { transfers[it]?.first == Phase.DONE }
    val anyActive = mine.any { transfers[it]?.first?.active == true }

    Box(Modifier.fillMaxSize().clickable(remember { MutableInteractionSource() }, null) { if (!anyActive) close() },
        contentAlignment = Alignment.BottomCenter) {
        AnimatedVisibility(shown, enter = slideInVertically { it }) {
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)).background(Color.White)
                .clickable(remember { MutableInteractionSource() }, null) {}.navigationBarsPadding().padding(bottom = 12.dp)) {
                Box(Modifier.padding(top = 8.dp).size(36.dp, 5.dp).clip(RoundedCornerShape(3.dp)).background(Color(0xFFD1D1D6)).align(Alignment.CenterHorizontally))
                Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                    Text("SwiftDrop", fontWeight = FontWeight.SemiBold, fontSize = 17.sp, modifier = Modifier.align(Alignment.Center))
                    Text(if (anySent || anyActive) "Done" else "Cancel", color = IOS.blue, fontSize = 17.sp,
                        fontWeight = if (anySent) FontWeight.SemiBold else FontWeight.Normal,
                        modifier = Modifier.align(Alignment.CenterEnd).clickable { mine.forEach { if (!anySent) Engine.cancel(it) }; close() })
                }
                Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(52.dp).clip(RoundedCornerShape(10.dp)).background(IOS.groupedBg), contentAlignment = Alignment.Center) {
                        if (thumb != null) Image(thumb.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                        else Text(if (items.firstOrNull()?.preview != null) "Aa" else "📄", fontSize = 20.sp)
                    }
                    Column(Modifier.padding(start = 12.dp)) {
                        Text(if (items.size == 1) items[0].preview?.take(40) ?: items[0].name else "${items.size} Items",
                            fontWeight = FontWeight.SemiBold, fontSize = 16.sp, maxLines = 1)
                        Text("Choose a person to share with", fontSize = 14.sp, color = IOS.secondary)
                    }
                }
                Box(Modifier.fillMaxWidth().height(250.dp), contentAlignment = Alignment.Center) {
                    if (peers.isEmpty()) Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Radar(120.dp)
                        Text("Looking for people nearby…", fontWeight = FontWeight.Medium, fontSize = 15.sp)
                        Text("They need SwiftDrop or LocalSend on the same Wi‑Fi.", fontSize = 13.sp, color = IOS.secondary)
                    } else LazyVerticalGrid(GridCells.Adaptive(100.dp), Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp),
                        verticalArrangement = Arrangement.spacedBy(18.dp)) {
                        items(peers, key = { it.id }) { p ->
                            val t = transfers[p.id]
                            Box(contentAlignment = Alignment.Center) {
                                DeviceTile(p.alias, p.caption, t?.first ?: Phase.IDLE, t?.second ?: 0f, 72.dp) {
                                    mine += p.id; Engine.send(p, items)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
