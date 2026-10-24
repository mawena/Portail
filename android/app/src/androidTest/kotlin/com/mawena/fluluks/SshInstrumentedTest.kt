package com.mawena.fluluks

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.mawena.fluluks.remote.HostKeyUnknown
import com.mawena.fluluks.remote.KeystoreSecretBox
import com.mawena.fluluks.remote.RemoteServers
import com.mawena.fluluks.remote.Remotes
import com.mawena.fluluks.remote.ServerConfig
import com.mawena.fluluks.remote.ssh.KeyInstaller
import com.mawena.fluluks.remote.ssh.SshKeys
import com.mawena.fluluks.remote.ssh.SshPromptBridge
import com.mawena.fluluks.remote.ssh.SshPrompts
import com.mawena.fluluks.remote.ssh.TerminalInfo
import com.mawena.fluluks.remote.ssh.TerminalSessions
import com.mawena.fluluks.remote.ssh.TunnelConfig
import com.mawena.fluluks.service.SshService
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Phase 13, T12 : connexions SSH sur le téléphone (Bouncy Castle et Conscrypt réels) contre le serveur d'essai du PC
 * (`tools/ssh/serveur-essai.sh --reverse` : 127.0.0.1:2222 et écho TCP 127.0.0.1:2223 par `adb reverse`). Les
 * serveurs et clés de l'essai vivent dans un magasin à part, sous le cache de l'application, effacé à la fin.
 */
@RunWith(AndroidJUnit4::class)
class SshInstrumentedTest {
    private val ctx = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var dir: File
    private lateinit var store: RemoteServers
    private val outputs = ConcurrentHashMap<String, ByteArrayOutputStream>()

    @Before fun setup() {
        dir = File(ctx.cacheDir, "ssh-essai").apply { deleteRecursively(); mkdirs() }
        store = RemoteServers(dir, KeystoreSecretBox())
        Remotes.resetForTests(store, null)
        TerminalSessions.resetForTests()
        SshKeys.defaultComment = "portail@essai"
        TerminalSessions.listener = object : TerminalSessions.Listener {
            override fun onOutput(id: String, data: ByteArray) {
                val o = outputs.getOrPut(id) { ByteArrayOutputStream() }
                synchronized(o) { o.write(data) }
            }

            override fun onChanged(info: TerminalInfo) {}
        }
    }

    @After fun teardown() {
        TerminalSessions.resetForTests()
        SshPromptBridge.prompts = null
        Remotes.resetForTests(null, null)
        dir.deleteRecursively()
    }

    private fun server(user: String = USER): String {
        val c = store.save(ServerConfig("", "sftp", "Essai", "127.0.0.1", PORT, user, "/", false, null, null), null, null)
        return c.id
    }

    /** Ouvre un terminal ; la clé du serveur, inconnue au premier essai, est acceptée comme le ferait l'utilisateur. */
    private fun open(id: String, password: String? = PASSWORD): TerminalInfo = try {
        TerminalSessions.open(id, password?.toByteArray(), null)
    } catch (e: HostKeyUnknown) {
        store.setHostKey(id, e.fingerprint)
        TerminalSessions.open(id, password?.toByteArray(), null)
    }

    private fun text(id: String) = outputs[id]?.let { synchronized(it) { it.toString("UTF-8") } }.orEmpty()

    private fun waitFor(what: String, timeoutMs: Long = 15_000, cond: () -> Boolean) {
        val end = System.currentTimeMillis() + timeoutMs
        while (!cond()) {
            if (System.currentTimeMillis() > end) throw AssertionError("délai dépassé : $what")
            Thread.sleep(20)
        }
    }

    @Test fun passwordTerminalEchoAndResize() {
        val t = open(server())
        waitFor("bienvenue") { text(t.id).contains("Bienvenue") }
        TerminalSessions.write(t.id, "term\n".toByteArray())
        waitFor("TERM") { text(t.id).contains("TERM=xterm-256color") }
        TerminalSessions.resize(t.id, 100, 30)
        TerminalSessions.write(t.id, "size\n".toByteArray())
        waitFor("taille") { text(t.id).contains("SIZE=100x30") }
    }

    @Test fun keyboardInteractiveCode() {
        var asked = ""
        SshPromptBridge.prompts = SshPrompts { _, _, prompts, _ ->
            asked = prompts.joinToString()
            listOf(CODE.toByteArray())
        }
        val t = open(server(KI_USER), password = null)
        assertTrue(asked, asked.contains("Code de vérification"))
        waitFor("bienvenue") { text(t.id).contains("Bienvenue") }
    }

    @Test fun ed25519GeneratedInstalledThenKeyLogin() {
        val k = store.keys.generate("Pixel", "ed25519", null)
        val id = server()
        open(id).also { TerminalSessions.close(it.id) } // clé du serveur acceptée
        assertEquals(KeyInstaller.Result.ADDED, Remotes.installPublicKey(id, k.id, PASSWORD.toByteArray()))
        store.setKey(id, k.id)
        val t = open(id, password = null) // par la clé seule
        waitFor("bienvenue") { text(t.id).contains("Bienvenue") }
        assertEquals(KeyInstaller.Result.ALREADY_PRESENT, Remotes.installPublicKey(id, k.id, PASSWORD.toByteArray()))
    }

    @Test fun tunnelToEcho() {
        val id = server()
        val t = open(id)
        val tunnel = store.tunnels.save(TunnelConfig("", id, LOCAL_PORT, "127.0.0.1", ECHO_PORT, false))
        assertTrue(TerminalSessions.startTunnel(t.id, tunnel.id).active)
        Socket("127.0.0.1", LOCAL_PORT).use { s ->
            s.soTimeout = 10_000
            s.getOutputStream().write("bonjour\n".toByteArray())
            s.getOutputStream().flush()
            assertEquals("bonjour", s.getInputStream().bufferedReader().readLine())
        }
        TerminalSessions.close(t.id)
    }

    @Test fun serviceKeepsSessionTwoMinutes() {
        TerminalSessions.init(ctx)
        val t = open(server())
        waitFor("service démarré", 10_000) { SshService.running }
        Thread.sleep(120_000)
        assertEquals(TerminalInfo.OPEN, TerminalSessions.list().single().state)
        TerminalSessions.write(t.id, "term\n".toByteArray())
        waitFor("écho après 2 min") { text(t.id).contains("TERM=") }
        TerminalSessions.closeAll()
        waitFor("service arrêté", 10_000) { !SshService.running }
    }

    private companion object {
        const val PORT = 2222
        const val ECHO_PORT = 2223
        const val LOCAL_PORT = 18089
        const val USER = "portail"
        const val PASSWORD = "essai-portail"
        const val KI_USER = "portail-ki"
        const val CODE = "123456"
    }
}
