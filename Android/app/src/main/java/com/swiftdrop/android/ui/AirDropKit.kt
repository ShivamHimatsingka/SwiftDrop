package com.swiftdrop.android.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.swiftdrop.android.core.Phase

/** iOS system palette so the UI reads as AirDrop. */
object IOS {
    val blue = Color(0xFF007AFF)
    val groupedBg = Color(0xFFF2F2F7)
    val card = Color.White
    val label = Color(0xFF000000)
    val secondary = Color(0x993C3C43)
    val separator = Color(0x4A3C3C43)
    val red = Color(0xFFFF3B30)
    val monogramTop = Color(0xFFA8ADBA)
    val monogramBottom = Color(0xFF858A96)
}

fun initials(name: String): String =
    name.split(' ', '-', '_', '’', '\'').filter { it.firstOrNull()?.isLetterOrDigit() == true }
        .take(2).joinToString("") { it.first().uppercase() }.ifEmpty { "?" }

@Composable
fun Avatar(alias: String, phase: Phase = Phase.IDLE, progress: Float = 0f, size: Dp = 64.dp) {
    val ring = size * 0.05f
    val anim by animateFloatAsState(progress, tween(150), label = "p")
    val spin = rememberInfiniteTransition(label = "s").animateFloat(0f, 360f,
        infiniteRepeatable(tween(1100, easing = LinearEasing)), label = "a")
    Box(Modifier.size(size + ring * 4), contentAlignment = Alignment.Center) {
        Box(Modifier.size(size).clip(CircleShape)
            .background(Brush.verticalGradient(listOf(IOS.monogramTop, IOS.monogramBottom))),
            contentAlignment = Alignment.Center) {
            Text(initials(alias), color = Color.White, fontSize = (size.value * 0.38f).sp, fontWeight = FontWeight.Medium)
        }
        if (phase == Phase.WAITING || phase == Phase.SENDING) Canvas(Modifier.size(size + ring * 3)) {
            val w = ring.toPx()
            drawCircle(Color(0x1A000000), style = Stroke(w))
            if (phase == Phase.WAITING) drawArc(IOS.blue, spin.value, 65f, false, style = Stroke(w, cap = StrokeCap.Round))
            else drawArc(IOS.blue, -90f, 360f * anim.coerceIn(0.01f, 1f), false, style = Stroke(w, cap = StrokeCap.Round))
        }
    }
}

@Composable
fun DeviceTile(alias: String, caption: String, phase: Phase, progress: Float, size: Dp = 64.dp, onClick: () -> Unit) {
    val status = when (phase) {
        Phase.IDLE -> caption
        Phase.WAITING -> "Waiting…"
        Phase.SENDING -> if (progress > 0) "Sending… ${(progress * 100).toInt()}%" else "Sending…"
        Phase.DONE -> "Sent"; Phase.DECLINED -> "Declined"; Phase.FAILED -> "Failed"; Phase.CANCELLED -> "Cancelled"
    }
    val color = when (phase) { Phase.IDLE, Phase.CANCELLED -> IOS.secondary; Phase.DECLINED, Phase.FAILED -> IOS.red; else -> IOS.blue }
    Column(Modifier.width(size + 30.dp).clickable(remember { MutableInteractionSource() }, null, enabled = !phase.active, onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Avatar(alias, phase, progress, size)
        Text(alias, fontSize = 12.sp, fontWeight = FontWeight.Medium, maxLines = 2, textAlign = TextAlign.Center,
            overflow = TextOverflow.Ellipsis, color = IOS.label)
        Text(status, fontSize = 11.sp, color = color, maxLines = 1)
    }
}

@Composable
fun Radar(size: Dp = 120.dp, active: Boolean = true) {
    val t = rememberInfiniteTransition(label = "r")
    val phases = (0..2).map { i ->
        t.animateFloat(0f, 1f, infiniteRepeatable(tween(2400, delayMillis = i * 800, easing = LinearEasing), RepeatMode.Restart), label = "r$i")
    }
    Box(Modifier.size(size), contentAlignment = Alignment.Center) {
        if (active) Canvas(Modifier.size(size)) {
            phases.forEach { p ->
                val v = p.value
                drawCircle(IOS.blue.copy(alpha = 0.45f * (1 - v)), radius = this.size.minDimension / 2 * (0.35f + 0.65f * v),
                    center = Offset(this.size.width / 2, this.size.height / 2), style = Stroke(1.5f))
            }
        }
        Box(Modifier.size(size * 0.36f).clip(CircleShape)
            .background(Brush.verticalGradient(listOf(Color(0xFF40A8FF), IOS.blue))), contentAlignment = Alignment.Center) {
            Canvas(Modifier.size(size * 0.18f)) {
                val c = Offset(this.size.width / 2, this.size.height / 2)
                drawCircle(Color.White, radius = this.size.minDimension * 0.12f, center = c)
                for (r in listOf(0.32f, 0.5f)) drawArc(Color.White, -50f, 100f, false,
                    topLeft = Offset(c.x - this.size.minDimension * r, c.y - this.size.minDimension * r),
                    size = androidx.compose.ui.geometry.Size(this.size.minDimension * r * 2, this.size.minDimension * r * 2),
                    style = Stroke(this.size.minDimension * 0.09f, cap = StrokeCap.Round))
                for (r in listOf(0.32f, 0.5f)) drawArc(Color.White, 130f, 100f, false,
                    topLeft = Offset(c.x - this.size.minDimension * r, c.y - this.size.minDimension * r),
                    size = androidx.compose.ui.geometry.Size(this.size.minDimension * r * 2, this.size.minDimension * r * 2),
                    style = Stroke(this.size.minDimension * 0.09f, cap = StrokeCap.Round))
            }
        }
    }
}

@Composable
fun SectionHeader(text: String) =
    Text(text.uppercase(), fontSize = 13.sp, color = IOS.secondary, modifier = Modifier.padding(start = 32.dp, top = 22.dp, bottom = 6.dp))
