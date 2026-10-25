package com.mawena.fluluks.ai

import android.content.Context
import androidx.annotation.VisibleForTesting
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.files.FilesException
import com.mawena.fluluks.remote.KeystoreSecretBox
import com.mawena.fluluks.remote.SecretBox
import java.io.File
import java.io.IOException
import java.net.URI
import java.net.URISyntaxException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/**
 * Serveur IA enregistré (« fournisseur », phase 15) : [baseUrl] normalisée (sans `/` final ni `/v1`) ; [hasKey] : une
 * clé API est enregistrée (lu sans rien déchiffrer) ; [isDefault] : serveur des nouvelles conversations ;
 * [defaultModel] : modèle choisi par défaut sur ce serveur.
 */
data class AiServerConfig(
    val id: String,
    val name: String,
    val baseUrl: String,
    val hasKey: Boolean = false,
    val isDefault: Boolean = false,
    val defaultModel: String? = null,
)

/** Résultat de « Tester la connexion » : [error] traduit et [detail] (message du serveur) en cas d'échec. */
data class AiTestResult(
    val ok: Boolean,
    val version: String?,
    val models: List<String>,
    val log: List<String>,
    val error: String? = null,
    val detail: String? = null,
)

/**
 * Serveurs IA enregistrés (`ai-servers.json` sous [dir]) et leurs clés API, une par fichier scellé par [box]
 * (`ai-keys/<id>`, la même boîte du Keystore que les mots de passe des serveurs distants). Une clé n'est jamais rendue
 * à l'interface : [openKey] sert aux appels, et l'appelant la remet à zéro. Écritures par fichier temporaire puis
 * renommage ; un fichier abîmé donne une liste vide.
 */
class AiServers(private val dir: File, private val box: SecretBox) {
    private val file = File(dir, "ai-servers.json")
    private val keysDir = File(dir, "ai-keys")
    private val lastLogs = ConcurrentHashMap<String, List<String>>()

    /** Appelés après la suppression d'un serveur (conversations marquées, automatisations annulées). */
    val onDeleted: MutableList<(String) -> Unit> = CopyOnWriteArrayList()

    @Synchronized
    fun list(): List<AiServerConfig> {
        if (!file.isFile) return emptyList()
        return try {
            val a = JSONArray(file.readText())
            (0 until a.length()).mapNotNull { a.optJSONObject(it)?.let(::fromJson) }
        } catch (e: JSONException) {
            emptyList()
        }
    }

    fun get(id: String): AiServerConfig? = list().firstOrNull { it.id == id }

    fun defaultServer(): AiServerConfig? = list().let { l -> l.firstOrNull { it.isDefault } ?: l.firstOrNull() }

    /**
     * Enregistre [c] (nouvel identifiant s'il est vide) et rend la fiche enregistrée. [key] vide ou null : la clé
     * enregistrée est gardée ([removeKey] la retire). [FilesException] FL_EINVAL : adresse invalide ou nom déjà pris.
     * Le premier serveur devient le serveur par défaut ; [AiServerConfig.isDefault] et [AiServerConfig.defaultModel]
     * ne changent que par [setDefault] et [setDefaultModel].
     */
    @Synchronized
    fun save(c: AiServerConfig, key: ByteArray?): AiServerConfig {
        val url = try {
            normalizeUrl(c.baseUrl)
        } catch (e: IllegalArgumentException) {
            throw FilesException(EngineError.FL_EINVAL, e.message ?: "Adresse invalide")
        }
        val all = list().toMutableList()
        val old = all.firstOrNull { it.id == c.id && c.id.isNotEmpty() }
        val name = c.name.trim().ifEmpty { URI(url).host }
        if (all.any { it.id != c.id && it.name.equals(name, ignoreCase = true) }) {
            throw FilesException(EngineError.FL_EINVAL, "Un serveur IA porte déjà ce nom")
        }
        val id = old?.id ?: UUID.randomUUID().toString()
        if (key != null && key.isNotEmpty()) writeKey(id, key)
        val saved = AiServerConfig(
            id = id, name = name, baseUrl = url, hasKey = File(keysDir, id).isFile,
            isDefault = old?.isDefault ?: all.none { it.isDefault },
            defaultModel = old?.defaultModel,
        )
        val i = all.indexOfFirst { it.id == id }
        if (i >= 0) all[i] = saved else all += saved
        write(all)
        return saved
    }

