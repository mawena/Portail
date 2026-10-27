package com.mawena.fluluks

import com.mawena.fluluks.ai.AiAttemptLog
import com.mawena.fluluks.ai.AiErrors
import com.mawena.fluluks.ai.AiException
import com.mawena.fluluks.ai.AiHealth
import com.mawena.fluluks.ai.AiHttp
import com.mawena.fluluks.ai.AiTimeouts
import com.mawena.fluluks.ai.ChatEvent
import com.mawena.fluluks.ai.ChatMessage
import com.mawena.fluluks.ai.ChatRequest
import com.mawena.fluluks.ai.OpenAiCompatibleProvider
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import okhttp3.Dns
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/** Couche réseau compatible OpenAI (phase 15, T2), contre MockWebServer. */
class AiProviderTest {
    private lateinit var server: MockWebServer

    @Before fun setUp() {
        server = MockWebServer().apply { start() }
    }

    @After fun tearDown() {
        server.shutdown()
    }

    private val base get() = server.url("/").toString().trimEnd('/')

    private fun provider(key: String? = null, timeouts: AiTimeouts = AiTimeouts(), log: AiAttemptLog = AiAttemptLog()) =
        OpenAiCompatibleProvider(base, key?.toByteArray(), timeouts, log)

    private fun json(code: Int, body: String) =
        MockResponse().setResponseCode(code).setHeader("Content-Type", "application/json").setBody(body)

    private fun error(code: Int, message: String) = json(code, "{\"error\":{\"message\":\"$message\",\"type\":\"x\",\"code\":\"$code\"}}")

    private fun sse(body: String) = MockResponse().setHeader("Content-Type", "text/event-stream").setBody(body)

    private fun delta(t: String) = "data: {\"choices\":[{\"delta\":{\"content\":${JSONObject.quote(t)}}}]}\n\n"

    private val models = "{\"object\":\"list\",\"data\":[{\"id\":\"a\",\"object\":\"model\",\"owned_by\":\"moi\"},{\"id\":\"b\",\"object\":\"model\"}]}"

    private val req = ChatRequest("a", listOf(ChatMessage("system", "Sois bref."), ChatMessage("user", "Bonjour")))

    private fun <T> expectAi(kind: AiException.Kind, block: () -> T): AiException {
        try {
            block()
        } catch (e: AiException) {
            assertEquals(e.message, kind, e.kind)
            return e
        }
        fail("AiException $kind attendue")
        throw AssertionError()
    }

    private fun chatFailure(p: OpenAiCompatibleProvider = provider()): AiException =
        runBlocking { (p.chat(req).toList().last() as ChatEvent.Failed).error }

    @Test fun parsesModelsChatCompleteAndEmbeddings() = runBlocking {
        server.enqueue(json(200, models))
        assertEquals(listOf("a", "b"), provider().models().map { it.id })
        server.enqueue(json(200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Salut\"},\"finish_reason\":\"stop\"}]}"))
        assertEquals("Salut", provider().complete(req.copy(temperature = 0.5, maxTokens = 20)))
        server.takeRequest()
        val body = JSONObject(server.takeRequest().body.readUtf8())
        assertEquals("a", body.getString("model"))
        assertFalse(body.getBoolean("stream"))
        assertEquals(0.5, body.getDouble("temperature"), 0.0)
        assertEquals(20, body.getInt("max_tokens"))
        assertEquals("system", body.getJSONArray("messages").getJSONObject(0).getString("role"))
        // sans choix : rien d'envoyé pour temperature et max_tokens
        server.enqueue(sse(delta("x") + "data: [DONE]\n\n"))
        provider().chat(req).toList()
        val b2 = JSONObject(server.takeRequest().body.readUtf8())
        assertTrue(b2.getBoolean("stream"))
        assertFalse(b2.has("temperature"))
        assertFalse(b2.has("max_tokens"))
        server.enqueue(json(200, "{\"data\":[{\"index\":0,\"embedding\":[0.5,-1]},{\"index\":1,\"embedding\":[2]}]}"))
        val e = provider().embeddings("emb", listOf("u", "v"))
        assertArrayEquals(floatArrayOf(0.5f, -1f), e[0], 0f)
        assertArrayEquals(floatArrayOf(2f), e[1], 0f)
    }

