package com.mawena.fluluks.remote.ssh

import android.content.Context
import androidx.annotation.VisibleForTesting
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.files.FilesException
import com.mawena.fluluks.remote.RemoteIOException
import com.mawena.fluluks.remote.Remotes
import com.mawena.fluluks.remote.Secrets
import java.io.FileNotFoundException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Sessions de terminal ouvertes (phase 13, T2), [MAX] au plus en cours (`connecting` ou `open`). Une session tombée
 * reste listée, `closed` avec son message, jusqu'à [close] (pour « Reconnecter » et relire sa sortie). Sortie et
 * changements d'état partent vers [listener], sur les fils de lecture et de lots (le pont les remet sur le fil
 * principal). [state] suit la liste ; [starter] est appelé à chaque changement (le service des sessions SSH s'y
 * démarre, T3).
 */
object TerminalSessions {
    interface Listener {
        fun onOutput(id: String, data: ByteArray)
        fun onChanged(info: TerminalInfo)

        /** Vrai si chaque lot sera acquitté par [delivered] (le pont, une fois Dart servi). */
        val acknowledges: Boolean get() = false
    }

    /** Un lot de sortie de [id] a été remis à Dart. */
    fun delivered(id: String) {
        synchronized(this) { sessions[id] }?.pump?.delivered()
    }

    @Volatile var listener: Listener? = null
        set(value) {
            field = value
            // l'ancien écouteur n'acquittera plus : rien ne reste en attente
            for (t in synchronized(this) { sessions.values.toList() }) t.pump.resetInflight()
        }

    /** Appelé après chaque changement : démarre le service si une session est en cours. */
    @Volatile var starter: (() -> Unit)? = null

    private val flow = MutableStateFlow<List<TerminalInfo>>(emptyList())
    val state: StateFlow<List<TerminalInfo>> = flow

    /** Branche le démarrage du service des sessions SSH (une fois, au premier pont). */
    fun init(context: Context) {
        if (starter == null) {
            val app = context.applicationContext
            starter = { com.mawena.fluluks.service.SshService.startIfNeeded(app) }
        }
    }

    private val sessions = LinkedHashMap<String, TerminalSession>()

    /**
     * Ouvre un terminal sur le serveur SFTP [serverId] ([password] : saisi à l'instant, sinon celui mémorisé ; copié,
     * l'appelant garde le sien), puis `cd` vers [startDir] s'il est donné. Mêmes exceptions que la connexion SFTP
     * ([com.mawena.fluluks.remote.HostKeyUnknown], [com.mawena.fluluks.remote.HostKeyChanged],
     * [com.mawena.fluluks.remote.AuthFailed], [SshFailure]) ; « 8 sessions au plus » au-delà de [MAX].
     */
    fun open(serverId: String, password: ByteArray?, startDir: String?): TerminalInfo {
        val store = Remotes.servers()
        val cfg = store.get(serverId) ?: throw FileNotFoundException("Serveur introuvable")
        if (cfg.protocol != "sftp") throw FilesException(EngineError.FL_ENOTSUP, NOT_SFTP)
        val t = synchronized(this) {
            if (sessions.values.count { it.info.state != TerminalInfo.CLOSED } >= MAX) {
                throw FilesException(EngineError.FL_EBUSY, TOO_MANY)
            }
            val same = sessions.values.count { it.info.serverId == serverId }
            val title = if (same == 0) cfg.name else "${cfg.name} (${same + 1})"
            val info = TerminalInfo(UUID.randomUUID().toString(), serverId, title, TerminalInfo.CONNECTING, null, COLS, ROWS)
            TerminalSession(info, cfg, { id, data -> listener?.onOutput(id, data) }, ::changed, {
                listener?.acknowledges == true
            })
                .also { sessions[info.id] = it }
        }
        changed(t.info)
        val sec = Remotes.secretsFor(cfg, password)
        try {
            t.connect(sec, SshPromptBridge.prompts, startDir)
            // fermée (« Tout fermer », croix) pendant la connexion : elle ne revient pas
            if (synchronized(this) { sessions[t.info.id] !== t }) throw RemoteIOException(TerminalSession.SESSION_CLOSED)
            for (tunnel in store.tunnels.list(serverId).filter { it.auto }) start(t, tunnel)
        } catch (e: Exception) {
            synchronized(this) { sessions.remove(t.info.id) }
            t.close()
            changed(t.info.copy(state = TerminalInfo.GONE, error = e.message)) // jamais ouverte : rien à montrer
            throw e
        } finally {
            sec.wipe()
        }
        changed(t.info)
        return t.info
    }

