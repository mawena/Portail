package com.mawena.fluluks.bridge

import android.content.Context
import com.mawena.fluluks.ai.Ai
import com.mawena.fluluks.ai.AiException
import com.mawena.fluluks.ai.AiHealth
import com.mawena.fluluks.ai.AiServerConfig
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

    fun attach(messenger: BinaryMessenger) {
        Ai.init(context)
        AiHostApi.setUp(messenger, this)
    }

    fun detach(messenger: BinaryMessenger) {
        AiHostApi.setUp(messenger, null)
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
        internal fun toFlutterError(e: Throwable): FlutterError = when (e) {
            is AiException -> FlutterError("ai", e.message, e.serverMessage)
            else -> HostApiImpl.toFlutterError(e)
        }
    }
}
