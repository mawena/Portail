package com.mawena.fluluks

import com.mawena.fluluks.remote.HostKeyChanged
import com.mawena.fluluks.remote.RemoteIOException
import com.mawena.fluluks.remote.RemoteServers
import com.mawena.fluluks.remote.Remotes
import com.mawena.fluluks.remote.SecretBox
import com.mawena.fluluks.remote.ServerConfig
import com.mawena.fluluks.remote.ssh.TerminalSessions
import com.mawena.fluluks.remote.ssh.TunnelConfig
import java.io.InputStream
import java.io.OutputStream
import java.net.ConnectException
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PublicKey
import java.util.Base64
import kotlin.concurrent.thread
import org.apache.sshd.common.config.keys.PublicKeyEntry
import org.apache.sshd.common.keyprovider.KeyPairProvider
import org.apache.sshd.server.Environment
import org.apache.sshd.server.ExitCallback
import org.apache.sshd.server.SshServer
import org.apache.sshd.server.auth.password.PasswordAuthenticator
import org.apache.sshd.server.channel.ChannelSession
import org.apache.sshd.server.command.Command
import org.apache.sshd.server.forward.AcceptAllForwardingFilter
import org.apache.sshd.server.shell.ShellFactory
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Tunnels (redirection de port locale, phase 13, T10) contre MINA SSHD et un serveur TCP d'écho sur 127.0.0.1. */
class TunnelsTest {
    @get:Rule val tmp = TemporaryFolder()

    private object Box : SecretBox {
        override fun seal(plain: ByteArray) = plain
        override fun open(sealed: ByteArray) = sealed
    }

    private val hostKeys: KeyPair = KeyPairGenerator.getInstance("EC").apply { initialize(256) }.generateKeyPair()
    private var sshd: SshServer? = null
    private lateinit var store: RemoteServers
    private lateinit var echo: ServerSocket
    private val busy = mutableListOf<ServerSocket>()

    /** Shell qui ne fait rien jusqu'à la fin de la session. */
    private class IdleShell : Command {
        private lateinit var input: InputStream
        override fun setInputStream(i: InputStream) { input = i }
        override fun setOutputStream(o: OutputStream) {}
        override fun setErrorStream(e: OutputStream) {}
        override fun setExitCallback(c: ExitCallback) {}
        override fun destroy(channel: ChannelSession) {}
        override fun start(channel: ChannelSession, env: Environment) {
            thread(isDaemon = true) { runCatching { while (input.read() >= 0) Unit } }
        }
    }

    @Before fun setup() {
        store = RemoteServers(tmp.root, Box)
        Remotes.resetForTests(store, null)
        TerminalSessions.resetForTests()
        echo = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        thread(isDaemon = true) {
            while (!echo.isClosed) {
                val c = runCatching { echo.accept() }.getOrNull() ?: break
                thread(isDaemon = true) { c.use { it.getInputStream().copyTo(it.getOutputStream()) } }
            }
        }
    }

    @After fun teardown() {
        TerminalSessions.resetForTests()
        Remotes.resetForTests(null, null)
        sshd?.stop(true)
        echo.close()
        busy.forEach { it.close() }
    }

    private fun fingerprint(k: PublicKey): String {
        val (type, b64) = PublicKeyEntry.toString(k).split(" ")
        val sha = MessageDigest.getInstance("SHA-256").digest(Base64.getDecoder().decode(b64))
        return "$type SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(sha)
    }

    private fun serverId(hostKey: String = fingerprint(hostKeys.public)): String {
        val s = SshServer.setUpDefaultServer().apply {
            host = "127.0.0.1"
            port = 0
            keyPairProvider = KeyPairProvider.wrap(hostKeys)
            passwordAuthenticator = PasswordAuthenticator { u, p, _ -> u == "portail" && p == "mdp" }
            shellFactory = ShellFactory { IdleShell() }
            forwardingFilter = AcceptAllForwardingFilter.INSTANCE
            start()
        }.also { sshd = it }
        val c = store.save(ServerConfig("", "sftp", "Maison", "127.0.0.1", s.port, "portail", "/", false, null, null), null, null)
        store.setHostKey(c.id, hostKey)
        return c.id
    }

