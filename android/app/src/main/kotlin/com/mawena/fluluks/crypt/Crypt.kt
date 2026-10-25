package com.mawena.fluluks.crypt

import com.mawena.fluluks.engine.ArcMode
import com.mawena.fluluks.engine.Engine
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.engine.FileType
import com.mawena.fluluks.files.Archives
import com.mawena.fluluks.files.FileSource
import com.mawena.fluluks.files.Files
import com.mawena.fluluks.files.FilesException
import com.mawena.fluluks.files.NativeIn
import com.mawena.fluluks.files.NativeOut
import com.mawena.fluluks.files.PathRules
import com.mawena.fluluks.files.Transfers
import com.mawena.fluluks.provider.DocNames
import com.mawena.fluluks.provider.DocumentIds
import com.mawena.fluluks.provider.WriteOps
import com.mawena.fluluks.volumes.VolumeManager
import java.io.FileNotFoundException
import java.io.OutputStream
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Chiffrer, déchiffrer, vérifier et changer le mot de passe d'un fichier ou d'un dossier (phase 14), sur le créneau
 * unique des opérations ([Transfers.launch], types `encrypt`, `decrypt`, `verify`).
 *
 * Formats : un fichier en age (« nom.age ») ; un dossier, ou une sélection réunie, en ZIP dans age (« nom.zip.age ») ;
 * ou, pour l'échange, en ZIP AES-256 (« nom.zip »).
 *
 * Rien en clair ailleurs que sur la destination choisie : la source est lue en flux, chiffrée par le moteur et écrite
 * sous un nom temporaire (`.nom.portail-partiel`) de la destination ; le chiffré est ensuite relu en entier et comparé
 * à l'empreinte SHA-256 du clair prise au passage ; il ne reçoit son nom qu'après. L'original n'est supprimé, si on le
 * demande, qu'à la toute fin, et seulement s'il n'a pas changé pendant le chiffrement : la suppression est définitive
 * (pas de corbeille, qui garderait le clair).
 *
 * Mots de passe : des ByteArray, jamais des String ; [Crypt] copie celui qu'il reçoit, met à zéro le tableau de
 * l'appelant tout de suite, donne une copie au moteur à chaque ouverture (le moteur l'efface) et efface la sienne à la
 * fin, succès, échec ou annulation.
 */
object Crypt {
    const val MSG_BAD_PASSWORD = Passwords.MSG_BAD_PASSWORD
    const val MSG_DAMAGED = "Fichier chiffré abîmé ou incomplet"
    const val MSG_VERIFY_FAILED = "La vérification du fichier chiffré a échoué : l'original est gardé"
    const val MSG_ORIGINAL_CHANGED = "Fichier modifié pendant le chiffrement : l'original est gardé"
    const val MSG_LOW_MEMORY = "Mémoire insuffisante pour ce chiffrement : fermez d'autres applications et réessayez"
    const val MSG_NOT_ENCRYPTED = "Ce fichier n'est pas chiffré dans un format reconnu"
    const val MSG_IS_VAULT = "Ce fichier est un coffre : ouvrez-le depuis l'écran des coffres"
    const val MSG_VAULT_OPEN = "Fermez d'abord le coffre"
    const val MSG_ONLY_AGE = "Seuls les fichiers .age changent de mot de passe"
    const val MSG_NOTHING = "Rien à chiffrer"
    const val MSG_ROOT = "La racine ne peut pas être chiffrée"
    const val MSG_FORMAT = "Format de chiffrement inconnu"

    /** [format] : `age` ou `zip` (ZIP AES-256) ; [together] : toute la sélection dans une seule archive. */
    data class EncryptRequest(
        val srcId: String, val paths: List<String>, val dstId: String, val dstDir: String, val format: String,
        val together: Boolean, val name: String?, val deleteOriginal: Boolean,
    )

    /** [format] : celui de [CryptFormats] ; [folder] : dossier dans un fichier age ; [workFactor] : log2 N de scrypt. */
    data class EncryptedInfo(val format: String, val folder: Boolean, val workFactor: Int?)

    /** Vrai si [path] de [sourceId] est le fichier d'un coffre ouvert (branché par les coffres, phase 14 T9). */
    @Volatile var isOpenVaultFile: (sourceId: String, path: String) -> Boolean = { _, _ -> false }

    private val engine: Engine get() = Archives.engine

