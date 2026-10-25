package com.mawena.fluluks

import com.mawena.fluluks.ai.AiServerConfig
import com.mawena.fluluks.ai.AiServers
import com.mawena.fluluks.ai.OpenAiCompatibleProvider
import com.mawena.fluluks.ai.chat.ChatSessions
import com.mawena.fluluks.ai.chat.ChatSink
import com.mawena.fluluks.ai.chat.ChatStore
import com.mawena.fluluks.ai.chat.Message
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.files.FilesException
import java.util.Collections
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Réponses en flux vers Dart, arrêter, régénérer (phase 15, T6), contre MockWebServer. */
class ChatSessionsTest {
    private val server = MockWebServer().apply { start() }
    private val dao = ChatStoreTest.MemChatDao()
    private var clock = 1_000L
    private val servers = mutableListOf(AiServerConfig("s1", "Essai", server.url("/").toString().trimEnd('/'), isDefault = true, defaultModel = "essai-court"))
    private val store = ChatStore(dao, { servers.toList() }, { synchronized(dao) { it() } }, { synchronized(this) { clock++ } })

    /** Lots reçus ; acquittés tout de suite, ou gardés pour l'être plus tard. */
    private class Rec(val autoAck: Boolean = true) : ChatSink {
        val events: MutableList<String> = Collections.synchronizedList(mutableListOf())
        val states: MutableList<Message> = Collections.synchronizedList(mutableListOf())
        val acks = ConcurrentLinkedQueue<() -> Unit>()
        val inflight = AtomicInteger()
        val maxInflight = AtomicInteger()

        override fun delta(conversationId: Long, messageId: Long, text: String, delivered: () -> Unit) {
            events += "d:$text"
            if (autoAck) return delivered()
            maxInflight.accumulateAndGet(inflight.incrementAndGet(), ::maxOf)
            acks += {
                inflight.decrementAndGet()
                delivered()
            }
        }

        override fun state(m: Message) {
            events += "s:${m.state}"
            states += m
        }

        fun deltas() = synchronized(events) { events.filter { it.startsWith("d:") }.joinToString("") { it.substring(2) } }
    }

    private fun sessions(rec: ChatSink, batchMs: Long = 50, maxBatch: Int = 16 * 1024) = ChatSessions(
        store = { store },
        providerFor = { id ->
            val c = servers.firstOrNull { it.id == id } ?: throw FilesException(EngineError.FL_ENOENT, AiServers.MSG_GONE)
            OpenAiCompatibleProvider(c.baseUrl, null)
        },
        batchMs = batchMs,
        maxBatch = maxBatch,
    ).also { it.sink = rec }

    private fun delta(t: String) = "data: {\"choices\":[{\"delta\":{\"content\":${JSONObject.quote(t)}}}]}\n\n"

    private fun sse(vararg parts: String) =
        MockResponse().setHeader("Content-Type", "text/event-stream").setBody(parts.joinToString("") + "data: [DONE]\n\n")

    private fun ChatSessions.await(id: Long) = runBlocking { withTimeout(20_000) { job(id)?.join() } }

    private fun waitFor(what: String, cond: () -> Boolean) {
        val end = System.currentTimeMillis() + 10_000
        while (!cond()) {
            if (System.currentTimeMillis() > end) fail("attendu : $what")
            Thread.sleep(5)
        }
    }

    private fun messagesOf(r: RecordedRequest) = JSONObject(r.body.readUtf8()).getJSONArray("messages").let { a ->
        (0 until a.length()).map { a.getJSONObject(it).let { m -> m.getString("role") + ":" + m.getString("content") } }
    }

    private fun busy(block: () -> Unit) {
        try {
            block()
        } catch (e: FilesException) {
            assertEquals(EngineError.FL_EBUSY, e.code)
            return
        }
        fail("refus attendu (réponse en cours)")
    }

    @After fun tearDown() = server.shutdown()

