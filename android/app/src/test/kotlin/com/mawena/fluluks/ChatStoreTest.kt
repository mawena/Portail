package com.mawena.fluluks

import com.mawena.fluluks.ai.AiServerConfig
import com.mawena.fluluks.ai.chat.ChatDao
import com.mawena.fluluks.ai.chat.ChatStore
import com.mawena.fluluks.ai.chat.Conversation
import com.mawena.fluluks.ai.chat.Message
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.files.FilesException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Historique des conversations (phase 15, T5) : logique de [ChatStore] sur une base en mémoire simulée ; les requêtes
 * SQL de Room sont vérifiées par `ChatStoreInstrumentedTest`.
 */
class ChatStoreTest {
    /** DAO en mémoire, mêmes règles que les requêtes de [ChatDao]. */
    class MemChatDao : ChatDao {
        val convs = linkedMapOf<Long, Conversation>()
        val msgs = linkedMapOf<Long, Message>()
        private var nextC = 1L
        private var nextM = 1L

        override fun conversations() = convs.values.sortedWith(compareByDescending<Conversation> { it.updatedAt }.thenByDescending { it.id })
        override fun conversation(id: Long) = convs[id]
        override fun insertConversation(c: Conversation): Long = nextC++.also { convs[it] = c.copy(id = it) }
        override fun updateConversation(c: Conversation) {
            if (c.id in convs) convs[c.id] = c
        }
        override fun deleteConversation(id: Long): Int {
            msgs.values.removeAll { it.conversationId == id }
            return if (convs.remove(id) != null) 1 else 0
        }
        override fun messages(conversationId: Long) = msgs.values.filter { it.conversationId == conversationId }.sortedBy { it.id }
        override fun message(id: Long) = msgs[id]
        override fun insertMessage(m: Message): Long = nextM++.also { msgs[it] = m.copy(id = it) }
        override fun updateMessage(m: Message) {
            if (m.id in msgs) msgs[m.id] = m
        }
        override fun deleteMessage(id: Long) {
            msgs.remove(id)
        }
        override fun deleteMessages(conversationId: Long) {
            msgs.values.removeAll { it.conversationId == conversationId }
        }
        override fun markInterrupted(error: String): Int {
            var n = 0
            for ((k, m) in msgs) {
                if (m.state == Message.STREAMING) {
                    msgs[k] = m.copy(state = Message.INTERRUPTED, error = error)
                    n++
                }
            }
            return n
        }
    }

    private var clock = 1_000L
    private val servers = mutableListOf(
        AiServerConfig("s1", "Atelier", "https://atelier.mawena.cloud", isDefault = false, defaultModel = "petit"),
        AiServerConfig("s2", "Maison", "http://192.168.0.10:11434", isDefault = true, defaultModel = "llama3"),
    )
    private val dao = MemChatDao()
    private var transactions = 0
    private val store = ChatStore(dao, { servers.toList() }, { block -> transactions++; block() }, { clock++ })

    private fun refused(block: () -> Unit): FilesException {
        try {
            block()
        } catch (e: FilesException) {
            return e
        }
        fail("refus attendu")
        throw AssertionError()
    }

    @Test fun createUsesDefaultServerAndItsModel() {
        val c = store.create()
        assertEquals("s2", c.serverId)
        assertEquals("llama3", c.model)
        assertNull(c.systemPrompt)
        assertEquals("", c.title)
        assertEquals(c, store.conversation(c.id))
    }

    @Test fun createOnChosenServerTakesThatServersModel() {
        val c = store.create(serverId = "s1")
        assertEquals("s1", c.serverId)
        assertEquals("petit", c.model)
        assertEquals("autre", store.create(serverId = "s1", model = "autre").model)
    }

    @Test fun createWithoutAnyServerLeavesServerEmpty() {
        servers.clear()
        val c = store.create()
        assertNull(c.serverId)
        assertNull(c.model)
    }

    @Test fun listMostRecentFirst() {
        val a = store.create()
        val b = store.create()
        assertEquals(listOf(b.id, a.id), store.conversations().map { it.id })
        store.addUserMessage(a.id, "Bonjour")
        assertEquals(listOf(a.id, b.id), store.conversations().map { it.id })
    }