    /** Mémoire de scrypt pour log2 N (r = 8) : 2^(n+10) octets ; refus au-delà de 0,8 × la mémoire disponible. */
    internal fun requireMemory(log2n: Int) {
        val need = 1L shl (log2n + 10)
        if (need > 0.8 * VolumeManager.availableMemory()) throw FilesException(EngineError.FL_ENOMEM, MSG_LOW_MEMORY)
    }

    /** Premiers octets de [path] (au plus [CryptFormats.HEAD_BYTES]). */
    private fun head(src: FileSource, path: String): ByteArray {
        src.openRead(path).use { input ->
            val buf = ByteArray(CryptFormats.HEAD_BYTES)
            var n = 0
            while (n < buf.size) {
                val k = input.read(buf, n, buf.size - n)
                if (k < 0) break
                n += k
            }
            return buf.copyOf(n)
        }
    }

    fun info(srcId: String, path: String): EncryptedInfo {
        val src = Files.source(srcId)
        val p = PathRules.require(path)
        val h = head(src, p)
        val format = CryptFormats.detect(h)
        return EncryptedInfo(format, format == "age" && CryptFormats.isFolder(WriteOps.nameOf(p)), CryptFormats.ageWorkFactor(h))
    }

    /** Copie du mot de passe ; le tableau de l'appelant est mis à zéro tout de suite. */
    private fun take(pw: ByteArray): ByteArray = pw.copyOf().also { pw.fill(0) }

    private fun badPassword(code: Int): Exception =
        if (code == EngineError.FL_EBADPASS) FilesException(code, MSG_BAD_PASSWORD)
        else if (code == EngineError.FL_ECORRUPT) FilesException(code, MSG_DAMAGED)
        else EngineError(code)

    private fun check(code: Long): Long = if (code < 0) throw badPassword(code.toInt()) else code
    private fun check(code: Int): Int = if (code < 0) throw badPassword(code) else code

    /** Lance [body] sur le créneau ; [pw] est effacé à la fin, ou tout de suite si le créneau est pris. */
    private fun launch(kind: String, srcId: String, dstId: String, pw: ByteArray, body: (Transfers.JobContext) -> Unit) {
        try {
            Transfers.launch(kind, srcId, dstId) { c ->
                try {
                    body(c)
                } finally {
                    pw.fill(0)
                }
            }
        } catch (e: Throwable) {
            pw.fill(0)
            throw e
        }
    }

    /** Termine l'opération [c] selon l'exception (annulation, mot de passe, stockage fermé, autre). */
    private fun fail(c: Transfers.JobContext, e: Throwable, vararg sources: FileSource) {
        when {
            e is Transfers.Cancelled -> c.finish(cancelled = true)
            sources.any { !Transfers.alive(it) } -> c.finish(Transfers.MSG_SOURCE_GONE)
            else -> c.finish(
                Files.toFilesException(e, "copyDocument").message,
                badPassword = (e as? FilesException)?.code == EngineError.FL_EBADPASS,
            )
        }
    }

    // --- chiffrement -----------------------------------------------------------------------------------------

    fun startEncrypt(req: EncryptRequest, password: ByteArray) {
        val pw = take(password)
        try {
            Passwords.check(pw)?.let { throw FilesException(EngineError.FL_EINVAL, it) }
            if (req.format != "age" && req.format != "zip") throw FilesException(EngineError.FL_EINVAL, MSG_FORMAT)
            if (req.format == "age") requireMemory(Engine.AGE_LOG2N)
        } catch (e: Throwable) {
            pw.fill(0)
            throw e
        }
        launch("encrypt", req.srcId, req.dstId, pw) { Encrypt(it, req, pw).run() }
    }

    private enum class Out { AGE, ZIP_AES, ZIP_AGE }

    /** Fichier écrit dans une archive : nom dans l'archive, taille, empreinte du clair. */
    private class Written(val name: String, val size: Long, val sha: ByteArray?)

    private class Encrypt(val c: Transfers.JobContext, val req: EncryptRequest, val pw: ByteArray) {
        var changed = 0
        var skipped = 0

        fun run() {
            val src = Files.sourceOrNull(req.srcId)
            val dst = Files.sourceOrNull(req.dstId)
            if (src == null || dst == null) return c.finish(Transfers.MSG_SOURCE_GONE)
            try {
                execute(src, dst)
                c.finish(
                    when {
                        changed > 0 -> MSG_ORIGINAL_CHANGED
                        skipped > 0 -> Transfers.MSG_LINKS
                        else -> null
                    },
                )
            } catch (e: Throwable) {
                fail(c, e, src, dst)
            }
        }

