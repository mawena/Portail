package com.mawena.fluluks.ai.auto

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.annotation.VisibleForTesting
import androidx.room.Room
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.mawena.fluluks.MainActivity
import com.mawena.fluluks.R
import com.mawena.fluluks.ai.Ai
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.files.FilesException
import java.util.concurrent.TimeUnit

/**
 * Exécution planifiée d'une automatisation (phase 15, T8) : valeurs par défaut, réponse entière, notée dans
 * l'historique ; une notification discrète à la fin (titre seulement). Un délai ou une erreur 5xx au premier essai est
 * repris une fois par WorkManager ; tout autre échec est noté sans reprise.
 */
class AutomationWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val id = inputData.getLong(KEY_ID, -1)
        Ai.init(applicationContext)
        Autos.init(applicationContext)
        val o = Autos.get().executeScheduled(id, runAttemptCount)
        val run = o.run ?: return Result.success()
        if (o.retry) return Result.retry()
        AutomationNotifier.finished(applicationContext, o.automation!!, run)
        return Result.success()
    }

    companion object {
        const val KEY_ID = "automationId"
        const val TAG = "automation"

        fun uniqueName(automationId: Long) = "automation-$automationId"
    }
}

/** Planification par WorkManager : travail périodique unique par automatisation, réseau requis. */
class WorkManagerScheduler(private val context: Context) : AutomationScheduler {
    override fun schedule(a: Automation) {
        val every = (a.intervalMinutes ?: Automations.MIN_INTERVAL).toLong()
        val req = PeriodicWorkRequestBuilder<AutomationWorker>(every, TimeUnit.MINUTES)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.LINEAR, RETRY_MINUTES, TimeUnit.MINUTES)
            .setInputData(workDataOf(AutomationWorker.KEY_ID to a.id))
            .addTag(AutomationWorker.TAG)
            .build()
        WorkManager.getInstance(context)
            .enqueueUniquePeriodicWork(AutomationWorker.uniqueName(a.id), ExistingPeriodicWorkPolicy.UPDATE, req)
    }

    override fun cancel(automationId: Long) {
        WorkManager.getInstance(context).cancelUniqueWork(AutomationWorker.uniqueName(automationId))
    }

    companion object {
        /** Délai avant la reprise unique d'un délai dépassé ou d'une erreur 5xx. */
        const val RETRY_MINUTES = 5L
    }
}

/**
 * Fin d'une exécution planifiée : « Automatisation « Nom » terminée » ou « … a échoué », sans le résultat ; sur l'écran
 * verrouillé, seulement « Automatisation terminée ». Rien si les notifications sont refusées.
 */
object AutomationNotifier {
    const val CHANNEL_ID = "automations"
    private const val BASE_ID = 40_000

    fun finished(context: Context, a: Automation, run: AutomationRun) {
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Automatisations", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val public = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_portail)
            .setContentTitle(MSG_PUBLIC)
            .build()
        val n = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_portail)
            .setContentTitle(title(a.name, run.state == AutomationRun.DONE))
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(public)
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        nm.notify(BASE_ID + (a.id % 10_000).toInt(), n)
    }

    fun title(name: String, ok: Boolean) =
        if (ok) "Automatisation « $name » terminée" else "Automatisation « $name » en échec"

    const val MSG_PUBLIC = "Automatisation terminée"
}

/**
 * Automatisations de l'application : `automations.db`, ouverte une fois par processus (l'application et les
 * exécutions planifiées). Les exécutions interrompues par l'arrêt précédent sont retrouvées au premier accès.
 */
object Autos {
    @Volatile private var autos: Automations? = null
    @Volatile private var recovered = false

    @Synchronized
    fun init(context: Context) {
        if (autos != null) return
        val app = context.applicationContext
        val db = Room.databaseBuilder(app, AutomationDatabase::class.java, AutomationDatabase.NAME).build()
        autos = Automations(
            dao = db.automationDao(),
            servers = { Ai.servers().list() },
            providerFor = { id -> Ai.servers().provider(id) },
            scheduler = WorkManagerScheduler(app),
            tx = { block -> db.runInTransaction(block) },
        )
    }

    fun get(): Automations {
        val a = autos ?: throw FilesException(EngineError.FL_ENODEV, "Automatisations indisponibles")
        if (!recovered) {
            synchronized(this) {
                if (!recovered) {
                    a.recoverInterrupted()
                    recovered = true
                }
            }
        }
        return a
    }

    @VisibleForTesting
    fun resetForTests(a: Automations?) {
        autos = a
        recovered = true
    }
}
