package com.mawena.fluluks

import com.jcraft.jsch.JSch
import com.jcraft.jsch.KeyPair as JKeyPair
import com.mawena.fluluks.remote.AuthFailed
import com.mawena.fluluks.remote.HostKeyChanged
import com.mawena.fluluks.remote.HostKeyUnknown
import com.mawena.fluluks.remote.Secrets
import com.mawena.fluluks.remote.ServerConfig
import com.mawena.fluluks.remote.ssh.SshConnector
import com.mawena.fluluks.remote.ssh.SshFailure
import com.mawena.fluluks.remote.ssh.SshPrompts
import java.io.ByteArrayOutputStream
import java.net.ServerSocket
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PublicKey
import java.util.Base64
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import org.apache.sshd.common.config.keys.PublicKeyEntry
import org.apache.sshd.common.keyprovider.KeyPairProvider
import org.apache.sshd.server.SshServer
import org.apache.sshd.server.auth.keyboard.InteractiveChallenge
import org.apache.sshd.server.auth.keyboard.KeyboardInteractiveAuthenticator
import org.apache.sshd.server.auth.keyboard.PromptEntry
import org.apache.sshd.server.auth.keyboard.UserAuthKeyboardInteractiveFactory
import org.apache.sshd.server.auth.password.PasswordAuthenticator
import org.apache.sshd.server.auth.pubkey.PublickeyAuthenticator
import org.apache.sshd.server.session.ServerSession
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Ouverture d'une session SSH par [SshConnector] (phase 13, T1) contre un serveur MINA SSHD sur 127.0.0.1, port libre :
 * empreinte, mot de passe, clé, keyboard-interactive, échecs traduits, journal de tentative sans secret.
 */
class SshConnectorTest {
    private val hostKeys: KeyPair = KeyPairGenerator.getInstance("EC").apply { initialize(256) }.generateKeyPair()
    private var sshd: SshServer? = null
    @Volatile private var allowedKey: String? = null

    @After fun teardown() {
        sshd?.stop(true)
    }

    private fun server(configure: SshServer.() -> Unit = {}): SshServer = SshServer.setUpDefaultServer().apply {
        host = "127.0.0.1"
        port = 0
        keyPairProvider = KeyPairProvider.wrap(hostKeys)
        passwordAuthenticator = PasswordAuthenticator { u, p, _ -> u == USER && p == PASSWORD }
        publickeyAuthenticator = PublickeyAuthenticator { u, k, _ -> u == USER && blob64(k) == allowedKey }
        configure()
        start()
    }.also { sshd = it }

    private fun blob64(k: PublicKey) = PublicKeyEntry.toString(k).split(" ")[1]

    private fun fingerprint(k: PublicKey): String {
        val (type, b64) = PublicKeyEntry.toString(k).split(" ")
        val sha = MessageDigest.getInstance("SHA-256").digest(Base64.getDecoder().decode(b64))
        return "$type SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(sha)
    }

    private fun cfg(port: Int, hostKey: String? = fingerprint(hostKeys.public)) =
        ServerConfig("s1", "sftp", "Test", "127.0.0.1", port, USER, "/", false, hostKey, null)

    private fun pw(p: String? = PASSWORD) = Secrets(p?.toByteArray(), null, null)

    private fun clientKey(type: Int, phrase: String?): ByteArray {
        val kp = JKeyPair.genKeyPair(SshConnector.jsch(), type, if (type == JKeyPair.RSA) 2048 else 256)
        allowedKey = Base64.getEncoder().encodeToString(kp.publicKeyBlob)
        val out = ByteArrayOutputStream()
        kp.writeOpenSSHv1PrivateKey(out, phrase?.toByteArray())
        return out.toByteArray()
    }

    /** Serveur qui n'accepte que keyboard-interactive, avec [auth]. */
    private fun kiServer(auth: KeyboardInteractiveAuthenticator) = server {
        userAuthFactories = listOf(UserAuthKeyboardInteractiveFactory.INSTANCE)
        keyboardInteractiveAuthenticator = auth
    }

    private fun challenge(prompt: String, echo: Boolean) = object : KeyboardInteractiveAuthenticator {
        @Volatile var answers: List<String>? = null

        override fun generateChallenge(s: ServerSession, user: String, lang: String?, sub: String?) =
            InteractiveChallenge().apply {
                interactionName = "Portail"
                interactionInstruction = "Code"
                addPrompt(PromptEntry(prompt, echo))
            }

        override fun authenticate(s: ServerSession, user: String, responses: List<String>): Boolean {
            answers = responses
            return user == USER && responses == listOf(CODE)
        }
    }

    @Test fun passwordLogin() {
        val s = server()
        val c = SshConnector(cfg(s.port), pw())
        val session = c.open()
        assertTrue(session.isConnected)
        session.disconnect()
        assertTrue(c.log.lines().isNotEmpty())
    }