        fun execute(src: FileSource, dst: FileSource) {
            val tops = req.paths.map { PathRules.require(it) }
            val dir = PathRules.require(req.dstDir)
            if (tops.isEmpty()) throw FileNotFoundException(MSG_NOTHING)
            if (tops.any { it == "/" }) throw FileNotFoundException(MSG_ROOT)
            dst.readOnlyReason?.let { throw FileNotFoundException(Files.readOnlyMessage(dst, it)) }
            if (req.deleteOriginal) src.readOnlyReason?.let { throw FileNotFoundException(Files.readOnlyMessage(src, it)) }
            val d = dst.stat(dir) ?: throw FileNotFoundException("Dossier introuvable")
            if (!d.type.isDirType()) throw FileNotFoundException("Ce n'est pas un dossier")
            if (tops.any { isOpenVaultFile(req.srcId, it) }) throw FilesException(EngineError.FL_EBUSY, MSG_VAULT_OPEN)

            // parcours borné de toute la sélection avant d'écrire quoi que ce soit
            val plans = tops.map { Transfers.scanTree(src, it, c::checkCancel) }
            val files = plans.sumOf { p -> p.count { it.type == FileType.FILE } }
            val total = plans.sumOf { p -> p.filter { it.type == FileType.FILE }.sumOf { it.size } }
            val (free, _) = dst.space()
            if (free >= 0 && total > free) throw FilesException(EngineError.FL_ENOSPC, Transfers.msgNoSpace(total, free))
            c.st = c.st.copy(fileCount = files, totalBytes = total)
            c.publish(force = true)

            val groups = if (req.together) listOf(tops.indices.toList()) else tops.indices.map { listOf(it) }
            for (g in groups) {
                c.checkCancel()
                val single = g.size == 1 && plans[g[0]][0].type == FileType.FILE
                val kind = when {
                    req.format == "zip" -> Out.ZIP_AES
                    single && !req.together -> Out.AGE
                    else -> Out.ZIP_AGE
                }
                val name = outputName(kind, g.map { tops[it] }, g.map { plans[it] }).let { if (dst.restrictedNames) DocNames.sanitize(it) else it }
                if (kind == Out.AGE) encryptFile(src, dst, dir, plans[g[0]][0], name) else encryptZip(src, dst, dir, kind, g, tops, plans, name)
                // l'original ne part qu'une fois le chiffré vérifié et nommé, et seulement s'il n'a pas changé
                if (req.deleteOriginal) for (i in g) {
                    if (unchanged(src, plans[i])) src.delete(tops[i]) else changed++
                }
            }
        }

        fun outputName(kind: Out, tops: List<String>, plans: List<List<Transfers.Node>>): String {
            val given = req.name?.trim().orEmpty()
            val first = WriteOps.nameOf(tops[0])
            return when (kind) {
                Out.AGE -> "$first.age"
                Out.ZIP_AGE -> {
                    val base = given.ifEmpty { if (tops.size == 1) first else "Archive" }
                    if (base.endsWith(".zip.age", ignoreCase = true)) base else "${base.removeSuffix(".zip")}.zip.age"
                }
                Out.ZIP_AES -> {
                    val base = given.ifEmpty {
                        when {
                            tops.size > 1 -> "Archive"
                            plans[0][0].type == FileType.DIR -> first
                            else -> first.substringBeforeLast('.', first).ifEmpty { first }
                        }
                    }
                    if (base.endsWith(".zip", ignoreCase = true)) base else "$base.zip"
                }
            }
        }

        /** Rien n'a bougé depuis le parcours : chaque élément a encore sa taille et sa date. */
        fun unchanged(src: FileSource, plan: List<Transfers.Node>): Boolean = plan.all { n ->
            val now = src.stat(n.src) ?: return false
            now.type == n.type && (n.type != FileType.FILE || (now.size == n.size && now.mtime == n.mtime))
        }

        fun open(kind: Out, fd: Int, file: Long, pass: ByteArray): Long = when (kind) {
            Out.AGE -> if (fd >= 0) engine.ageWriterOpenFd(fd, pass, Engine.AGE_LOG2N) else engine.ageWriterOpenFile(file, pass, Engine.AGE_LOG2N)
            Out.ZIP_AES -> if (fd >= 0) engine.arcwOpenFd(fd, ArcMode.AES, pass) else engine.arcwOpenFile(file, ArcMode.AES, pass)
            Out.ZIP_AGE -> if (fd >= 0) engine.arcwOpenFd(fd, ArcMode.AGE, pass) else engine.arcwOpenFile(file, ArcMode.AGE, pass)
        }

