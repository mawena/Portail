package com.mawena.fluluks.bridge

import android.content.Context
import com.mawena.fluluks.ai.Ai
import com.mawena.fluluks.ai.AiException
import com.mawena.fluluks.ai.AiHealth
import com.mawena.fluluks.ai.AiServerConfig
import com.mawena.fluluks.ai.chat.ChatSink
import com.mawena.fluluks.ai.chat.Chats
import com.mawena.fluluks.ai.chat.Conversation
import com.mawena.fluluks.ai.chat.Message
import io.flutter.plugin.common.BinaryMessenger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Pont Pigeon de l'intégration IA (phase 15) : serveurs, chat, automatisations. Réponses sur le fil principal ; le
 * réseau et le disque en Dispatchers.IO. Une [AiException] devient le code `ai` (message français, détails : message
 * du serveur) ; jamais de clé ni de contenu de conversation dans une erreur.
 */
class AiHostApiImpl(private val context: Context) : AiHostApi {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private var sink: ChatSink? = null

    fun attach(messenger: BinaryMessenger) {
        Ai.init(context)
        Chats.init(context)
        AiHostApi.setUp(messenger, this)
        val events = AiEventsApi(messenger)
        // Lots et fins de réponse envoyés sur le fil principal, dans l'ordre ; la réponse de Dart acquitte le lot.
        sink = object : ChatSink {
            override fun delta(conversationId: Long, messageId: Long, text: String, delivered: () -> Unit) {
                scope.launch { events.onChatDelta(conversationId, messageId, text) { delivered() } }
            }

            override fun state(m: com.mawena.fluluks.ai.chat.Message) {
                scope.launch { events.onChatState(messageMsg(m)) { /* réponse ignorée */ } }
            }
        }.also { Chats.sessions().sink = it }
    }

    fun detach(messenger: BinaryMessenger) {
        AiHostApi.setUp(messenger, null)
        if (Chats.sessions().sink === sink) Chats.sessions().sink = null
        sink = null
        scope.cancel()
    }

    // --- serveurs (T3)

    private fun serverMsg(c: AiServerConfig) = AiServerMsg(c.id, c.name, c.baseUrl, c.hasKey, c.isDefault, c.defaultModel)

    override fun aiServers(): List<AiServerMsg> = sync { Ai.servers().list().map(::serverMsg) }

    override fun saveAiServer(server: AiServerMsg, key: ByteArray?): AiServerMsg = sync {
        try {
            serverMsg(Ai.servers().save(AiServerConfig(server.id, server.name, server.baseUrl), key))
        } finally {
            key?.fill(0)
        }
    }

    override fun removeAiServerKey(serverId: String) = sync { Ai.servers().removeKey(serverId) }

    override fun deleteAiServer(serverId: String) = sync { Ai.servers().delete(serverId) }

    override fun setDefaultAiServer(serverId: String) = sync { Ai.servers().setDefault(serverId) }

    override fun testAiServer(serverId: String, callback: (Result<AiTestResultMsg>) -> Unit) = io(callback) {
        val r = Ai.servers().test(serverId)
        AiTestResultMsg(r.ok, r.version, r.models, r.log, r.error, r.detail)
    }

    override fun aiModels(serverId: String, callback: (Result<List<String>>) -> Unit) = io(callback) {
        Ai.servers().models(serverId)
    }

    override fun setAiDefaultModel(serverId: String, model: String?) = sync { Ai.servers().setDefaultModel(serverId, model) }

    override fun aiHealth(serverId: String, callback: (Result<AiHealthMsg>) -> Unit) = io(callback) {
        val h = Ai.servers().health(serverId)
        val state = when (h.state) {
            AiHealth.State.ONLINE -> "online"
            AiHealth.State.OFFLINE -> "offline"
            AiHealth.State.KEY_REFUSED -> "key-refused"
        }
        AiHealthMsg(serverId, state, h.version, h.modelCount?.toLong(), h.error?.message, h.error?.serverMessage)
    }

    override fun aiAttemptLog(serverId: String): List<String> = sync { Ai.servers().lastLog(serverId) }

    // --- historique des conversations (T5)

    override fun conversations(callback: (Result<List<ConversationMsg>>) -> Unit) = io(callback) {
        Chats.store().conversations().map(::conversationMsg)
    }

    override fun conversation(id: Long, callback: (Result<ConversationDetailMsg>) -> Unit) = io(callback) {
        val s = Chats.store()
        ConversationDetailMsg(conversationMsg(s.conversation(id)), s.messages(id).map(::messageMsg))
    }

    override fun createConversation(serverId: String?, model: String?, callback: (Result<ConversationMsg>) -> Unit) =
        io(callback) { conversationMsg(Chats.store().create(serverId, model)) }

    override fun renameConversation(id: Long, title: String, callback: (Result<Unit>) -> Unit) =
        io(callback) { Chats.store().rename(id, title) }

    override fun deleteConversation(id: Long, callback: (Result<Unit>) -> Unit) = io(callback) { Chats.store().delete(id) }

    override fun setConversationModel(id: Long, serverId: String?, model: String?, callback: (Result<Unit>) -> Unit) =
        io(callback) { Chats.store().setModel(id, serverId, model) }

    override fun setSystemPrompt(id: Long, prompt: String?, callback: (Result<Unit>) -> Unit) =
        io(callback) { Chats.store().setSystemPrompt(id, prompt) }

    // --- réponses en flux (T6)

    override fun sendChatMessage(conversationId: Long, text: String, callback: (Result<ChatMessageMsg>) -> Unit) =
        io(callback) { messageMsg(Chats.sessions().send(conversationId, text)) }

    override fun stopGeneration(conversationId: Long) = sync { Chats.sessions().stop(conversationId) }

    override fun regenerate(conversationId: Long, callback: (Result<ChatMessageMsg>) -> Unit) =
        io(callback) { messageMsg(Chats.sessions().regenerate(conversationId)) }

    override fun runningChats(): List<Long> = sync { Chats.sessions().running().toList() }

    // --- utilitaires

    private fun <T> io(callback: (Result<T>) -> Unit, block: suspend () -> T) {
        scope.launch {
            val result = try {
                Result.success(kotlinx.coroutines.withContext(Dispatchers.IO) { block() })
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                Result.failure(toFlutterError(e))
            }
            callback(result)
        }
    }

    private inline fun <T> sync(block: () -> T): T = try {
        block()
    } catch (e: Throwable) {
        throw toFlutterError(e)
    }

    companion object {
        internal fun conversationMsg(c: Conversation) =
            ConversationMsg(c.id, c.title, c.serverId, c.model, c.systemPrompt, c.createdAt, c.updatedAt)

        internal fun messageMsg(m: Message) =
            ChatMessageMsg(m.id, m.conversationId, m.role, m.content, m.state, m.error, m.errorDetail, m.createdAt)

        internal fun toFlutterError(e: Throwable): FlutterError = when (e) {
            is AiException -> FlutterError("ai", e.message, e.serverMessage)
            else -> HostApiImpl.toFlutterError(e)
        }
    }
}
