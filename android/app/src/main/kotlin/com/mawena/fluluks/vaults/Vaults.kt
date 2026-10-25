package com.mawena.fluluks.vaults

import android.content.Context
import android.os.ParcelFileDescriptor
import androidx.annotation.VisibleForTesting
import com.mawena.fluluks.crypt.Crypt
import com.mawena.fluluks.crypt.DecryptedSource
import com.mawena.fluluks.crypt.Passwords
import com.mawena.fluluks.engine.Engine
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.files.Archives
import com.mawena.fluluks.files.DiskSource
import com.mawena.fluluks.files.FileSource
import com.mawena.fluluks.files.Files
import com.mawena.fluluks.files.FilesException
import com.mawena.fluluks.files.LocalSource
import com.mawena.fluluks.files.PathRules
import com.mawena.fluluks.files.Sources
import com.mawena.fluluks.files.Transfers
import com.mawena.fluluks.provider.DocNames
import com.mawena.fluluks.provider.DocumentIds
import com.mawena.fluluks.provider.WriteOps
import com.mawena.fluluks.volumes.VaultHost
import com.mawena.fluluks.volumes.VolumeManager
import com.mawena.fluluks.volumes.VolumeState
import java.io.File
import java.io.FileNotFoundException
import java.security.SecureRandom
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Coffre tel que l'écran le montre ; [state] : `closed`, `open` ou `unavailable` (son stockage n'est pas là). */
data class VaultInfo(
    val id: String,
    val name: String,
    val sourceKey: String,
    val sourceLabel: String,
    val path: String,
    val sizeBytes: Long,
    val fs: String,
    val state: String,
    val volumeId: String?,
    val hasRecovery: Boolean,
    val biometric: Boolean,
    val luksVersion: Int,
)

/**
 * Coffres de fichiers (phase 14) : un fichier conteneur LUKS2 (`nom.luks`) sans table de partitions, qui contient un
 * exFAT ou un ext4, ouvert par le moteur comme un disque ([VolumeManager.openVault]). Le fichier peut être sur le
 * téléphone, une carte SD ou un volume ouvert d'un disque USB ; jamais sur un dossier distant ni dans un autre coffre.
 * Tant qu'un coffre est ouvert, son fichier est protégé ([requireClosed]).
 */
object Vaults {
    const val EXT = ".luks"
    const val MIN_SIZE = 32L shl 20

    /** Plus grand fichier d'un stockage FAT (4 Gio − 1 octet), arrondi au secteur. */
    const val FAT_MAX = (4L shl 30) - 512
    const val MSG_REMOTE = "Un coffre ne se crée ni ne s'ouvre sur un dossier distant"
    const val MSG_IN_VAULT = "Un coffre ne se crée ni ne s'ouvre dans un autre coffre"
    const val MSG_TOO_SMALL = "Un coffre fait au moins 32 Mio"
    const val MSG_TOO_BIG = "Pas assez de place pour un coffre de cette taille"
    const val MSG_FAT_LIMIT = "4 Gio au plus pour un coffre sur un stockage FAT32"
    const val MSG_FS = "Système de fichiers d'un coffre : exFAT ou ext4"
    const val MSG_NAME = "Nom de coffre non valable"
    const val MSG_UNKNOWN = "Coffre inconnu"
    const val MSG_UNAVAILABLE = "Le stockage de ce coffre n'est pas disponible"
    const val MSG_CANCELLED = "Création du coffre annulée"
    const val MSG_OPEN = Crypt.MSG_VAULT_OPEN
    const val MSG_LUKS1 = "Coffre LUKS1\u00A0: changez la phrase sous Linux"
    const val MSG_NO_RECOVERY = "Ce coffre n'a pas de clé de secours"
    const val MSG_BAD_RECOVERY = "Clé de secours non valable\u00A0: 24 caractères, chiffres et lettres"
    const val MSG_FOREIGN_LAYOUT = "Emplacements de clé inconnus\u00A0: changez la phrase de ce coffre sous Linux"
    const val MSG_SLOTS_FULL = "Plus aucun emplacement de clé libre dans ce coffre"
    const val MSG_BUSY = "Une opération est déjà en cours sur ce coffre"