        fun close(kind: Out, h: Long, commit: Boolean): Int =
            if (kind == Out.AGE) engine.ageWriterClose(h, commit) else engine.arcwClose(h, commit)

        /**
         * Écrit le chiffré sous un nom temporaire de [dir] ([body] reçoit la poignée du moteur), le relit par [verify],
         * puis lui donne [finalName] (nom unique). Le temporaire est supprimé sur tout échec ou annulation.
         */
        fun output(dst: FileSource, dir: String, finalName: String, kind: Out, body: (Long) -> Unit, verify: (String) -> Unit) {
            val tmp = Transfers.partialName(finalName)
            dst.stat(DocumentIds.child(dir, tmp))?.let { if (it.type == FileType.FILE) dst.delete(it.path) }
            val (partial, out) = dst.createNative(dir, tmp)
            var keep = false
            var committed = false
            var onClosed: (Boolean) -> Unit = {}
            var pump: Archives.Pump? = null
            var h = 0L
            try {
                try {
                    val pass = pw.copyOf()
                    h = try {
                        when (out) {
                            is NativeOut.Fd -> open(kind, Archives.openFd(out.file, true), 0, pass)
                            is NativeOut.EngineFile -> {
                                onClosed = { out.onClosed() }
                                open(kind, -1, out.handle, pass)
                            }
                            is NativeOut.Pipe -> {
                                onClosed = out.onClosed
                                val (fd, input) = Archives.pipe()
                                pump = Archives.Pump(input, out.sink).also { it.start() }
                                open(kind, fd, 0, pass)
                            }
                        }
                    } finally {
                        pass.fill(0)
                    }
                    check(h) // en cas d'échec, le moteur a déjà fermé la destination
                    body(h)
                    val rc = close(kind, h, true)
                    h = 0L
                    check(rc)
                    pump?.let { p ->
                        p.join()
                        p.error?.let { throw FilesException(EngineError.FL_EIO, it.message ?: "Écriture interrompue") }
                    }
                    committed = true
                } finally {
                    if (h > 0) runCatching { close(kind, h, false) }
                    pump?.join()
                    onClosed(committed)
                }
                // relecture complète du chiffré avant de lui donner son nom
                c.st = c.st.copy(currentName = finalName)
                c.publish(force = true)
                try {
                    verify(partial)
                } catch (e: Transfers.Cancelled) {
                    throw e
                } catch (e: Throwable) {
                    throw FilesException(EngineError.FL_ECORRUPT, MSG_VERIFY_FAILED)
                }
                val final = DocNames.unique(finalName) { dst.stat(DocumentIds.child(dir, it)) != null }
                    ?: throw FileNotFoundException("Trop d'éléments portent déjà ce nom")
                dst.rename(partial, final)
                keep = true
                c.publish(force = true)
            } finally {
                if (!keep && Transfers.alive(dst)) runCatching { dst.delete(partial) }
            }
        }

        fun encryptFile(src: FileSource, dst: FileSource, dir: String, n: Transfers.Node, name: String) {
            c.st = c.st.copy(currentName = WriteOps.nameOf(n.src), fileIndex = c.st.fileIndex + 1)
            c.publish(force = true)
            val sha = MessageDigest.getInstance("SHA-256")
            var written = 0L
            output(dst, dir, name, Out.AGE, body = { h ->
                val buf = ByteArray(WriteOps.COPY_CHUNK)
                try {
                    src.openRead(n.src).use { input ->
                        while (true) {
                            c.checkCancel()
                            val k = input.read(buf)
                            if (k < 0) break
                            if (k == 0) continue
                            check(engine.ageWrite(h, buf, k))
                            sha.update(buf, 0, k)
                            written += k
                            c.st = c.st.copy(doneBytes = c.st.doneBytes + k)
                            c.publish()
                        }
                    }
                } finally {
                    buf.fill(0) // clair : ne traîne pas dans le tas
                }
            }, verify = { partial -> verifyAge(dst, partial, written, sha.digest()) })
            if (written != n.size) c.st = c.st.copy(totalBytes = c.st.totalBytes + (written - n.size))
        }

