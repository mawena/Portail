package com.mawena.fluluks

import com.mawena.fluluks.ai.AiHealth
import com.mawena.fluluks.ai.AiServerConfig
import com.mawena.fluluks.ai.AiServers
import com.mawena.fluluks.files.FilesException
import com.mawena.fluluks.remote.SecretBox
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Serveurs IA enregistrés et clés scellées (phase 15, T3). */
class AiServersTest {
    @get:Rule val tmp = TemporaryFolder()

    /** Boîte de test : rien de lisible en clair sur le disque, réversible. */
    private object Box : SecretBox {
        override fun seal(plain: ByteArray) = plain.reversedArray().map { (it + 7).toByte() }.toByteArray()
        override fun open(sealed: ByteArray) = sealed.map { (it - 7).toByte() }.toByteArray().reversedArray()
    }

    private fun store() = AiServers(tmp.root, Box)

    private fun cfg(name: String, url: String = "https://atelier.mawena.cloud") = AiServerConfig("", name, url)

    private fun allBytes() = tmp.root.walk().filter { it.isFile }.map { it.readBytes() }.fold(ByteArray(0)) { a, b -> a + b }

    private fun contains(hay: ByteArray, needle: ByteArray) = (0..hay.size - needle.size).any { i ->
        needle.indices.all { hay[i + it] == needle[it] }
    }

    private fun refused(block: () -> Unit): String {
        try {
            block()
        } catch (e: FilesException) {
            return e.message.orEmpty()
        }
        fail("refus attendu")
        throw AssertionError()
    }

    @Test fun urlValidated() {
        assertEquals("https://atelier.mawena.cloud", AiServers.normalizeUrl(" https://atelier.mawena.cloud/ "))
        assertEquals("http://192.168.0.20:11434", AiServers.normalizeUrl("HTTP://192.168.0.20:11434"))
        assertEquals("https://h.example/ia", AiServers.normalizeUrl("https://h.example/ia//"))
        // URL de base « à la OpenAI » : /v1 retiré, Portail l'ajoute
        assertEquals("http://localhost:8000", AiServers.normalizeUrl("http://localhost:8000/v1/"))
        for (bad in listOf("atelier.mawena.cloud", "ftp://h", "http://", "http://h:0", "http://h:65536", "http://h:abc",
            "https://h/?a=1", "https://h/#x", "https://moi:secret@h", "")) {
            try {
                AiServers.normalizeUrl(bad)
                fail("accepté : $bad")
            } catch (e: IllegalArgumentException) {
                assertTrue(e.message!!, e.message!!.isNotEmpty())
            }
        }
        refused { store().save(cfg("A", "ftp://h"), null) }
    }

    @Test fun nameUniqueAndDefaultFromHost() {
        val s = store()
        val a = s.save(cfg("Atelier"), null)
        assertTrue(a.id.isNotEmpty())
        assertTrue(refused { s.save(cfg(" atelier "), null) }.contains("nom"))
        val b = s.save(cfg("", "http://192.168.0.20:11434"), null)
        assertEquals("192.168.0.20", b.name)
        // renommer en gardant son propre nom : permis
        assertEquals("Atelier", s.save(a.copy(baseUrl = "https://autre.example"), null).name)
        assertEquals(listOf("Atelier", "192.168.0.20"), store().list().map { it.name })
    }

    @Test fun keySealedNeverReadBackEmptyKeepsRemoveErases() {
        val s = store()
        val a = s.save(cfg("Atelier"), "cle-tres-secrete".toByteArray())
        assertTrue(a.hasKey)
        assertFalse("clé en clair sur le disque", contains(allBytes(), "cle-tres-secrete".toByteArray()))
        assertArrayEquals("cle-tres-secrete".toByteArray(), s.openKey(a.id))
        // champ vide : la clé reste
        val a2 = s.save(a.copy(name = "Atelier 2"), null)
        assertTrue(a2.hasKey)
        assertTrue(s.save(a2, ByteArray(0)).hasKey)
        assertArrayEquals("cle-tres-secrete".toByteArray(), s.openKey(a.id))
        // remplacée
        s.save(a2, "nouvelle".toByteArray())
        assertArrayEquals("nouvelle".toByteArray(), s.openKey(a.id))
        // « Retirer la clé » : fichier scellé supprimé
        s.removeKey(a.id)
        assertFalse(store().get(a.id)!!.hasKey)
        assertNull(s.openKey(a.id))
        assertFalse(java.io.File(tmp.root, "ai-keys/${a.id}").exists())
    }

