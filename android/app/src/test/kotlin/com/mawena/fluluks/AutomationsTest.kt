package com.mawena.fluluks

import com.mawena.fluluks.ai.AiException
import com.mawena.fluluks.ai.AiServerConfig
import com.mawena.fluluks.ai.AiServers
import com.mawena.fluluks.ai.OpenAiCompatibleProvider
import com.mawena.fluluks.ai.auto.Automation
import com.mawena.fluluks.ai.auto.AutomationDao
import com.mawena.fluluks.ai.auto.AutomationRun
import com.mawena.fluluks.ai.auto.AutomationScheduler
import com.mawena.fluluks.ai.auto.AutomationSink
import com.mawena.fluluks.ai.auto.AutomationVar
import com.mawena.fluluks.ai.auto.Automations
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.files.FilesException
import java.time.LocalDateTime
import java.util.Collections
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Automatisations (phase 15, T8) : enregistrement et planification, lancement manuel en flux, exécution planifiée sans
 * flux, échecs sans reprise en boucle, historique ; logique de [Automations] sur une base en mémoire simulée et contre
 * MockWebServer. WorkManager lui-même est vérifié par `AutomationWorkerInstrumentedTest`.
 */
class AutomationsTest {
    /** DAO en mémoire, mêmes règles que les requêtes de [AutomationDao]. */
    class MemAutomationDao : AutomationDao {
        val autos = linkedMapOf<Long, Automation>()
        val runsById = linkedMapOf<Long, AutomationRun>()
        private var nextA = 1L
        private var nextR = 1L

        @Synchronized override fun automations() = autos.values.sortedBy { it.id }
        @Synchronized override fun automation(id: Long) = autos[id]
        @Synchronized override fun automationsOf(serverId: String) = autos.values.filter { it.serverId == serverId }
        @Synchronized override fun count() = autos.size
        @Synchronized override fun insertAutomation(a: Automation): Long = nextA++.also { autos[it] = a.copy(id = it) }
        @Synchronized override fun updateAutomation(a: Automation) {
            if (a.id in autos) autos[a.id] = a
        }
        @Synchronized override fun deleteAutomation(id: Long): Int {
            runsById.values.removeAll { it.automationId == id }
            return if (autos.remove(id) != null) 1 else 0
        }
        @Synchronized override fun runs(automationId: Long) = runsById.values.filter { it.automationId == automationId }.sortedByDescending { it.id }
        @Synchronized override fun run(id: Long) = runsById[id]
        @Synchronized override fun lastRun(automationId: Long) = runs(automationId).firstOrNull()
        @Synchronized override fun insertRun(r: AutomationRun): Long = nextR++.also { runsById[it] = r.copy(id = it) }
        @Synchronized override fun updateRun(r: AutomationRun) {
            if (r.id in runsById) runsById[r.id] = r
        }
        @Synchronized override fun deleteRuns(automationId: Long) {
            runsById.values.removeAll { it.automationId == automationId }
        }
        @Synchronized override fun pruneRuns(automationId: Long, keep: Int) {
            val kept = runs(automationId).take(keep).map { it.id }.toSet()
            runsById.values.removeAll { it.automationId == automationId && it.id !in kept }
        }
        @Synchronized override fun markInterrupted(error: String, at: Long): Int {
            var n = 0
            for ((k, r) in runsById) {
                if (r.state == AutomationRun.RUNNING) {
                    runsById[k] = r.copy(state = AutomationRun.INTERRUPTED, error = error, endedAt = at)
                    n++
                }
            }
            return n
        }
    }

    private class RecScheduler : AutomationScheduler {
        val events: MutableList<String> = Collections.synchronizedList(mutableListOf())
        override fun schedule(a: Automation) {
            events += "schedule ${a.id} ${a.intervalMinutes}"
        }
        override fun cancel(automationId: Long) {
            events += "cancel $automationId"
        }
    }

    private class RecSink : AutomationSink {
        val deltas: MutableList<String> = Collections.synchronizedList(mutableListOf())
        val states: MutableList<AutomationRun> = Collections.synchronizedList(mutableListOf())
        override fun delta(runId: Long, text: String, delivered: () -> Unit) {
            deltas += text
            delivered()
        }
        override fun state(r: AutomationRun) {
            states += r
        }
    }