        fun verifyAge(dst: FileSource, path: String, size: Long, expected: ByteArray) {
            val r = openAgeReader(dst, path, pw)
            try {
                if (engine.ageSize(r) != size) throw FilesException(EngineError.FL_ECORRUPT, MSG_DAMAGED)
                val got = shaOfAge(r, c::checkCancel)
                if (!got.contentEquals(expected)) throw FilesException(EngineError.FL_ECORRUPT, MSG_DAMAGED)
            } finally {
                engine.ageReaderClose(r)
            }
        }

        fun encryptZip(
            src: FileSource, dst: FileSource, dir: String, kind: Out, g: List<Int>, tops: List<String>,
            plans: List<List<Transfers.Node>>, name: String,
        ) {
            val written = ArrayList<Written>()
            output(dst, dir, name, kind, body = { h ->
                val buf = ByteArray(WriteOps.COPY_CHUNK)
                try {
                    for (i in g) {
                        val topName = WriteOps.nameOf(tops[i])
                        for (n in plans[i]) {
                            c.checkCancel()
                            if (n.type != FileType.DIR && n.type != FileType.FILE) {
                                skipped++
                                continue
                            }
                            val entryName = topName + n.rel
                            val isDir = n.type == FileType.DIR
                            val json = JSONObject().put("name", entryName).put("type", if (isDir) "d" else "f")
                                .put("size", if (isDir) 0L else n.size).put("mtime", n.mtime).put("store", false)
                            check(engine.arcwAdd(h, json.toString().toByteArray(Charsets.UTF_8)))
                            written.add(Written(entryName, if (isDir) -1 else n.size, if (isDir) null else addData(src, n, h, buf, entryName)))
                        }
                    }
                } finally {
                    buf.fill(0)
                }
            }, verify = { partial -> verifyZip(dst, partial, kind, written) })
        }

        /** Données du fichier [n] dans l'entrée courante (exactement la taille annoncée) ; rend leur empreinte. */
        fun addData(src: FileSource, n: Transfers.Node, h: Long, buf: ByteArray, name: String): ByteArray {
            c.st = c.st.copy(currentName = WriteOps.nameOf(name), fileIndex = c.st.fileIndex + 1)
            c.publish(force = true)
            val sha = MessageDigest.getInstance("SHA-256")
            var done = 0L
            src.openRead(n.src).use { input ->
                while (true) {
                    c.checkCancel()
                    val k = input.read(buf)
                    if (k < 0) break
                    if (k == 0) continue
                    if (done + k > n.size) throw FilesException(EngineError.FL_EIO, Archives.MSG_CHANGED)
                    check(engine.arcwWrite(h, buf, k))
                    sha.update(buf, 0, k)
                    done += k
                    c.st = c.st.copy(doneBytes = c.st.doneBytes + k)
                    c.publish()
                }
            }
            if (done != n.size) throw FilesException(EngineError.FL_EIO, Archives.MSG_CHANGED)
            return sha.digest()
        }

        /** ZIP relu : mêmes entrées, dans le même ordre, mêmes tailles, mêmes empreintes. */
        fun verifyZip(dst: FileSource, path: String, kind: Out, expected: List<Written>) {
            val mode = if (kind == Out.ZIP_AGE) ArcMode.AGE else ArcMode.PLAIN
            Archives.withReader(dst, path, mode, pw) { h, _ ->
                val buf = ByteArray(WriteOps.COPY_CHUNK)
                for (w in expected) {
                    c.checkCancel()
                    val b = engine.arcNext(h) ?: throw FilesException(EngineError.FL_ECORRUPT, MSG_DAMAGED)
                    val o = JSONObject(String(b, Charsets.UTF_8))
                    if (o.has("err")) throw badPassword(o.getInt("err"))
                    val nameOk = String(java.util.Base64.getDecoder().decode(o.getString("name")), Charsets.UTF_8).trimEnd('/') == w.name
                    if (!nameOk) throw FilesException(EngineError.FL_ECORRUPT, MSG_DAMAGED)
                    if (w.sha == null) continue
                    val sha = MessageDigest.getInstance("SHA-256")
                    var n = 0L
                    while (true) {
                        val k = check(engine.arcRead(h, buf, buf.size))
                        if (k == 0) break
                        sha.update(buf, 0, k)
                        n += k
                    }
                    if (n != w.size || !sha.digest().contentEquals(w.sha)) throw FilesException(EngineError.FL_ECORRUPT, MSG_DAMAGED)
                }
                buf.fill(0)
                if (engine.arcNext(h) != null) throw FilesException(EngineError.FL_ECORRUPT, MSG_DAMAGED)
            }
        }
    }

