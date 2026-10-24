package com.mawena.fluluks.remote

import android.content.Context
import androidx.annotation.VisibleForTesting
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.files.FilesException
import com.mawena.fluluks.provider.StreamTokens
import java.io.FileNotFoundException
import java.util.concurrent.ConcurrentHashMap

/**
 * Connexions aux serveurs enregistrés (phase 10). Une connexion ouverte est une [RemoteSource] de `Sources.list()` ;
 * ses secrets restent en mémoire le temps de la connexion (reconnexions du client), puis sont remis à zéro.
 */
object Remotes {
    /** Crée le client d'un protocole ; les tâches FTP et SFTP le remplissent. */
    fun interface Factory {
        fun connect(server: ServerConfig, secrets: Secrets): RemoteClient
    }

    @Volatile private var store: RemoteServers? = null
    @Volatile private var factory: Factory = Factory { s, sec ->
        when (s.protocol) {
            "ftp" -> FtpClient(s, sec)
            "sftp" -> SftpClient.connect(s, sec)
            else -> throw FilesException(EngineError.FL_ENOTSUP, "Protocole ${s.protocol.uppercase()} pas encore pris en charge")
        }
    }
    private val open = ConcurrentHashMap<String, Pair<RemoteSource, Secrets>>()

    fun init(context: Context) {
        if (store == null) {
            com.mawena.fluluks.remote.ssh.SshKeys.defaultComment = "portail@${android.os.Build.MODEL ?: "Android"}"
            store = RemoteServers(context.applicationContext.filesDir, KeystoreSecretBox()).also {
                runCatching { it.migrateKeys() } // phase 13 : clés de la phase 10 dans le trousseau
            }
        }
    }

    fun servers(): RemoteServers = store ?: throw FilesException(EngineError.FL_ENODEV, "Serveurs indisponibles")

    /** Tests JVM : magasin et fabrique simulés ; tout est déconnecté. */
    @VisibleForTesting
    fun resetForTests(store: RemoteServers?, factory: Factory?) {
        for (id in open.keys.toList()) disconnect(id)
        this.store = store
        if (factory != null) this.factory = factory
    }

    fun setFactory(f: Factory) {
        factory = f
    }

    /**
     * Connecte [serverId] ([password] : saisi à l'instant, sinon celui mémorisé) ; déjà connecté : la même source.
     * Lève [HostKeyUnknown], [HostKeyChanged] ou [AuthFailed] selon le cas.
     */
    /**
     * Secrets d'une connexion à [cfg] : [password] (copié) sinon celui mémorisé, la phrase mémorisée, la clé du
     * trousseau désignée par le serveur (sinon une clé de la phase 10 pas encore migrée). À remettre à zéro.
     */
    fun secretsFor(cfg: ServerConfig, password: ByteArray?): Secrets {
        val s = servers()
        val stored = s.secrets(cfg.id)
        val fromRing = cfg.keyId?.let { runCatching { s.keys.privateKey(it) }.getOrNull() }
        if (password != null) stored?.password?.fill(0)
        if (fromRing != null) stored?.privateKey?.fill(0)
        return Secrets(password?.copyOf() ?: stored?.password, stored?.keyPassphrase, fromRing ?: stored?.privateKey)
    }

    fun connect(serverId: String, password: ByteArray?): RemoteSource {
        open[serverId]?.let { return it.first }
        val s = servers()
        val cfg = s.get(serverId) ?: throw FileNotFoundException("Serveur introuvable")
        val sec = secretsFor(cfg, password)
        val client = try {
            net { factory.connect(cfg, sec) }
        } catch (e: Exception) {
            sec.wipe()
            throw e
        }
        val src = RemoteSource(cfg, client)
        open[serverId] = src to sec
        return src
    }

    /**
     * « Tester la connexion » (phase 13) : connecte [serverId] comme [connect], puis ferme aussitôt, sans source ni
     * connexion gardée ; mêmes exceptions que [connect].
     */
    fun testServer(serverId: String, password: ByteArray?) {
        val s = servers()
        val cfg = s.get(serverId) ?: throw FileNotFoundException("Serveur introuvable")
        val sec = secretsFor(cfg, password)
        try {
            val client = net { factory.connect(cfg, sec) }
            runCatching { client.close() }
        } finally {
            sec.wipe()
        }
    }

    fun disconnect(serverId: String) {
        val (src, sec) = open.remove(serverId) ?: return
        runCatching { src.client.close() }
        sec.wipe()
        StreamTokens.forget(src.id)
    }

    fun connected(): List<RemoteSource> = open.values.map { it.first }

    fun isConnected(serverId: String) = open.containsKey(serverId)

    /** Accepte la clé SFTP [fingerprint] pour [serverId] (première connexion, après l'avoir montrée). */
    fun trustHostKey(serverId: String, fingerprint: String) = servers().setHostKey(serverId, fingerprint)

    fun forgetHostKey(serverId: String) = servers().setHostKey(serverId, null)

    /**
     * Clé privée OpenSSH [key] importée pour [serverId] : rangée dans le trousseau (« Clé de <serveur> », phase 13)
     * et désignée par le serveur ; rend sa description (« ssh-ed25519 SHA256:… »). [key] est remise à zéro dans tous
     * les cas ; un fichier qui n'est pas une clé ne change rien.
     */
    fun importPrivateKey(serverId: String, key: ByteArray): String {
        try {
            val info = PrivateKeys.describe(net { PrivateKeys.inspect(key) })
            val cfg = servers().get(serverId) ?: throw FileNotFoundException("Serveur introuvable")
            val k = net { servers().keys.import("Clé de ${cfg.name}", key.copyOf()) }
            servers().setKey(serverId, k.id)
            return info
        } finally {
            key.fill(0)
        }
    }

    /**
     * Installe la clé publique [keyId] du trousseau dans `~/.ssh/authorized_keys` de [serverId] (phase 13). Connexion
     * par [password] (sinon celui mémorisé ; sans mot de passe, par la clé actuelle du serveur), empreinte vérifiée ;
     * mêmes exceptions que [connect].
     */
    fun installPublicKey(serverId: String, keyId: String, password: ByteArray?): com.mawena.fluluks.remote.ssh.KeyInstaller.Result {
        val s = servers()
        val cfg = s.get(serverId) ?: throw FileNotFoundException("Serveur introuvable")
        val line = net { s.keys.publicKey(keyId) }
        val stored = s.secrets(serverId)
        val pw = password?.copyOf() ?: stored?.password?.copyOf()
        stored?.wipe()
        val sec = if (pw != null) Secrets(pw, null, null) else secretsFor(cfg, null)
        val connector = com.mawena.fluluks.remote.ssh.SshConnector(cfg, sec, com.mawena.fluluks.remote.ssh.SshPromptBridge.prompts)
        try {
            val session = net { connector.open() }
            try {
                return net { com.mawena.fluluks.remote.ssh.KeyInstaller.install(session, line) }
            } finally {
                session.disconnect()
            }
        } finally {
            connector.close()
            sec.wipe()
        }
    }

    /** Le serveur n'utilise plus de clé ; elle reste dans le trousseau. */
    fun forgetPrivateKey(serverId: String) = servers().setKey(serverId, null)
}