    /** Emplacements LUKS2 d'un coffre de Portail : mot de passe, clé de secours, biométrie. */
    const val SLOT_PASSWORD = 0
    const val SLOT_RECOVERY = 1
    const val SLOT_BIOMETRIC = 2
    private const val KDF_TIME = 4

    /** Alphabet Crockford base32 (ni I, ni L, ni O, ni U). */
    private const val CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    private const val KDF_KIB = 1_048_576
    private const val KDF_LOW_KIB = 262_144
    private const val ROOT_ID = 1000
    private const val CHUNK = 1 shl 20

    @Volatile private var store: VaultStore? = null
    @Volatile private var sources: () -> List<FileSource> = Sources::list
    @Volatile private var openFdForTests: ((File, Boolean) -> Int)? = null
    private val rnd = SecureRandom()

    /** Coffres dont les emplacements de clé sont en cours de réécriture (ni ouverture, ni seconde opération). */
    private val busy = java.util.Collections.synchronizedSet(HashSet<String>())

    private val engine: Engine get() = Archives.engine

    fun init(context: Context) {
        val app = context.applicationContext
        if (store == null) store = VaultStore(app.filesDir)
        if (bio == null) bio = BiometricBox(File(app.filesDir, "vaults"), KeystoreBioKeys(), BiometricUi)
        appContext = app
    }

    @Volatile private var bio: BiometricBox? = null
    @Volatile private var appContext: Context? = null

    @VisibleForTesting
    fun setBiometricForTests(box: BiometricBox?) {
        bio = box
    }

    @VisibleForTesting
    fun resetForTests(store: VaultStore?, sources: (() -> List<FileSource>)?, openFd: ((File, Boolean) -> Int)?) {
        this.store = store
        this.sources = sources ?: Sources::list
        openFdForTests = openFd
    }

    private fun st(): VaultStore = store ?: throw FilesException(EngineError.FL_ENODEV, Files.MSG_GENERIC)

    private fun newId(): String = ByteArray(8).also(rnd::nextBytes).joinToString("") { "%02x".format(it) }

    // --- protection du fichier d'un coffre ouvert ------------------------------------------------------------

    /** Vrai si [path] de [sourceId] est le fichier d'un coffre ouvert, ou un dossier qui en contient un. */
    fun isOpenFile(sourceId: String, path: String): Boolean = VolumeManager.openVaultHosts().any {
        it.sourceId == sourceId && (it.path == path || it.path.startsWith(if (path == "/") "/" else "$path/"))
    }

    /** Refus « Fermez d'abord le coffre » pour le fichier d'un coffre ouvert (supprimer, renommer, copier…). */
    fun requireClosed(sourceId: String, path: String) {
        if (isOpenFile(sourceId, path)) throw FileNotFoundException(MSG_OPEN)
    }

    // --- liste ----------------------------------------------------------------------------------------------

    private fun hostOf(r: VaultRecord): FileSource? = sources().firstOrNull { s ->
        runCatching { s.stableKey == r.sourceKey }.getOrDefault(false)
    }

    private fun info(r: VaultRecord): VaultInfo {
        val vol = VolumeManager.vaultVolume(r.id)
        val host = hostOf(r)
        val state = when {
            vol != null -> "open"
            host == null || runCatching { host.stat(r.path) }.getOrNull() == null -> "unavailable"
            else -> "closed"
        }
        return VaultInfo(
            id = r.id, name = r.name, sourceKey = r.sourceKey, sourceLabel = host?.let { runCatching { it.label }.getOrNull() } ?: "",
            path = r.path, sizeBytes = r.sizeBytes, fs = vol?.fs?.takeIf { it.isNotEmpty() } ?: r.fs, state = state,
            volumeId = vol?.id, hasRecovery = r.slots.containsValue("recovery"), biometric = r.biometric,
            luksVersion = r.luksVersion,
        )
    }

    fun list(): List<VaultInfo> = (store?.list() ?: emptyList()).map(::info)

    fun get(id: String): VaultInfo? = store?.get(id)?.let(::info)

