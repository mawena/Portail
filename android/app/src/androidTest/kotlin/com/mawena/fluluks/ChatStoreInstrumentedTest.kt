package com.mawena.fluluks

import androidx.room.Room
import androidx.room.testing.MigrationTestHelper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.mawena.fluluks.ai.AiServerConfig
import com.mawena.fluluks.ai.chat.ChatDatabase
import com.mawena.fluluks.ai.chat.ChatStore
import com.mawena.fluluks.ai.chat.Message
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Historique des conversations sur la vraie base Room (phase 15, T5), en mémoire, sur le Pixel. */
@RunWith(AndroidJUnit4::class)
class ChatStoreInstrumentedTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val db = Room.inMemoryDatabaseBuilder(context, ChatDatabase::class.java).build()
    private var clock = 1_000L
    private val servers = listOf(AiServerConfig("s1", "Essai", "http://127.0.0.1:8765", isDefault = true, defaultModel = "essai-court"))
    private val store = ChatStore(db.chatDao(), { servers }, { db.runInTransaction(it) }, { clock++ })

    @get:Rule val migrations = MigrationTestHelper(InstrumentationRegistry.getInstrumentation(), ChatDatabase::class.java)

    @After fun close() = db.close()

    @Test fun listOrderRenameDeleteCascade() {
        val a = store.create()
        val b = store.create()
        assertEquals(listOf(b.id, a.id), store.conversations().map { it.id })
        store.addUserMessage(a.id, "Premier\nmessage")
        val r = store.startReply(a.id)
        store.finishReply(r.id, "Réponse", Message.DONE, null)
        assertEquals(listOf(a.id, b.id), store.conversations().map { it.id })
        assertEquals("Premier message", store.conversation(a.id).title)
        assertEquals("essai-court", store.conversation(a.id).model)
        store.rename(a.id, "Renommée")
        assertEquals("Renommée", store.conversation(a.id).title)
        assertEquals(listOf("Premier\nmessage", "Réponse"), store.messages(a.id).map { it.content })
        store.delete(a.id)
        assertEquals(listOf(b.id), store.conversations().map { it.id })
        assertTrue(store.messages(a.id).isEmpty())
    }

    @Test fun streamingFoundInterrupted() {
        val c = store.create()
        store.addUserMessage(c.id, "Bonjour")
        store.startReply(c.id)
        assertEquals(1, store.recoverInterrupted())
        assertEquals(Message.INTERRUPTED, store.messages(c.id).last().state)
    }

    /** Schéma exporté de la version 1 relu ; les migrations des versions suivantes s'ajouteront ici. */
    @Test fun schemaVersion1Validates() {
        migrations.createDatabase(TEST_DB, 1).close()
        migrations.runMigrationsAndValidate(TEST_DB, 1, true).close()
    }

    companion object {
        const val TEST_DB = "chat-migration-test.db"
    }
}