    @Test fun publicKeyLoginEd25519AndRsa() {
        for (type in listOf(JKeyPair.ED25519, JKeyPair.RSA)) {
            val s = server()
            val key = clientKey(type, if (type == JKeyPair.RSA) "phrase" else null)
            val sec = Secrets(null, if (type == JKeyPair.RSA) "phrase".toByteArray() else null, key)
            val session = SshConnector(cfg(s.port), sec).open()
            assertTrue(session.isConnected)
            session.disconnect()
            s.stop(true)
        }
    }

    @Test fun keyboardInteractiveAnswersPasswordPrompt() {
        val s = kiServer(object : KeyboardInteractiveAuthenticator {
            override fun generateChallenge(ss: ServerSession, user: String, lang: String?, sub: String?) =
                InteractiveChallenge().apply { addPrompt(PromptEntry("Password: ", false)) }

            override fun authenticate(ss: ServerSession, user: String, responses: List<String>) =
                user == USER && responses == listOf(PASSWORD)
        })
        var asked = false
        val session = SshConnector(cfg(s.port), pw(), SshPrompts { _, _, _, _ -> asked = true; null }).open()
        assertTrue(session.isConnected)
        assertFalse(asked) // le mot de passe répond seul à l'invite de mot de passe
        session.disconnect()
    }

    @Test fun keyboardInteractiveAsksOtherPrompts() {
        val ki = challenge("Verification code: ", echo = true)
        val s = kiServer(ki)
        val seen = AtomicReference<List<String>>()
        val session = SshConnector(cfg(s.port), pw(), SshPrompts { _, _, prompts, echo ->
            seen.set(prompts)
            assertEquals(listOf(true), echo)
            listOf(CODE.toByteArray())
        }).open()
        assertTrue(session.isConnected)
        assertEquals(listOf("Verification code: "), seen.get())
        session.disconnect()

        // invite refusée par l'utilisateur : identifiants refusés, sans autre message
        val refused = assertThrows(AuthFailed::class.java) {
            SshConnector(cfg(s.port), pw(), SshPrompts { _, _, _, _ -> null }).open()
        }
        assertFalse(refused.missing)
    }

    @Test fun promptAnswersZeroed() {
        val s = kiServer(challenge("Verification code: ", echo = false))
        val answer = CODE.toByteArray()
        SshConnector(cfg(s.port), pw(), SshPrompts { _, _, _, _ -> listOf(answer) }).open().disconnect()
        assertTrue(answer.all { it == 0.toByte() })
    }

    @Test fun serverClosesBeforeAuthIsClosedByServer() {
        val sock = ServerSocket(0, 1, java.net.InetAddress.getByName("127.0.0.1"))
        val t = thread { runCatching { sock.accept().use { it.getOutputStream().write("SSH-2.0-Faux\r\n".toByteArray()) } } }
        val e = assertThrows(SshFailure::class.java) { SshConnector(cfg(sock.localPort), pw()).open() }
        assertEquals(e.detail, SshFailure.Reason.CLOSED_BY_SERVER, e.reason)
        assertTrue(e.detail.isNotBlank())
        t.join(2_000)
        sock.close()
    }

    @Test fun refusedPortIsRefused() {
        val free = ServerSocket(0).use { it.localPort }
        val e = assertThrows(SshFailure::class.java) { SshConnector(cfg(free), pw()).open() }
        assertEquals(SshFailure.Reason.REFUSED, e.reason)
    }

    @Test fun connectionLogNeverContainsSecrets() {
        val s = kiServer(challenge("Verification code: ", echo = false))
        val key = clientKey(JKeyPair.RSA, "phrase-secrète")
        val c = SshConnector(cfg(s.port), Secrets(PASSWORD.toByteArray(), "phrase-secrète".toByteArray(), key),
            SshPrompts { _, _, _, _ -> listOf(CODE.toByteArray()) })
        runCatching { c.open().disconnect() }
        val all = c.log.lines().joinToString("\n")
        assertTrue(all.isNotEmpty())
        for (secret in listOf(PASSWORD, "phrase-secrète", CODE)) assertFalse(secret, all.contains(secret))
    }

    @Test fun testConnectionAsksForUnknownKey() {
        val s = server()
        val e = assertThrows(HostKeyUnknown::class.java) { SshConnector(cfg(s.port, hostKey = null), pw()).open() }
        assertEquals(fingerprint(hostKeys.public), e.fingerprint)
    }

    @Test fun changedKeyRefused() {
        val s = server()
        val other = KeyPairGenerator.getInstance("EC").apply { initialize(256) }.generateKeyPair()
        val e = assertThrows(HostKeyChanged::class.java) {
            SshConnector(cfg(s.port, hostKey = fingerprint(other.public)), pw()).open()
        }
        assertNotNull(e.message)
    }

    @Test fun wrongPasswordIsAuthFailed() {
        val s = server()
        val e = assertThrows(AuthFailed::class.java) { SshConnector(cfg(s.port), pw("faux")).open() }
        assertFalse(e.missing)
    }

    private companion object {
        const val USER = "portail"
        const val PASSWORD = "mot-de-passe-test"
        const val CODE = "123456"
    }
}
