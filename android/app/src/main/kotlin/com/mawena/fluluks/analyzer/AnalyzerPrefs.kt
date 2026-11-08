package com.mawena.fluluks.analyzer

import java.io.File
import java.io.IOException
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/** Emplacement exclu des analyses : [path] dans le stockage de clé [stableKey] (`phone`, `sd:…`, `disk:…`). */
data class Exclusion(val stableKey: String, val sourceLabel: String, val path: String)

/**
 * Réglages de l'analyseur (phase 16) : les emplacements exclus, dans `analyzer.json` sous [dir], écrit par un fichier
 * temporaire puis renommage. Un fichier abîmé donne une liste vide.
 */
class AnalyzerPrefs(private val dir: File) {
    private val file = File(dir, "analyzer.json")

    @Synchronized
    fun exclusions(): List<Exclusion> {
        if (!file.isFile) return emptyList()
        return try {
            val a = JSONObject(file.readText()).optJSONArray("exclusions") ?: return emptyList()
            (0 until a.length()).mapNotNull { i ->
                val o = a.optJSONObject(i) ?: return@mapNotNull null
                val key = o.optString("key").ifEmpty { return@mapNotNull null }
                val path = o.optString("path").takeIf { it.startsWith("/") } ?: return@mapNotNull null
                Exclusion(key, o.optString("label"), path)
            }
        } catch (e: JSONException) {
            emptyList()
        }
    }

    /** Ajoute [e] (une seule fois par stockage et chemin). */
    @Synchronized
    fun add(e: Exclusion) {
        val all = exclusions()
        if (all.none { it.stableKey == e.stableKey && it.path == e.path }) write(all + e)
    }

    @Synchronized
    fun remove(stableKey: String, path: String) = write(exclusions().filterNot { it.stableKey == stableKey && it.path == path })

    private fun write(all: List<Exclusion>) {
        dir.mkdirs()
        val a = JSONArray()
        for (e in all) a.put(JSONObject().put("key", e.stableKey).put("label", e.sourceLabel).put("path", e.path))
        val tmp = File(dir, ".${file.name}.tmp")
        tmp.writeText(JSONObject().put("exclusions", a).toString())
        if (!tmp.renameTo(file)) {
            tmp.delete()
            throw IOException("Enregistrement impossible")
        }
    }
}
