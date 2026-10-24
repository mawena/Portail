package com.mawena.fluluks.remote.ssh

import com.jcraft.jsch.KeyPair
import com.mawena.fluluks.remote.PrivateKeys
import com.mawena.fluluks.remote.RemoteIOException
import com.mawena.fluluks.remote.SecretBox
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.util.Base64
import java.util.UUID
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/** Une clé du trousseau : [type] « ssh-ed25519 »… ; [fingerprint] « SHA256:… » ; [usedBy] : noms des serveurs qui l'utilisent. */
data class SshKeyInfo(
    val id: String,
    val name: String,
    val type: String,
    val fingerprint: String,
    val encrypted: Boolean,
    val usedBy: List<String> = emptyList(),
)

/**
 * Trousseau de clés SSH (phase 13, T7) sous [dir] : `ssh-keys.json` (nom, type, empreinte, clé publique : rien de
 * secret) et une clé privée scellée par [box] par fichier sous `ssh-keys/`. Jamais de clé privée en clair sur le
 * disque ; celles rendues par [privateKey] sont des copies à remettre à zéro. [usage] : serveurs qui utilisent une clé.
 */
class SshKeys(private val dir: File, private val box: SecretBox, private val usage: (String) -> List<String> = { emptyList() }) {
    private val index = File(dir, "ssh-keys.json")
    private val keysDir = File(dir, "ssh-keys")

    private data class Entry(
        val id: String, val name: String, val type: String, val fingerprint: String, val encrypted: Boolean,
        val publicKey: String,
    )

    @Synchronized
    fun list(): List<SshKeyInfo> = entries().map { SshKeyInfo(it.id, it.name, it.type, it.fingerprint, it.encrypted, usage(it.id)) }

    /**
     * Génère une clé [type] `ed25519` ou `rsa` (4096 bits), protégée par [passphrase] si elle est donnée (remise à
     * zéro), commentée [defaultComment].
     */
    @Synchronized
    fun generate(name: String, type: String, passphrase: ByteArray?): SshKeyInfo {
        try {
            val (jt, bits) = when (type) {
                "ed25519" -> KeyPair.ED25519 to 256
                "rsa" -> KeyPair.RSA to RSA_BITS
                else -> throw IllegalArgumentException("Type de clé inconnu")
            }
            val kp = KeyPair.genKeyPair(PrivateKeys.jsch(), jt, bits)
            val out = WipeableBytes()
            try {
                kp.setPublicKeyComment(defaultComment)
                kp.writeOpenSSHv1PrivateKey(out, passphrase)
                val line = publicLine(kp) ?: throw RemoteIOException("Clé publique introuvable")
                val priv = out.toByteArray()
                return add(name, kp.keyTypeString, PrivateKeys.fingerprint(kp.publicKeyBlob), passphrase != null, line, priv)
            } finally {
                out.wipe()
                kp.dispose()
            }
        } finally {
            passphrase?.fill(0)
        }
    }

    /** Importe la clé privée OpenSSH [key] (remise à zéro dans tous les cas) ; « Clé privée illisible » sinon. */
    @Synchronized
    fun import(name: String, key: ByteArray): SshKeyInfo {
        try {
            val info = try {
                PrivateKeys.inspect(key)
            } catch (e: IOException) {
                throw RemoteIOException(PrivateKeys.MSG_UNREADABLE)
            }
            val copy = key.copyOf()
            val line = try {
                val kp = KeyPair.load(PrivateKeys.jsch(), copy, null)
                try {
                    publicLine(kp).orEmpty()
                } finally {
                    kp.dispose()
                }
            } finally {
                copy.fill(0)
            }
            return add(name, info.type, info.fingerprint, info.encrypted, line, key.copyOf())
        } finally {
            key.fill(0)
        }
    }

    @Synchronized
    fun rename(id: String, name: String) {
        val all = entries()
        if (all.none { it.id == id }) throw FileNotFoundException(NOT_FOUND)
        write(all.map { if (it.id == id) it.copy(name = clean(name)) else it })
    }

