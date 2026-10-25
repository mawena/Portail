package com.mawena.fluluks.ai

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.ProducerScope
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Dispatcher
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/** Client HTTP commun des serveurs IA : un seul pool de connexions ; délais réglés par fournisseur. */
object AiHttp {
    val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            // reprise par OkHttp seulement sur une connexion morte du pool ou une adresse injoignable ; jamais sur
            // une réponse (un 401 n'est jamais relancé)
            .retryOnConnectionFailure(true)
            .followRedirects(false)
            .dispatcher(Dispatcher().apply { maxRequestsPerHost = 16 })
            .build()
    }
}

/**
 * Serveur compatible OpenAI (contrat de `docs/ia/contrat-api.md`) : Portail, Ollama, vLLM, LocalAI. [apiKey] est
 * copiée (en-tête `Authorization: Bearer` sur toutes les routes, aucun en-tête si elle est vide) et remise à zéro par
 * [close]. Chaque appel est noté dans [log] sans rien de secret.
 */
class OpenAiCompatibleProvider(
    baseUrl: String,
    apiKey: ByteArray?,
    timeouts: AiTimeouts = AiTimeouts(),
    val log: AiAttemptLog = AiAttemptLog(),
    http: OkHttpClient = AiHttp.client,
) : AiProvider, AutoCloseable {
    private val base = baseUrl.trimEnd('/')
    private val key: ByteArray? = apiKey?.takeIf { it.isNotEmpty() }?.copyOf()
    private val client = http.newBuilder()
        .connectTimeout(timeouts.connectMs, TimeUnit.MILLISECONDS)
        .readTimeout(timeouts.readMs, TimeUnit.MILLISECONDS)
        .build()
    private val streamClient = client.newBuilder().readTimeout(timeouts.streamIdleMs, TimeUnit.MILLISECONDS).build()
    private val healthClient = client.newBuilder()
        .connectTimeout(timeouts.healthMs, TimeUnit.MILLISECONDS)
        .callTimeout(timeouts.healthMs, TimeUnit.MILLISECONDS)
        .build()

    override fun close() {
        key?.fill(0)
    }

    // --- requêtes

    /** L'en-tête est un texte pour OkHttp : créé pour l'appel seulement, jamais noté. */
    private fun request(path: String, body: JSONObject? = null, sse: Boolean = false): Request {
        val b = Request.Builder().url(base + path)
        if (key != null) b.header("Authorization", "Bearer " + String(key, Charsets.UTF_8))
        if (sse) b.header("Accept", "text/event-stream")
        if (body != null) b.post(body.toString().toRequestBody(JSON))
        return b.build()
    }

    private fun label(r: Request) = "${r.method} ${r.url.encodedPath}"

    private fun ms(start: Long) = (System.nanoTime() - start) / 1_000_000

    /** Code et corps (texte, [MAX_BODY] au plus) d'un appel ; une erreur HTTP n'en est pas une ici. */
    private suspend fun raw(c: OkHttpClient, req: Request): Pair<Int, String> {
        val start = System.nanoTime()
        val call = c.newCall(req)
        return suspendCancellableCoroutine { cont ->
            cont.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    val err = AiErrors.fromException(e, streaming = false)
                    log.add("${label(req)} → échec : ${AiErrors.message(err.kind)} (${ms(start)} ms)")
                    cont.resumeWithException(err)
                }

                override fun onResponse(call: Call, response: Response) {
                    try {
                        val text = response.use { readBody(it, MAX_BODY) }
                        log.add("${label(req)} → ${response.code} (${ms(start)} ms, ${text.length} car.)")
                        cont.resume(response.code to text)
                    } catch (e: IOException) {
                        val err = AiErrors.fromException(e, streaming = false)
                        log.add("${label(req)} → ${response.code}, échec : ${AiErrors.message(err.kind)} (${ms(start)} ms)")
                        cont.resumeWithException(err)
                    }
                }
            })
        }
    }

    /** Appel attendu en 2xx, puis lu par [parse] ; JSON hors du contrat : [AiException.Kind.PROTOCOL]. */
    private suspend fun <T> call(c: OkHttpClient, req: Request, modelRoute: Boolean, parse: (String) -> T): T {
        val (code, text) = raw(c, req)
        if (code !in 200..299) throw AiErrors.fromHttp(code, text.take(ERROR_BODY), modelRoute)
        return try {
            parse(text)
        } catch (e: JSONException) {
            throw AiException(AiException.Kind.PROTOCOL, cause = e)
        } catch (e: ClassCastException) {
            throw AiException(AiException.Kind.PROTOCOL, cause = e)
        }
    }

    private fun readBody(r: Response, max: Long): String {
        val source = r.body?.source() ?: return ""
        source.request(max + 1)
        if (source.buffer.size > max) throw AiException(AiException.Kind.PROTOCOL, detail = "réponse trop grande")
        return source.buffer.readUtf8()
    }

    // --- routes

    override suspend fun health(): AiHealth {
        var version: String? = null
        try {
            val (code, text) = raw(healthClient, request("/health"))
            when {
                code == 200 -> version = runCatching { JSONObject(text).opt("version") as? String }.getOrNull()
                code == 401 || code == 403 ->
                    return AiHealth(AiHealth.State.KEY_REFUSED, null, AiErrors.fromHttp(code, text.take(ERROR_BODY), false))
                code >= 500 -> return AiHealth(AiHealth.State.OFFLINE, null, AiErrors.fromHttp(code, text.take(ERROR_BODY), false))
                // 404 (Ollama, LocalAI) et autres : l'état se déduit de /v1/models
            }
        } catch (e: AiException) {
            return AiHealth(AiHealth.State.OFFLINE, null, e)
        }
        return try {
            val n = call(healthClient, request("/v1/models"), false, ::parseModels).size
            AiHealth(AiHealth.State.ONLINE, version, null, n)
        } catch (e: AiException) {
            val refused = e.kind == AiException.Kind.KEY_REFUSED || e.kind == AiException.Kind.FORBIDDEN
            AiHealth(if (refused) AiHealth.State.KEY_REFUSED else AiHealth.State.OFFLINE, version, e)
        }
    }

    override suspend fun models(): List<AiModel> = call(client, request("/v1/models"), false, ::parseModels)

    private fun parseModels(text: String): List<AiModel> {
        val data = JSONObject(text).getJSONArray("data")
        return (0 until data.length()).map {
            val m = data.getJSONObject(it)
            AiModel(m.getString("id"), m.opt("owned_by") as? String)
        }
    }

    override suspend fun complete(req: ChatRequest): String =
        call(client, request(CHAT, chatBody(req, stream = false)), true) { parseCompletion(it).first }

    /** Contenu et raison de fin d'une réponse sans flux. */
    private fun parseCompletion(text: String): Pair<String, String?> {
        val c = JSONObject(text).getJSONArray("choices").getJSONObject(0)
        val content = c.getJSONObject("message").get("content") as String
        return content to (c.opt("finish_reason") as? String)
    }

    override suspend fun embeddings(model: String, input: List<String>): List<FloatArray> {
        val body = JSONObject().put("model", model).put("input", JSONArray(input))
        return call(client, request("/v1/embeddings", body), true) { text ->
            val data = JSONObject(text).getJSONArray("data")
            (0 until data.length()).map { data.getJSONObject(it) }
                .sortedBy { it.optInt("index", 0) }
                .map { o ->
                    val v = o.getJSONArray("embedding")
                    FloatArray(v.length()) { i -> v.getDouble(i).toFloat() }
                }
        }
    }

    private fun chatBody(req: ChatRequest, stream: Boolean): JSONObject {
        val messages = JSONArray()
        for (m in req.messages) messages.put(JSONObject().put("role", m.role).put("content", m.content))
        val o = JSONObject().put("model", req.model).put("messages", messages).put("stream", stream)
        req.temperature?.let { o.put("temperature", it) }
        req.maxTokens?.let { o.put("max_tokens", it) }
        return o
    }

    override fun chat(req: ChatRequest): Flow<ChatEvent> = callbackFlow {
        val call = streamClient.newCall(request(CHAT, chatBody(req, stream = true), sse = true))
        launch(Dispatchers.IO) {
            try {
                stream(call)
            } catch (e: Exception) {
                // annulée : rien de plus n'est envoyé
                if (isActive) runCatching { send(ChatEvent.Failed(AiErrors.fromException(e, streaming = true))) }
            } finally {
                channel.close()
            }
        }
        awaitClose { call.cancel() }
    }

    private suspend fun ProducerScope<ChatEvent>.stream(call: Call) {
        val start = System.nanoTime()
        val label = "POST $CHAT (flux)"
        val response = try {
            call.execute()
        } catch (e: IOException) {
            // attente de l'en-tête comprise : 60 s sans aucun octet, « Le serveur ne répond plus »
            val err = AiErrors.fromException(e, streaming = true)
            log.add("$label → échec : ${AiErrors.message(err.kind)} (${ms(start)} ms)")
            if (isActive) send(ChatEvent.Failed(err))
            return
        }
        response.use { r ->
            if (!r.isSuccessful) {
                val text = runCatching { readBody(r, ERROR_BODY.toLong()) }.getOrDefault("")
                log.add("$label → ${r.code} (${ms(start)} ms)")
                send(ChatEvent.Failed(AiErrors.fromHttp(r.code, text, modelRoute = true)))
                return
            }
            if (!r.header("Content-Type").orEmpty().startsWith("text/event-stream")) {
                // serveur qui ignore « stream » : réponse entière d'un bloc
                val result = try {
                    parseCompletion(readBody(r, MAX_BODY))
                } catch (e: Exception) {
                    log.add("$label → ${r.code}, réponse sans flux illisible (${ms(start)} ms)")
                    val err = when (e) {
                        is AiException -> e
                        is IOException -> AiErrors.fromException(e, streaming = false)
                        else -> AiException(AiException.Kind.PROTOCOL, cause = e)
                    }
                    send(ChatEvent.Failed(err))
                    return
                }
                log.add("$label → ${r.code}, réponse sans flux (${ms(start)} ms)")
                if (result.first.isNotEmpty()) send(ChatEvent.Delta(result.first))
                send(ChatEvent.Done(result.second, null))
                return
            }
            log.add("$label → ${r.code}, flux ouvert (${ms(start)} ms)")
            val sse = SseReader(r.body!!.byteStream())
            var events = 0
            var done = false
            var finish: String? = null
            var usage: Usage? = null
            var failure: AiException? = null
            try {
                while (true) {
                    val data = sse.next() ?: break
                    if (data.trim() == "[DONE]") {
                        done = true
                        break
                    }
                    val o = try {
                        JSONObject(data)
                    } catch (e: JSONException) {
                        failure = AiException(AiException.Kind.INTERRUPTED, cause = e, detail = "réponse du serveur illisible")
                        break
                    }
                    events++
                    val err = o.opt("error")
                    if (err != null && err != JSONObject.NULL) {
                        val msg = (err as? JSONObject)?.opt("message") as? String ?: err as? String
                        failure = AiException(AiException.Kind.STREAM_ERROR, serverMessage = msg)
                        break
                    }
                    val choice = o.optJSONArray("choices")?.optJSONObject(0)
                    val text = choice?.optJSONObject("delta")?.opt("content") as? String
                    if (!text.isNullOrEmpty()) send(ChatEvent.Delta(text))
                    (choice?.opt("finish_reason") as? String)?.let { finish = it }
                    o.optJSONObject("usage")?.let { u ->
                        usage = Usage(
                            (u.opt("prompt_tokens") as? Number)?.toInt(),
                            (u.opt("completion_tokens") as? Number)?.toInt(),
                        )
                    }
                }
            } catch (e: IOException) {
                failure = AiErrors.fromException(e, streaming = true)
            }
            val end = when {
                failure != null -> "échec : ${AiErrors.message(failure.kind)}"
                done -> "[DONE]"
                finish != null -> "fin sans [DONE]"
                else -> "interrompu"
            }
            log.add("$label : $events événements, ${sse.bytesRead} o, ${ms(start)} ms, $end")
            if (!isActive) return
            when {
                failure != null -> send(ChatEvent.Failed(failure))
                done || finish != null -> send(ChatEvent.Done(finish, usage))
                else -> send(ChatEvent.Failed(AiException(AiException.Kind.INTERRUPTED)))
            }
        }
    }

    companion object {
        private const val CHAT = "/v1/chat/completions"
        private val JSON = "application/json; charset=utf-8".toMediaType()

        /** Corps lu au plus (liste de modèles, réponse sans flux). */
        private const val MAX_BODY = 16L * 1024 * 1024

        /** Corps d'erreur gardé au plus (message du serveur). */
        private const val ERROR_BODY = 2048
    }
}
