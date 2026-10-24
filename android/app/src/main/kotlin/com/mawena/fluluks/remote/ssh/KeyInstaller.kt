package com.mawena.fluluks.remote.ssh

import com.jcraft.jsch.ChannelSftp
import com.jcraft.jsch.Session
import com.jcraft.jsch.SftpException
import com.mawena.fluluks.remote.RemoteIOException
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

/**
 * Ajoute une clé publique à `~/.ssh/authorized_keys` d'un serveur, par SFTP (phase 13, T8) : `~/.ssh` créé en 700 (et
 * retiré de l'écriture du groupe et des autres s'il l'était), lignes existantes gardées octet pour octet, clé déjà
 * présente (même type et même blob) laissée telle quelle, nouveau fichier écrit à côté en 600 puis mis en place par
 * `posix-rename@openssh.com` (sinon suppression puis renommage). Un `authorized_keys` en lien symbolique est refusé.
 */
object KeyInstaller {
    enum class Result { ADDED, ADDED_NOT_ATOMIC, ALREADY_PRESENT }

    /** Message montré après l'installation sur [server]. */
    fun message(r: Result, server: String) = when (r) {
        Result.ADDED -> "Clé installée sur $server"
        Result.ADDED_NOT_ATOMIC -> "Clé installée sur $server (fichier remplacé en deux temps\u00A0: le serveur ne sait pas le faire d'un coup)"
        Result.ALREADY_PRESENT -> "Clé déjà installée sur $server"
    }

    private const val DIR = ".ssh"
    private const val FILE = ".ssh/authorized_keys"
    private const val TMP = ".ssh/authorized_keys.portail-tmp"
    private const val MAX_FILE = 1024 * 1024

    fun install(session: Session, publicKey: String): Result {
        val wanted = keyOf(publicKey.trim()) ?: throw RemoteIOException("Clé publique illisible")
        val ch = session.openChannel("sftp") as ChannelSftp
        try {
            ch.connect(SshConnector.CONNECT_TIMEOUT_MS)
            return sftp { install(ch, publicKey.trim(), wanted) }
        } finally {
            ch.disconnect()
        }
    }

    private fun install(ch: ChannelSftp, line: String, wanted: Pair<String, String>): Result {
        val dir = stat(ch, DIR)
        if (dir == null) {
            ch.mkdir(DIR)
            ch.chmod(0b111_000_000, DIR)
        } else {
            if (!dir.isDir) throw RemoteIOException("$DIR n'est pas un dossier : installation annulée")
            val perm = dir.permissions and 0b111_111_111
            if (perm and 0b000_010_010 != 0) ch.chmod(perm and 0b111_101_101, DIR) // sans écriture pour le groupe ni les autres
        }
        val file = stat(ch, FILE)
        if (file != null && file.isLink) throw RemoteIOException("$FILE est un lien symbolique : installation annulée")
        val old = if (file == null) ByteArray(0) else read(ch)
        val text = String(old, Charsets.UTF_8)
        if (text.lineSequence().any { keyOf(it) == wanted }) return Result.ALREADY_PRESENT

        val sep = if (old.isEmpty() || old.last() == '\n'.code.toByte()) "" else "\n"
        val content = old + (sep + line + "\n").toByteArray(Charsets.UTF_8)
        runCatching { ch.rm(TMP) }
        ch.put(ByteArrayInputStream(content), TMP, ChannelSftp.OVERWRITE)
        ch.chmod(0b110_000_000, TMP)
        if (file == null || ch.getExtension("posix-rename@openssh.com") != null) {
            ch.rename(TMP, FILE) // posix-rename quand le serveur le connaît : remplacement atomique
            return Result.ADDED
        }
        ch.rm(FILE)
        ch.rename(TMP, FILE)
        return Result.ADDED_NOT_ATOMIC
    }

    private fun read(ch: ChannelSftp): ByteArray {
        val out = ByteArrayOutputStream()
        ch.get(FILE, out)
        if (out.size() > MAX_FILE) throw RemoteIOException("$FILE est trop gros : installation annulée")
        return out.toByteArray()
    }

    private fun stat(ch: ChannelSftp, path: String) = try {
        ch.lstat(path)
    } catch (e: SftpException) {
        if (e.id == ChannelSftp.SSH_FX_NO_SUCH_FILE) null else throw e
    }

    /** (type, blob) d'une ligne `authorized_keys` (options et commentaire ignorés), ou null pour un commentaire ou une ligne vide. */
    internal fun keyOf(line: String): Pair<String, String>? {
        val t = line.trim()
        if (t.isEmpty() || t.startsWith("#")) return null
        val parts = t.split(Regex("\\s+"))
        val i = parts.indexOfFirst { p -> TYPES.any { p.startsWith(it) } && !p.contains('=') }
        if (i < 0 || i + 1 >= parts.size) return null
        return parts[i] to parts[i + 1]
    }

    private val TYPES = listOf("ssh-", "ecdsa-", "sk-")

    private inline fun <T> sftp(block: () -> T): T = try {
        block()
    } catch (e: SftpException) {
        throw RemoteIOException(
            when (e.id) {
                ChannelSftp.SSH_FX_PERMISSION_DENIED -> "Accès refusé par le serveur : installation annulée"
                else -> "Installation impossible : ${e.message.orEmpty()}"
            },
            e,
        )
    }
}
