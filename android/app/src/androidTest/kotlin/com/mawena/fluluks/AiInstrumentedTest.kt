package com.mawena.fluluks

import androidx.room.Room
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.mawena.fluluks.ai.AiException
import com.mawena.fluluks.ai.AiServerConfig
import com.mawena.fluluks.ai.AiServers
import com.mawena.fluluks.ai.AiTimeouts
import com.mawena.fluluks.ai.chat.ChatDatabase
import com.mawena.fluluks.ai.chat.ChatSessions
import com.mawena.fluluks.ai.chat.ChatSink
import com.mawena.fluluks.ai.chat.ChatStore
import com.mawena.fluluks.ai.chat.Message
import com.mawena.fluluks.remote.KeystoreSecretBox
import java.io.File
import java.util.Collections
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Intégration IA sur le Pixel (phase 15, T12), contre le serveur d'essai joint par `adb reverse`
 * (`tools/ia/serveur-essai.py --reverse`, port 8765, clé `essai-portail`) : vraie clé scellée par le Keystore, vraie
 * base Room, vraie pile réseau du téléphone (configuration de sécurité réseau comprise : `http://` local).
 */
@RunWith(AndroidJUnit4::class)
class AiInstrumentedTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val dir = File(context.cacheDir, "ia-essai-${System.nanoTime()}").apply { mkdirs() }
    private val servers = AiServers(dir, KeystoreSecretBox())
    private val db = Room.inMemoryDatabaseBuilder(context, ChatDatabase::class.java).build()
    private val store = ChatStore(db.chatDao(), { servers.list() }, { db.runInTransaction(it) })

    @After fun tearDown() {
        db.close()
        for (s in servers.list()) servers.delete(s.id)
        dir.deleteRecursively()
    }

    private fun server(key: String = KEY): AiServerConfig =
        servers.save(AiServerConfig("", "Essai", URL), key.toByteArray())

    /** Lots reçus, acquittés aussitôt ; fins de réponse. */
    private class Rec : ChatSink {
        val deltas: MutableList<String> = Collections.synchronizedList(mutableListOf())
        val states: MutableList<Message> = Collections.synchronizedList(mutableListOf())
        override fun delta(conversationId: Long, messageId: Long, text: String, delivered: () -> Unit) {
            deltas += text
            delivered()
        }
        override fun state(m: Message) {
            states += m
        }
    }

    private fun sessions(rec: Rec, timeouts: AiTimeouts = AiTimeouts()) =
        ChatSessions({ store }, { id -> servers.provider(id, timeouts = timeouts) }).also { it.sink = rec }

    /** Envoie [text] avec [model] et attend la fin ; rend la réponse finale. */
    private fun ask(model: String, text: String, rec: Rec = Rec(), timeouts: AiTimeouts = AiTimeouts()): Message {
        val s = server()
        val c = store.create(s.id, model)
        val chat = sessions(rec, timeouts)
        chat.send(c.id, text)
        runBlocking { withTimeout(120_000) { chat.job(c.id)?.join() } }
        return rec.states.single()
    }

    @Test fun connectionTestAndModels() {
        val s = server()
        val r = runBlocking { servers.test(s.id) }
        assertTrue(r.error ?: "", r.ok)
        assertEquals("essai-0.1.0", r.version)
        assertEquals(listOf("essai-court", "essai-long", "essai-erreur", "essai-lent"), r.models)
        assertFalse(r.log.joinToString("\n").contains(KEY))
    }

    @Test fun wrongKeyRefusedOnce() {
        val s = server(key = "mauvaise-cle")
        val r = runBlocking { servers.test(s.id) }
        assertFalse(r.ok)
        assertEquals(AiException(AiException.Kind.KEY_REFUSED).message, r.error)
        // un 401 n'est jamais relancé : une seule requête par route dans le journal du test
        assertEquals(r.log.toString(), 1, r.log.count { "/v1/models" in it })
    }

    @Test fun longStreamWithoutLossOrDuplicate() {
        val rec = Rec()
        val m = ask("essai-long", "Compte jusqu'à 2000 $MARK", rec)
        assertEquals(Message.DONE, m.state)
        val expected = (1..2000).joinToString("") { "%04d ".format(it) }
        assertEquals(expected, m.content)
        assertTrue("les lots sont un début de la réponse", expected.startsWith(rec.deltas.joinToString("")))
        assertEquals(expected, store.messages(m.conversationId).last().content)
    }

    @Test fun stopKeepsReceivedTextAndNothingArrivesAfter() {
        val rec = Rec()
        val s = server()
        val c = store.create(s.id, "essai-court")
        val chat = sessions(rec)
        chat.send(c.id, "Bonjour $MARK")
        val end = System.currentTimeMillis() + 20_000
        while (rec.deltas.isEmpty() && System.currentTimeMillis() < end) Thread.sleep(10)
        chat.stop(c.id)
        runBlocking { withTimeout(20_000) { chat.job(c.id)?.join() } }
        val m = rec.states.single()
        assertEquals(Message.STOPPED, m.state)
        assertTrue(m.content.isNotEmpty())
        val n = rec.deltas.size
        Thread.sleep(1_000)
        assertEquals("aucun lot après l'arrêt", n, rec.deltas.size)
    }

    @Test fun errorInTheMiddleOfTheStreamKeepsText() {
        val m = ask("essai-erreur", "Bonjour $MARK")
        assertEquals(Message.FAILED, m.state)
        assertTrue(m.content.isNotEmpty())
        assertEquals("Erreur d'essai au milieu du flux.", m.errorDetail)
    }

    @Test fun silentServerTimesOut() {
        val m = ask("essai-lent", "Bonjour $MARK", timeouts = AiTimeouts(readMs = 5_000, streamIdleMs = 5_000))
        assertEquals(Message.FAILED, m.state)
        assertTrue(m.error ?: "", m.error!!.isNotEmpty())
    }

    @Test fun neitherKeyNorContentInLogcat() {
        ask("essai-court", "Question secrète $MARK")
        val log = Runtime.getRuntime().exec(arrayOf("logcat", "-d")).inputStream.bufferedReader().readText()
        assertFalse("clé dans logcat", log.contains(KEY))
        assertFalse("prompt dans logcat", log.contains(MARK))
        assertFalse("réponse dans logcat", log.contains("réponse d'essai** de Portail"))
    }

    companion object {
        const val URL = "http://127.0.0.1:8765"
        const val KEY = "essai-portail"

        /** Repère des prompts d'essai, cherché dans logcat. */
        const val MARK = "REPERE-PORTAIL-7f3a91"
    }
}
