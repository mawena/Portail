package com.mawena.fluluks.vaults

import java.io.File
import org.json.JSONArray
import org.json.JSONObject

/**
 * Coffre connu (phase 14) : où est son fichier (clé stable de la source, chemin), sa taille et son système de
 * fichiers ; [slots] : rôle de chaque emplacement de clé LUKS2 posé par Portail (`password`, `recovery`,
 * `biometric`), les autres emplacements ne sont jamais touchés ; [biometric] : déverrouillage biométrique activé ;
 * [luksVersion] : 1 pour un conteneur LUKS1 créé ailleurs (rien n'y est réécrit). Aucun secret.
 */
data class VaultRecord(
    val id: String,
    val name: String,
    val sourceKey: String,
    val path: String,
    val sizeBytes: Long,
    val fs: String,
    val slots: Map<Int, String> = mapOf(0 to "password"),
    val biometric: Boolean = false,
    val luksVersion: Int = 2,
)

/**
 * Liste des coffres connus, dans `vaults.json` de [dir] : écrite dans un fichier temporaire puis renommée (jamais à
 * moitié). Un fichier abîmé donne une liste vide et est gardé à part (`vaults.json.abime`) ; les coffres eux-mêmes
 * ne sont jamais touchés : on les retrouve en les rouvrant depuis leur dossier.
 */
class VaultStore(private val dir: File) {
    private val file get() = File(dir, NAME)

    @Synchronized
    fun list(): List<VaultRecord> {
        val f = file
        if (!f.exists()) return emptyList()
        return try {
            val a = JSONObject(f.readText()).getJSONArray("vaults")
            (0 until a.length()).map { parse(a.getJSONObject(it)) }
        } catch (e: Exception) {
            f.renameTo(File(dir, "$NAME.abime"))
            emptyList()
        }
    }

    @Synchronized
    fun get(id: String): VaultRecord? = list().firstOrNull { it.id == id }

    /** Ajoute [r] en fin de liste, ou remplace sur place le coffre de même identifiant (l'ordre de l'accueil reste). */
    @Synchronized
    fun put(r: VaultRecord) {
        val all = list()
        write(if (all.any { it.id == r.id }) all.map { if (it.id == r.id) r else it } else all + r)
    }

    @Synchronized
    fun remove(id: String) = write(list().filter { it.id != id })

    private fun write(all: List<VaultRecord>) {
        dir.mkdirs()
        val o = JSONObject().put("version", 1).put("vaults", JSONArray(all.map(::json)))
        val tmp = File(dir, "$NAME.tmp")
        tmp.writeText(o.toString())
        if (!tmp.renameTo(file)) {
            tmp.delete()
            throw java.io.IOException("Liste des coffres non enregistrée")
        }
    }

    private fun json(r: VaultRecord) = JSONObject()
        .put("id", r.id).put("name", r.name).put("source", r.sourceKey).put("path", r.path)
        .put("size", r.sizeBytes).put("fs", r.fs).put("biometric", r.biometric).put("luks", r.luksVersion)
        .put("slots", JSONObject().apply { r.slots.forEach { (k, v) -> put(k.toString(), v) } })

    private fun parse(o: JSONObject): VaultRecord {
        val s = o.optJSONObject("slots")
        val slots = s?.keys()?.asSequence()?.associate { it.toInt() to s.getString(it) } ?: mapOf(0 to "password")
        return VaultRecord(
            id = o.getString("id"), name = o.getString("name"), sourceKey = o.getString("source"),
            path = o.getString("path"), sizeBytes = o.getLong("size"), fs = o.optString("fs"), slots = slots,
            biometric = o.optBoolean("biometric"), luksVersion = o.optInt("luks", 2),
        )
    }

    companion object {
        const val NAME = "vaults.json"
    }
}
