package com.mawena.fluluks

import com.mawena.fluluks.remote.RemoteServers
import com.mawena.fluluks.remote.SecretBox
import com.mawena.fluluks.remote.Secrets
import com.mawena.fluluks.remote.ServerConfig
import com.mawena.fluluks.remote.ssh.SshConnector
import com.mawena.fluluks.remote.ssh.SshKeys
import java.io.File
import java.io.IOException
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PublicKey
import java.util.Base64
import org.apache.sshd.common.config.keys.PublicKeyEntry
import org.apache.sshd.common.keyprovider.KeyPairProvider
import org.apache.sshd.server.SshServer
import org.apache.sshd.server.auth.pubkey.PublickeyAuthenticator
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Trousseau de clés SSH (phase 13, T7) : génération, import, clé publique, suppression, scellement sur le disque. */
class SshKeysTest {
    @get:Rule val tmp = TemporaryFolder()

    private object Box : SecretBox {
        override fun seal(plain: ByteArray) = plain.reversedArray().map { (it + 7).toByte() }.toByteArray()
        override fun open(sealed: ByteArray) = sealed.map { (it - 7).toByte() }.toByteArray().reversedArray()
    }

    private val hostKeys: KeyPair = KeyPairGenerator.getInstance("EC").apply { initialize(256) }.generateKeyPair()
    private var sshd: SshServer? = null
    private lateinit var store: RemoteServers
    private val keys get() = store.keys

    @Before fun setup() {
        store = RemoteServers(tmp.root, Box)
        SshKeys.defaultComment = "portail@Pixel 4 XL"
    }

    @After fun teardown() {
        sshd?.stop(true)
    }

    private fun fingerprint(k: PublicKey): String {
        val (type, b64) = PublicKeyEntry.toString(k).split(" ")
        val sha = MessageDigest.getInstance("SHA-256").digest(Base64.getDecoder().decode(b64))
        return "$type SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(sha)
    }

    /** Ouvre une session MINA avec la clé [keyId] du trousseau ; le serveur n'accepte que sa clé publique. */
    private fun loginWith(keyId: String, phrase: String? = null) {
        val allowed = keys.publicKey(keyId).split(" ")[1]
        val s = SshServer.setUpDefaultServer().apply {
            host = "127.0.0.1"
            port = 0
            keyPairProvider = KeyPairProvider.wrap(hostKeys)
            publickeyAuthenticator = PublickeyAuthenticator { u, k, _ ->
                u == "portail" && PublicKeyEntry.toString(k).split(" ")[1] == allowed
            }
            start()
        }.also { sshd = it }
        val cfg = ServerConfig("s1", "sftp", "Test", "127.0.0.1", s.port, "portail", "/", false, fingerprint(hostKeys.public), null)
        val key = keys.privateKey(keyId)
        val session = SshConnector(cfg, Secrets(null, phrase?.toByteArray(), key)).open()
        assertTrue(session.isConnected)
        session.disconnect()
        key.fill(0)
        s.stop(true)
    }

    @Test fun generateEd25519() {
        val k = keys.generate("Téléphone", "ed25519", null)
        assertEquals("ssh-ed25519", k.type)
        assertTrue(k.fingerprint.startsWith("SHA256:"))
        assertFalse(k.encrypted)
        assertEquals(listOf(k), keys.list())
        loginWith(k.id)
    }

    @Test fun generateRsa4096() {
        val k = keys.generate("Gros", "rsa", null)
        assertEquals("ssh-rsa", k.type)
        val blob = Base64.getDecoder().decode(keys.publicKey(k.id).split(" ")[1])
        assertTrue(blob.size > 512) // module de 4096 bits
        loginWith(k.id)
    }

    @Test fun generatedWithPassphraseIsEncrypted() {
        val phrase = "phrase-secrète".toByteArray()
        val k = keys.generate("Chiffrée", "ed25519", phrase)
        assertTrue(k.encrypted)
        assertTrue(phrase.all { it == 0.toByte() }) // remise à zéro
        loginWith(k.id, "phrase-secrète")
    }

    @Test fun publicKeyIsOpenSshLine() {
        val k = keys.generate("Téléphone", "ed25519", null)
        val line = keys.publicKey(k.id)
        assertTrue(line, Regex("^ssh-ed25519 AAAA[A-Za-z0-9+/=]+ portail@Pixel 4 XL$").matches(line))
    }

    @Test fun importRejectsGarbage() {
        val e = assertThrows(IOException::class.java) { keys.import("Rien", "pas une clé".toByteArray()) }
        assertEquals("Clé privée illisible", e.message)
        assertTrue(keys.list().isEmpty())
    }

    @Test fun importKeepsKeyAndComment() {
        val kp = com.jcraft.jsch.KeyPair.genKeyPair(SshConnector.jsch(), com.jcraft.jsch.KeyPair.ED25519)
        kp.setPublicKeyComment("charles@portable")
        val bytes = java.io.ByteArrayOutputStream().also { kp.writeOpenSSHv1PrivateKey(it, null) }.toByteArray()
        val keep = bytes.copyOf()
        val k = keys.import("Portable", bytes)
        assertTrue(bytes.all { it == 0.toByte() })
        assertTrue(keep.contentEquals(keys.privateKey(k.id)))
        assertTrue(keys.publicKey(k.id).endsWith(" charles@portable"))
        keys.rename(k.id, "Ancien portable")
        assertEquals("Ancien portable", keys.list().single().name)
    }

    @Test fun deleteUsedKeyRefused() {
        val k = keys.generate("Téléphone", "ed25519", null)
        val a = store.save(ServerConfig("", "sftp", "Maison", "h", 22, "u", "/", false, null, null), null, null)
        val b = store.save(ServerConfig("", "sftp", "Cloud", "h", 22, "u", "/", false, null, null), null, null)
        store.setKey(a.id, k.id)
        store.setKey(b.id, k.id)
        assertEquals(listOf("Maison", "Cloud"), keys.list().single().usedBy)
        val e = assertThrows(IOException::class.java) { keys.delete(k.id) }
        assertEquals("Clé utilisée par : Maison, Cloud", e.message)
        store.setKey(a.id, null)
        store.setKey(b.id, null)
        keys.delete(k.id)
        assertTrue(keys.list().isEmpty())
        assertFalse(File(tmp.root, "ssh-keys/${k.id}").exists())
    }

    @Test fun keysSealedOnDisk() {
        val k = keys.generate("Téléphone", "ed25519", null)
        val plain = keys.privateKey(k.id)
        val text = String(plain, Charsets.US_ASCII)
        val body = text.lines().filter { it.isNotEmpty() && !it.startsWith("-----") }.joinToString("")
        for (f in tmp.root.walkTopDown().filter { it.isFile }) {
            val bytes = f.readBytes()
            val s = String(bytes, Charsets.ISO_8859_1)
            assertFalse(f.path, s.contains("OPENSSH PRIVATE KEY"))
            assertFalse(f.path, s.contains(body.take(40)))
        }
    }
}