    // --- ouverture ------------------------------------------------------------------------------------------

    private fun checkHost(src: FileSource) {
        when {
            src is DiskSource && VolumeManager.volume(src.id)?.vaultId != null ->
                throw FilesException(EngineError.FL_ENOTSUP, MSG_IN_VAULT)
            src !is LocalSource && src !is DiskSource || src is DecryptedSource ->
                throw FilesException(EngineError.FL_ENOTSUP, MSG_REMOTE)
        }
    }

    /** Descripteur détaché du fichier local [f], en lecture et écriture sans troncature si [writable]. */
    private fun openFd(f: File, writable: Boolean): Int {
        openFdForTests?.let { return it(f, writable) }
        val mode = if (writable) ParcelFileDescriptor.MODE_READ_WRITE else ParcelFileDescriptor.MODE_READ_ONLY
        return ParcelFileDescriptor.open(f, mode).detachFd()
    }

    /** Disque du moteur sur le fichier [path] de [src] ; le fichier appartient ensuite au disque, qui le ferme. */
    private fun openDisk(src: FileSource, path: String, writable: Boolean): Long = when (src) {
        is LocalSource -> engine.openDiskFd(openFd(src.fileOf(path), writable), !writable)
        is DiskSource -> {
            val (f, size) = src.openForVault(path, writable)
            engine.openDiskOnFile(f, size)
        }
        else -> throw FilesException(EngineError.FL_ENOTSUP, MSG_REMOTE)
    }

    /**
     * Ouvre le coffre [vaultId], ou le fichier [path] de [srcId] (enregistré comme coffre connu s'il s'ouvre) avec
     * [password] (mis à zéro tout de suite) ; [slot] : emplacement de clé précis (clé de secours, biométrie).
     */
    suspend fun open(
        vaultId: String?,
        srcId: String?,
        path: String?,
        password: ByteArray,
        writable: Boolean,
        slot: Int = -1,
        recovery: Boolean = false,
    ): VolumeState {
        // clé de secours : tirets, espaces et casse ignorés, forme écrite par Portail rétablie
        val pw = if (recovery) normalizeRecoveryKey(password) else password.copyOf()
        password.fill(0)
        try {
            if (pw == null) throw FilesException(EngineError.FL_EBADPASS, MSG_BAD_RECOVERY)
            val known = vaultId?.let { st().get(it) ?: throw FilesException(EngineError.FL_ENOENT, MSG_UNKNOWN) }
            val src: FileSource
            val rec: VaultRecord
            if (known != null) {
                rec = known
                src = hostOf(known) ?: throw FilesException(EngineError.FL_ENODEV, MSG_UNAVAILABLE)
            } else {
                src = Files.source(srcId ?: throw FilesException(EngineError.FL_EINVAL, MSG_UNKNOWN))
                val p = PathRules.require(path ?: "")
                checkHost(src)
                val key = src.stableKey
                val e = src.stat(p) ?: throw FileNotFoundException("Document introuvable")
                rec = st().list().firstOrNull { it.sourceKey == key && it.path == p }
                    ?: VaultRecord(newId(), WriteOps.nameOf(p).removeSuffix(EXT).ifEmpty { WriteOps.nameOf(p) }, key, p, e.size, "")
            }
            checkHost(src)
            if (rec.id in busy) throw FilesException(EngineError.FL_EBUSY, MSG_BUSY)
            val p = PathRules.require(rec.path)
            src.stat(p) ?: throw FilesException(EngineError.FL_ENOENT, MSG_UNAVAILABLE)
            val rw = writable && src.readOnlyReason == null
            // la clé de secours n'essaie que son emplacement (Argon2 d'un seul emplacement)
            val s = if (recovery) rec.slots.entries.firstOrNull { it.value == "recovery" }?.key ?: -1 else slot
            val vol = VolumeManager.openVault(VaultHost(rec.id, src.id, p), rec.name, pw.copyOf(), rw, s) {
                openDisk(src, p, rw)
            }
            val seen = rec.copy(fs = vol.fs, luksVersion = VolumeManager.vaultLuksVersion(rec.id) ?: rec.luksVersion)
            if (st().get(rec.id) != seen) st().put(seen)
            return vol
        } catch (e: Throwable) {
            throw failure(e, "openDocument")
        } finally {
            pw?.fill(0)
        }
    }

