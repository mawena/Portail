package com.mawena.fluluks

import com.mawena.fluluks.remote.RemoteServers
import com.mawena.fluluks.remote.SecretBox
import com.mawena.fluluks.remote.ServerConfig
import com.mawena.fluluks.remote.ssh.Snippet
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Commandes enregistrées du terminal (phase 13, T9) : `ssh-snippets.json`, par serveur ou communes. */
class SnippetsTest {
    @get:Rule val tmp = TemporaryFolder()

    private object Box : SecretBox {
        override fun seal(plain: ByteArray) = plain
        override fun open(sealed: ByteArray) = sealed
    }

    private lateinit var store: RemoteServers
    private val snippets get() = store.snippets

    @Before fun setup() {
        store = RemoteServers(tmp.root, Box)
    }

    private fun server(name: String) =
        store.save(ServerConfig("", "sftp", name, "h", 22, "u", "/", false, null, null), null, null).id

    @Test fun serverThenCommonOrder() {
        val a = server("Maison")
        val b = server("Cloud")
        snippets.save(Snippet("", null, "Disque", "df -h", true))
        snippets.save(Snippet("", a, "Journal", "journalctl -f", true))
        snippets.save(Snippet("", b, "Docker", "docker ps", true))
        snippets.save(Snippet("", null, "Haut", "htop", true))
        snippets.save(Snippet("", a, "Mises à jour", "sudo apt update", false))
        assertEquals(listOf("Journal", "Mises à jour", "Disque", "Haut"), snippets.list(a).map { it.name })
        assertEquals(listOf("Disque", "Haut"), snippets.list(null).map { it.name })
    }

    @Test fun saveUpdatesAndDeletes() {
        val s = snippets.save(Snippet("", null, "Disque", "df -h", true))
        assertTrue(s.id.isNotEmpty())
        snippets.save(s.copy(command = "df -hT", runNow = false))
        assertEquals(listOf(s.copy(command = "df -hT", runNow = false)), snippets.list(null))
        snippets.delete(s.id)
        assertTrue(snippets.list(null).isEmpty())
        assertFalse(File(tmp.root, ".ssh-snippets.json.tmp").exists())
    }

    @Test fun emptyNameOrCommandRefused() {
        assertThrows(IllegalArgumentException::class.java) { snippets.save(Snippet("", null, " ", "ls", true)) }
        assertThrows(IllegalArgumentException::class.java) { snippets.save(Snippet("", null, "Liste", "", true)) }
    }

    @Test fun damagedFileGivesEmptyList() {
        File(tmp.root, "ssh-snippets.json").writeText("[{ abîmé")
        assertTrue(snippets.list(null).isEmpty())
        snippets.save(Snippet("", null, "Disque", "df -h", true)) // réécrit proprement
        assertEquals(1, snippets.list(null).size)
    }

    @Test fun deletedServerDropsItsSnippets() {
        val a = server("Maison")
        snippets.save(Snippet("", a, "Journal", "journalctl -f", true))
        snippets.save(Snippet("", null, "Disque", "df -h", true))
        store.delete(a)
        assertEquals(listOf("Disque"), snippets.list(a).map { it.name })
    }
}
