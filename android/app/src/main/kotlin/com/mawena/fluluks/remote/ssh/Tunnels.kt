package com.mawena.fluluks.remote.ssh

import com.mawena.fluluks.remote.RemoteIOException
import java.io.File
import java.util.UUID
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/**
 * Tunnel enregistré d'un serveur : `127.0.0.1:[localPort]` sur le téléphone mène à [remoteHost]:[remotePort] vu du
 * serveur ; [auto] : ouvert avec chaque terminal de ce serveur.
 */
data class TunnelConfig(
    val id: String,
    val serverId: String,
    val localPort: Int,
    val remoteHost: String,
    val remotePort: Int,
    val auto: Boolean,
)

/** Un tunnel et son état : [active] sur un terminal ouvert ; [error] : dernier échec à l'ouverture. */
data class TunnelState(val config: TunnelConfig, val active: Boolean, val error: String?)

/**
 * Tunnels enregistrés (phase 13, T10), dans `ssh-tunnels.json` sous [dir] (rien de secret), écrit par un fichier
 * temporaire puis renommage ; un fichier abîmé donne une liste vide.
 */
class TunnelStore(private val dir: File) {
    private val file = File(dir, "ssh-tunnels.json")

    @Synchronized
    fun list(serverId: String): List<TunnelConfig> = read().filter { it.serverId == serverId }

    @Synchronized
    fun get(id: String): TunnelConfig? = read().firstOrNull { it.id == id }

    /** Enregistre [t] (nouvel identifiant s'il est vide) ; ports et hôte vérifiés. */
    @Synchronized
    fun save(t: TunnelConfig): TunnelConfig {
        require(t.localPort in LOCAL_MIN..PORT_MAX) { "Port du téléphone entre $LOCAL_MIN et $PORT_MAX" }
        require(t.remotePort in 1..PORT_MAX) { "Port distant entre 1 et $PORT_MAX" }
        val host = t.remoteHost.trim()
        require(host.isNotEmpty() && host.none { it.isWhitespace() }) { "Hôte distant invalide" }
        val saved = t.copy(id = t.id.ifEmpty { UUID.randomUUID().toString() }, remoteHost = host)
        val all = read().toMutableList()
        val i = all.indexOfFirst { it.id == saved.id }
        if (i >= 0) all[i] = saved else all += saved
        write(all)
        return saved
    }

    @Synchronized
    fun delete(id: String) = write(read().filter { it.id != id })

    /** Serveur supprimé : ses tunnels partent avec lui. */
    @Synchronized
    fun dropServer(serverId: String) {
        val all = read()
        if (all.any { it.serverId == serverId }) write(all.filter { it.serverId != serverId })
    }

    private fun read(): List<TunnelConfig> {
        if (!file.isFile) return emptyList()
        return try {
            val a = JSONArray(file.readText())
            (0 until a.length()).mapNotNull { i ->
                val o = a.optJSONObject(i) ?: return@mapNotNull null
                val id = o.optString("id").ifEmpty { return@mapNotNull null }
                TunnelConfig(id, o.optString("serverId"), o.optInt("localPort"), o.optString("remoteHost"),
                    o.optInt("remotePort"), o.optBoolean("auto"))
            }
        } catch (e: JSONException) {
            emptyList()
        }
    }

    private fun write(all: List<TunnelConfig>) {
        dir.mkdirs()
        val a = JSONArray()
        for (t in all) {
            a.put(JSONObject().put("id", t.id).put("serverId", t.serverId).put("localPort", t.localPort)
                .put("remoteHost", t.remoteHost).put("remotePort", t.remotePort).put("auto", t.auto))
        }
        val tmp = File(dir, ".${file.name}.tmp")
        tmp.writeText(a.toString())
        if (!tmp.renameTo(file)) {
            tmp.delete()
            throw RemoteIOException("Enregistrement impossible")
        }
    }

    companion object {
        const val LOCAL_MIN = 1024
        const val PORT_MAX = 65535
    }
}