    /** Erreur en français : le message précis du moteur ou de VolumeManager est gardé (« Ce fichier n'est pas un coffre »). */
    private fun failure(e: Throwable, op: String): FilesException = when (e) {
        is FilesException -> e
        is EngineError -> FilesException(e.code, if (e.code == EngineError.FL_EBADPASS) Crypt.MSG_BAD_PASSWORD else e.message ?: Files.MSG_GENERIC)
        else -> Files.toFilesException(e, op)
    }

    /** Ferme le coffre (synchronisé, démonté, clé effacée), comme une éjection. */
    fun close(vaultId: String) = VolumeManager.closeVault(vaultId)

    /** Oublie le coffre (fermé d'abord) : son fichier reste là où il est. */
    fun forget(vaultId: String) {
        close(vaultId)
        bio?.wipe(vaultId)
        st().remove(vaultId)
    }

    /** Ferme les coffres dont le stockage a disparu (carte SD retirée…). */
    fun checkSources() {
        for (h in VolumeManager.openVaultHosts().map { it.sourceId }.distinct()) {
            if (Files.sourceOrNull(h) == null) VolumeManager.closeVaultsOn(h)
        }
    }

    // --- mot de passe et clé de secours ---------------------------------------------------------------------

    /** Mémoire d'Argon2 des emplacements : 1 Gio, ou 256 Mio si la mémoire manque (comme à la création). */
    private fun kdfKib(): Int {
        val avail = VolumeManager.availableMemory()
        return when {
            KDF_KIB * 1024L <= 0.8 * avail -> KDF_KIB
            KDF_LOW_KIB * 1024L <= 0.8 * avail -> KDF_LOW_KIB
            else -> throw FilesException(EngineError.FL_ENOMEM, VolumeManager.MSG_LOW_MEMORY)
        }
    }

    /** Nouvelle clé de secours : 24 caractères Crockford base32 (120 bits aléatoires) en 6 groupes de 4. */
    fun newRecoveryKey(): ByteArray {
        val r = ByteArray(15).also(rnd::nextBytes)
        val sym = ByteArray(24)
        try {
            var bit = 0
            for (i in sym.indices) {
                var v = 0
                repeat(5) {
                    v = (v shl 1) or ((r[bit / 8].toInt() shr (7 - bit % 8)) and 1)
                    bit++
                }
                sym[i] = CROCKFORD[v].code.toByte()
            }
            return grouped(sym)
        } finally {
            r.fill(0)
            sym.fill(0)
        }
    }

    /** « ABCD-EFGH-… » depuis 24 symboles. */
    private fun grouped(sym: ByteArray): ByteArray {
        val out = ByteArray(29)
        var o = 0
        for (i in sym.indices) {
            if (i > 0 && i % 4 == 0) out[o++] = '-'.code.toByte()
            out[o++] = sym[i]
        }
        return out
    }

    /**
     * Clé de secours saisie, remise sous la forme écrite par Portail : tirets et blancs ignorés, minuscules
     * acceptées, O lu 0, I et L lus 1 ; null si ce ne sont pas 24 caractères de l'alphabet. Ne modifie pas [input].
     */
    fun normalizeRecoveryKey(input: ByteArray): ByteArray? {
        val sym = ByteArray(24)
        try {
            var n = 0
            for (b in input) {
                var c = (b.toInt() and 0xFF).toChar()
                if (c == '-' || c == ' ' || c == '\t' || c == '\n' || c == '\r') continue
                c = c.uppercaseChar()
                c = when (c) {
                    'O' -> '0'
                    'I', 'L' -> '1'
                    else -> c
                }
                if (c !in CROCKFORD || n == sym.size) return null
                sym[n++] = c.code.toByte()
            }
            return if (n == sym.size) grouped(sym) else null
        } finally {
            sym.fill(0)
        }
    }