    @Test fun autoTitleFromFirstMessage() {
        val c = store.create()
        store.addUserMessage(c.id, "  Écris un poème\nsur la mer  ")
        assertEquals("Écris un poème sur la mer", store.conversation(c.id).title)
        store.addUserMessage(c.id, "Un autre message")
        assertEquals("Écris un poème sur la mer", store.conversation(c.id).title)
    }

    @Test fun autoTitleCutAt40Characters() {
        assertEquals(40, ChatStore.autoTitle("a".repeat(100)).length)
        assertEquals("a".repeat(39) + "…", ChatStore.autoTitle("a".repeat(100)))
        assertEquals("a".repeat(40), ChatStore.autoTitle("a".repeat(40)))
        assertEquals("un deux", ChatStore.autoTitle("un\r\n\tdeux"))
        // jamais une moitié d'émoji
        val t = ChatStore.autoTitle("😀".repeat(50))
        assertEquals(40, t.codePointCount(0, t.length))
        assertEquals("😀".repeat(39) + "…", t)
    }

    @Test fun renameKeepsTitleAgainstAutoTitle() {
        val c = store.create()
        store.rename(c.id, "  Mes notes\n ")
        assertEquals("Mes notes", store.conversation(c.id).title)
        store.addUserMessage(c.id, "Bonjour")
        assertEquals("Mes notes", store.conversation(c.id).title)
        store.rename(c.id, "Autre titre")
        assertEquals("Autre titre", store.conversation(c.id).title)
    }

    @Test fun renameRefusesEmptyTitle() {
        val c = store.create()
        assertEquals(EngineError.FL_EINVAL, refused { store.rename(c.id, " \n ") }.code)
    }

    @Test fun deleteRemovesMessagesToo() {
        val c = store.create()
        val keep = store.create()
        store.addUserMessage(c.id, "Bonjour")
        store.startReply(c.id)
        store.addUserMessage(keep.id, "Reste")
        store.delete(c.id)
        assertEquals(listOf(keep.id), store.conversations().map { it.id })
        assertTrue(dao.msgs.values.none { it.conversationId == c.id })
        assertEquals(1, dao.msgs.size)
        assertTrue(transactions > 0)
    }

    @Test fun missingConversationRefused() {
        assertEquals(EngineError.FL_ENOENT, refused { store.conversation(42) }.code)
        assertEquals(EngineError.FL_ENOENT, refused { store.rename(42, "x") }.code)
        assertEquals(EngineError.FL_ENOENT, refused { store.addUserMessage(42, "x") }.code)
    }

    @Test fun serverModelAndSystemPromptPerConversation() {
        val a = store.create()
        val b = store.create()
        store.setModel(a.id, "s1", "petit")
        store.setSystemPrompt(a.id, "  Réponds en français.  ")
        assertEquals("s1", store.conversation(a.id).serverId)
        assertEquals("petit", store.conversation(a.id).model)
        assertEquals("Réponds en français.", store.conversation(a.id).systemPrompt)
        assertEquals("s2", store.conversation(b.id).serverId)
        assertNull(store.conversation(b.id).systemPrompt)
        store.setSystemPrompt(a.id, "   ")
        assertNull(store.conversation(a.id).systemPrompt)
    }

    @Test fun messagesInOrderWithStates() {
        val c = store.create()
        val u = store.addUserMessage(c.id, "Bonjour")
        val r = store.startReply(c.id)
        assertEquals(Message.DONE, u.state)
        assertEquals("user", u.role)
        assertEquals(Message.STREAMING, r.state)
        assertEquals("assistant", r.role)
        assertEquals("", r.content)
        store.finishReply(r.id, "Salut !", Message.DONE, null)
        val ms = store.messages(c.id)
        assertEquals(listOf("Bonjour", "Salut !"), ms.map { it.content })
        assertEquals(Message.DONE, ms[1].state)
    }

    @Test fun interruptedGenerationFoundInterruptedAtStartup() {
        val c = store.create()
        store.addUserMessage(c.id, "Bonjour")
        val r = store.startReply(c.id)
        // Portail s'arrête ; au démarrage suivant :
        val again = ChatStore(dao, { servers.toList() }, { it() }, { clock++ })
        assertEquals(1, again.recoverInterrupted())
        val m = again.messages(c.id).single { it.id == r.id }
        assertEquals(Message.INTERRUPTED, m.state)
        assertTrue(m.error!!.isNotEmpty())
        assertTrue(again.messages(c.id).none { it.state == Message.STREAMING })
    }
}
