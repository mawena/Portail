package com.mawena.fluluks.crypt

import android.net.Uri
import androidx.annotation.VisibleForTesting
import com.mawena.fluluks.engine.Engine
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.engine.FileType
import com.mawena.fluluks.files.Archives
import com.mawena.fluluks.files.Entry
import com.mawena.fluluks.files.FileSource
import com.mawena.fluluks.files.Files
import com.mawena.fluluks.files.FilesException
import com.mawena.fluluks.files.NativeIn
import com.mawena.fluluks.files.NativeOut
import com.mawena.fluluks.files.PathRules
import com.mawena.fluluks.files.Thumbnails
import com.mawena.fluluks.provider.StreamProvider
import com.mawena.fluluks.provider.StreamTokens
import com.mawena.fluluks.provider.WriteOps
import java.io.FileNotFoundException
import java.io.InputStream
import java.io.OutputStream
import java.security.SecureRandom

/**
 * Vue déchiffrée d'un fichier age : une source en lecture seule qui contient un seul fichier, `/<nom sans .age>`,
 * lu à n'importe quel décalage par le lecteur age du moteur. Le clair n'existe qu'en mémoire, par morceaux lus à la
 * demande : rien n'est écrit, ni sur une source ni dans un cache. Les lecteurs de Portail et « Ouvrir avec » la
 * lisent comme n'importe quelle source (`dec:<jeton>`), par le fournisseur de flux.
 */
class DecryptedSource internal constructor(
    override val id: String,
    /** Source et chemin du fichier chiffré. */
    val originId: String,
    val originPath: String,
    /** Nom du fichier en clair. */
    val name: String,
    /** Taille du clair. */
    val size: Long,
    private val mtime: Long,
    private val engine: Engine,
    private val reader: Long,
    /** Activité de la source d'origine à chaque lecture (verrouillage automatique d'un disque). */
    private val onActivity: () -> Unit,
) : FileSource {
    val path = "/$name"

    private var closed = false

    override val stableKey get() = id
    override val label get() = name
    override val readOnlyReason get() = DecryptedSources.MSG_READ_ONLY
    override val caseInsensitive get() = false
    override val restrictedNames get() = false
    override val hasTrash get() = false

    private fun entry() = Entry(name, path, FileType.FILE, size, mtime)

    private fun requireFile(p: String) {
        if (PathRules.check(p) != path) throw FileNotFoundException("Document introuvable")
    }

    override fun list(path: String): List<Entry> {
        if (PathRules.check(path) != "/") throw FileNotFoundException("Dossier introuvable")
        return listOf(entry())
    }

    override fun stat(path: String): Entry? = when (PathRules.check(path)) {
        "/" -> Entry("", "/", FileType.DIR, 0, mtime)
        this.path -> entry()
        else -> null
    }

    override fun space() = 0L to size

    private fun readOnly(): Nothing = throw FileNotFoundException(DecryptedSources.MSG_READ_ONLY)

    override fun mkdir(parent: String, name: String): String = readOnly()
    override fun rename(path: String, newName: String): String = readOnly()
    override fun delete(path: String) = readOnly()
    override fun move(path: String, targetParent: String): String = readOnly()
    override fun createFile(parent: String, name: String): Pair<String, OutputStream> = readOnly()
    override fun openOverwrite(path: String): OutputStream = readOnly()
    override fun createNative(parent: String, name: String): Pair<String, NativeOut> = readOnly()

    override fun openRead(path: String): InputStream = openReadAt(path, 0)

    override fun openReadAt(path: String, offset: Long): InputStream {
        requireFile(path)
        synchronized(this) { if (closed) throw FileNotFoundException(DecryptedSources.MSG_CLOSED) }
        return Stream(offset.coerceIn(0, size))
    }

    override fun contentUri(path: String): Uri {
        requireFile(path)
        return StreamProvider.uriFor(this, this.path)
    }

    override fun openNative(path: String): NativeIn {
        requireFile(path)
        return NativeIn.Proxy(size) { StreamProvider.openProxy(this, this.path, size).detachFd() }
    }

    /** Lit jusqu'à [len] octets du clair à [offset] ; 0 à la fin. Un appel à la fois (le lecteur natif aussi). */
    internal fun pread(offset: Long, buf: ByteArray, len: Int): Int = synchronized(this) {
        if (closed) throw FileNotFoundException(DecryptedSources.MSG_CLOSED)
        val k = engine.agePread(reader, offset, buf, len)
        if (k < 0) throw if (k == EngineError.FL_ECORRUPT) FilesException(k, Crypt.MSG_DAMAGED) else EngineError(k)
        onActivity()
        k
    }

    /** Ferme le lecteur natif (clé effacée) ; sans effet la seconde fois. */
    internal fun close() {
        synchronized(this) {
            if (closed) return
            closed = true
            engine.ageReaderClose(reader)
        }
    }

    private inner class Stream(private var pos: Long) : InputStream() {
        override fun read(): Int {
            val one = ByteArray(1)
            return if (read(one, 0, 1) <= 0) -1 else one[0].toInt() and 0xff
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (len == 0) return 0
            if (pos >= size) return -1
            val want = minOf(len.toLong(), size - pos, CHUNK.toLong()).toInt()
            val tmp = if (off == 0) b else ByteArray(want)
            val k = pread(pos, tmp, want)
            if (k == 0) return -1
            if (tmp !== b) {
                System.arraycopy(tmp, 0, b, off, k)
                tmp.fill(0)
            }
            pos += k
            return k
        }

        override fun skip(n: Long): Long {
            val k = maxOf(0L, minOf(n, size - pos))
            pos += k
            return k
        }

        override fun available(): Int = minOf(size - pos, Int.MAX_VALUE.toLong()).toInt()
    }

    private companion object {
        const val CHUNK = 1 shl 20
    }
}