    /**
     * Ouvre le disque du coffre fermé [vaultId] (fichier en écriture, aucune autre opération ni ouverture pendant
     * ce temps) et lit ses emplacements ; [block] reçoit le coffre, la poignée et les emplacements présents.
     * LUKS1 : [MSG_LUKS1], rien n'est écrit.
     */
    private fun <T> withClosedDisk(vaultId: String, block: (VaultRecord, Long, Set<Int>) -> T): T {
        val rec = st().get(vaultId) ?: throw FilesException(EngineError.FL_ENOENT, MSG_UNKNOWN)
        if (VolumeManager.vaultVolume(vaultId) != null) throw FilesException(EngineError.FL_EBUSY, MSG_OPEN)
        if (rec.luksVersion == 1) throw FilesException(EngineError.FL_ENOTSUP, MSG_LUKS1)
        val src = hostOf(rec) ?: throw FilesException(EngineError.FL_ENODEV, MSG_UNAVAILABLE)
        checkHost(src)
        src.readOnlyReason?.let { throw FileNotFoundException(Files.readOnlyMessage(src, it)) }
        val p = PathRules.require(rec.path)
        src.stat(p) ?: throw FilesException(EngineError.FL_ENOENT, MSG_UNAVAILABLE)
        if (!busy.add(vaultId)) throw FilesException(EngineError.FL_EBUSY, MSG_BUSY)
        try {
            if (VolumeManager.vaultVolume(vaultId) != null) throw FilesException(EngineError.FL_EBUSY, MSG_OPEN)
            val h = EngineError.check(openDisk(src, p, true))
            try {
                val j = org.json.JSONObject(String(engine.luksSlots(h), Charsets.UTF_8))
                if (j.has("err")) throw EngineError(j.getInt("err"))
                val version = j.getInt("version")
                val r = if (version != rec.luksVersion) rec.copy(luksVersion = version).also { st().put(it) } else rec
                if (version != 2) throw FilesException(EngineError.FL_ENOTSUP, MSG_LUKS1)
                val a = j.getJSONArray("slots")
                return block(r, h, (0 until a.length()).map { a.getInt(it) }.toSet())
            } finally {
                engine.closeDisk(h)
            }
        } finally {
            busy.remove(vaultId)
        }
    }

    private fun slotOf(r: VaultRecord, role: String): Int? = r.slots.entries.firstOrNull { it.value == role }?.key

    /**
     * Change le mot de passe du coffre fermé [vaultId] sans réécrire son contenu : son emplacement est remplacé
     * (sûr même interrompu). [old] peut aussi être la clé de secours. Les deux tableaux sont mis à zéro.
     */
    suspend fun changePassword(vaultId: String, old: ByteArray, new: ByteArray) {
        val o = old.copyOf()
        val n = new.copyOf()
        old.fill(0)
        new.fill(0)
        try {
            Passwords.check(n)?.let { throw FilesException(EngineError.FL_EINVAL, it) }
            withContext(Dispatchers.IO) {
                withClosedDisk(vaultId) { r, h, slots ->
                    val slot = slotOf(r, "password") ?: SLOT_PASSWORD
                    if (slot !in slots) throw FilesException(EngineError.FL_ENOTSUP, MSG_FOREIGN_LAYOUT)
                    EngineError.check(engine.luksSlotSet(h, slot, o, n, kdfKib(), KDF_TIME))
                }
            }
        } catch (e: Throwable) {
            throw failure(e, "changePassword")
        } finally {
            o.fill(0)
            n.fill(0)
        }
    }