    private val server = MockWebServer().apply { start() }
    private val dao = MemAutomationDao()
    private val scheduler = RecScheduler()
    private val sink = RecSink()
    private var clock = 1_000L
    private val servers = mutableListOf(
        AiServerConfig("s1", "Essai", server.url("/").toString().trimEnd('/'), isDefault = true, defaultModel = "essai-court"),
        AiServerConfig("s2", "Autre", server.url("/").toString().trimEnd('/'), defaultModel = "essai-long"),
    )
    private val autos = Automations(
        dao = dao,
        servers = { servers.toList() },
        providerFor = { id ->
            val c = servers.firstOrNull { it.id == id } ?: throw FilesException(EngineError.FL_ENOENT, AiServers.MSG_GONE)
            OpenAiCompatibleProvider(c.baseUrl, null)
        },
        scheduler = scheduler,
        tx = { synchronized(dao) { it() } },
        now = { synchronized(this) { clock++ } },
        clock = { LocalDateTime.of(2026, 10, 25, 9, 5) },
    ).also { it.sink = sink }

    @After fun tearDown() = server.shutdown()

    private fun auto(
        name: String = "Météo",
        template: String = "Météo à {{ville}} le {{date}}",
        trigger: String = Automation.MANUAL,
        interval: Int? = null,
        serverId: String? = "s1",
        model: String? = "essai-court",
        systemPrompt: String? = null,
        enabled: Boolean = true,
    ) = Automation(
        name = name, template = template, variables = "", serverId = serverId, model = model, systemPrompt = systemPrompt,
        trigger = trigger, intervalMinutes = interval, enabled = enabled, createdAt = 0, updatedAt = 0,
    )

    private val ville = listOf(AutomationVar("ville", "Lomé"))

    private fun refused(code: Int, block: () -> Unit): String {
        try {
            block()
        } catch (e: FilesException) {
            assertEquals(code, e.code)
            return e.message!!
        }
        fail("refus attendu")
        error("")
    }

    private fun completion(text: String) = MockResponse().setHeader("Content-Type", "application/json")
        .setBody(JSONObject().put("choices", org.json.JSONArray().put(JSONObject().put("message", JSONObject().put("role", "assistant").put("content", text)))).toString())

    private fun sse(vararg parts: String) = MockResponse().setHeader("Content-Type", "text/event-stream").setBody(
        parts.joinToString("") { "data: {\"choices\":[{\"delta\":{\"content\":${JSONObject.quote(it)}}}]}\n\n" } + "data: [DONE]\n\n",
    )

    private fun Automations.await(runId: Long) = runBlocking { withTimeout(20_000) { job(runId)?.join() } }

    // --- enregistrement et planification

    @Test fun manualSavedWithoutScheduling() {
        val a = autos.save(auto(), ville)
        assertTrue(a.id > 0)
        assertEquals(ville, autos.variablesOf(a))
        assertTrue(scheduler.events.none { it.startsWith("schedule") })
    }

    @Test fun periodicSavedAndScheduled() {
        val a = autos.save(auto(trigger = Automation.PERIODIC, interval = 60), ville)
        assertEquals(listOf("schedule ${a.id} 60"), scheduler.events)
    }

    @Test fun unknownVariableRefused() {
        val msg = refused(EngineError.FL_EINVAL) { autos.save(auto(template = "Bonjour {{nom}}"), emptyList()) }
        assertTrue(msg, msg.contains("{{nom}}"))
    }

    @Test fun unusedDeclaredVariablesDropped() {
        val a = autos.save(auto(), ville + AutomationVar("inutile", "x"))
        assertEquals(ville, autos.variablesOf(a))
    }

    @Test fun periodicNeedsFifteenMinutesAndDefaults() {
        refused(EngineError.FL_EINVAL) { autos.save(auto(trigger = Automation.PERIODIC, interval = 10), ville) }
        refused(EngineError.FL_EINVAL) { autos.save(auto(trigger = Automation.PERIODIC, interval = 15), listOf(AutomationVar("ville", null))) }
        autos.save(auto(trigger = Automation.PERIODIC, interval = 15), ville)
    }

    @Test fun nameAndModelRequired() {
        refused(EngineError.FL_EINVAL) { autos.save(auto(name = "  "), ville) }
        servers[0] = servers[0].copy(defaultModel = null)
        refused(EngineError.FL_EINVAL) { autos.save(auto(model = null), ville) }
    }

    @Test fun defaultServerAndModelWhenNotChosen() {
        val a = autos.save(auto(serverId = null, model = null), ville)
        assertEquals("s1", a.serverId)
        assertEquals("essai-court", a.model)
    }

    @Test fun atMostTwentyAutomations() {
        repeat(Automations.MAX_AUTOMATIONS) { autos.save(auto(name = "A$it"), ville) }
        refused(EngineError.FL_ENOSPC) { autos.save(auto(name = "Une de trop"), ville) }
    }

    @Test fun disableEnableAndDeleteDriveScheduling() {
        val a = autos.save(auto(trigger = Automation.PERIODIC, interval = 30), ville)
        scheduler.events.clear()
        autos.setEnabled(a.id, false)
        autos.setEnabled(a.id, true)
        autos.delete(a.id)
        assertEquals(listOf("cancel ${a.id}", "schedule ${a.id} 30", "cancel ${a.id}"), scheduler.events)
        assertNull(dao.automation(a.id))
    }

