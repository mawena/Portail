package com.mawena.fluluks.bridge

import android.content.Context
import com.mawena.fluluks.ai.Ai
import com.mawena.fluluks.ai.AiException
import com.mawena.fluluks.ai.AiHealth
import com.mawena.fluluks.ai.AiServerConfig
import com.mawena.fluluks.ai.AiServers
import com.mawena.fluluks.ai.TrustedCerts
import com.mawena.fluluks.ai.auto.Automation
import com.mawena.fluluks.ai.auto.AutomationRun
import com.mawena.fluluks.ai.auto.AutomationSink
import com.mawena.fluluks.ai.auto.AutomationVar
import com.mawena.fluluks.ai.auto.Automations
import com.mawena.fluluks.ai.auto.Autos
import com.mawena.fluluks.ai.auto.Template
import com.mawena.fluluks.ai.chat.ChatSink
import com.mawena.fluluks.ai.chat.Chats
import com.mawena.fluluks.ai.chat.Conversation
import com.mawena.fluluks.ai.chat.Message
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.files.FilesException
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
    private var autoSink: AutomationSink? = null

    fun attach(messenger: BinaryMessenger) {
        Ai.init(context)
        Chats.init(context)
        Autos.init(context)
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
        autoSink = object : AutomationSink {
            override fun delta(runId: Long, text: String, delivered: () -> Unit) {
                scope.launch { events.onAutomationDelta(runId, text) { delivered() } }
            }

            override fun state(r: AutomationRun) {
                scope.launch { events.onAutomationState(runMsg(r)) { /* réponse ignorée */ } }
            }
        }.also { Autos.live().sink = it }
    }

    fun detach(messenger: BinaryMessenger) {
        AiHostApi.setUp(messenger, null)
        if (Chats.sessions().sink === sink) Chats.sessions().sink = null
        sink = null
        if (Autos.live().sink === autoSink) Autos.live().sink = null
        autoSink = null
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

    /** Ses automatisations sont désactivées et leur planification annulée ; son certificat approuvé est oublié. */
    override fun deleteAiServer(serverId: String, callback: (Result<Unit>) -> Unit) = io(callback) {
        val hostPort = Ai.servers().get(serverId)?.let { TrustedCerts.hostPort(it.baseUrl) }
        Ai.servers().delete(serverId)
        Autos.get().serverDeleted(serverId)
        if (hostPort != null && Ai.servers().list().none { TrustedCerts.hostPort(it.baseUrl) == hostPort }) {
            Ai.certs().forget(hostPort)
        }
    }

    override fun trustAiCertificate(serverId: String, fingerprint: String) = sync {
        val s = Ai.servers().get(serverId) ?: throw FilesException(EngineError.FL_ENOENT, AiServers.MSG_GONE)
        Ai.certs().trust(TrustedCerts.hostPort(s.baseUrl), fingerprint)
    }

    override fun setDefaultAiServer(serverId: String) = sync { Ai.servers().setDefault(serverId) }

    override fun testAiServer(serverId: String, callback: (Result<AiTestResultMsg>) -> Unit) = io(callback) {
        val r = Ai.servers().test(serverId)
        AiTestResultMsg(r.ok, r.version, r.models, r.log, r.error, r.detail, r.certificate?.fingerprint, r.certificate?.changed)
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

    override fun deleteConversation(id: Long, callback: (Result<Unit>) -> Unit) = io(callback) { Chats.sessions().delete(id) }

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

    // --- automatisations (T8)

    private fun automationMsg(a: Automation, autos: Automations) = AutomationMsg(
        a.id, a.name, a.template, autos.variablesOf(a).map { AutomationVarMsg(it.name, it.default) }, a.serverId, a.model,
        a.systemPrompt, a.trigger, a.intervalMinutes?.toLong(), a.enabled, autos.lastRun(a.id)?.let(::runMsg),
    )

    override fun automations(callback: (Result<List<AutomationMsg>>) -> Unit) = io(callback) {
        val autos = Autos.get()
        autos.list().map { automationMsg(it, autos) }
    }

    override fun saveAutomation(automation: AutomationMsg, callback: (Result<AutomationMsg>) -> Unit) = io(callback) {
        val autos = Autos.get()
        val a = Automation(
            id = automation.id, name = automation.name, template = automation.template, variables = "",
            serverId = automation.serverId, model = automation.model, systemPrompt = automation.systemPrompt,
            trigger = automation.trigger, intervalMinutes = automation.intervalMinutes?.toInt(), enabled = automation.enabled,
            createdAt = 0, updatedAt = 0,
        )
        automationMsg(autos.save(a, automation.variables.map { AutomationVar(it.name, it.defaultValue) }), autos)
    }

    override fun deleteAutomation(id: Long, callback: (Result<Unit>) -> Unit) = io(callback) { Autos.get().delete(id) }

    override fun setAutomationEnabled(id: Long, enabled: Boolean, callback: (Result<AutomationMsg>) -> Unit) =
        io(callback) { Autos.get().let { automationMsg(it.setEnabled(id, enabled), it) } }

    override fun duplicateAutomation(id: Long, callback: (Result<AutomationMsg>) -> Unit) =
        io(callback) { Autos.get().let { automationMsg(it.duplicate(id), it) } }

    override fun templateVariables(template: String): List<String> = sync { Template.variables(template) }

    override fun runAutomation(id: Long, values: Map<String, String>, callback: (Result<AutomationRunMsg>) -> Unit) =
        io(callback) { runMsg(Autos.get().start(id, values)) }

    override fun stopAutomationRun(runId: Long) = sync { Autos.live().stop(runId) }

    override fun runningAutomationRuns(): List<Long> = sync { Autos.live().running().toList() }

    override fun automationRuns(automationId: Long, callback: (Result<List<AutomationRunMsg>>) -> Unit) =
        io(callback) { Autos.get().runs(automationId).map(::runMsg) }

    override fun automationRun(runId: Long, callback: (Result<AutomationRunMsg>) -> Unit) =
        io(callback) { runMsg(Autos.get().run(runId)) }

    override fun clearAutomationRuns(automationId: Long, callback: (Result<Unit>) -> Unit) =
        io(callback) { Autos.get().clearRuns(automationId) }

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

        internal fun runMsg(r: AutomationRun) = AutomationRunMsg(
            r.id, r.automationId, r.startedAt, r.endedAt, r.state, r.scheduled, r.input, r.output, r.error, r.errorDetail,
        )

        internal fun toFlutterError(e: Throwable): FlutterError = when (e) {
            is AiException -> FlutterError("ai", e.message, e.serverMessage)
            else -> HostApiImpl.toFlutterError(e)
        }
    }
}