    /**
     * Crée (ou remplace) la clé de secours du coffre fermé [vaultId] et la rend, une seule fois : elle n'est
     * gardée nulle part. Emplacement 1, ou le premier libre à partir de 3 si un autre l'occupe (coffre créé sous
     * Linux). [password] est mis à zéro.
     */
    suspend fun addRecoveryKey(vaultId: String, password: ByteArray): ByteArray {
        val pw = password.copyOf()
        password.fill(0)
        val key = newRecoveryKey()
        try {
            withContext(Dispatchers.IO) {
                withClosedDisk(vaultId) { r, h, slots ->
                    val slot = slotOf(r, "recovery")
                        ?: if (SLOT_RECOVERY !in slots) SLOT_RECOVERY
                        else (SLOT_BIOMETRIC + 1 until 32).firstOrNull { it !in slots && it !in r.slots }
                            ?: throw FilesException(EngineError.FL_ENOSPC, MSG_SLOTS_FULL)
                    // copie : le moteur met à zéro les phrases reçues, et la clé doit encore être rendue
                    EngineError.check(engine.luksSlotSet(h, slot, pw, key.copyOf(), kdfKib(), KDF_TIME))
                    st().put(r.copy(slots = r.slots + (slot to "recovery")))
                }
            }
            return key
        } catch (e: Throwable) {
            key.fill(0)
            throw failure(e, "addRecoveryKey")
        } finally {
            pw.fill(0)
        }
    }

    /** Retire la clé de secours du coffre fermé [vaultId] ; le mot de passe l'ouvre toujours. */
    suspend fun removeRecoveryKey(vaultId: String, password: ByteArray) {
        val pw = password.copyOf()
        password.fill(0)
        try {
            withContext(Dispatchers.IO) {
                withClosedDisk(vaultId) { r, h, slots ->
                    val slot = slotOf(r, "recovery") ?: throw FilesException(EngineError.FL_ENOENT, MSG_NO_RECOVERY)
                    if (slot in slots) EngineError.check(engine.luksSlotRemove(h, slot, pw))
                    st().put(r.copy(slots = r.slots - slot))
                }
            }
        } catch (e: Throwable) {
            throw failure(e, "removeRecoveryKey")
        } finally {
            pw.fill(0)
        }
    }

    // --- déverrouillage biométrique ---------------------------------------------------------------------------

    private const val BIO_KDF_KIB = 64 * 1024
    private const val BIO_KDF_TIME = 1
    private const val BIO_SECRET = 32

    /** Raison pour laquelle la biométrie forte n'est pas utilisable sur ce téléphone, ou null. */
    fun biometricUnavailable(): String? {
        if (bio == null) return BiometricBox.MSG_NO_STRONG
        val c = appContext ?: return null // tests : boîte fournie, biométrie supposée là
        return BiometricBox.unavailableReason(c)
    }

    private fun box(): BiometricBox {
        biometricUnavailable()?.let { throw BiometricUnavailable(it) }
        return bio!!
    }

    /**
     * Active le déverrouillage biométrique du coffre fermé [vaultId] : un secret aléatoire de 32 octets, scellé par
     * une clé du Keystore (invite biométrique), ouvre l'emplacement 2 (Argon2 de 64 Mio, une passe). [password] est mis
     * à zéro. Annulé ou refusé : rien n'est gardé.
     */
    suspend fun enableBiometric(vaultId: String, password: ByteArray) {
        val pw = password.copyOf()
        password.fill(0)
        val secret = ByteArray(BIO_SECRET).also(rnd::nextBytes)
        try {
            val rec = st().get(vaultId) ?: throw FilesException(EngineError.FL_ENOENT, MSG_UNKNOWN)
            if (VolumeManager.vaultVolume(vaultId) != null) throw FilesException(EngineError.FL_EBUSY, MSG_OPEN)
            if (rec.luksVersion == 1) throw FilesException(EngineError.FL_ENOTSUP, MSG_LUKS1)
            val b = box()
            b.seal(vaultId, BiometricBox.enableTitle(rec.name), secret.copyOf())
            try {
                withContext(Dispatchers.IO) {
                    withClosedDisk(vaultId) { r, h, slots ->
                        val slot = slotOf(r, "biometric")
                            ?: if (SLOT_BIOMETRIC !in slots) SLOT_BIOMETRIC
                            else (SLOT_BIOMETRIC + 1 until 32).firstOrNull { it !in slots && it !in r.slots }
                                ?: throw FilesException(EngineError.FL_ENOSPC, MSG_SLOTS_FULL)
                        EngineError.check(engine.luksSlotSet(h, slot, pw, secret, BIO_KDF_KIB, BIO_KDF_TIME))
                        st().put(r.copy(slots = r.slots + (slot to "biometric"), biometric = true))
                    }
                }
            } catch (e: Throwable) {
                b.wipe(vaultId)
                throw e
            }
        } catch (e: BiometricCancelled) {
            throw e
        } catch (e: BiometricUnavailable) {
            throw e
        } catch (e: BiometricInvalidated) {
            throw e
        } catch (e: Throwable) {
            throw failure(e, "enableBiometric")
        } finally {
            pw.fill(0)
            secret.fill(0)
        }
    }