    @Synchronized
    fun removeKey(id: String) {
        File(keysDir, id).delete()
        write(list().map { if (it.id == id) it.copy(hasKey = false) else it })
    }

    /** Supprime le serveur et sa clé ; le défaut passe au premier restant. Ses conversations restent. */
    fun delete(id: String) {
        synchronized(this) {
            val rest = list().filter { it.id != id }
            val fixed = if (rest.isNotEmpty() && rest.none { it.isDefault }) {
                listOf(rest[0].copy(isDefault = true)) + rest.drop(1)
            } else {
                rest
            }
            write(fixed)
            File(keysDir, id).delete()
            lastLogs.remove(id)
        }
        for (l in onDeleted) runCatching { l(id) }
    }

    @Synchronized
    fun setDefault(id: String) {
        val all = list()
        if (all.none { it.id == id }) throw FilesException(EngineError.FL_ENOENT, MSG_GONE)
        write(all.map { it.copy(isDefault = it.id == id) })
    }

    @Synchronized
    fun setDefaultModel(id: String, model: String?) {
        write(list().map { if (it.id == id) it.copy(defaultModel = model?.trim()?.ifEmpty { null }) else it })
    }

    /** Clé API en clair, à remettre à zéro par l'appelant ; null sans clé (ou si elle ne s'ouvre plus). */
    @Synchronized
    fun openKey(id: String): ByteArray? {
        val f = File(keysDir, id)
        if (!f.isFile) return null
        return try {
            box.open(f.readBytes())
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Fournisseur de [id], clé ouverte puis remise à zéro (le fournisseur en garde une copie jusqu'à son `close`).
     * [FilesException] FL_ENOENT si le serveur a été supprimé ; FL_EIO si sa clé ne s'ouvre plus.
     */
    fun provider(id: String, log: AiAttemptLog = AiAttemptLog(), timeouts: AiTimeouts = AiTimeouts()): OpenAiCompatibleProvider {
        val c = get(id) ?: throw FilesException(EngineError.FL_ENOENT, MSG_GONE)
        val key = openKey(id)
        if (c.hasKey && key == null) throw FilesException(EngineError.FL_EIO, "Clé API illisible : enregistrez-la de nouveau")
        try {
            return OpenAiCompatibleProvider(c.baseUrl, key, timeouts, log, AiHttp.client)
        } finally {
            key?.fill(0)
        }
    }

    suspend fun health(id: String): AiHealth = provider(id).use { it.health() }

    suspend fun models(id: String): List<String> = provider(id).use { p -> p.models().map { it.id } }

    /** « Tester la connexion » : santé, puis liste des modèles ; le journal reste pour « Détails » ([lastLog]). */
    suspend fun test(id: String): AiTestResult {
        val log = AiAttemptLog()
        val result = provider(id, log).use { p ->
            val h = p.health()
            if (h.state != AiHealth.State.ONLINE) {
                AiTestResult(false, h.version, emptyList(), emptyList(), h.error?.message, h.error?.serverMessage)
            } else {
                try {
                    AiTestResult(true, h.version, p.models().map { it.id }, emptyList())
                } catch (e: AiException) {
                    AiTestResult(false, h.version, emptyList(), emptyList(), e.message, e.serverMessage)
                }
            }
        }
        val lines = log.lines()
        lastLogs[id] = lines
        return result.copy(log = lines)
    }

    fun lastLog(id: String): List<String> = lastLogs[id].orEmpty()

    private fun writeKey(id: String, key: ByteArray) {
        keysDir.mkdirs()
        atomic(File(keysDir, id), box.seal(key))
    }

    private fun write(all: List<AiServerConfig>) {
        dir.mkdirs()
        atomic(file, JSONArray().apply { all.forEach { put(toJson(it)) } }.toString().toByteArray(Charsets.UTF_8))
    }

    private fun atomic(f: File, bytes: ByteArray) {
        val tmp = File(f.parentFile, ".${f.name}.tmp")
        tmp.writeBytes(bytes)
        if (!tmp.renameTo(f)) {
            tmp.delete()
            throw IOException("Enregistrement impossible")
        }
    }

    private fun toJson(c: AiServerConfig) = JSONObject()
        .put("id", c.id).put("name", c.name).put("baseUrl", c.baseUrl).put("isDefault", c.isDefault)
        .put("defaultModel", c.defaultModel ?: JSONObject.NULL)

    private fun fromJson(o: JSONObject): AiServerConfig? {
        val id = o.optString("id").ifEmpty { return null }
        return AiServerConfig(
            id = id, name = o.optString("name"), baseUrl = o.optString("baseUrl"),
            hasKey = File(keysDir, id).isFile, isDefault = o.optBoolean("isDefault"),
            defaultModel = o.optString("defaultModel").takeIf { !o.isNull("defaultModel") && it.isNotEmpty() },
        )
    }

    companion object {
        const val MSG_GONE = "Ce serveur IA a été supprimé"

        /**
         * URL de base : `http` ou `https`, un nom d'hôte, port 1 à 65535, ni identifiants, ni `?`, ni `#` ; `/` final
         * et `/v1` final retirés (Portail ajoute `/v1/…`). [IllegalArgumentException] au message français sinon.
         */
        fun normalizeUrl(raw: String): String {
            val s = raw.trim()
            if (s.isEmpty()) throw IllegalArgumentException("Adresse du serveur manquante")
            val u = try {
                URI(s)
            } catch (e: URISyntaxException) {
                throw IllegalArgumentException("Adresse invalide")
            }
            val scheme = u.scheme?.lowercase()
            if (scheme != "http" && scheme != "https") {
                throw IllegalArgumentException("L'adresse doit commencer par http:// ou https://")
            }
            if (u.rawUserInfo != null) throw IllegalArgumentException("L'adresse ne doit pas contenir d'identifiants")
            if (u.rawQuery != null || u.rawFragment != null || s.contains('?') || s.contains('#')) {
                throw IllegalArgumentException("L'adresse ne doit contenir ni « ? » ni « # »")
            }
            val host = u.host
            if (host.isNullOrEmpty()) {
                // « http://h:abc » : port illisible, l'hôte n'est pas reconnu
                if (u.rawAuthority?.contains(':') == true) throw IllegalArgumentException("Port invalide")
                throw IllegalArgumentException("Adresse sans nom de serveur")
            }
            if (u.port != -1 && u.port !in 1..65535) throw IllegalArgumentException("Port invalide")
            if (u.port == -1 && u.rawAuthority?.substringAfterLast(']')?.contains(':') == true) {
                throw IllegalArgumentException("Port invalide")
            }
            var path = (u.rawPath ?: "").trimEnd('/')
            if (path.endsWith("/v1")) path = path.removeSuffix("/v1").trimEnd('/')
            val port = if (u.port == -1) "" else ":${u.port}"
            return "$scheme://${host.lowercase()}$port$path"
        }
    }
}

/** Accès aux serveurs IA de l'application (comme `Remotes` pour les serveurs distants). */
object Ai {
    @Volatile private var store: AiServers? = null

    fun init(context: Context) {
        if (store == null) store = AiServers(context.applicationContext.filesDir, KeystoreSecretBox())
    }

    fun servers(): AiServers = store ?: throw FilesException(EngineError.FL_ENODEV, "Serveurs IA indisponibles")

    @VisibleForTesting
    fun resetForTests(s: AiServers?) {
        store = s
    }
}