    /** Lecteur age sur [path] de [src] (une copie de [pw] est donnée au moteur). */
    private fun openAgeReader(src: FileSource, path: String, pw: ByteArray): Long = openAgeReaderFor(src, path, pw).first

    /** Lecteur age sur [path] de [src], et l'activité à signaler à chaque lecture (fichier d'un disque). */
    internal fun openAgeReaderFor(src: FileSource, path: String, pw: ByteArray): Pair<Long, () -> Unit> {
        val pass = pw.copyOf()
        try {
            val n = src.openNative(path)
            val r = check(
                when (n) {
                    is NativeIn.Fd -> engine.ageReaderOpenFd(Archives.openFd(n.file, false), pass)
                    is NativeIn.EngineFile -> engine.ageReaderOpenFile(n.handle, n.size, pass)
                    is NativeIn.Proxy -> engine.ageReaderOpenFd(n.open(), pass)
                },
            )
            return r to ((n as? NativeIn.EngineFile)?.onActivity ?: {})
        } finally {
            pass.fill(0)
        }
    }

    /** Empreinte du clair d'un lecteur age, lu en entier (le clair ne quitte pas ce tampon, effacé ensuite). */
    private fun shaOfAge(r: Long, checkCancel: () -> Unit): ByteArray {
        val sha = MessageDigest.getInstance("SHA-256")
        val buf = ByteArray(WriteOps.COPY_CHUNK)
        var off = 0L
        try {
            while (true) {
                checkCancel()
                val k = check(engine.agePread(r, off, buf, buf.size))
                if (k == 0) break
                sha.update(buf, 0, k)
                off += k
            }
        } finally {
            buf.fill(0)
        }
        return sha.digest()
    }

    // --- déchiffrement et vérification -------------------------------------------------------------------------

    /**
     * Déchiffre [path] sous [dstDir] de [dstId] : un fichier age donne le fichier sans « .age » ; un dossier (ZIP dans
     * age) est extrait dans un nouveau dossier si [extractFolder] (aucun .zip écrit), sinon rendu en « nom.zip » ; un ZIP
     * protégé est extrait.
     */
    fun startDecrypt(srcId: String, path: String, dstId: String, dstDir: String, password: ByteArray, extractFolder: Boolean) {
        val pw = take(password)
        launch("decrypt", srcId, dstId, pw) { Decrypt(it, srcId, path, dstId, dstDir, pw, extractFolder).run() }
    }