    /**
     * Ouvre le coffre [vaultId] par la biométrie (invite « Ouvrir le coffre <nom> »), par son seul emplacement.
     * [BiometricCancelled] : l'écran propose le mot de passe ; [BiometricInvalidated] : biométrie désactivée.
     */
    suspend fun openBiometric(vaultId: String, writable: Boolean): VolumeState {
        val rec = st().get(vaultId) ?: throw FilesException(EngineError.FL_ENOENT, MSG_UNKNOWN)
        if (!rec.biometric) throw FilesException(EngineError.FL_ENOENT, BiometricBox.MSG_OFF)
        VolumeManager.vaultVolume(vaultId)?.let { return it }
        val secret = try {
            box().unseal(vaultId, BiometricBox.openTitle(rec.name))
        } catch (e: BiometricInvalidated) {
            st().get(vaultId)?.let { st().put(it.copy(biometric = false)) }
            throw e
        }
        return open(vaultId, null, null, secret, writable, slot = slotOf(rec, "biometric") ?: SLOT_BIOMETRIC)
    }

    /**
     * Désactive le déverrouillage biométrique : clé et secret scellé effacés ; avec [password] et le coffre fermé,
     * son emplacement est aussi retiré (sinon il reste, inutilisable sans le secret, et resservira).
     */
    suspend fun disableBiometric(vaultId: String, password: ByteArray?) {
        val pw = password?.copyOf()
        password?.fill(0)
        try {
            val rec = st().get(vaultId) ?: throw FilesException(EngineError.FL_ENOENT, MSG_UNKNOWN)
            bio?.wipe(vaultId)
            st().put(rec.copy(biometric = false))
            if (pw != null && VolumeManager.vaultVolume(vaultId) == null && rec.luksVersion != 1) {
                withContext(Dispatchers.IO) {
                    withClosedDisk(vaultId) { r, h, slots ->
                        val slot = slotOf(r, "biometric") ?: return@withClosedDisk
                        if (slot in slots) EngineError.check(engine.luksSlotRemove(h, slot, pw))
                        st().put(r.copy(slots = r.slots - slot, biometric = false))
                    }
                }
            }
        } catch (e: Throwable) {
            throw failure(e, "disableBiometric")
        } finally {
            pw?.fill(0)
        }
    }

    // --- création -------------------------------------------------------------------------------------------