    @Test fun becomingManualCancelsWork() {
        val a = autos.save(auto(trigger = Automation.PERIODIC, interval = 30), ville)
        scheduler.events.clear()
        autos.save(a.copy(trigger = Automation.MANUAL, intervalMinutes = null), ville)
        assertEquals(listOf("cancel ${a.id}"), scheduler.events)
    }

    @Test fun serverDeletedCancelsAndDisablesItsAutomations() {
        val a1 = autos.save(auto(trigger = Automation.PERIODIC, interval = 30), ville)
        val a2 = autos.save(auto(trigger = Automation.PERIODIC, interval = 30, serverId = "s2", model = "essai-long"), ville)
        scheduler.events.clear()
        autos.serverDeleted("s1")
        assertEquals(listOf("cancel ${a1.id}"), scheduler.events)
        assertFalse(dao.automation(a1.id)!!.enabled)
        assertTrue(dao.automation(a2.id)!!.enabled)
    }

    @Test fun duplicateIsDisabledCopy() {
        val a = autos.save(auto(trigger = Automation.PERIODIC, interval = 30), ville)
        scheduler.events.clear()
        val d = autos.duplicate(a.id)
        assertEquals("Météo (copie)", d.name)
        assertFalse(d.enabled)
        assertEquals(ville, autos.variablesOf(d))
        assertTrue(scheduler.events.none { it.startsWith("schedule") })
    }

    // --- lancement manuel, en flux

    @Test fun manualRunStreamsAndWritesResultOnce() {
        val a = autos.save(auto(systemPrompt = "Sois bref."), ville)
        server.enqueue(sse("Il fait ", "beau."))
        val r = autos.start(a.id, mapOf("ville" to "Kara"))
        assertEquals(AutomationRun.RUNNING, r.state)
        assertEquals("Météo à Kara le 25/10/2026", r.input)
        assertFalse(r.scheduled)
        autos.await(r.id)
        val done = dao.run(r.id)!!
        assertEquals(AutomationRun.DONE, done.state)
        assertEquals("Il fait beau.", done.output)
        assertTrue(done.endedAt!! >= done.startedAt)
        // lots partis avant la fin (aucun si la réponse tient en moins de 50 ms), puis tout le texte avec l'état final
        assertTrue("Il fait beau.".startsWith(sink.deltas.joinToString("")))
        assertEquals(listOf(AutomationRun.DONE), sink.states.map { it.state })
        assertEquals("Il fait beau.", sink.states.single().output)
        val body = JSONObject(server.takeRequest(5, TimeUnit.SECONDS)!!.body.readUtf8())
        assertEquals("essai-court", body.getString("model"))
        val msgs = body.getJSONArray("messages")
        assertEquals("system", msgs.getJSONObject(0).getString("role"))
        assertEquals("Sois bref.", msgs.getJSONObject(0).getString("content"))
        assertEquals("Météo à Kara le 25/10/2026", msgs.getJSONObject(1).getString("content"))
    }

    @Test fun manualRunUsesDefaultsForMissingValues() {
        val a = autos.save(auto(), ville)
        server.enqueue(sse("ok"))
        val r = autos.start(a.id, emptyMap())
        assertEquals("Météo à Lomé le 25/10/2026", r.input)
        autos.await(r.id)
    }

    @Test fun manualRunMissingValueRefusedBeforeAnyRun() {
        val a = autos.save(auto(), listOf(AutomationVar("ville", null)))
        refused(EngineError.FL_EINVAL) { autos.start(a.id, emptyMap()) }
        assertTrue(dao.runs(a.id).isEmpty())
    }

    @Test fun stopKeepsPartialResult() {
        val a = autos.save(auto(), ville)
        server.enqueue(
            MockResponse().setHeader("Content-Type", "text/event-stream")
                .setBody("data: {\"choices\":[{\"delta\":{\"content\":\"Début\"}}]}\n\n" + ":\n\n".repeat(2000))
                .throttleBody(64, 50, TimeUnit.MILLISECONDS),
        )
        val r = autos.start(a.id, emptyMap())
        val end = System.currentTimeMillis() + 10_000
        while (sink.deltas.isEmpty() && System.currentTimeMillis() < end) Thread.sleep(5)
        autos.stop(r.id)
        autos.await(r.id)
        val stopped = dao.run(r.id)!!
        assertEquals(AutomationRun.STOPPED, stopped.state)
        assertEquals("Début", stopped.output)
    }

