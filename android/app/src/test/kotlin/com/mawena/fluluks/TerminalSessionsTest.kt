package com.mawena.fluluks

import com.mawena.fluluks.files.FilesException
import com.mawena.fluluks.remote.HostKeyChanged
import com.mawena.fluluks.remote.RemoteServers
import com.mawena.fluluks.remote.Remotes
import com.mawena.fluluks.remote.SecretBox
import com.mawena.fluluks.remote.ServerConfig
import com.mawena.fluluks.remote.ssh.OutputPump
import com.mawena.fluluks.remote.ssh.TerminalInfo
import com.mawena.fluluks.remote.ssh.TerminalSessions
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PublicKey
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.concurrent.thread
import org.apache.sshd.common.config.keys.PublicKeyEntry
import org.apache.sshd.common.keyprovider.KeyPairProvider
import org.apache.sshd.server.Environment
import org.apache.sshd.server.ExitCallback
import org.apache.sshd.server.SshServer
import org.apache.sshd.server.auth.password.PasswordAuthenticator
import org.apache.sshd.server.channel.ChannelSession
import org.apache.sshd.server.command.Command
import org.apache.sshd.server.shell.ShellFactory
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Sessions de terminal (phase 13, T2) contre un serveur MINA SSHD sur 127.0.0.1 dont le shell, écrit pour le test,
 * renvoie ce qu'il reçoit et connaît `term`, `size`, `exit` et `flood <n>`.
 */
class TerminalSessionsTest {
    @get:Rule val tmp = TemporaryFolder()

    private val hostKeys: KeyPair = KeyPairGenerator.getInstance("EC").apply { initialize(256) }.generateKeyPair()
    private var sshd: SshServer? = null
    private lateinit var store: RemoteServers

    private val outputs = ConcurrentHashMap<String, ByteArrayOutputStream>()
    private val batches = ConcurrentHashMap<String, CopyOnWriteArrayList<Pair<Long, Int>>>()
    private val changes = CopyOnWriteArrayList<TerminalInfo>()

    private object Box : SecretBox {
        override fun seal(plain: ByteArray) = plain.reversedArray().map { (it + 7).toByte() }.toByteArray()
        override fun open(sealed: ByteArray) = sealed.map { (it - 7).toByte() }.toByteArray().reversedArray()
    }

    @Before fun setup() {
        store = RemoteServers(tmp.root, Box)
        Remotes.resetForTests(store, null)
        TerminalSessions.resetForTests()
        TerminalSessions.listener = object : TerminalSessions.Listener {
            override fun onOutput(id: String, data: ByteArray) {
                batches.getOrPut(id) { CopyOnWriteArrayList() }.add(System.nanoTime() to data.size)
                val o = outputs.getOrPut(id) { ByteArrayOutputStream() }
                synchronized(o) { o.write(data) }
            }

            override fun onChanged(info: TerminalInfo) {
                changes += info
            }
        }
    }

    @After fun teardown() {
        TerminalSessions.resetForTests()
        Remotes.resetForTests(null, null)
        sshd?.stop(true)
    }

    /** Shell d'écho du test : renvoie chaque octet reçu, puis exécute la ligne terminée. */
    private class EchoShell : Command {
        private lateinit var input: InputStream
        private lateinit var out: OutputStream
        private var exit: ExitCallback? = null
        private lateinit var env: Environment

        override fun setInputStream(i: InputStream) { input = i }
        override fun setOutputStream(o: OutputStream) { out = o }
        override fun setErrorStream(e: OutputStream) {}
        override fun setExitCallback(c: ExitCallback) { exit = c }
        override fun destroy(channel: ChannelSession) {}

        override fun start(channel: ChannelSession, env: Environment) {
            this.env = env
            thread(isDaemon = true) { runCatching { loop() } }
        }

        private fun say(s: String) {
            out.write(s.toByteArray())
            out.flush()
        }

