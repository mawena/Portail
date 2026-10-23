package com.mawena.fluluks.remote.ssh

import com.jcraft.jsch.HostKey
import com.jcraft.jsch.HostKeyRepository
import com.jcraft.jsch.JSch
import com.jcraft.jsch.JSchException
import com.jcraft.jsch.KeyPair
import com.jcraft.jsch.Session
import com.jcraft.jsch.UIKeyboardInteractive
import com.jcraft.jsch.UserInfo
import com.mawena.fluluks.remote.AuthFailed
import com.mawena.fluluks.remote.HostKeyChanged
import com.mawena.fluluks.remote.HostKeyUnknown
import com.mawena.fluluks.remote.PrivateKeys
import com.mawena.fluluks.remote.Secrets
import com.mawena.fluluks.remote.ServerConfig
import java.io.IOException

/**
 * Ouverture d'une session SSH vers [server] (phase 13, spec § 21), pour tous les usages : explorateur SFTP, terminal,
 * tunnels, installation de clé, « Tester la connexion ». La clé du serveur est vérifiée contre [ServerConfig.hostKey]
 * (jamais acceptée en silence) ; authentification par la clé privée importée si elle existe, sinon par le mot de
 * passe ; keyboard-interactive : l'invite « Password: » reçoit le mot de passe (par JSch, en octets), les autres
 * invites passent par [prompts]. Lève [HostKeyUnknown], [HostKeyChanged], [AuthFailed], « Clé privée illisible » ou
 * [SshFailure] ; chaque tentative remplit [log], gardé aussi par [AttemptLogs]. [secrets] appartient à l'appelant,
 * qui les remet à zéro ; [close] efface les clés déchiffrées par JSch.
 */
