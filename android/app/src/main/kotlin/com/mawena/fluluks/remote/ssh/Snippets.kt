package com.mawena.fluluks.remote.ssh

import com.mawena.fluluks.remote.RemoteIOException
import java.io.File
import java.util.UUID
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/** Commande enregistrée : [serverId] null pour une commande commune à tous les serveurs ; [runNow] : suivie d'Entrée. */
data class Snippet(val id: String, val serverId: String?, val name: String, val command: String, val runNow: Boolean)

/**
 * Commandes enregistrées du terminal (phase 13, T9), dans `ssh-snippets.json` sous [dir] (rien de secret), écrit par
 * un fichier temporaire puis renommage. Un fichier abîmé donne une liste vide.
 */
class Snippets(private val dir: File) {
    private val file = File(dir, "ssh-snippets.json")

    /** Celles de [serverId] d'abord, puis les communes, chacune dans l'ordre d'enregistrement. */
    @Synchronized
    fun list(serverId: String?): List<Snippet> {
        val all = read()
        return all.filter { serverId != null && it.serverId == serverId } + all.filter { it.serverId == null }
    }

    /** Enregistre [s] (nouvel identifiant s'il est vide) ; nom et commande obligatoires. */
    @Synchronized
    fun save(s: Snippet): Snippet {
        require(s.name.isNotBlank()) { "Nom de la commande manquant" }
        require(s.command.isNotEmpty()) { "Commande manquante" }
        val saved = s.copy(id = s.id.ifEmpty { UUID.randomUUID().toString() }, name = s.name.trim())
        val all = read().toMutableList()
        val i = all.indexOfFirst { it.id == saved.id }
        if (i >= 0) all[i] = saved else all += saved
        write(all)
        return saved
    }

    @Synchronized
    fun delete(id: String) = write(read().filter { it.id != id })

    /** Serveur supprimé : ses commandes partent avec lui. */
    @Synchronized
    fun dropServer(serverId: String) {
        val all = read()
        if (all.any { it.serverId == serverId }) write(all.filter { it.serverId != serverId })
    }

    private fun read(): List<Snippet> {
        if (!file.isFile) return emptyList()
        return try {
            val a = JSONArray(file.readText())
            (0 until a.length()).mapNotNull { i ->
                val o = a.optJSONObject(i) ?: return@mapNotNull null
                val id = o.optString("id").ifEmpty { return@mapNotNull null }
                Snippet(
                    id,
                    o.optString("serverId").takeIf { !o.isNull("serverId") && it.isNotEmpty() },
                    o.optString("name"),
                    o.optString("command"),
                    o.optBoolean("runNow", true),
                )
            }
        } catch (e: JSONException) {
            emptyList()
        }
    }

    private fun write(all: List<Snippet>) {
        dir.mkdirs()
        val a = JSONArray()
        for (s in all) {
            a.put(JSONObject().put("id", s.id).put("serverId", s.serverId ?: JSONObject.NULL).put("name", s.name)
                .put("command", s.command).put("runNow", s.runNow))
        }
        val tmp = File(dir, ".${file.name}.tmp")
        tmp.writeText(a.toString())
        if (!tmp.renameTo(file)) {
            tmp.delete()
            throw RemoteIOException("Enregistrement impossible")
        }
    }
}