        private fun loop() {
            val line = ByteArrayOutputStream()
            val buf = ByteArray(4096)
            while (true) {
                val n = input.read(buf)
                if (n < 0) return
                out.write(buf, 0, n)
                out.flush()
                for (i in 0 until n) {
                    val b = buf[i]
                    if (b != '\n'.code.toByte() && b != '\r'.code.toByte()) {
                        line.write(b.toInt())
                        continue
                    }
                    val cmd = line.toString(Charsets.UTF_8.name()).trim()
                    line.reset()
                    when {
                        cmd == "term" -> say("TERM=${env.env[Environment.ENV_TERM]}\n")
                        cmd == "size" -> say("SIZE=${env.env[Environment.ENV_COLUMNS]}x${env.env[Environment.ENV_LINES]}\n")
                        cmd == "exit" -> {
                            exit?.onExit(0)
                            return
                        }
                        cmd.startsWith("flood ") -> {
                            var left = cmd.removePrefix("flood ").toLong()
                            val chunk = ByteArray(8192) { ('a'.code + it % 26).toByte() }
                            while (left > 0) {
                                val k = minOf(left, chunk.size.toLong()).toInt()
                                out.write(chunk, 0, k)
                                left -= k
                            }
                            say("FIN\n")
                        }
                    }
                }
            }
        }
    }

    private fun fingerprint(k: PublicKey): String {
        val (type, b64) = PublicKeyEntry.toString(k).split(" ")
        val sha = MessageDigest.getInstance("SHA-256").digest(Base64.getDecoder().decode(b64))
        return "$type SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(sha)
    }

    /** Démarre le serveur et enregistre « Maison » (clé du serveur acceptée, mot de passe non mémorisé). */
    private fun serverId(hostKey: String? = fingerprint(hostKeys.public)): String {
        val s = SshServer.setUpDefaultServer().apply {
            host = "127.0.0.1"
            port = 0
            keyPairProvider = KeyPairProvider.wrap(hostKeys)
            passwordAuthenticator = PasswordAuthenticator { u, p, _ -> u == USER && p == PASSWORD }
            shellFactory = ShellFactory { EchoShell() }
            start()
        }.also { sshd = it }
        val c = store.save(ServerConfig("", "sftp", "Maison", "127.0.0.1", s.port, USER, "/", false, null, null), null, null)
        store.setHostKey(c.id, hostKey)
        return c.id
    }

    private fun open(serverId: String, startDir: String? = null) =
        TerminalSessions.open(serverId, PASSWORD.toByteArray(), startDir)

    private fun text(id: String) = outputs[id]?.let { synchronized(it) { it.toString(Charsets.UTF_8.name()) } }.orEmpty()

    private fun waitFor(what: String, timeoutMs: Long = 10_000, cond: () -> Boolean) {
        val end = System.currentTimeMillis() + timeoutMs
        while (!cond()) {
            if (System.currentTimeMillis() > end) throw AssertionError("délai dépassé : $what")
            Thread.sleep(10)
        }
    }

    private fun send(id: String, s: String) = TerminalSessions.write(id, s.toByteArray())

    @Test fun echoRoundTrip() {
        val t = open(serverId())
        assertEquals("open", t.state)
        assertEquals("Maison", t.title)
        send(t.id, "bonjour\n")
        waitFor("écho") { text(t.id).contains("bonjour") }
        assertTrue(String(TerminalSessions.backlog(t.id)).contains("bonjour"))
        assertTrue(changes.any { it.id == t.id && it.state == "connecting" })
        assertTrue(changes.any { it.id == t.id && it.state == "open" })
    }

    @Test fun ptyIsXterm256() {
        val t = open(serverId())
        send(t.id, "term\n")
        waitFor("TERM") { text(t.id).contains("TERM=xterm-256color") }
    }

    @Test fun resizeReachesServer() {
        val t = open(serverId())
        assertEquals(80, t.cols)
        assertEquals(24, t.rows)
        send(t.id, "size\n")
        waitFor("80x24") { text(t.id).contains("SIZE=80x24") }
        TerminalSessions.resize(t.id, 100, 40)
        send(t.id, "size\n")
        waitFor("100x40") { text(t.id).contains("SIZE=100x40") }
        val now = TerminalSessions.list().single()
        assertEquals(100, now.cols)
        assertEquals(40, now.rows)
    }

    @Test fun startDirSendsCd() {
        val t = open(serverId(), startDir = "/srv/l'été")
        waitFor("cd") { text(t.id).contains("cd -- '/srv/l'\\''été'\n") }
    }

    @Test fun maxEightSessions() {
        val id = serverId()
        val opened = (1..8).map { open(id) }
        assertEquals("Maison (2)", opened[1].title)
        val e = assertThrows(FilesException::class.java) { open(id) }
        assertEquals("8 sessions au plus", e.message)
        assertEquals(8, TerminalSessions.list().size)
    }

