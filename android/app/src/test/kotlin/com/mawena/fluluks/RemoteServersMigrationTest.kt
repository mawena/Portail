package com.mawena.fluluks

import com.mawena.fluluks.remote.PrivateKeys
import com.mawena.fluluks.remote.RemoteServers
import com.mawena.fluluks.remote.Remotes
import com.mawena.fluluks.remote.SecretBox
import com.mawena.fluluks.remote.ServerConfig
import com.mawena.fluluks.remote.ssh.SshConnector
import java.io.ByteArrayOutputStream
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Phase 13, T7 : les clés importées par serveur en phase 10 passent dans le trousseau, une seule fois. */
class RemoteServersMigrationTest {
    @get:Rule val tmp = TemporaryFolder()

    private object Box : SecretBox {
        override fun seal(plain: ByteArray) = plain.reversedArray().map { (it + 7).toByte() }.toByteArray()
        override fun open(sealed: ByteArray) = sealed.map { (it - 7).toByte() }.toByteArray().reversedArray()
    }

    @After fun teardown() = Remotes.resetForTests(null, null)

    private fun key(): ByteArray {
        val kp = com.jcraft.jsch.KeyPair.genKeyPair(SshConnector.jsch(), com.jcraft.jsch.KeyPair.ED25519)
        return ByteArrayOutputStream().also { kp.writeOpenSSHv1PrivateKey(it, null) }.toByteArray()
    }

    /** Un magasin comme la phase 10 l'a laissé : clé dans les secrets du serveur, mot de passe mémorisé. */
    private fun phase10Store(key: ByteArray): Pair<RemoteServers, String> {
        val store = RemoteServers(tmp.root, Box)
        val s = store.save(
            ServerConfig("", "sftp", "Maison", "192.168.0.10", 22, "charles", "/", true, null, null),
            "mdp".toByteArray(), null,
        )
        store.setPrivateKey(s.id, key.copyOf(), PrivateKeys.describe(PrivateKeys.inspect(key)))
        return store to s.id
    }

    @Test fun migrationMovesPerServerKeys() {
        val key = key()
        val (old, id) = phase10Store(key)
        val info = old.get(id)!!.keyInfo
        val store = RemoteServers(tmp.root, Box) // ouverture suivante de l'application
        store.migrateKeys()
        val k = store.keys.list().single()
        assertEquals("Clé de Maison", k.name)
        assertEquals(listOf("Maison"), k.usedBy)
        val cfg = store.get(id)!!
        assertEquals(k.id, cfg.keyId)
        assertEquals(info, cfg.keyInfo)
        val sec = store.secrets(id)!!
        assertNull(sec.privateKey) // plus dans les secrets du serveur
        assertArrayEquals("mdp".toByteArray(), sec.password) // le reste est gardé
        // la connexion prend la clé du trousseau
        Remotes.resetForTests(store, null)
        val forConnect = Remotes.secretsFor(cfg, null)
        assertArrayEquals(key, forConnect.privateKey)
        forConnect.wipe()
    }

    @Test fun migrationRunsOnce() {
        val (_, id) = phase10Store(key())
        val store = RemoteServers(tmp.root, Box)
        store.migrateKeys()
        store.migrateKeys()
        RemoteServers(tmp.root, Box).migrateKeys()
        assertEquals(1, store.keys.list().size)
        assertEquals(store.keys.list().single().id, store.get(id)!!.keyId)
    }
}
