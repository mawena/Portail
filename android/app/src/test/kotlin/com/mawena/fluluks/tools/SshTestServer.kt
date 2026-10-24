package com.mawena.fluluks.tools

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import kotlin.concurrent.thread
import org.apache.sshd.common.config.keys.PublicKeyEntry
import org.apache.sshd.common.file.virtualfs.VirtualFileSystemFactory
import org.apache.sshd.server.Environment
import org.apache.sshd.server.ExitCallback
import org.apache.sshd.server.SshServer
import org.apache.sshd.server.auth.keyboard.InteractiveChallenge
import org.apache.sshd.server.auth.keyboard.KeyboardInteractiveAuthenticator
import org.apache.sshd.server.auth.keyboard.PromptEntry
import org.apache.sshd.server.auth.password.PasswordAuthenticator
import org.apache.sshd.server.auth.pubkey.PublickeyAuthenticator
import org.apache.sshd.server.channel.ChannelSession
import org.apache.sshd.server.command.Command
import org.apache.sshd.server.forward.AcceptAllForwardingFilter
import org.apache.sshd.server.keyprovider.SimpleGeneratorHostKeyProvider
import org.apache.sshd.server.session.ServerSession
import org.apache.sshd.server.shell.ShellFactory
import org.apache.sshd.sftp.server.SftpSubsystemFactory

/**
 * Serveur SSH d'essai pour les essais instrumentés de la phase 13 (T12), lancé sur le PC par
 * `tools/ssh/serveur-essai.sh` (tâche Gradle `:app:runSshTestServer`) et joint par le téléphone via
 * `adb reverse tcp:2222 tcp:2222` et `adb reverse tcp:2223 tcp:2223`.
 *
 * - SSH sur 127.0.0.1:2222 ; compte `portail`, mot de passe `essai-portail` ; compte `portail-ki` par
 *   keyboard-interactive, code `123456` ; clés acceptées : celles de `~/.ssh/authorized_keys` du dossier personnel
 *   (un dossier temporaire, effacé à l'arrêt), où les essais installent la leur par SFTP ;
 * - shell d'écho (`term`, `size`, `exit`), SFTP, redirection de port acceptée ;
 * - serveur TCP d'écho sur 127.0.0.1:2223, cible des tunnels.
 *
 * Comptes et clé du serveur jetables : rien n'est gardé après l'arrêt.
 */
fun main() {
    val home = Files.createTempDirectory("portail-ssh-essai")
    Files.setPosixFilePermissions(home, PosixFilePermissions.fromString("rwx------"))
    val hostKey = Files.createTempFile("portail-ssh-essai-cle", ".ser").also { Files.delete(it) }
    Runtime.getRuntime().addShutdownHook(Thread {
        home.toFile().deleteRecursively()
        hostKey.toFile().delete()
    })

    val loopback = InetAddress.getByName("127.0.0.1")
    val echo = ServerSocket(ECHO_PORT, 50, loopback)
    thread(isDaemon = true, name = "echo") {
        while (true) {
            val c = runCatching { echo.accept() }.getOrNull() ?: break
            thread(isDaemon = true) { c.use { runCatching { it.getInputStream().copyTo(it.getOutputStream()) } } }
        }
    }

    val sshd = SshServer.setUpDefaultServer().apply {
        host = "127.0.0.1"
        port = SSH_PORT
        keyPairProvider = SimpleGeneratorHostKeyProvider(hostKey)
        passwordAuthenticator = PasswordAuthenticator { u, p, _ -> u == USER && p == PASSWORD }
        keyboardInteractiveAuthenticator = object : KeyboardInteractiveAuthenticator {
            override fun generateChallenge(s: ServerSession, user: String, lang: String?, sub: String?) =
                InteractiveChallenge().apply {
                    if (user == KI_USER) {
                        interactionName = "Portail (essai)"
                        interactionInstruction = "Double facteur"
                        addPrompt(PromptEntry("Code de vérification : ", true))
                    } else {
                        addPrompt(PromptEntry("Password: ", false))
                    }
                }

            override fun authenticate(s: ServerSession, user: String, responses: List<String>) = when (user) {
                KI_USER -> responses == listOf(CODE)
                USER -> responses == listOf(PASSWORD)
                else -> false
            }
        }
        // clés relues à chaque tentative (celle installée par l'essai compte aussitôt), pour le compte d'essai seulement
        val authorized = home.resolve(".ssh/authorized_keys")
        publickeyAuthenticator = PublickeyAuthenticator { user, key, _ ->
            val blob = PublicKeyEntry.toString(key).split(" ")[1]
            user == USER && Files.isRegularFile(authorized) &&
                Files.readAllLines(authorized).any { it.trim().split(Regex("\\s+")).getOrNull(1) == blob }
        }
        shellFactory = ShellFactory { EchoShell() }
        subsystemFactories = listOf(SftpSubsystemFactory())
        fileSystemFactory = VirtualFileSystemFactory(home)
        forwardingFilter = AcceptAllForwardingFilter.INSTANCE
        start()
    }
    println("Serveur SSH d'essai : 127.0.0.1:$SSH_PORT, écho TCP : 127.0.0.1:$ECHO_PORT, dossier $home")
    println("Comptes : $USER / $PASSWORD ; $KI_USER (code $CODE). Ctrl+C pour arrêter.")
    Runtime.getRuntime().addShutdownHook(Thread { sshd.stop(true); echo.close() })
    Thread.currentThread().join()
}

const val SSH_PORT = 2222
const val ECHO_PORT = 2223
const val USER = "portail"
const val PASSWORD = "essai-portail"
const val KI_USER = "portail-ki"
const val CODE = "123456"

/** Shell d'écho : renvoie chaque octet reçu, puis exécute la ligne terminée (`term`, `size`, `exit`). */
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
        say("Bienvenue sur le serveur d'essai de Portail\r\n$ ")
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
                when (cmd) {
                    "term" -> say("\r\nTERM=${env.env[Environment.ENV_TERM]}\r\n$ ")
                    "size" -> say("\r\nSIZE=${env.env[Environment.ENV_COLUMNS]}x${env.env[Environment.ENV_LINES]}\r\n$ ")
                    "exit" -> {
                        exit?.onExit(0)
                        return
                    }
                    else -> if (cmd.isNotEmpty()) say("\r\n$ ")
                }
            }
        }
    }
}
