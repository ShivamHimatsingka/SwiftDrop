package com.swiftdrop.android

import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.IBinder
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.swiftdrop.android.core.Engine
import com.swiftdrop.android.core.Incoming
import com.swiftdrop.android.core.ReceiveMode
import com.swiftdrop.android.ui.MainActivity

class SwiftDropApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        Engine.init(this)
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CH_STATUS, "Receiving", NotificationManager.IMPORTANCE_MIN).apply {
            description = "Shown while SwiftDrop is discoverable"; setShowBadge(false) })
        nm.createNotificationChannel(NotificationChannel(CH_INCOMING, "Incoming transfers", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Accept or decline files from nearby devices" })
        if (Engine.mode.value != ReceiveMode.OFF) ReceiverService.start(this)
    }

    companion object { const val CH_STATUS = "status"; const val CH_INCOMING = "incoming" }
}

/**
 * Keeps SwiftDrop discoverable and able to receive with no app open — like
 * AirDrop. Uses a minimal-importance foreground notification (Android requires one).
 */
class ReceiverService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Engine.init(this)
        startForeground(1, statusNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        Engine.ensureStarted()
        Engine.onIncoming = { notifyIncoming(this, it) }
        return START_STICKY
    }

    private fun statusNotification(): Notification =
        Notification.Builder(this, SwiftDropApplication.CH_STATUS)
            .setSmallIcon(Icon.createWithResource(this, R.drawable.ic_tile))
            .setContentTitle("SwiftDrop")
            .setContentText("Discoverable by ${Engine.mode.value.title.lowercase()}")
            .setContentIntent(PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE))
            .setOngoing(true)
            .build()

    companion object {
        fun start(ctx: Context) = runCatching { ctx.startForegroundService(Intent(ctx, ReceiverService::class.java)) }
        fun stop(ctx: Context) = ctx.stopService(Intent(ctx, ReceiverService::class.java))

        fun notifyIncoming(ctx: Context, inc: Incoming) {
            val nm = ctx.getSystemService(NotificationManager::class.java)
            fun action(accept: Boolean, always: Boolean = false) = PendingIntent.getBroadcast(ctx, (if (accept) 1 else 0) + if (always) 2 else 0,
                Intent(ctx, PromptActionReceiver::class.java).putExtra("id", inc.id).putExtra("accept", accept).putExtra("always", always),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val open = PendingIntent.getActivity(ctx, 2, Intent(ctx, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
            val b = Notification.Builder(ctx, SwiftDropApplication.CH_INCOMING)
                .setSmallIcon(Icon.createWithResource(ctx, R.drawable.ic_tile))
                .setContentIntent(open)
                .setCategory(Notification.CATEGORY_MESSAGE)
            when {
                inc.isMessage -> b.setContentTitle("Message from “${inc.senderAlias}”")
                    .setContentText(Engine.message.value?.second).setStyle(Notification.BigTextStyle().bigText(Engine.message.value?.second))
                    .setAutoCancel(true)
                inc.state == Incoming.State.ASKING -> b.setContentTitle("SwiftDrop")
                    .setContentText("“${inc.senderAlias}” would like to share ${inc.noun}.")
                    .addAction(Notification.Action.Builder(null, "Decline", action(false)).build())
                    .addAction(Notification.Action.Builder(null, "Accept", action(true)).build())
                    .addAction(Notification.Action.Builder(null, "Always accept", action(true, true)).build())
                    .setOngoing(true).setTimeoutAfter(120_000)
                inc.state == Incoming.State.RECEIVING -> b.setContentTitle("Receiving ${inc.noun}")
                    .setContentText("From “${inc.senderAlias}”").setProgress(100, (inc.progress * 100).toInt(), inc.progress == 0f)
                    .setOnlyAlertOnce(true).setOngoing(true)
                inc.state == Incoming.State.DONE -> b.setContentTitle("Received ${inc.noun}")
                    .setContentText("From “${inc.senderAlias}” · saved to Downloads/SwiftDrop").setAutoCancel(true)
                    .setContentIntent(PendingIntent.getActivity(ctx, 3, Intent(Intent.ACTION_VIEW).setDataAndType(inc.saved.firstOrNull(),
                        ctx.contentResolver.getType(inc.saved.firstOrNull() ?: return)).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                        PendingIntent.FLAG_IMMUTABLE))
                else -> b.setContentTitle("Couldn’t receive ${inc.noun}").setContentText(inc.error).setAutoCancel(true)
            }
            runCatching { nm.notify(if (inc.isMessage) 3 else 2, b.build()) }
        }
    }
}

class PromptActionReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, i: Intent) {
        Engine.respond(i.getStringExtra("id") ?: return, i.getBooleanExtra("accept", false), i.getBooleanExtra("always", false))
        if (!i.getBooleanExtra("accept", false)) ctx.getSystemService(NotificationManager::class.java).cancel(2)
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, i: Intent) {
        Engine.init(ctx)
        if (Engine.mode.value != ReceiveMode.OFF) ReceiverService.start(ctx)
    }
}

/** Quick Settings tile: tap cycles Off → Everyone → Favorites; long-press opens SwiftDrop. */
class SwiftDropTile : TileService() {
    override fun onStartListening() { render() }

    override fun onClick() {
        Engine.init(this)
        val next = when (Engine.mode.value) {
            ReceiveMode.OFF -> ReceiveMode.EVERYONE; ReceiveMode.EVERYONE -> ReceiveMode.FAVORITES; ReceiveMode.FAVORITES -> ReceiveMode.OFF }
        Engine.setMode(next)
        if (next == ReceiveMode.OFF) ReceiverService.stop(this) else ReceiverService.start(this)
        render()
    }

    private fun render() {
        val t = qsTile ?: return
        Engine.init(this)
        t.state = if (Engine.mode.value == ReceiveMode.OFF) Tile.STATE_INACTIVE else Tile.STATE_ACTIVE
        t.label = "SwiftDrop"
        t.subtitle = Engine.mode.value.title.replace("Receiving ", "")
        t.updateTile()
    }
}