    /**
     * Crée le coffre [name] (fichier `name.luks`, nom unique) sous [dir] de [srcId], de [sizeBytes] octets, en [fs]
     * (`exfat` ou `ext4`), dans le créneau des opérations (type `vault`, annulable) : la place est écrite (zéros, 0 à
     * 80 %), puis le conteneur LUKS2 et le système de fichiers (80 à 100 %), dans un fichier partiel renommé à la fin
     * seulement. [password] est mis à zéro tout de suite.
     */
    suspend fun create(srcId: String, dir: String, name: String, sizeBytes: Long, fs: String, password: ByteArray): VaultInfo {
        val pw = password.copyOf()
        password.fill(0)
        try {
            val src = Files.source(srcId)
            checkHost(src)
            val d = PathRules.require(dir)
            val base = name.trim().removeSuffix(EXT)
            if (base.isEmpty() || base.contains('/') || base.contains('\u0000') || base.startsWith(".")) {
                throw FilesException(EngineError.FL_EINVAL, MSG_NAME)
            }
            if (fs != "exfat" && fs != "ext4") throw FilesException(EngineError.FL_EINVAL, MSG_FS)
            src.readOnlyReason?.let { throw FileNotFoundException(Files.readOnlyMessage(src, it)) }
            if (sizeBytes < MIN_SIZE) throw FilesException(EngineError.FL_EINVAL, MSG_TOO_SMALL)
            val size = sizeBytes / 512 * 512
            val hostFs = (src as? DiskSource)?.let { VolumeManager.volume(it.id)?.fs } ?: ""
            if (hostFs.startsWith("FAT", ignoreCase = true) && size > FAT_MAX) {
                throw FilesException(EngineError.FL_EFBIG, MSG_FAT_LIMIT)
            }
            val (free, total) = src.space()
            if (size > free - Archives.reserve(total)) throw FilesException(EngineError.FL_ENOSPC, MSG_TOO_BIG)
            val kdf = kdfKib()
            val done = CompletableDeferred<VaultInfo>()
            val job = pw.copyOf()
            try {
                Transfers.launch("vault", srcId, srcId) { c ->
                    try {
                        done.complete(Create(c, src, d, base, size, fs, job, kdf).run())
                    } catch (e: Transfers.Cancelled) {
                        c.finish(cancelled = true)
                        done.completeExceptionally(FilesException(EngineError.FL_EIO, MSG_CANCELLED))
                    } catch (e: Throwable) {
                        val fe = failure(e, "createDocument")
                        c.finish(if (!Transfers.alive(src)) Transfers.MSG_SOURCE_GONE else fe.message)
                        done.completeExceptionally(fe)
                    } finally {
                        job.fill(0)
                    }
                }
            } catch (e: Throwable) {
                job.fill(0)
                throw e
            }
            return done.await()
        } catch (e: Throwable) {
            throw failure(e, "createDocument")
        } finally {
            pw.fill(0)
        }
    }

    private class Create(
        val c: Transfers.JobContext,
        val src: FileSource,
        val dir: String,
        val name: String,
        val size: Long,
        val fs: String,
        val pw: ByteArray,
        val kdf: Int,
    ) {
        fun run(): VaultInfo {
            val fileName = name + EXT
            val (partial, out) = src.createFile(dir, Transfers.partialName(fileName))
            var keep = false
            try {
                c.st = c.st.copy(currentName = fileName, fileIndex = 1, fileCount = 1, totalBytes = size)
                c.publish(force = true)
                // la place d'abord : rien n'est réservé à moitié (et un stockage trop petit échoue avant le formatage)
                out.use { o ->
                    val zeros = ByteArray(CHUNK)
                    var written = 0L
                    while (written < size) {
                        c.checkCancel()
                        val n = minOf(CHUNK.toLong(), size - written).toInt()
                        o.write(zeros, 0, n)
                        written += n
                        c.st = c.st.copy(doneBytes = written * 8 / 10)
                        c.publish()
                    }
                }
                c.publish(force = true) // place écrite : 80 %, avant le formatage
                c.checkCancel()
                val opts = org.json.JSONObject()
                    .put("fs", fs).put("encrypted", true).put("label", "").put("kdf_mem_kib", kdf)
                    .put("uid", ROOT_ID).put("gid", ROOT_ID).put("table", "none")
                    .toString().toByteArray(Charsets.UTF_8)
                val h = EngineError.check(openDisk(src, partial, true))
                val rc = try {
                    Archives.engine.format(h, opts, pw.copyOf()) { pct ->
                        c.st = c.st.copy(doneBytes = size * 8 / 10 + size * pct / 500)
                        c.publish()
                    }
                } finally {
                    Archives.engine.closeDisk(h)
                }
                if (rc < 0) throw EngineError(rc)
                c.checkCancel()
                val final = DocNames.unique(fileName) { src.stat(DocumentIds.child(dir, it)) != null }
                    ?: throw FileNotFoundException("Trop d'éléments portent déjà ce nom")
                val path = src.rename(partial, final)
                keep = true
                val rec = VaultRecord(newId(), name, src.stableKey, path, size, fs)
                st().put(rec)
                c.st = c.st.copy(currentName = final, doneBytes = size)
                c.finish()
                return info(rec)
            } finally {
                if (!keep && Transfers.alive(src)) runCatching { src.delete(partial) }
            }
        }
    }
}