    @Test fun deleteErasesKeyAndNotifies() {
        val s = store()
        val deleted = mutableListOf<String>()
        s.onDeleted += { deleted += it }
        val a = s.save(cfg("Atelier"), "k".toByteArray())
        s.delete(a.id)
        assertTrue(store().list().isEmpty())
        assertFalse(java.io.File(tmp.root, "ai-keys/${a.id}").exists())
        assertEquals(listOf(a.id), deleted)
    }

    @Test fun singleDefaultFirstIsDefaultNextTakesOver() {
        val s = store()
        val a = s.save(cfg("A"), null)
        val b = s.save(cfg("B"), null)
        val c = s.save(cfg("C"), null)
        assertTrue(a.isDefault)
        assertFalse(b.isDefault)
        s.setDefault(c.id)
        assertEquals(listOf(c.id), store().list().filter { it.isDefault }.map { it.id })
        assertEquals(c.id, s.defaultServer()?.id)
        // enregistrer une fiche avec isDefault ne change pas le défaut (setDefault seulement)
        s.save(store().get(a.id)!!.copy(isDefault = true), null)
        assertEquals(c.id, s.defaultServer()?.id)
        s.delete(c.id)
        assertEquals(a.id, s.defaultServer()?.id) // le suivant (premier restant)
        s.delete(a.id)
        assertEquals(b.id, s.defaultServer()?.id)
        s.delete(b.id)
        assertNull(s.defaultServer())
    }

    @Test fun defaultModelRemembered() {
        val s = store()
        val a = s.save(cfg("A"), null)
        s.setDefaultModel(a.id, "qwen2.5:7b")
        assertEquals("qwen2.5:7b", store().get(a.id)!!.defaultModel)
        // enregistrer la fiche garde le modèle
        s.save(store().get(a.id)!!.copy(name = "A2"), null)
        assertEquals("qwen2.5:7b", store().get(a.id)!!.defaultModel)
        s.setDefaultModel(a.id, null)
        assertNull(store().get(a.id)!!.defaultModel)
    }

    @Test fun testServerHealthModelsAndLogWithoutSecret() = runBlocking {
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.getHeader("Authorization") != "Bearer cle-essai-77") {
                    return MockResponse().setResponseCode(401).setBody("{\"error\":{\"message\":\"cle refusee\"}}")
                }
                return when (request.path) {
                    "/health" -> MockResponse().setBody("{\"status\":\"ok\",\"version\":\"0.1.0\"}")
                    else -> MockResponse().setBody("{\"object\":\"list\",\"data\":[{\"id\":\"m1\",\"object\":\"model\"},{\"id\":\"m2\",\"object\":\"model\"}]}")
                }
            }
        }
        server.start()
        try {
            val s = store()
            val a = s.save(cfg("Essai", server.url("/").toString()), "cle-essai-77".toByteArray())
            val r = s.test(a.id)
            assertTrue(r.ok)
            assertEquals("0.1.0", r.version)
            assertEquals(listOf("m1", "m2"), r.models)
            assertTrue(r.log.joinToString().contains("/v1/models"))
            assertFalse(r.log.joinToString().contains("cle-essai-77"))
            assertEquals(r.log, s.lastLog(a.id))
            // clé changée : refusée, message traduit, message du serveur à part
            s.save(store().get(a.id)!!, "autre".toByteArray())
            val bad = s.test(a.id)
            assertFalse(bad.ok)
            assertTrue(bad.error!!.startsWith("Clé API refusée"))
            assertEquals("cle refusee", bad.detail)
            assertEquals(AiHealth.State.KEY_REFUSED, s.health(a.id).state)
            assertEquals(listOf("m1", "m2"), runCatching { s.save(store().get(a.id)!!, "cle-essai-77".toByteArray()); s.models(a.id) }.getOrThrow())
        } finally {
            server.shutdown()
        }
    }

    @Test fun corruptFileGivesEmptyList() {
        java.io.File(tmp.root, "ai-servers.json").writeText("{pas du json")
        assertTrue(store().list().isEmpty())
    }
}