    /** Derniers échecs d'ouverture des tunnels, par tunnel. */
    private val tunnelErrors = ConcurrentHashMap<String, String>()

    /** Tunnels enregistrés de [serverId] et leur état (ouvert sur un terminal, dernier échec). */
    fun tunnels(serverId: String): List<TunnelState> {
        val active = synchronized(this) {
            sessions.values.filter { it.info.serverId == serverId }.flatMap { it.activeTunnels() }.toSet()
        }
        return Remotes.servers().tunnels.list(serverId).map { TunnelState(it, it.id in active, tunnelErrors[it.id]) }
    }

    /** Ouvre le tunnel [tunnelId] sur le terminal [sessionId] (du même serveur). */
    fun startTunnel(sessionId: String, tunnelId: String): TunnelState {
        val tunnel = Remotes.servers().tunnels.get(tunnelId) ?: throw FileNotFoundException("Tunnel introuvable")
        val t = synchronized(this) { sessions[sessionId] } ?: throw FileNotFoundException("Session introuvable")
        if (t.info.serverId != tunnel.serverId) throw FilesException(EngineError.FL_EINVAL, "Tunnel d'un autre serveur")
        start(t, tunnel)
        changed(t.info)
        tunnelErrors[tunnel.id]?.let { throw com.mawena.fluluks.remote.RemoteIOException(it) }
        return TunnelState(tunnel, true, null)
    }

    fun stopTunnel(sessionId: String, tunnelId: String) {
        val t = synchronized(this) { sessions[sessionId] } ?: return
        t.stopTunnel(tunnelId)
        changed(t.info)
    }

    /** Ouvre [tunnel] sur [t] ; l'échec est retenu pour l'écran des tunnels. */
    private fun start(t: TerminalSession, tunnel: TunnelConfig) {
        try {
            t.startTunnel(tunnel)
            tunnelErrors.remove(tunnel.id)
        } catch (e: com.mawena.fluluks.remote.RemoteIOException) {
            tunnelErrors[tunnel.id] = e.message.orEmpty()
        }
    }

    fun write(id: String, data: ByteArray) {
        val t = synchronized(this) { sessions[id] } ?: return data.fill(0)
        t.write(data)
    }

    fun resize(id: String, cols: Int, rows: Int) {
        synchronized(this) { sessions[id] }?.resize(cols, rows)
    }

    /** Sortie récente de [id] (vide si inconnue). */
    fun backlog(id: String): ByteArray = synchronized(this) { sessions[id] }?.pump?.backlog() ?: ByteArray(0)

    /** Ferme et retire [id] ; `gone` est annoncé au [listener]. */
    fun close(id: String) {
        val t = synchronized(this) { sessions.remove(id) } ?: return
        t.close()
        changed(t.info.copy(state = TerminalInfo.GONE))
    }

    fun closeAll() {
        for (id in synchronized(this) { sessions.keys.toList() }) close(id)
    }

    fun list(): List<TerminalInfo> = synchronized(this) { sessions.values.map { it.info } }

    private fun changed(info: TerminalInfo) {
        flow.value = list()
        runCatching { listener?.onChanged(info) }
        runCatching { starter?.invoke() }
    }

    /** Tests JVM : tout est fermé, sans écouteur. */
    @VisibleForTesting
    fun resetForTests() {
        listener = null
        starter = null
        closeAll()
    }

    const val MAX = 8
    const val COLS = 80
    const val ROWS = 24
    const val TOO_MANY = "8 sessions au plus"
    const val NOT_SFTP = "Le terminal demande un serveur SFTP"
}
