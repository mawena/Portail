package com.mawena.fluluks.ai.chat

import androidx.annotation.VisibleForTesting
import com.mawena.fluluks.ai.AiException
import com.mawena.fluluks.ai.AiProvider
import com.mawena.fluluks.ai.ChatEvent
import com.mawena.fluluks.ai.ChatMessage
import com.mawena.fluluks.ai.ChatRequest
import com.mawena.fluluks.ai.DeltaPump
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.files.FilesException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Destinataire des réponses en cours (le pont vers Dart). [delta] : texte reçu, par lots ; [delivered] à appeler quand
 * Dart l'a reçu (acquittement). [state] : réponse terminée (arrêtée, en échec), avec tout son texte.
 */
interface ChatSink {
    fun delta(conversationId: Long, messageId: Long, text: String, delivered: () -> Unit)

    fun state(m: Message)
}

/**
 * Générations en cours (phase 15, T6) : une à la fois par conversation, [maxParallel] au plus en tout. Le message de
 * l'utilisateur et la réponse vide (« en cours ») sont écrits avant l'envoi ; le texte reçu part vers [sink] par lots
 * (au plus un toutes les [batchMs] ms, [maxBatch] caractères, [maxInflight] lots non acquittés : au-delà, la lecture
 * du flux attend) ; la réponse complète est écrite une seule fois, à la fin. Arrêter annule l'appel HTTP et garde le
 * texte reçu ; plus aucun lot ne part ensuite. Les générations continuent quand l'écran se ferme. Rien de ce qui est
 * envoyé ou reçu n'est écrit dans un journal.
 */