    /** Supprime [id] ; refusé tant qu'un serveur l'utilise (« Clé utilisée par : … »). */
    @Synchronized
    fun delete(id: String) {
        val users = usage(id)
        if (users.isNotEmpty()) throw RemoteIOException("Clé utilisée par : ${users.joinToString(", ")}")
        File(keysDir, id).delete()
        write(entries().filter { it.id != id })
    }

    /** Ligne OpenSSH de la clé publique (« ssh-ed25519 AAAA… commentaire »), pour `authorized_keys`. */
    @Synchronized
    fun publicKey(id: String): String {
        val e = entries().firstOrNull { it.id == id } ?: throw FileNotFoundException(NOT_FOUND)
        return e.publicKey.ifEmpty { throw RemoteIOException("Clé publique inconnue : clé chiffrée à l'ancien format") }
    }

    /** Copie de la clé privée (encore chiffrée si elle a une phrase), à remettre à zéro après usage. */
    @Synchronized
    fun privateKey(id: String): ByteArray {
        val f = File(keysDir, id)
        if (!f.isFile) throw FileNotFoundException(NOT_FOUND)
        return box.open(f.readBytes())
    }

    private fun add(name: String, type: String, fp: String, encrypted: Boolean, line: String, priv: ByteArray): SshKeyInfo {
        val e = Entry(UUID.randomUUID().toString(), clean(name), type, fp, encrypted, line)
        try {
            keysDir.mkdirs()
            atomic(File(keysDir, e.id), box.seal(priv))
        } finally {
            priv.fill(0)
        }
        write(entries() + e)
        return SshKeyInfo(e.id, e.name, e.type, e.fingerprint, e.encrypted, usage(e.id))
    }

    private fun clean(name: String) = name.trim().ifEmpty { "Clé" }

    private fun publicLine(kp: KeyPair): String? {
        val blob = kp.publicKeyBlob ?: return null
        val comment = kp.publicKeyComment.orEmpty().trim()
        return "${kp.keyTypeString} ${Base64.getEncoder().encodeToString(blob)}${if (comment.isEmpty()) "" else " $comment"}"
    }

    private fun entries(): List<Entry> {
        if (!index.isFile) return emptyList()
        return try {
            val a = JSONArray(index.readText())
            (0 until a.length()).mapNotNull { i ->
                val o = a.optJSONObject(i) ?: return@mapNotNull null
                val id = o.optString("id").ifEmpty { return@mapNotNull null }
                Entry(id, o.optString("name"), o.optString("type"), o.optString("fingerprint"), o.optBoolean("encrypted"),
                    o.optString("publicKey"))
            }
        } catch (e: JSONException) {
            emptyList()
        }
    }

    private fun write(all: List<Entry>) {
        dir.mkdirs()
        val a = JSONArray()
        for (e in all) {
            a.put(JSONObject().put("id", e.id).put("name", e.name).put("type", e.type).put("fingerprint", e.fingerprint)
                .put("encrypted", e.encrypted).put("publicKey", e.publicKey))
        }
        atomic(index, a.toString().toByteArray(Charsets.UTF_8))
    }

    private fun atomic(f: File, bytes: ByteArray) {
        val tmp = File(f.parentFile, ".${f.name}.tmp")
        tmp.writeBytes(bytes)
        if (!tmp.renameTo(f)) {
            tmp.delete()
            throw RemoteIOException("Enregistrement impossible")
        }
    }

    /** Tampon dont la mémoire interne peut être remise à zéro. */
    private class WipeableBytes : ByteArrayOutputStream() {
        fun wipe() = buf.fill(0)
    }

    companion object {
        const val RSA_BITS = 4096
        const val NOT_FOUND = "Clé introuvable"

        /** Commentaire des clés générées : `portail@<modèle du téléphone>`, posé au démarrage. */
        @Volatile var defaultComment = "portail@Android"
    }
}