    private class Decrypt(
        val c: Transfers.JobContext, val srcId: String, val path: String, val dstId: String, val dstDir: String,
        val pw: ByteArray, val extractFolder: Boolean,
    ) {
        fun run() {
            val src = Files.sourceOrNull(srcId)
            val dst = Files.sourceOrNull(dstId)
            if (src == null || dst == null) return c.finish(Transfers.MSG_SOURCE_GONE)
            try {
                if (execute(src, dst)) c.finish()
            } catch (e: Throwable) {
                fail(c, e, src, dst)
            }
        }

        /** Vrai si l'opération reste à terminer ici (une extraction se termine elle-même). */
        fun execute(src: FileSource, dst: FileSource): Boolean {
            val p = PathRules.require(path)
            val dir = PathRules.require(dstDir)
            val name = WriteOps.nameOf(p)
            dst.readOnlyReason?.let { throw FileNotFoundException(Files.readOnlyMessage(dst, it)) }
            val h = head(src, p)
            when (CryptFormats.detect(h)) {
                "luks" -> throw FilesException(EngineError.FL_ENOTSUP, MSG_IS_VAULT)
                "none" -> throw FilesException(EngineError.FL_ENOTSUP, MSG_NOT_ENCRYPTED)
                "zip-aes", "zip-legacy" -> {
                    Archives.extractOnSlot(c, srcId, p, dstId, dir, true, pw.copyOf(), ArcMode.PLAIN, null)
                    return false
                }
            }
            requireMemory(CryptFormats.ageWorkFactor(h) ?: Engine.AGE_LOG2N)
            if (extractFolder && CryptFormats.isFolder(name)) {
                Archives.extractOnSlot(
                    c, srcId, p, dstId, dir, true, pw.copyOf(), ArcMode.AGE, CryptFormats.plainName(name, folder = true), smart = true,
                )
                return false
            }
            decryptFile(src, dst, p, dir, CryptFormats.plainName(name).let { if (dst.restrictedNames) DocNames.sanitize(it) else it })
            return true
        }

        fun decryptFile(src: FileSource, dst: FileSource, p: String, dir: String, plain: String) {
            val r = openAgeReader(src, p, pw)
            try {
                val size = engine.ageSize(r)
                val (free, _) = dst.space()
                if (free >= 0 && size > free) throw FilesException(EngineError.FL_ENOSPC, Transfers.msgNoSpace(size, free))
                c.st = c.st.copy(currentName = plain, fileIndex = 1, fileCount = 1, totalBytes = size)
                c.publish(force = true)
                val tmp = Transfers.partialName(plain)
                dst.stat(DocumentIds.child(dir, tmp))?.let { if (it.type == FileType.FILE) dst.delete(it.path) }
                val (partial, out) = dst.createFile(dir, tmp)
                var keep = false
                var o: OutputStream? = out
                val buf = ByteArray(WriteOps.COPY_CHUNK)
                try {
                    var off = 0L
                    while (true) {
                        c.checkCancel()
                        val k = check(engine.agePread(r, off, buf, buf.size))
                        if (k == 0) break
                        out.write(buf, 0, k)
                        off += k
                        c.st = c.st.copy(doneBytes = off)
                        c.publish()
                    }
                    o = null
                    out.close()
                    if (off != size || dst.stat(partial)?.size != size) throw FilesException(EngineError.FL_EIO, Transfers.MSG_SIZE_MISMATCH)
                    val final = DocNames.unique(plain) { dst.stat(DocumentIds.child(dir, it)) != null }
                        ?: throw FileNotFoundException("Trop d'éléments portent déjà ce nom")
                    dst.rename(partial, final)
                    keep = true
                } finally {
                    buf.fill(0)
                    o?.let { runCatching { it.close() } }
                    if (!keep && Transfers.alive(dst)) runCatching { dst.delete(partial) }
                }
            } finally {
                engine.ageReaderClose(r)
            }
        }
    }

    /** Relit le fichier chiffré en entier sans rien écrire : fin sans erreur s'il est intact, [MSG_DAMAGED] sinon. */
    fun startVerify(srcId: String, path: String, password: ByteArray) {
        val pw = take(password)
        launch("verify", srcId, srcId, pw) { c ->
            val src = Files.sourceOrNull(srcId) ?: return@launch c.finish(Transfers.MSG_SOURCE_GONE)
            try {
                val p = PathRules.require(path)
                val h = head(src, p)
                c.st = c.st.copy(currentName = WriteOps.nameOf(p), fileIndex = 1, fileCount = 1)
                c.publish(force = true)
                when (CryptFormats.detect(h)) {
                    "age" -> {
                        requireMemory(CryptFormats.ageWorkFactor(h) ?: Engine.AGE_LOG2N)
                        if (CryptFormats.isFolder(WriteOps.nameOf(p))) readAllZip(src, p, ArcMode.AGE, pw, c::checkCancel)
                        else {
                            val r = openAgeReader(src, p, pw)
                            try {
                                shaOfAge(r, c::checkCancel)
                            } finally {
                                engine.ageReaderClose(r)
                            }
                        }
                    }
                    "zip-aes", "zip-legacy" -> readAllZip(src, p, ArcMode.PLAIN, pw, c::checkCancel)
                    "luks" -> throw FilesException(EngineError.FL_ENOTSUP, MSG_IS_VAULT)
                    else -> throw FilesException(EngineError.FL_ENOTSUP, MSG_NOT_ENCRYPTED)
                }
                c.finish()
            } catch (e: Throwable) {
                fail(c, e, src)
            }
        }
    }

    /** Lit toutes les données d'une archive (chaque entrée déchiffrée, vérifiée par le moteur), sans rien écrire. */
    private fun readAllZip(src: FileSource, p: String, mode: Int, pw: ByteArray, checkCancel: () -> Unit) {
        Archives.withReader(src, p, mode, pw) { h, activity ->
            val buf = ByteArray(WriteOps.COPY_CHUNK)
            try {
                while (true) {
                    checkCancel()
                    activity()
                    val b = engine.arcNext(h) ?: break
                    val o = JSONObject(String(b, Charsets.UTF_8))
                    if (o.has("err")) throw badPassword(o.getInt("err"))
                    if (o.getString("type") != "f") continue
                    while (check(engine.arcRead(h, buf, buf.size)) > 0) checkCancel()
                }
            } finally {
                buf.fill(0)
            }
        }
    }