    private fun freePort(): Int = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }.let { p ->
        if (p < 1024) freePort() else p
    }

    private fun tunnel(serverId: String, local: Int = freePort(), auto: Boolean = false) =
        store.tunnels.save(TunnelConfig("", serverId, local, "127.0.0.1", echo.localPort, auto))

    private fun open(id: String) = TerminalSessions.open(id, "mdp".toByteArray(), null)

    private fun roundTrip(port: Int): String = Socket("127.0.0.1", port).use { s ->
        s.soTimeout = 5_000
        s.getOutputStream().write("bonjour\n".toByteArray())
        s.getOutputStream().flush()
        s.getInputStream().bufferedReader().readLine()
    }

    private fun listening(port: Int) = runCatching { Socket("127.0.0.1", port).close() }.isSuccess

    @Test fun tunnelForwardsBytes() {
        val id = serverId()
        val t = tunnel(id)
        val session = open(id)
        val info = TerminalSessions.startTunnel(session.id, t.id)
        assertTrue(info.active)
        assertEquals("bonjour", roundTrip(t.localPort))
        assertEquals(1, TerminalSessions.list().single().tunnels)
        TerminalSessions.stopTunnel(session.id, t.id)
        assertFalse(listening(t.localPort))
        assertFalse(TerminalSessions.tunnels(id).single().active)
    }

    @Test fun boundToLoopbackOnly() {
        val id = serverId()
        val t = tunnel(id)
        TerminalSessions.startTunnel(open(id).id, t.id)
        val lan = NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList() }
            .firstOrNull { it is Inet4Address }
        assumeTrue("aucune adresse réseau hors boucle locale", lan != null)
        assertThrows(ConnectException::class.java) {
            Socket().use { it.connect(InetSocketAddress(lan, t.localPort), 2_000) }
        }
    }

    @Test fun portInUseSaysSo() {
        val id = serverId()
        val taken = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).also { busy += it }
        assumeTrue(taken.localPort >= 1024)
        val t = tunnel(id, local = taken.localPort)
        val session = open(id)
        val e = assertThrows(RemoteIOException::class.java) { TerminalSessions.startTunnel(session.id, t.id) }
        assertEquals("Le port ${t.localPort} est déjà utilisé sur ce téléphone", e.message)
        assertEquals(e.message, TerminalSessions.tunnels(id).single().error)
    }

    @Test fun portRangeValidated() {
        val id = serverId()
        for (bad in listOf(
            TunnelConfig("", id, 80, "127.0.0.1", 80, false),
            TunnelConfig("", id, 70_000, "127.0.0.1", 80, false),
            TunnelConfig("", id, 8080, "127.0.0.1", 0, false),
            TunnelConfig("", id, 8080, " ", 80, false),
        )) {
            assertThrows(IllegalArgumentException::class.java) { store.tunnels.save(bad) }
        }
        assertTrue(store.tunnels.list(id).isEmpty())
    }

    @Test fun autoTunnelsStartWithSession() {
        val id = serverId()
        val t = tunnel(id, auto = true)
        open(id)
        assertEquals("bonjour", roundTrip(t.localPort))
        assertTrue(TerminalSessions.tunnels(id).single().active)
    }

    @Test fun tunnelsStopWithSession() {
        val id = serverId()
        val t = tunnel(id, auto = true)
        val session = open(id)
        assertTrue(listening(t.localPort))
        TerminalSessions.close(session.id)
        assertFalse(listening(t.localPort))
        assertFalse(TerminalSessions.tunnels(id).single().active)
    }

    @Test fun tunnelRefusesChangedHostKey() {
        val other = KeyPairGenerator.getInstance("EC").apply { initialize(256) }.generateKeyPair()
        val id = serverId(hostKey = fingerprint(other.public))
        val t = tunnel(id, auto = true)
        assertThrows(HostKeyChanged::class.java) { open(id) }
        assertFalse(listening(t.localPort))
    }

    @Test fun deletedServerDropsItsTunnels() {
        val id = serverId()
        tunnel(id)
        store.delete(id)
        assertTrue(store.tunnels.list(id).isEmpty())
    }
}