class ChatSessions(
    private val store: () -> ChatStore,
    private val providerFor: (serverId: String) -> AiProvider,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val batchMs: Long = BATCH_MS,
    private val maxBatch: Int = MAX_BATCH,
    private val maxInflight: Int = MAX_INFLIGHT,
    private val maxParallel: Int = MAX_PARALLEL,
    private val maxHistory: Int = MAX_HISTORY,
    private val ackTimeoutMs: Long = ACK_TIMEOUT_MS,
) {
    /** Le pont, quand Dart est là ; sans lui, les lots ne partent pas (le texte reste dans la réponse finale). */
    @Volatile var sink: ChatSink? = null

    private val jobs = HashMap<Long, Job>()

    /** Conversations dont une réponse est en cours. */
    fun running(): Set<Long> = synchronized(jobs) { jobs.keys.toSet() }

    @VisibleForTesting
    fun job(conversationId: Long): Job? = synchronized(jobs) { jobs[conversationId] }

    /** Envoie [text] et lance la réponse ; rend la réponse vide « en cours ». FL_EBUSY si une réponse est en cours. */
    fun send(conversationId: Long, text: String): Message = start(conversationId) {
        val s = store()
        s.addUserMessage(conversationId, text)
        s.startReply(conversationId)
    }

    /** Remplace la dernière réponse par une nouvelle (même historique, même modèle) ; sert aussi à « Réessayer ». */
    fun regenerate(conversationId: Long): Message = start(conversationId) {
        val s = store()
        s.conversation(conversationId)
        s.messages(conversationId).lastOrNull()?.takeIf { it.role == ROLE_ASSISTANT }?.let { s.deleteMessage(it.id) }
        s.startReply(conversationId)
    }

    /** Arrête la réponse en cours de la conversation (sans effet s'il n'y en a pas). */
    fun stop(conversationId: Long) {
        job(conversationId)?.cancel()
    }

    private fun start(conversationId: Long, prepare: () -> Message): Message {
        synchronized(jobs) {
            if (conversationId in jobs) throw FilesException(EngineError.FL_EBUSY, MSG_BUSY)
            if (jobs.size >= maxParallel) throw FilesException(EngineError.FL_EBUSY, MSG_TOO_MANY)
            val reply = prepare()
            val job = scope.launch(start = CoroutineStart.LAZY) { generate(reply) }
            jobs[conversationId] = job
            job.invokeOnCompletion { synchronized(jobs) { if (jobs[conversationId] === job) jobs.remove(conversationId) } }
            job.start()
            return reply
        }
    }

    private class Outcome(val state: String, val error: String? = null, val detail: String? = null)

    private suspend fun generate(reply: Message) {
        val text = StringBuilder()
        var outcome: Outcome? = null
        val pump = DeltaPump(
            send = { sink?.let { s -> { chunk, delivered -> s.delta(reply.conversationId, reply.id, chunk, delivered) } } },
            batchMs = batchMs,
            maxBatch = maxBatch,
            maxInflight = maxInflight,
            ackTimeoutMs = ackTimeoutMs,
        )
        try {
            val req = request(reply)
            val provider = providerFor(req.first)
            try {
                pump.run {
                    provider.chat(req.second).collect { ev ->
                        when (ev) {
                            is ChatEvent.Delta -> {
                                synchronized(text) { text.append(ev.text) }
                                pump.offer(ev.text)
                            }
                            is ChatEvent.Done -> outcome = Outcome(Message.DONE)
                            is ChatEvent.Failed -> outcome = Outcome(Message.FAILED, ev.error.message, ev.error.serverMessage)
                        }
                    }
                }
            } finally {
                (provider as? AutoCloseable)?.close()
            }
            if (outcome == null) outcome = Outcome(Message.FAILED, AiException(AiException.Kind.INTERRUPTED).message)
        } catch (e: CancellationException) {
            if (outcome == null) outcome = Outcome(Message.STOPPED)
            throw e
        } catch (e: AiException) {
            outcome = Outcome(Message.FAILED, e.message, e.serverMessage)
        } catch (e: FilesException) {
            outcome = Outcome(Message.FAILED, e.message)
        } catch (e: Exception) {
            outcome = Outcome(Message.FAILED, MSG_UNEXPECTED)
        } finally {
            pump.close()
            withContext(NonCancellable) {
                val o = outcome ?: Outcome(Message.STOPPED)
                val done = runCatching { store().finishReply(reply.id, synchronized(text) { text.toString() }, o.state, o.error, o.detail) }
                    .getOrNull()
                    ?: reply.copy(content = text.toString(), state = o.state, error = o.error, errorDetail = o.detail)
                runCatching { sink?.state(done) }
            }
        }
    }

    /** Serveur et requête : prompt système d'abord, puis les [maxHistory] derniers messages non vides. */
    private fun request(reply: Message): Pair<String, ChatRequest> {
        val s = store()
        val c = s.conversation(reply.conversationId)
        val serverId = c.serverId ?: throw FilesException(EngineError.FL_ENOENT, MSG_NO_SERVER)
        val model = c.model ?: throw FilesException(EngineError.FL_EINVAL, MSG_NO_MODEL)
        val history = s.messages(c.id)
            .filter { it.id != reply.id && it.content.isNotEmpty() && (it.role == ROLE_USER || it.role == ROLE_ASSISTANT) }
            .takeLast(maxHistory)
            .map { ChatMessage(it.role, it.content) }
        val all = listOfNotNull(c.systemPrompt?.let { ChatMessage("system", it) }) + history
        return serverId to ChatRequest(model, all)
    }

    companion object {
        const val BATCH_MS = 50L
        const val MAX_BATCH = 16 * 1024
        const val MAX_INFLIGHT = 4
        const val MAX_PARALLEL = 3
        const val MAX_HISTORY = 200
        const val ACK_TIMEOUT_MS = 5_000L
        const val ROLE_USER = "user"
        const val ROLE_ASSISTANT = "assistant"

        const val MSG_BUSY = "Une réponse est déjà en cours dans cette conversation"
        const val MSG_TOO_MANY = "Trois réponses sont déjà en cours : attendez la fin de l'une d'elles"
        const val MSG_NO_SERVER = "Aucun serveur IA pour cette conversation : ajoutez-en un dans Serveurs IA"
        const val MSG_NO_MODEL = "Aucun modèle choisi : choisissez un modèle pour cette conversation"
        const val MSG_UNEXPECTED = "Erreur inattendue : la réponse n'a pas pu être obtenue"
    }
}
