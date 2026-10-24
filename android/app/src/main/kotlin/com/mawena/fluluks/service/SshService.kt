package com.mawena.fluluks.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.content.ContextCompat
import com.mawena.fluluks.MainActivity
import com.mawena.fluluks.R
import com.mawena.fluluks.remote.ssh.TerminalInfo
import com.mawena.fluluks.remote.ssh.TerminalSessions
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Ce que décide et dit le service des sessions SSH, sans Android (phase 13, T3). */
object SshServiceLogic {
    const val ACTION_CLOSE_ALL = "com.mawena.fluluks.SSH_CLOSE_ALL"

    /** Valeur de l'extra [MainActivity] posé par la notification : ouvrir Portail sur les sessions. */
    const val OPEN_SESSIONS = "ssh-sessions"

    private fun active(sessions: List<TerminalInfo>) = sessions.filter { it.state != TerminalInfo.CLOSED }

    /** Le service tourne tant qu'une session se connecte ou est ouverte ; une session tombée ne le garde pas. */
    fun shouldRun(sessions: List<TerminalInfo>) = active(sessions).isNotEmpty()

    fun count(sessions: List<TerminalInfo>) = active(sessions).size

    fun title(n: Int) = if (n <= 1) "$n session SSH ouverte" else "$n sessions SSH ouvertes"

    /** Noms des sessions en cours, dans l'ordre d'ouverture, puis le nombre de tunnels ouverts (phase 13, T10). */
    fun text(sessions: List<TerminalInfo>): String {
        val a = active(sessions)
        val names = a.joinToString(", ") { it.title }
        val n = a.sumOf { it.tunnels }
        return when (n) {
            0 -> names
            1 -> "$names · 1 tunnel actif"
            else -> "$names · $n tunnels actifs"
        }
    }

    /** Action d'un intent : « Tout fermer » ferme toutes les sessions ; rend vrai si l'action est connue. */
    fun onAction(action: String?, closeAll: () -> Unit = TerminalSessions::closeAll): Boolean {
        if (action != ACTION_CLOSE_ALL) return false
        closeAll()
        return true
    }
}

/**
 * Service au premier plan tant qu'une session SSH est en cours (phase 13, T3) : les terminaux survivent à la fermeture
 * de l'écran et de l'activité. Notification du canal « Sessions SSH » : toucher ouvre Portail sur les sessions, action
 * « Tout fermer ». Il suit [TerminalSessions.state] et s'arrête avec la dernière session.
 */
class SshService : Service() {
    companion object {
        @Volatile @JvmStatic var running: Boolean = false
        const val EXTRA_OPEN = "com.mawena.fluluks.OPEN"
        private const val CHANNEL_ID = "sessions_ssh"
        private const val NOTIF_ID = 3
        private const val TAG = "SshService"

        /** Démarre le service si une session est en cours et qu'il ne tourne pas déjà. */
        fun startIfNeeded(context: Context) {
            if (running || !SshServiceLogic.shouldRun(TerminalSessions.state.value)) return
            try {
                ContextCompat.startForegroundService(context, Intent(context, SshService::class.java))
            } catch (e: RuntimeException) { // démarrage refusé en arrière-plan : les sessions restent ouvertes
                Log.w(TAG, "service non démarré : ${e.javaClass.simpleName}")
            }
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var lastStartId = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = true
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Sessions SSH", NotificationManager.IMPORTANCE_LOW),
        )
        startAsForeground(TerminalSessions.state.value)
        scope.launch {
            TerminalSessions.state.collect { list ->
                if (SshServiceLogic.shouldRun(list)) {
                    startAsForeground(list)
                } else {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    if (lastStartId > 0) stopSelf(lastStartId) else stopSelf()
                }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStartId = startId
        val list = TerminalSessions.state.value
        // toute commande de démarrage est suivie de startForeground (startForegroundService)
        val ok = startAsForeground(list)
        if (intent?.action == SshServiceLogic.ACTION_CLOSE_ALL) {
            scope.launch { withContext(Dispatchers.IO) { SshServiceLogic.onAction(intent.action) } }
        } else if (!ok || !SshServiceLogic.shouldRun(list)) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        scope.cancel()
        super.onDestroy()
    }

    /** Type « specialUse » dès Android 14 ; avant, le type du manifeste suffit. */
    private fun startAsForeground(list: List<TerminalInfo>): Boolean = try {
        val n = notification(list)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIF_ID, n)
        }
        true
    } catch (e: RuntimeException) {
        Log.w(TAG, "service au premier plan impossible : ${e.javaClass.simpleName}")
        false
    }

    private fun notification(list: List<TerminalInfo>): Notification {
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(EXTRA_OPEN, SshServiceLogic.OPEN_SESSIONS),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val closeAll = PendingIntent.getService(
            this, 1, Intent(this, SshService::class.java).setAction(SshServiceLogic.ACTION_CLOSE_ALL),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_portail)
            .setContentTitle(SshServiceLogic.title(SshServiceLogic.count(list)))
            .setContentText(SshServiceLogic.text(list))
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Tout fermer", closeAll).build())
            .build()
    }
}