/**
 * Vues déchiffrées ouvertes : [MAX] au plus (la plus ancienne est fermée à l'ouverture d'une de plus), retirées
 * avec leur source d'origine (éjection, verrouillage, débranchement, déconnexion), à la fermeture, ou au premier
 * accès si l'origine a disparu sans prévenir.
 */
object DecryptedSources {
    const val PREFIX = "dec:"
    const val MAX = 4
    const val MSG_READ_ONLY = "Fichier déchiffré en mémoire, en lecture seule"
    const val MSG_CLOSED = "Le fichier déchiffré a été fermé"
    const val MSG_FOLDER = "Un dossier chiffré ne s'ouvre pas : déchiffrez-le ou extrayez-le"

    private val open = LinkedHashMap<String, DecryptedSource>() // ordre d'ouverture
    private val rnd = SecureRandom()

    private val engine: Engine get() = Archives.engine

    /**
     * Ouvre une vue déchiffrée de [path] de [srcId] avec [password] (mis à zéro tout de suite) ; FL_EBADPASS si le mot
     * de passe est faux, [MSG_FOLDER] pour un `.zip.age`, [Crypt.MSG_NOT_ENCRYPTED] si ce n'est pas un fichier age.
     */
    fun open(srcId: String, path: String, password: ByteArray): DecryptedSource {
        val pw = password.copyOf()
        password.fill(0)
        try {
            val src = Files.source(srcId)
            val p = PathRules.require(path)
            val original = WriteOps.nameOf(p)
            if (CryptFormats.isFolder(original)) throw FilesException(EngineError.FL_ENOTSUP, MSG_FOLDER)
            val e = src.stat(p) ?: throw FileNotFoundException("Document introuvable")
            if (e.type != FileType.FILE) throw FileNotFoundException("Ce n'est pas un fichier ordinaire")
            val info = Crypt.info(srcId, p)
            if (info.format != "age") throw FilesException(EngineError.FL_ENOTSUP, Crypt.MSG_NOT_ENCRYPTED)
            info.workFactor?.let(Crypt::requireMemory)
            val (r, activity) = Crypt.openAgeReaderFor(src, p, pw)
            val size = engine.ageSize(r)
            if (size < 0) {
                engine.ageReaderClose(r)
                throw EngineError(size.toInt())
            }
            val view = DecryptedSource(newId(), srcId, p, CryptFormats.plainName(original), size, e.mtime, engine, r, activity)
            val evicted = synchronized(this) {
                open[view.id] = view
                if (open.size > MAX) open.keys.first().let { open.remove(it) } else null
            }
            evicted?.let(::wipe)
            return view
        } catch (e: Throwable) {
            throw Files.toFilesException(e, "openDocument")
        } finally {
            pw.fill(0)
        }
    }

    private fun newId(): String = PREFIX + ByteArray(16).also(rnd::nextBytes).joinToString("") { "%02x".format(it) }

    /** La vue [id], ou null ; retirée (et fermée) si sa source d'origine n'existe plus. */
    fun get(id: String): DecryptedSource? {
        val v = synchronized(this) { open[id] } ?: return null
        if (Files.sourceOrNull(v.originId) == null) {
            close(id)
            return null
        }
        return v
    }

    /** Vues ouvertes, de la plus ancienne à la plus récente. */
    fun all(): List<DecryptedSource> = synchronized(this) { open.values.toList() }

    /** Ferme la vue [id] : lecteur natif fermé, liens du fournisseur de flux expirés, vignettes oubliées. */
    fun close(id: String) {
        val v = synchronized(this) { open.remove(id) } ?: return
        wipe(v)
    }

    /** Ferme les vues dont le fichier chiffré est sur [originId] (stockage fermé ou sur le point de l'être). */
    fun dropFor(originId: String) {
        val gone = synchronized(this) { open.values.filter { it.originId == originId }.onEach { open.remove(it.id) } }
        gone.forEach(::wipe)
    }

    fun closeAll() {
        val gone = synchronized(this) { open.values.toList().also { open.clear() } }
        gone.forEach(::wipe)
    }

    private fun wipe(v: DecryptedSource) {
        v.close()
        StreamTokens.forget(v.id)
        Thumbnails.drop(v.id)
    }

    @VisibleForTesting
    fun resetForTests() = closeAll()
}