class SshConnector(
    private val server: ServerConfig,
    private val secrets: Secrets,
    private val prompts: SshPrompts? = null,
) {
    val log = AttemptLog()
    private val jsch: JSch = jsch().also { it.setInstanceLogger(log.logger) }
    private val useKey = secrets.privateKey != null

    /** Identifiants inutilisables, connus avant d'appeler le serveur (rien à envoyer, ou phrase refusée). */
    private var authProblem: AuthFailed? = null

    fun open(): Session {
        log.add("Connexion à ${server.host}, port ${server.port}, utilisateur ${server.user}")
        try {
            prepareIdentity()
            return connect()
        } catch (e: Exception) {
            log.add("Échec : ${e.message.orEmpty()}${(e as? SshFailure)?.let { " (${it.detail})" }.orEmpty()}")
            throw e
        } finally {
            AttemptLogs.put(server.id, log)
        }
    }

    fun close() {
        runCatching { jsch.removeAllIdentity() }
    }

    private fun prepareIdentity() {
        val key = secrets.privateKey
        if (key == null) {
            if (secrets.password == null) authProblem = AuthFailed(missing = true)
            return
        }
        val copy = key.copyOf()
        var phrase: ByteArray? = null
        try {
            val encrypted = try {
                KeyPair.load(jsch, copy, null).let { kp -> kp.isEncrypted.also { kp.dispose() } }
            } catch (e: Exception) {
                throw IOException("Clé privée illisible")
            }
            if (encrypted) {
                // la phrase mémorisée, sinon le mot de passe saisi à la connexion
                phrase = (secrets.keyPassphrase ?: secrets.password)?.copyOf()
                if (phrase == null) {
                    authProblem = AuthFailed(missing = true)
                    return
                }
            }
            try {
                jsch.addIdentity("portail", copy, null, phrase)
            } catch (e: JSchException) {
                authProblem = AuthFailed(missing = false)
            }
        } finally {
            copy.fill(0)
            phrase?.fill(0)
        }
    }

    /** Clé du serveur : celle acceptée ([accepted]) ou rien ; la clé vue est notée pour le message. */
    private class TrustedKey(private val accepted: String?) : HostKeyRepository {
        @Volatile var seen: String? = null
        @Volatile var verdict = HostKeyRepository.OK

        override fun check(host: String?, key: ByteArray?): Int {
            val k = PrivateKeys.hostKey(key ?: ByteArray(0))
            seen = k
            verdict = when (accepted) {
                null -> HostKeyRepository.NOT_INCLUDED
                k -> HostKeyRepository.OK
                else -> HostKeyRepository.CHANGED
            }
            return verdict
        }

        override fun add(hostkey: HostKey?, ui: UserInfo?) {} // la confiance passe par Remotes.trustHostKey
        override fun remove(host: String?, type: String?) {}
        override fun remove(host: String?, type: String?, key: ByteArray?) {}
        override fun getKnownHostsRepositoryID() = "portail"
        override fun getHostKey(): Array<HostKey> = emptyArray()
        override fun getHostKey(host: String?, type: String?): Array<HostKey> = emptyArray()
    }

    /** Réponses aux invites keyboard-interactive ; aucune autre question de JSch n'est posée à l'utilisateur. */
    private inner class Ui : UserInfo, UIKeyboardInteractive {
        override fun getPassphrase(): String? = null
        override fun getPassword(): String? = null
        override fun promptPassword(message: String?) = false
        override fun promptPassphrase(message: String?) = false
        override fun promptYesNo(message: String?) = false
        override fun showMessage(message: String?) {
            message?.let { log.add("Message du serveur : $it") }
        }

        override fun promptKeyboardInteractive(
            destination: String?, name: String?, instruction: String?, prompt: Array<String>?, echo: BooleanArray?,
        ): Array<String>? {
            val p = prompt?.toList().orEmpty()
            if (p.isEmpty()) return emptyArray()
            log.add("Invite du serveur : ${p.joinToString(" / ")}")
            val answers = prompts?.ask(name.orEmpty(), instruction.orEmpty(), p, echo?.toList() ?: p.map { false })
                ?: return null
            // l'interface de JSch prend des chaînes : copies brèves, jamais journalisées ; nos octets remis à zéro
            return try {
                if (answers.size != p.size) null else answers.map { String(it, Charsets.UTF_8) }.toTypedArray()
            } finally {
                answers.forEach { it.fill(0) }
            }
        }
    }

    private fun connect(): Session {
        val trusted = TrustedKey(server.hostKey)
        jsch.hostKeyRepository = trusted
        val s = try {
            jsch.getSession(server.user, server.host, server.port)
        } catch (e: JSchException) {
            throw IOException("Adresse du serveur invalide")
        }
        s.setConfig("StrictHostKeyChecking", "yes")
        s.setConfig(
            "PreferredAuthentications",
            if (useKey) "publickey,keyboard-interactive" else "password,keyboard-interactive",
        )
        hostKeyOrder()?.let { s.setConfig("server_host_key", it) }
        // copié par JSch, effacé par lui après usage ; avec une clé, le mot de passe saisi peut être sa phrase : il ne
        // part jamais vers le serveur
        if (!useKey) secrets.password?.let { s.setPassword(it) }
        s.userInfo = Ui()
        s.timeout = DATA_TIMEOUT_MS
        s.serverAliveInterval = ALIVE_MS
        s.serverAliveCountMax = ALIVE_COUNT
        try {
            s.connect(CONNECT_TIMEOUT_MS)
        } catch (e: JSchException) {
            s.disconnect()
            throw when {
                trusted.verdict == HostKeyRepository.NOT_INCLUDED -> HostKeyUnknown(trusted.seen!!)
                trusted.verdict == HostKeyRepository.CHANGED -> HostKeyChanged(server.hostKey!!, trusted.seen!!)
                isAuth(e) -> authProblem ?: AuthFailed(missing = false)
                else -> SshErrors.failure(e)
            }
        }
        log.add("Connecté")
        return s
    }

    /** Algorithmes de clé du serveur, celui de la clé acceptée en tête (sinon une autre clé du serveur paraîtrait changée). */
    private fun hostKeyOrder(): String? {
        val type = server.hostKey?.substringBefore(' ')?.takeIf { it.isNotEmpty() } ?: return null
        val first = if (type == "ssh-rsa") listOf("rsa-sha2-512", "rsa-sha2-256") else listOf(type)
        val all = JSch.getConfig("server_host_key").split(',').filter { it.isNotEmpty() }
        return (first + all.filter { it !in first }).joinToString(",")
    }

    /** JSch range ses refus d'authentification en « Auth fail… » ou « Auth cancel… ». */
    private fun isAuth(e: JSchException) =
        e.message.orEmpty().let { it.startsWith("Auth fail") || it.startsWith("Auth cancel") }

    companion object {
        const val CONNECT_TIMEOUT_MS = 10_000
        const val DATA_TIMEOUT_MS = 30_000
        const val ALIVE_MS = 30_000
        const val ALIVE_COUNT = 3

        /** Une instance de JSch réglée pour Bouncy Castle (Ed25519, Curve25519, ML-KEM), comme en phase 10. */
        fun jsch(): JSch = PrivateKeys.jsch()
    }
}
