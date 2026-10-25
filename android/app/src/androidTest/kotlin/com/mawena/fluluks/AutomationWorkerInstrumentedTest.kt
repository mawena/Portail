package com.mawena.fluluks

import androidx.room.Room
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.work.Configuration
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.testing.SynchronousExecutor
import androidx.work.testing.WorkManagerTestInitHelper
import com.mawena.fluluks.ai.AiServerConfig
import com.mawena.fluluks.ai.OpenAiCompatibleProvider
import com.mawena.fluluks.ai.auto.Automation
import com.mawena.fluluks.ai.auto.AutomationDatabase
import com.mawena.fluluks.ai.auto.AutomationRun
import com.mawena.fluluks.ai.auto.AutomationVar
import com.mawena.fluluks.ai.auto.AutomationWorker
import com.mawena.fluluks.ai.auto.Automations
import com.mawena.fluluks.ai.auto.Autos
import com.mawena.fluluks.ai.auto.WorkManagerScheduler
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Automatisations planifiées par le vrai WorkManager (phase 15, T8), sur le Pixel, contre le serveur d'essai joint par
 * `adb reverse` (`tools/ia/serveur-essai.py --reverse`, port 8765, clé `essai-portail`) : planification unique par
 * automatisation, réseau requis, exécution notée dans l'historique, annulation à la désactivation, à la suppression et à
 * la suppression du serveur.
 */
@RunWith(AndroidJUnit4::class)
class AutomationWorkerInstrumentedTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val db = Room.inMemoryDatabaseBuilder(context, AutomationDatabase::class.java).build()
    private val servers = mutableListOf(
        AiServerConfig("s1", "Essai", "http://127.0.0.1:8765", hasKey = true, isDefault = true, defaultModel = "essai-court"),
    )
    private lateinit var autos: Automations

    @Before fun setUp() {
        WorkManagerTestInitHelper.initializeTestWorkManager(
            context,
            Configuration.Builder().setExecutor(SynchronousExecutor()).build(),
        )
        autos = Automations(
            dao = db.automationDao(),
            servers = { servers.toList() },
            providerFor = { id ->
                val c = servers.first { it.id == id }
                OpenAiCompatibleProvider(c.baseUrl, "essai-portail".toByteArray())
            },
            scheduler = WorkManagerScheduler(context),
            tx = { db.runInTransaction(it) },
        )
        Autos.resetForTests(autos)
    }

    @After fun tearDown() {
        Autos.resetForTests(null)
        db.close()
    }

    private fun periodic() = autos.save(
        Automation(
            name = "Essai planifié", template = "Dis bonjour à {{nom}} le {{date}}", variables = "", serverId = "s1",
            model = "essai-court", systemPrompt = null, trigger = Automation.PERIODIC, intervalMinutes = 15, enabled = true,
            createdAt = 0, updatedAt = 0,
        ),
        listOf(AutomationVar("nom", "Portail")),
    )

    private fun work(id: Long): WorkInfo =
        WorkManager.getInstance(context).getWorkInfosForUniqueWork(AutomationWorker.uniqueName(id)).get().single()

    private fun waitFor(what: String, cond: () -> Boolean) {
        val end = System.currentTimeMillis() + 30_000
        while (!cond()) {
            if (System.currentTimeMillis() > end) fail("attendu : $what")
            Thread.sleep(50)
        }
    }

    @Test fun scheduledOnceWithNetworkAndRunWrittenToHistory() {
        val a = periodic()
        val w = work(a.id)
        assertEquals(WorkInfo.State.ENQUEUED, w.state)
        assertTrue(w.tags.contains(AutomationWorker.TAG))
        assertEquals(androidx.work.NetworkType.CONNECTED, w.constraints.requiredNetworkType)
        assertEquals(15 * 60_000L, w.periodicityInfo!!.repeatIntervalMillis)

        // réenregistrée : la même planification est mise à jour, pas doublée
        autos.save(a.copy(intervalMinutes = 30), autos.variablesOf(a))
        assertEquals(30 * 60_000L, work(a.id).periodicityInfo!!.repeatIntervalMillis)

        val driver = WorkManagerTestInitHelper.getTestDriver(context)!!
        driver.setAllConstraintsMet(work(a.id).id)
        driver.setPeriodDelayMet(work(a.id).id)
        waitFor("une exécution terminée") { autos.runs(a.id).any { it.state != AutomationRun.RUNNING } }
        val run = autos.runs(a.id).first()
        assertEquals(AutomationRun.DONE, run.state)
        assertTrue(run.scheduled)
        assertTrue(run.input.startsWith("Dis bonjour à Portail le "))
        assertFalse(run.output.isNullOrEmpty())
    }

    @Test fun disabledDeletedOrServerDeletedCancelsWork() {
        val a = periodic()
        autos.setEnabled(a.id, false)
        assertEquals(WorkInfo.State.CANCELLED, work(a.id).state)
        autos.setEnabled(a.id, true)
        assertEquals(WorkInfo.State.ENQUEUED, work(a.id).state)
        autos.serverDeleted("s1")
        assertEquals(WorkInfo.State.CANCELLED, work(a.id).state)
        val b = periodic()
        autos.delete(b.id)
        assertEquals(WorkInfo.State.CANCELLED, work(b.id).state)
    }
}