    // --- changement de mot de passe ----------------------------------------------------------------------------

    /**
     * Nouveau mot de passe d'un fichier age, dans le même dossier : la charge utile est recopiée sans être déchiffrée
     * sous un nom temporaire, vérifiée par le moteur, puis prend la place de l'ancien fichier (qui n'est supprimé
     * qu'après). Sur échec, l'ancien fichier reste tel quel.
     */
    suspend fun changePassword(srcId: String, path: String, old: ByteArray, new: ByteArray) = withContext(Dispatchers.IO) {
        val o = take(old)
        val n = take(new)
        try {
            Passwords.check(n)?.let { throw FilesException(EngineError.FL_EINVAL, it) }
            if (Transfers.isBusy(srcId)) throw FilesException(EngineError.FL_EBUSY, Transfers.MSG_BUSY)
            val src = Files.source(srcId)
            val p = PathRules.require(path)
            src.readOnlyReason?.let { throw FileNotFoundException(Files.readOnlyMessage(src, it)) }
            if (isOpenVaultFile(srcId, p)) throw FilesException(EngineError.FL_EBUSY, MSG_VAULT_OPEN)
            val h = head(src, p)
            if (CryptFormats.detect(h) != "age") throw FilesException(EngineError.FL_ENOTSUP, MSG_ONLY_AGE)
            requireMemory(maxOf(CryptFormats.ageWorkFactor(h) ?: Engine.AGE_LOG2N, Engine.AGE_LOG2N))
            val dir = WriteOps.parentOf(p)
            val name = WriteOps.nameOf(p)
            val tmp = Transfers.partialName(name)
            src.stat(DocumentIds.child(dir, tmp))?.let { if (it.type == FileType.FILE) src.delete(it.path) }
            val (partial, out) = src.createNative(dir, tmp)
            var keep = false
            try {
                rewrap(src, p, out, o, n)
                // remplacement : l'ancien est mis de côté, le nouveau prend son nom, l'ancien est supprimé
                val aside = src.rename(p, Transfers.partialName("$name.ancien"))
                try {
                    src.rename(partial, name)
                } catch (e: Throwable) {
                    runCatching { src.rename(aside, name) }
                    throw e
                }
                keep = true
                runCatching { src.delete(aside) }
            } finally {
                if (!keep && Transfers.alive(src)) runCatching { src.delete(partial) }
            }
        } finally {
            o.fill(0)
            n.fill(0)
        }
    }

    /** ageRewrap de [p] vers [out] ; les deux extrémités sont fermées par le moteur. */
    private fun rewrap(src: FileSource, p: String, out: NativeOut, o: ByteArray, n: ByteArray) {
        var inFd = -1
        var inFile = 0L
        var inSize = 0L
        when (val i = src.openNative(p)) {
            is NativeIn.Fd -> inFd = Archives.openFd(i.file, false)
            is NativeIn.EngineFile -> {
                inFile = i.handle
                inSize = i.size
            }
            is NativeIn.Proxy -> inFd = i.open()
        }
        var outFd = -1
        var outFile = 0L
        var onClosed: (Boolean) -> Unit = {}
        var pump: Archives.Pump? = null
        when (out) {
            is NativeOut.Fd -> outFd = Archives.openFd(out.file, true)
            is NativeOut.EngineFile -> {
                outFile = out.handle
                onClosed = { out.onClosed() }
            }
            is NativeOut.Pipe -> {
                onClosed = out.onClosed
                val (fd, input) = Archives.pipe()
                pump = Archives.Pump(input, out.sink).also { it.start() }
                outFd = fd
            }
        }
        var rc = EngineError.FL_EIO
        try {
            rc = engine.ageRewrap(inFd, inFile, inSize, outFd, outFile, o.copyOf(), n.copyOf(), Engine.AGE_LOG2N)
            pump?.let { pp ->
                pp.join()
                pp.error?.let { throw FilesException(EngineError.FL_EIO, it.message ?: "Écriture interrompue") }
            }
            check(rc)
        } finally {
            pump?.join()
            onClosed(rc == 0)
        }
    }

    private fun FileType.isDirType() = this == FileType.DIR
}