    @Test fun bearerSentOnEveryRoute() = runBlocking {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.path) {
                "/health" -> json(200, "{\"status\":\"ok\",\"version\":\"1\"}")
                "/v1/models" -> json(200, models)
                "/v1/embeddings" -> json(200, "{\"data\":[{\"embedding\":[1]}]}")
                else -> if (request.body.peek().readUtf8().contains("\"stream\":true")) {
                    sse(delta("x") + "data: [DONE]\n\n")
                } else {
                    json(200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"x\"}}]}")
                }
            }
        }
        val p = provider("cle-essai")
        p.health()
        p.models()
        p.chat(req).toList()
        p.complete(req)
        p.embeddings("a", listOf("x"))
        val n = server.requestCount
        assertEquals(6, n) // santé : /health puis /v1/models
        repeat(n) { assertEquals("Bearer cle-essai", server.takeRequest().getHeader("Authorization")) }
    }

    @Test fun noKeyNoHeader() = runBlocking {
        server.enqueue(json(200, models))
        server.enqueue(sse(delta("x") + "data: [DONE]\n\n"))
        val p = OpenAiCompatibleProvider(base, ByteArray(0))
        p.models()
        p.chat(req).toList()
        assertNull(server.takeRequest().getHeader("Authorization"))
        assertNull(server.takeRequest().getHeader("Authorization"))
    }

    @Test fun healthFallsBackToModels() = runBlocking {
        // Ollama : pas de /health
        server.enqueue(MockResponse().setResponseCode(404).setBody("404 page not found"))
        server.enqueue(json(200, models))
        val h = provider().health()
        assertEquals(AiHealth.State.ONLINE, h.state)
        assertNull(h.version)
        // serveur maison : /health publique, clé refusée par /v1/models
        server.enqueue(json(200, "{\"status\":\"ok\",\"version\":\"0.1.0\"}"))
        server.enqueue(error(401, "Authentication Error"))
        val h2 = provider("mauvaise").health()
        assertEquals(AiHealth.State.KEY_REFUSED, h2.state)
        assertEquals("0.1.0", h2.version)
        assertEquals("Authentication Error", h2.error?.serverMessage)
        // vLLM : 200 sans corps
        server.enqueue(MockResponse().setResponseCode(200))
        server.enqueue(json(200, models))
        val h3 = provider().health()
        assertEquals(AiHealth.State.ONLINE, h3.state)
        assertNull(h3.version)
        // injoignable
        server.shutdown()
        val h4 = OpenAiCompatibleProvider(base, null).health()
        assertEquals(AiHealth.State.OFFLINE, h4.state)
        assertEquals(AiException.Kind.REFUSED, h4.error?.kind)
    }

    @Test fun errorsTranslated() = runBlocking {
        server.enqueue(error(401, "Clé invalide"))
        val e401 = expectAi(AiException.Kind.KEY_REFUSED) { runBlocking { provider("k").models() } }
        assertTrue(e401.message, e401.message.startsWith("Clé API refusée"))
        assertEquals("Clé invalide", e401.serverMessage)
        assertFalse(e401.retryable)
        assertEquals(1, server.requestCount) // un 401 n'est jamais relancé

        server.enqueue(error(403, "Interdit"))
        assertEquals("Interdit", expectAi(AiException.Kind.FORBIDDEN) { runBlocking { provider().models() } }.serverMessage)

        server.enqueue(error(404, "The model `zz` does not exist."))
        val e404 = chatFailure()
        assertEquals(AiException.Kind.MODEL_NOT_FOUND, e404.kind)
        assertTrue(e404.message.startsWith("Modèle introuvable sur ce serveur"))
        assertEquals("The model `zz` does not exist.", e404.serverMessage)

        server.enqueue(MockResponse().setResponseCode(404).setBody("<html>Not Found</html>"))
        assertEquals(AiException.Kind.NOT_FOUND, expectAi(AiException.Kind.NOT_FOUND) { runBlocking { provider().complete(req) } }.kind)

        server.enqueue(error(429, "Trop de requêtes"))
        val e429 = chatFailure()
        assertEquals(AiException.Kind.RATE_LIMITED, e429.kind)
        assertTrue(e429.message.contains("réessayez plus tard"))

        for (code in listOf(500, 503)) {
            server.enqueue(error(code, "Panne $code"))
            val e = chatFailure()
            assertEquals(AiException.Kind.SERVER_ERROR, e.kind)
            assertEquals("Panne $code", e.serverMessage)
            assertTrue(e.retryable)
        }

        // vLLM ancien : erreur au premier niveau
        server.enqueue(json(400, "{\"object\":\"error\",\"message\":\"max_tokens trop grand\",\"type\":\"BadRequestError\",\"code\":400}"))
        val e400 = expectAi(AiException.Kind.BAD_REQUEST) { runBlocking { provider().complete(req) } }
        assertEquals("max_tokens trop grand", e400.serverMessage)

        // délai de connexion (OkHttp : « connect timed out »)
        assertEquals(AiException.Kind.CONNECT_TIMEOUT, AiErrors.fromException(SocketTimeoutException("connect timed out"), streaming = false).kind)
        // délai sans octet en flux (60 s, ici 300 ms)
        server.enqueue(sse(delta("début")).setBodyDelay(3, TimeUnit.SECONDS))
        val slow = chatFailure(provider(timeouts = AiTimeouts(streamIdleMs = 300)))
        assertEquals(AiException.Kind.STREAM_TIMEOUT, slow.kind)
        assertEquals("Le serveur ne répond plus", slow.message)
        // en flux, l'attente de l'en-tête compte aussi (essai-lent : 70 s avant le premier octet)
        server.enqueue(sse(delta("début ")).setHeadersDelay(3, TimeUnit.SECONDS))
        val ev = runBlocking { provider(timeouts = AiTimeouts(streamIdleMs = 500)).chat(req).toList() }
        assertEquals(AiException.Kind.STREAM_TIMEOUT, (ev.last() as ChatEvent.Failed).error.kind)
        // délai sans flux (120 s, ici 300 ms)
        server.enqueue(json(200, "{}").setBodyDelay(3, TimeUnit.SECONDS))
        expectAi(AiException.Kind.READ_TIMEOUT) { runBlocking { provider(timeouts = AiTimeouts(readMs = 300)).complete(req) } }

        // hôte inconnu
        val noDns = AiHttp.client.newBuilder().dns(object : Dns {
            override fun lookup(hostname: String): List<InetAddress> = throw UnknownHostException(hostname)
        }).build()
        val unknown = OpenAiCompatibleProvider("http://ia.invalid:8080", null, AiTimeouts(), AiAttemptLog(), noDns)
        assertEquals(AiException.Kind.UNKNOWN_HOST, expectAi(AiException.Kind.UNKNOWN_HOST) { runBlocking { unknown.models() } }.kind)

        // certificat refusé (auto-signé, inconnu du téléphone)
        val cert = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val tls = MockWebServer()
        tls.useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory(), false)
        tls.enqueue(json(200, models))
        tls.start()
        try {
            val https = OpenAiCompatibleProvider(tls.url("/").toString().replace("127.0.0.1", "localhost").trimEnd('/'), null)
            val ec = expectAi(AiException.Kind.CERTIFICATE) { runBlocking { https.models() } }
            assertTrue(ec.message.startsWith("Certificat du serveur refusé"))
        } finally {
            tls.shutdown()
        }

        // connexion refusée
        val port = server.port
        server.shutdown()
        val refused = OpenAiCompatibleProvider("http://127.0.0.1:$port", null)
        expectAi(AiException.Kind.REFUSED) { runBlocking { refused.models() } }
        assertEquals(AiException.Kind.REFUSED, chatFailure(refused).kind)
    }

    @Test fun malformedResponsesAreProtocolErrors() = runBlocking {
        server.enqueue(json(200, "pas du json"))
        expectAi(AiException.Kind.PROTOCOL) { runBlocking { provider().models() } }
        server.enqueue(json(200, "{\"choices\":[]}"))
        expectAi(AiException.Kind.PROTOCOL) { runBlocking { provider().complete(req) } }
        // serveur qui ignore stream=true : réponse entière en JSON, rendue d'un bloc
        server.enqueue(json(200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Tout\"},\"finish_reason\":\"stop\"}]}"))
        val ev = provider().chat(req).toList()
        assertEquals(listOf("Tout"), ev.filterIsInstance<ChatEvent.Delta>().map { it.text })
        assertEquals("stop", (ev.last() as ChatEvent.Done).finishReason)
        // SocketPolicy : connexion coupée avant toute réponse (OkHttp peut retenter une connexion morte : toutes coupées)
        repeat(5) { server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST)) }
        val lg = AiAttemptLog()
        val cut = chatFailure(provider(log = lg))
        assertTrue(cut.kind.toString() + lg.lines() + cut.cause, cut.kind in setOf(AiException.Kind.CLOSED, AiException.Kind.INTERRUPTED))
    }

    @Test fun cancelStopsReading() {
        ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { ss ->
            var closedSeen = false
            val t = thread {
                ss.accept().use { s ->
                    s.soTimeout = 10_000
                    val input = s.getInputStream()
                    // lit l'en-tête de la requête puis le corps (Content-Length)
                    val head = StringBuilder()
                    while (!head.endsWith("\r\n\r\n")) head.append(input.read().toChar())
                    val len = Regex("(?i)content-length: (\\d+)").find(head)!!.groupValues[1].toInt()
                    repeat(len) { input.read() }
                    val out = s.getOutputStream()
                    out.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".toByteArray())
                    out.write(delta("premier").toByteArray())
                    out.flush()
                    // plus rien n'est envoyé : la lecture suivante voit la fermeture par le client
                    closedSeen = try {
                        input.read() == -1
                    } catch (e: java.io.IOException) {
                        true
                    }
                }
            }
            val p = OpenAiCompatibleProvider("http://127.0.0.1:${ss.localPort}", null)
            val first = runBlocking { p.chat(req).first() }
            assertEquals("premier", (first as ChatEvent.Delta).text)
            t.join(5_000)
            assertFalse("le serveur attend encore", t.isAlive)
            assertTrue("socket non fermée", closedSeen)
        }
    }

    @Test fun attemptLogHasNoSecrets() = runBlocking {
        server.enqueue(json(200, models))
        server.enqueue(sse(delta("reponse-secrete-42") + "data: [DONE]\n\n"))
        server.enqueue(json(200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"reponse-secrete-43\"}}]}"))
        server.enqueue(error(401, "cle cle-secrete-99 refusee"))
        val log = AiAttemptLog()
        val p = provider("cle-secrete-99", log = log)
        val secretReq = ChatRequest("a", listOf(ChatMessage("system", "prompt-secret-1"), ChatMessage("user", "message-secret-2")))
        p.models()
        p.chat(secretReq).toList()
        p.complete(secretReq)
        runCatching { p.models() }
        val text = log.lines().joinToString("\n")
        assertTrue(text, log.lines().size >= 4)
        assertTrue(text, text.contains("/v1/chat/completions") && text.contains("200") && text.contains("401"))
        for (secret in listOf("cle-secrete-99", "prompt-secret-1", "message-secret-2", "reponse-secrete-42", "reponse-secrete-43", "Bearer")) {
            assertFalse("« $secret » dans le journal :\n$text", text.contains(secret))
        }
        // 200 lignes au plus
        repeat(250) { log.add("ligne $it") }
        assertEquals(AiAttemptLog.MAX_LINES, log.lines().size)
    }
}