    @Test fun messagesWrittenBeforeRequestAndReplyWrittenOnceAtEnd() {
        val c = store.create()
        var seenAtRequest = emptyList<String>()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                seenAtRequest = store.messages(c.id).map { "${it.role}:${it.state}" }
                return sse(delta("Bon"), delta("jour"), delta(" !"))
            }
        }
        val rec = Rec()
        val s = sessions(rec)
        val reply = s.send(c.id, "Salut")
        assertEquals(Message.STREAMING, reply.state)
        s.await(c.id)
        assertEquals(listOf("user:done", "assistant:streaming"), seenAtRequest)
        val final = store.messages(c.id).last()
        assertEquals("Bonjour !", final.content)
        assertEquals(Message.DONE, final.state)
        assertEquals(1, dao.messageUpdates.count { it == reply.id })
        assertEquals(Message.DONE, rec.states.last().state)
        assertEquals("Bonjour !", rec.states.last().content)
        assertTrue("Bonjour !".startsWith(rec.deltas()))
        assertEquals(listOf("user:Salut"), messagesOf(server.takeRequest()))
    }

    @Test fun batchesAwaitAcknowledgementFourInFlightAtMost() {
        val c = store.create()
        val parts = (1..300).map { "x".repeat(100) }
        server.enqueue(sse(*parts.map(::delta).toTypedArray()))
        val rec = Rec(autoAck = false)
        val s = sessions(rec, batchMs = 1, maxBatch = 1000)
        val acker = thread {
            while (!Thread.currentThread().isInterrupted) {
                try {
                    Thread.sleep(15)
                } catch (e: InterruptedException) {
                    break
                }
                generateSequence { rec.acks.poll() }.forEach { it() }
            }
        }
        s.send(c.id, "Long")
        s.await(c.id)
        acker.interrupt()
        assertTrue("au plus 4 lots en route (${rec.maxInflight.get()})", rec.maxInflight.get() in 1..4)
        assertTrue(rec.events.count { it.startsWith("d:") } >= 2)
        assertEquals("x".repeat(30_000), store.messages(c.id).last().content)
        assertTrue("x".repeat(30_000).startsWith(rec.deltas()))
        assertTrue(rec.events.filter { it.startsWith("d:") }.all { it.length - 2 <= 1000 })
    }

    @Test fun stopKeepsTextAndNoChunkAfterwards() {
        val c = store.create()
        server.enqueue(sse(*(1..400).map { delta("mot$it ") }.toTypedArray()).throttleBody(64, 20, TimeUnit.MILLISECONDS))
        val rec = Rec()
        val s = sessions(rec, batchMs = 5)
        s.send(c.id, "Raconte")
        waitFor("un premier lot") { rec.events.any { it.startsWith("d:") } }
        s.stop(c.id)
        s.await(c.id)
        Thread.sleep(300)
        val final = store.messages(c.id).last()
        assertEquals(Message.STOPPED, final.state)
        assertTrue(final.content.startsWith("mot1 "))
        assertTrue(final.content.length < (1..400).sumOf { "mot$it ".length })
        assertTrue(final.content.startsWith(rec.deltas()))
        assertEquals("s:stopped", rec.events.last())
        assertTrue(s.job(c.id) == null)
    }

    @Test fun stopWhileConnecting() {
        val c = store.create()
        server.enqueue(sse(delta("tard")).setHeadersDelay(5, TimeUnit.SECONDS))
        val rec = Rec()
        val s = sessions(rec)
        s.send(c.id, "Bonjour")
        Thread.sleep(200)
        s.stop(c.id)
        s.await(c.id)
        val final = store.messages(c.id).last()
        assertEquals(Message.STOPPED, final.state)
        assertEquals("", final.content)
        assertTrue(rec.events.none { it.startsWith("d:") })
    }

    @Test fun stopAfterDoneChangesNothing() {
        val c = store.create()
        server.enqueue(sse(delta("Fini")))
        val rec = Rec()
        val s = sessions(rec)
        s.send(c.id, "Bonjour")
        s.await(c.id)
        s.stop(c.id)
        assertEquals(Message.DONE, store.messages(c.id).last().state)
    }

    @Test fun regenerateReplacesLastReplyWithSameHistory() {
        val c = store.create()
        store.setSystemPrompt(c.id, "Sois bref.")
        server.enqueue(sse(delta("Première")))
        server.enqueue(sse(delta("Seconde")))
        val rec = Rec()
        val s = sessions(rec)
        val first = s.send(c.id, "Bonjour")
        s.await(c.id)
        val second = s.regenerate(c.id)
        s.await(c.id)
        assertNotEquals(first.id, second.id)
        val ms = store.messages(c.id)
        assertEquals(listOf("user:Bonjour", "assistant:Seconde"), ms.map { "${it.role}:${it.content}" })
        val h1 = messagesOf(server.takeRequest())
        val h2 = messagesOf(server.takeRequest())
        assertEquals(listOf("system:Sois bref.", "user:Bonjour"), h1)
        assertEquals(h1, h2)
    }

    @Test fun oneGenerationPerConversationThreeOverall() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest) = sse(delta("lent")).setHeadersDelay(3, TimeUnit.SECONDS)
        }
        val s = sessions(Rec())
        val ids = (1..4).map { store.create().id }
        s.send(ids[0], "un")
        busy { s.send(ids[0], "encore") }
        busy { s.regenerate(ids[0]) }
        s.send(ids[1], "deux")
        s.send(ids[2], "trois")
        busy { s.send(ids[3], "quatre") }
        assertEquals(setOf(ids[0], ids[1], ids[2]), s.running())
        ids.take(3).forEach(s::stop)
        ids.take(3).forEach { s.await(it) }
        assertTrue(s.running().isEmpty())
    }

    @Test fun errorMidStreamKeepsTextAndFails() {
        val c = store.create()
        server.enqueue(
            MockResponse().setHeader("Content-Type", "text/event-stream")
                .setBody(delta("Début ") + "data: {\"error\":{\"message\":\"panne du modèle\"}}\n\n"),
        )
        val rec = Rec()
        val s = sessions(rec)
        s.send(c.id, "Bonjour")
        s.await(c.id)
        val final = store.messages(c.id).last()
        assertEquals(Message.FAILED, final.state)
        assertEquals("Début ", final.content)
        assertNotNull(final.error)
        assertEquals("panne du modèle", final.errorDetail)
        assertEquals("s:failed", rec.events.last())
    }

    @Test fun historyLimitedTo200WithSystemPromptKept() {
        val c = store.create()
        store.setSystemPrompt(c.id, "Système")
        for (i in 1..250) store.addUserMessage(c.id, "m$i")
        server.enqueue(sse(delta("ok")))
        val s = sessions(Rec())
        s.send(c.id, "dernier")
        s.await(c.id)
        val h = messagesOf(server.takeRequest())
        assertEquals(201, h.size)
        assertEquals("system:Système", h.first())
        assertEquals("user:m52", h[1])
        assertEquals("user:dernier", h.last())
    }

    @Test fun deletedServerOrNoServerFailsWithReason() {
        val c = store.create()
        servers.clear()
        val rec = Rec()
        val s = sessions(rec)
        s.send(c.id, "Bonjour")
        s.await(c.id)
        assertEquals(Message.FAILED, store.messages(c.id).last().state)
        assertEquals(AiServers.MSG_GONE, store.messages(c.id).last().error)
        val none = store.create()
        s.send(none.id, "Bonjour")
        s.await(none.id)
        assertTrue(store.messages(none.id).last().error!!.contains("serveur IA"))
        assertEquals(0, server.requestCount)
    }

    @Test fun regenerateAfterFailureRetries() {
        val c = store.create()
        server.enqueue(MockResponse().setResponseCode(503).setBody("{\"error\":{\"message\":\"occupé\"}}"))
        server.enqueue(sse(delta("Enfin")))
        val s = sessions(Rec())
        s.send(c.id, "Bonjour")
        s.await(c.id)
        assertEquals(Message.FAILED, store.messages(c.id).last().state)
        s.regenerate(c.id)
        s.await(c.id)
        assertEquals(listOf("user:Bonjour", "assistant:Enfin"), store.messages(c.id).map { "${it.role}:${it.content}" })
    }
}
