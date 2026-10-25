package com.mawena.fluluks.ai.chat

import android.content.Context
import androidx.annotation.VisibleForTesting
import androidx.room.Room
import com.mawena.fluluks.ai.Ai
import com.mawena.fluluks.ai.AiServerConfig
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.files.FilesException

/**
 * Historique local des conversations (phase 15, spec § 23) : conversations et messages dans Room (stockage privé de
 * l'application), jamais dans un journal. [servers] donne les serveurs IA enregistrés (serveur et modèle par défaut
 * des nouvelles conversations) ; [tx] exécute un bloc dans une transaction ; [now] : horloge en millisecondes. Appelé
 * hors du fil principal.
 */
class ChatStore(
    private val dao: ChatDao,
    private val servers: () -> List<AiServerConfig>,
    private val tx: (() -> Unit) -> Unit,
    private val now: () -> Long = System::currentTimeMillis,
) {
    /**
     * Au démarrage : une réponse restée « en cours » a été coupée par l'arrêt de Portail ; elle devient
     * « Interrompue ». Rend le nombre de réponses marquées.
     */
    fun recoverInterrupted(): Int = dao.markInterrupted(MSG_INTERRUPTED)

    /** Plus récente d'abord. */
    fun conversations(): List<Conversation> = dao.conversations()

    /** [FilesException] FL_ENOENT si elle a été supprimée. */
    fun conversation(id: Long): Conversation =
        dao.conversation(id) ?: throw FilesException(EngineError.FL_ENOENT, MSG_GONE)

    fun messages(conversationId: Long): List<Message> = dao.messages(conversationId)

    /**
     * Nouvelle conversation, au titre vide (fixé par le premier message). Sans [serverId] : serveur par défaut ; sans
     * [model] : modèle par défaut du serveur.
     */
    fun create(serverId: String? = null, model: String? = null): Conversation {
        val all = servers()
        val server = if (serverId == null) all.firstOrNull { it.isDefault } ?: all.firstOrNull() else all.firstOrNull { it.id == serverId }
        val t = now()
        val c = Conversation(
            title = "", serverId = serverId ?: server?.id, model = model ?: server?.defaultModel,
            systemPrompt = null, createdAt = t, updatedAt = t,
        )
        return c.copy(id = dao.insertConversation(c))
    }

    /** Titre choisi (sans saut de ligne) ; [FilesException] FL_EINVAL s'il est vide. */
    fun rename(id: Long, title: String) {
        val clean = oneLine(title)
        if (clean.isEmpty()) throw FilesException(EngineError.FL_EINVAL, "Titre vide")
        tx { dao.updateConversation(conversation(id).copy(title = clean)) }
    }

    /** Supprime la conversation et ses messages. */
    fun delete(id: Long) {
        tx {
            dao.deleteMessages(id)
            dao.deleteConversation(id)
        }
    }

    fun setModel(id: Long, serverId: String?, model: String?) {
        tx { dao.updateConversation(conversation(id).copy(serverId = serverId, model = model?.trim()?.ifEmpty { null })) }
    }

    /** Prompt système de la conversation ; vide : aucun. */
    fun setSystemPrompt(id: Long, prompt: String?) {
        tx { dao.updateConversation(conversation(id).copy(systemPrompt = prompt?.trim()?.ifEmpty { null })) }
    }

    /** Message de l'utilisateur ; le premier donne son titre à une conversation qui n'en a pas. */
    fun addUserMessage(conversationId: Long, text: String): Message {
        var out: Message? = null
        tx {
            val c = conversation(conversationId)
            val t = now()
            val m = Message(conversationId = c.id, role = "user", content = text, state = Message.DONE, error = null, createdAt = t)
            out = m.copy(id = dao.insertMessage(m))
            dao.updateConversation(c.copy(title = c.title.ifEmpty { autoTitle(text) }, updatedAt = t))
        }
        return out!!
    }

    /** Réponse vide, « en cours », écrite avant l'envoi de la requête. */
    fun startReply(conversationId: Long): Message {
        var out: Message? = null
        tx {
            val c = conversation(conversationId)
            val t = now()
            val m = Message(conversationId = c.id, role = "assistant", content = "", state = Message.STREAMING, error = null, createdAt = t)
            out = m.copy(id = dao.insertMessage(m))
            dao.updateConversation(c.copy(updatedAt = t))
        }
        return out!!
    }

    /** Réponse terminée (une seule écriture, à la fin) : [state] parmi done, stopped, failed. */
    fun finishReply(messageId: Long, content: String, state: String, error: String?) {
        val m = dao.message(messageId) ?: return
        dao.updateMessage(m.copy(content = content, state = state, error = error))
    }

    fun deleteMessage(messageId: Long) = dao.deleteMessage(messageId)

    companion object {
        const val MSG_GONE = "Cette conversation n'existe plus"
        const val MSG_INTERRUPTED = "Réponse interrompue : Portail a été fermé pendant la génération"
        const val TITLE_MAX = 40

        private val SPACES = Regex("\\s+")

        private fun oneLine(s: String) = s.replace(SPACES, " ").trim()

        /** Titre tiré d'un message : une ligne, [TITLE_MAX] caractères au plus (« … » compris s'il est coupé). */
        fun autoTitle(text: String): String {
            val s = oneLine(text)
            val n = s.codePointCount(0, s.length)
            if (n <= TITLE_MAX) return s
            return s.substring(0, s.offsetByCodePoints(0, TITLE_MAX - 1)).trimEnd() + "…"
        }
    }
}

/**
 * Historique de l'application : `chat.db`, ouvert une fois par processus. Les réponses interrompues par l'arrêt
 * précédent sont retrouvées au premier accès (hors du fil principal), avant toute nouvelle génération.
 */
object Chats {
    @Volatile private var store: ChatStore? = null
    @Volatile private var recovered = false

    @Synchronized
    fun init(context: Context) {
        if (store != null) return
        val db = Room.databaseBuilder(context.applicationContext, ChatDatabase::class.java, ChatDatabase.NAME).build()
        store = ChatStore(db.chatDao(), { Ai.servers().list() }, { block -> db.runInTransaction(block) })
    }

    fun store(): ChatStore {
        val s = store ?: throw FilesException(EngineError.FL_ENODEV, "Historique indisponible")
        if (!recovered) {
            synchronized(this) {
                if (!recovered) {
                    s.recoverInterrupted()
                    recovered = true
                }
            }
        }
        return s
    }

    @VisibleForTesting
    fun resetForTests(s: ChatStore?) {
        store = s
        recovered = true
    }
}