    @Test fun oneManualRunAtATimePerAutomation() {
        val a = autos.save(auto(), ville)
        server.enqueue(MockResponse().setHeader("Content-Type", "text/event-stream").setBody(":\n\n".repeat(400)).throttleBody(16, 50, TimeUnit.MILLISECONDS))
        val r = autos.start(a.id, emptyMap())
        refused(EngineError.FL_EBUSY) { autos.start(a.id, emptyMap()) }
        autos.stop(r.id)
        autos.await(r.id)
    }

    // --- exécution planifiée (WorkManager), sans flux

    @Test fun scheduledRunUsesDefaultsAndCompletion() {
        val a = autos.save(auto(trigger = Automation.PERIODIC, interval = 60), ville)
        server.enqueue(completion("Ensoleillé"))
        val o = runBlocking { autos.executeScheduled(a.id, attempt = 0) }
        assertFalse(o.retry)
        assertEquals(AutomationRun.DONE, o.run!!.state)
        assertTrue(o.run!!.scheduled)
        assertEquals("Ensoleillé", o.run!!.output)
        assertEquals("Météo à Lomé le 25/10/2026", o.run!!.input)
        assertFalse(JSONObject(server.takeRequest(5, TimeUnit.SECONDS)!!.body.readUtf8()).optBoolean("stream", false))
    }

    @Test fun scheduledRunOfDeletedServerFailsWithoutRetry() {
        val a = autos.save(auto(trigger = Automation.PERIODIC, interval = 60, serverId = "s2", model = "essai-long"), ville)
        servers.removeAt(1)
        val o = runBlocking { autos.executeScheduled(a.id, attempt = 0) }
        assertFalse(o.retry)
        assertEquals(AutomationRun.FAILED, o.run!!.state)
        assertEquals(AiServers.MSG_GONE, o.run!!.error)
    }

    @Test fun scheduledRunServerErrorRetriedOnceOnly() {
        val a = autos.save(auto(trigger = Automation.PERIODIC, interval = 60), ville)
        server.enqueue(MockResponse().setResponseCode(500).setBody("{\"error\":{\"message\":\"panne\"}}"))
        server.enqueue(MockResponse().setResponseCode(500).setBody("{\"error\":{\"message\":\"panne\"}}"))
        val first = runBlocking { autos.executeScheduled(a.id, attempt = 0) }
        assertTrue(first.retry)
        assertEquals(AutomationRun.FAILED, first.run!!.state)
        assertEquals("panne", first.run!!.errorDetail)
        val second = runBlocking { autos.executeScheduled(a.id, attempt = 1) }
        assertFalse(second.retry)
        assertEquals(2, dao.runs(a.id).size)
    }

    @Test fun scheduledRunKeyRefusedNotRetried() {
        val a = autos.save(auto(trigger = Automation.PERIODIC, interval = 60), ville)
        server.enqueue(MockResponse().setResponseCode(401).setBody("{\"error\":{\"message\":\"clé invalide\"}}"))
        val o = runBlocking { autos.executeScheduled(a.id, attempt = 0) }
        assertFalse(o.retry)
        assertEquals(AiException(AiException.Kind.KEY_REFUSED).message, o.run!!.error)
    }

    @Test fun scheduledRunOfDisabledOrDeletedAutomationCancelsItsWork() {
        val a = autos.save(auto(trigger = Automation.PERIODIC, interval = 60, enabled = false), ville)
        scheduler.events.clear()
        val o = runBlocking { autos.executeScheduled(a.id, attempt = 0) }
        assertNull(o.run)
        assertFalse(o.retry)
        val gone = runBlocking { autos.executeScheduled(999, attempt = 0) }
        assertNull(gone.run)
        assertEquals(listOf("cancel ${a.id}", "cancel 999"), scheduler.events)
        assertTrue(dao.runs(a.id).isEmpty())
    }

    @Test fun historyKeepsFiftyRuns() {
        val a = autos.save(auto(trigger = Automation.PERIODIC, interval = 60), ville)
        repeat(Automations.MAX_RUNS + 3) { server.enqueue(completion("r$it")) }
        repeat(Automations.MAX_RUNS + 3) { runBlocking { autos.executeScheduled(a.id, attempt = 0) } }
        val runs = autos.runs(a.id)
        assertEquals(Automations.MAX_RUNS, runs.size)
        assertEquals("r${Automations.MAX_RUNS + 2}", runs.first().output)
        autos.clearRuns(a.id)
        assertTrue(autos.runs(a.id).isEmpty())
    }

    @Test fun interruptedRunsRecovered() {
        val a = autos.save(auto(), ville)
        dao.insertRun(AutomationRun(automationId = a.id, startedAt = 1, endedAt = null, state = AutomationRun.RUNNING, scheduled = false, input = "x", output = null, error = null, errorDetail = null))
        assertEquals(1, autos.recoverInterrupted())
        assertEquals(AutomationRun.INTERRUPTED, autos.runs(a.id).single().state)
    }
}
