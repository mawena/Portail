package com.mawena.fluluks.remote.ssh

import com.jcraft.jsch.ChannelShell
import com.jcraft.jsch.JSchException
import com.jcraft.jsch.Session
import com.mawena.fluluks.remote.Secrets
import com.mawena.fluluks.remote.ServerConfig
import com.mawena.fluluks.remote.net
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Une session de terminal vue de Dart : `state` ∈ `connecting`, `open`, `closed` ; [error] : pourquoi elle s'est fermée. */
data class TerminalInfo(
    val id: String,
    val serverId: String,
    val title: String,
    val state: String,
    val error: String?,
    val cols: Int,
    val rows: Int,
) {
    companion object {
        const val CONNECTING = "connecting"
        const val OPEN = "open"
        const val CLOSED = "closed"
    }
}

/**
 * Un terminal (phase 13, T2) : sa propre session SSH (jamais partagée avec l'explorateur SFTP : une session lente ne
 * bloque pas l'autre) et un `ChannelShell` en PTY `xterm-256color`, UTF-8. Un fil lit la sortie vers [OutputPump] ;
 * écritures et changements de taille passent par un exécuteur unique, dans l'ordre, sans bloquer l'appelant. Les
 * octets restent bruts : Dart les décode. [changed] est appelé quand la session se ferme d'elle-même.
 */
internal class TerminalSession(
    initial: TerminalInfo,
    private val server: ServerConfig,
    output: (String, ByteArray) -> Unit,
    private val changed: (TerminalInfo) -> Unit,
) {
    @Volatile var info: TerminalInfo = initial
        private set

    val pump = OutputPump({ output(initial.id, it) })
    private val writer: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "terminal-écriture").apply { isDaemon = true }
    }
    private var session: Session? = null
    private var channel: ChannelShell? = null
    private var out: OutputStream? = null
    @Volatile private var closing = false

    /** Connecte (vérification d'empreinte et authentification par [SshConnector]) puis ouvre le shell. */
    fun connect(secrets: Secrets, prompts: SshPrompts?, startDir: String?) {
        val connector = SshConnector(server, secrets, prompts)
        val s = try {
            net { connector.open() }
        } finally {
            connector.close() // clé déchiffrée inutile une fois authentifié
        }
        try {
            val ch = s.openChannel("shell") as ChannelShell
            ch.setPtyType(PTY_TYPE, info.cols, info.rows, 0, 0)
            ch.setTerminalMode(IUTF8_ON)
            val input = ch.inputStream
            val o = ch.outputStream
            ch.connect(SshConnector.CONNECT_TIMEOUT_MS)
            session = s
            channel = ch
            out = o
            info = info.copy(state = TerminalInfo.OPEN)
            Thread({ read(input) }, "terminal-lecture").apply { isDaemon = true }.start()
            startDir?.takeIf { it.isNotEmpty() }?.let { write(cd(it).toByteArray(Charsets.UTF_8)) }
        } catch (e: Exception) {
            s.disconnect()
            throw if (e is JSchException) SshErrors.failure(e) else e
        }
    }

    /** Octets tapés ; remis à zéro une fois envoyés (un mot de passe tapé pour `sudo` n'y reste pas). */
    fun write(data: ByteArray) {
        if (info.state != TerminalInfo.OPEN) return data.fill(0)
        runCatching {
            writer.execute {
                try {
                    out?.apply { write(data); flush() }
                } catch (e: IOException) {
                    // la lecture voit la fin de la session et la ferme
                } finally {
                    data.fill(0)
                }
            }
        }
    }

    fun resize(cols: Int, rows: Int) {
        val c = cols.coerceIn(1, MAX_SIZE)
        val r = rows.coerceIn(1, MAX_SIZE)
        info = info.copy(cols = c, rows = r)
        if (info.state != TerminalInfo.OPEN) return
        runCatching { writer.execute { runCatching { channel?.setPtySize(c, r, 0, 0) } } }
    }

    /** Fermeture demandée : tout est libéré, la sortie récente effacée. */
    fun close() {
        closing = true
        info = info.copy(state = TerminalInfo.CLOSED, error = null)
        release()
        pump.close()
        pump.clear()
    }

    private fun release() {
        writer.shutdownNow()
        runCatching { channel?.disconnect() }
        runCatching { session?.disconnect() }
    }

    private fun read(input: InputStream) {
        val buf = ByteArray(READ_BUFFER)
        try {
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                pump.offer(buf, 0, n)
            }
        } catch (e: IOException) {
            // fin de session
        }
        pump.close()
        if (closing) return
        // `exit` (statut rendu) ou session encore vivante : fermeture normale ; sinon la connexion est tombée. JSch
        // ferme les canaux avant de marquer la session déconnectée : on lui laisse un instant.
        val ch = channel
        val normal = (ch != null && ch.exitStatus >= 0) || stillConnected()
        release()
        info = info.copy(state = TerminalInfo.CLOSED, error = if (normal) null else LOST)
        changed(info)
    }

    private fun stillConnected(): Boolean {
        val s = session ?: return false
        val end = System.nanoTime() + DROP_WAIT_NS
        while (System.nanoTime() < end) {
            if (!s.isConnected || closing) return false
            Thread.sleep(10)
        }
        return s.isConnected
    }

    companion object {
        const val PTY_TYPE = "xterm-256color"
        const val LOST = "Connexion au serveur perdue"
        const val MAX_SIZE = 1000
        private const val READ_BUFFER = 16 * 1024
        private const val DROP_WAIT_NS = 1_000_000_000L

        /** Modes du PTY : IUTF8 (opcode 42) à 1, puis TTY_OP_END. */
        private val IUTF8_ON = byteArrayOf(42, 0, 0, 0, 1, 0)

        /** `cd` vers [dir] au début du shell, le nom entre guillemets simples (un guillemet simple échappé en `'\''`). */
        fun cd(dir: String) = "cd -- '" + dir.replace("'", "'\\''") + "'\n"
    }
}
