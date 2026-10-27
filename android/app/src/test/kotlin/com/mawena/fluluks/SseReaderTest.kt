package com.mawena.fluluks

import com.mawena.fluluks.ai.AiException
import com.mawena.fluluks.ai.ChatEvent
import com.mawena.fluluks.ai.ChatMessage
import com.mawena.fluluks.ai.ChatRequest
import com.mawena.fluluks.ai.OpenAiCompatibleProvider
import com.mawena.fluluks.ai.SseReader
import java.io.InputStream
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Lecture du flux SSE (phase 15, T2) : coupures, fins de ligne, commentaires, erreurs et fins abruptes. */
class SseReaderTest {
    private lateinit var server: MockWebServer

    @Before fun setUp() {
        server = MockWebServer().apply { start() }
    }

    @After fun tearDown() {
        server.shutdown()
    }

    /** Flux qui rend ses octets par morceaux de tailles choisies (coupures n'importe où). */
    private class Chunked(bytes: ByteArray, sizes: List<Int>) : InputStream() {
        private val parts = ArrayDeque<ByteArray>()

        init {
            var off = 0
            for (s in sizes) {
                if (off >= bytes.size) break
                val n = minOf(s, bytes.size - off)
                parts.addLast(bytes.copyOfRange(off, off + n))
                off += n
            }
            if (off < bytes.size) parts.addLast(bytes.copyOfRange(off, bytes.size))
        }

        private var cur: ByteArray? = null
        private var pos = 0

        override fun read(): Int {
            val b = ByteArray(1)
            return if (read(b, 0, 1) < 0) -1 else b[0].toInt() and 0xff
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (cur == null || pos >= cur!!.size) {
                cur = parts.removeFirstOrNull() ?: return -1
                pos = 0
            }
            val n = minOf(len, cur!!.size - pos)
            System.arraycopy(cur!!, pos, b, off, n)
            pos += n
            return n
        }
    }

    private fun events(text: String, sizes: List<Int>): List<String> {
        val r = SseReader(Chunked(text.toByteArray(Charsets.UTF_8), sizes))
        return generateSequence { r.next() }.toList()
    }

    private fun provider() = OpenAiCompatibleProvider(server.url("/").toString().trimEnd('/'), null)

    private fun chat(): List<ChatEvent> = runBlocking {
        provider().chat(ChatRequest("m", listOf(ChatMessage("user", "Bonjour")))).toList()
    }

    private fun sse(body: String) = MockResponse().setHeader("Content-Type", "text/event-stream").setBody(body)

    private fun delta(t: String) = "data: {\"choices\":[{\"delta\":{\"content\":${org.json.JSONObject.quote(t)}},\"finish_reason\":null}]}\n\n"

    private fun text(ev: List<ChatEvent>) = ev.filterIsInstance<ChatEvent.Delta>().joinToString("") { it.text }

    @Test fun sseSplitAcrossChunks() {
        // « é » (2 octets) et « 😀 » (4 octets) coupés en deux, comme le champ JSON
        val payload = "{\"choices\":[{\"delta\":{\"content\":\"Été 😀 fini\"}}]}"
        val text = "data: $payload\n\ndata: [DONE]\n\n"
        val bytes = text.toByteArray(Charsets.UTF_8)
        val accent = String(bytes, Charsets.ISO_8859_1).indexOf('Ã') // premier octet de « É »
        for (cut in listOf(1, 3, accent + 1, 20, bytes.size - 3)) {
            val got = events(text, listOf(cut, 1, 2, 5, 1))
            assertEquals("coupure à $cut", listOf(payload, "[DONE]"), got)
        }
        // même chose à travers le réseau, un octet à la fois
        server.enqueue(sse(text).throttleBody(1, 1, java.util.concurrent.TimeUnit.MILLISECONDS))
        val ev = chat()
        assertEquals("Été 😀 fini", text(ev))
        assertTrue(ev.last() is ChatEvent.Done)
    }

    @Test fun sseCrLfAndComments() {
        val text = ": bonjour\r\nevent: message\r\nid: 1\r\ndata: a\r\ndata: b\r\n\r\nretry: 10\r\n\r\ndata: c\r\rdata: [DONE]\n\n"
        assertEquals(listOf("a\nb", "c", "[DONE]"), events(text, listOf(3, 7, 1, 2)))
        server.enqueue(sse(": commentaire\r\n\r\n" + delta("Bon").replace("\n", "\r\n") + delta("jour") + "data: [DONE]\r\n\r\n"))
        val ev = chat()
        assertEquals("Bonjour", text(ev))
        assertTrue(ev.last() is ChatEvent.Done)
    }

    @Test fun sseErrorEventMidStream() {
        server.enqueue(sse(delta("Début ") + "data: {\"error\":{\"message\":\"GPU en panne\"}}\n\n" + delta("jamais")))
        val ev = chat()
        assertEquals("Début ", text(ev))
        val f = ev.last() as ChatEvent.Failed
        assertEquals(AiException.Kind.STREAM_ERROR, f.error.kind)
        assertEquals("GPU en panne", f.error.serverMessage)
        assertEquals(1, ev.count { it is ChatEvent.Failed })
    }

    @Test fun sseClosedWithoutDone() {
        server.enqueue(sse(delta("Texte ") + delta("partiel")))
        val ev = chat()
        assertEquals("Texte partiel", text(ev))
        val f = ev.last() as ChatEvent.Failed
        assertEquals(AiException.Kind.INTERRUPTED, f.error.kind)
        assertEquals("La réponse a été interrompue", f.error.message)
        // JSON invalide au milieu : texte gardé, interrompu aussi, jamais de doublon
        server.enqueue(sse(delta("Avant ") + "data: {\"choices\":[{\"delta\":\n\n" + delta("après")))
        val ev2 = chat()
        assertEquals("Avant ", text(ev2))
        assertTrue((ev2.last() as ChatEvent.Failed).error.message.startsWith("La réponse a été interrompue"))
    }

    @Test fun sseIgnoresEmptyDeltas() {
        server.enqueue(
            sse(
                "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n" +
                    "data: {\"choices\":[{\"delta\":{\"content\":\"\"}}]}\n\n" +
                    "data: {\"choices\":[]}\n\n" +
                    "data: {\"object\":\"ping\"}\n\n" +
                    "data: {\"choices\":[{\"delta\":{\"content\":null}}]}\n\n" +
                    delta("seul") +
                    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1}}\n\n" +
                    "data: [DONE]\n\n",
            ),
        )
        val ev = chat()
        assertEquals(listOf("seul"), ev.filterIsInstance<ChatEvent.Delta>().map { it.text })
        val done = ev.last() as ChatEvent.Done
        assertEquals("stop", done.finishReason)
        assertEquals(1, done.usage?.completionTokens)
        assertNull(ev.firstOrNull { it is ChatEvent.Failed })
    }

    @Test fun readerEndsOnEmptyStream() {
        assertEquals(emptyList<String>(), events("", emptyList()))
        // dernier événement sans ligne vide finale : rendu quand même
        assertEquals(listOf("x"), events("data: x", listOf(2)))
    }
}