    @Test fun floodIsBatchedAndBounded() {
        val t = open(serverId())
        send(t.id, "flood 5000000\n")
        waitFor("FIN", 30_000) { text(t.id).endsWith("FIN\n") }
        val b = batches.getValue(t.id).toList()
        assertTrue(b.all { it.second <= 64 * 1024 })
        // au plus un lot par 16 ms sur toute la durée (l'écart d'un lot à l'autre, vu d'ici, varie avec le ramasse-miettes)
        val spanMs = (b.last().first - b.first().first) / 1_000_000.0
        assertTrue("${b.size} lots en $spanMs ms", b.size - 1 <= spanMs / 16.0 + 1)
        assertTrue(b.size >= 5_000_000 / (64 * 1024)) // 5 Mo en lots de 64 Kio au plus
        val backlog = TerminalSessions.backlog(t.id)
        assertTrue(backlog.size <= 256 * 1024)
        assertEquals(256 * 1024, backlog.size)
        assertTrue(String(backlog).endsWith("FIN\n"))
        assertTrue(text(t.id).length >= 5_000_000)
    }

    @Test fun backlogKeepsLastBytesInOrder() {
        val sent = ByteArrayOutputStream()
        val pump = OutputPump({ synchronized(sent) { sent.write(it) } })
        val all = ByteArray(300_001) { (it % 251).toByte() }
        var off = 0
        for (n in listOf(1, 70_000, 33, 100_000, 129_967)) {
            pump.offer(all, off, n)
            off += n
        }
        pump.close()
        assertEquals(all.size, off)
        assertTrue(all.contentEquals(synchronized(sent) { sent.toByteArray() }))
        assertTrue(all.copyOfRange(all.size - 256 * 1024, all.size).contentEquals(pump.backlog()))
    }

    @Test fun serverDropClosesSession() {
        val t = open(serverId())
        sshd!!.stop(true)
        waitFor("fermée") { changes.any { it.id == t.id && it.state == "closed" } }
        val closed = changes.last { it.id == t.id }
        assertEquals("closed", closed.state)
        assertNotNull(closed.error)
        assertEquals("closed", TerminalSessions.list().single().state) // gardée pour « Reconnecter »
        TerminalSessions.write(t.id, "rien\n".toByteArray()) // sans effet, sans erreur
    }

    @Test fun exitClosesSession() {
        val t = open(serverId())
        send(t.id, "exit\n")
        waitFor("fermée") { changes.any { it.id == t.id && it.state == "closed" } }
        assertNull(changes.last { it.id == t.id }.error)
    }

    @Test fun passwordNeverInBacklog() {
        val t = open(serverId())
        send(t.id, "term\n")
        waitFor("TERM") { text(t.id).contains("TERM=") }
        assertFalse(String(TerminalSessions.backlog(t.id)).contains(PASSWORD))
        assertFalse(text(t.id).contains(PASSWORD))
    }

    @Test fun terminalRefusesChangedHostKey() {
        val other = KeyPairGenerator.getInstance("EC").apply { initialize(256) }.generateKeyPair()
        val id = serverId(hostKey = fingerprint(other.public))
        assertThrows(HostKeyChanged::class.java) { open(id) }
        assertTrue(TerminalSessions.list().isEmpty())
    }

    @Test fun stateFlowAndServiceStarter() {
        var starts = 0
        TerminalSessions.starter = { starts++ }
        val t = open(serverId())
        assertTrue(starts >= 1) // service démarré dès la première session
        assertEquals(listOf(t.id), TerminalSessions.state.value.map { it.id })
        assertEquals("open", TerminalSessions.state.value.single().state)
        TerminalSessions.close(t.id)
        assertTrue(TerminalSessions.state.value.isEmpty())
    }

    @Test fun closeAllClosesEverything() {
        val id = serverId()
        val a = open(id)
        val b = open(id)
        waitFor("sessions côté serveur") { sshd!!.activeSessions.size == 2 }
        TerminalSessions.closeAll()
        assertTrue(TerminalSessions.list().isEmpty())
        for (t in listOf(a, b)) assertTrue(changes.any { it.id == t.id && it.state == "closed" })
        waitFor("sessions fermées côté serveur") { sshd!!.activeSessions.isEmpty() }
        assertEquals(0, TerminalSessions.backlog(a.id).size)
    }

    private companion object {
        const val USER = "portail"
        const val PASSWORD = "mot-de-passe-test"
    }
}
