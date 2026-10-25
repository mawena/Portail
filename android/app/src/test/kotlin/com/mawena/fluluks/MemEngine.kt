package com.mawena.fluluks

import com.mawena.fluluks.engine.Engine
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.engine.OpenFlags
import org.json.JSONArray
import org.json.JSONObject

/**
 * Système de fichiers en mémoire, avec les codes d'erreur du moteur (tests JVM de WriteOps, des sources
 * de fichiers et des copies). Un disque à une partition ext4 se monte par VolumeManager : scan, mount et
 * statfs rendent des réponses valides ; [readOnly], [roReason] et [free] règlent le statfs.
 */
/** Arbre en mémoire : chemin → contenu (null = dossier). */
open class MemEngine : Engine {
    val nodes = sortedMapOf<String, ByteArray?>("/" to null)
    val files = HashMap<Long, String>()
    var next = 1L
    var ops = 0
    /** Disque hostile : liste les enfants d'un chemin (nom, type) sans rapport avec `nodes`. */
    var hostile: ((String) -> List<Pair<String, String>>)? = null
    /** Comme FAT : noms insensibles à la casse (le nom garde la casse donnée à la création ou au renommage). */
    var caseInsensitive = false

    /** Clé existante désignant p (à la casse près si caseInsensitive), ou p. */
    private fun key(p: String) = if (caseInsensitive) nodes.keys.firstOrNull { it.equals(p, ignoreCase = true) } ?: p else p

    private fun s(b: ByteArray) = String(b, Charsets.UTF_8)
    private fun parent(p: String) = p.substring(0, p.lastIndexOf('/')).ifEmpty { "/" }
    private fun children(p: String) = nodes.keys.filter { it != "/" && it != p && parent(it) == p }
    private fun err(c: Int) = """{"err":$c}""".toByteArray()
    private fun entry(p: String) = JSONObject()
        .put("name", p.substring(p.lastIndexOf('/') + 1))
        .put("type", if (nodes[p] == null) "d" else "f")
        .put("size", nodes[p]?.size ?: 0).put("mtime", 0)
        .also { o -> owner?.let { (mode, uid, gid) -> o.put("mode", mode).put("uid", uid).put("gid", gid) } }

    /** (mode, uid, gid) rendus par stat et list ; null : clés absentes. */
    var owner: Triple<Int, Long, Long>? = null
    /** Système de fichiers rendu par statfs. */
    var fs = "ext4"

    override fun version() = "mem"
    override fun strerror(code: Int) = ByteArray(0)
    var readOnly = false
    var roReason = ""
    var free = 1L shl 30
    var total = 2L shl 30
    var partUuid = "uuid-mem"
    /** Code rendu par le n-ième pwrite à venir (1 = le prochain) ; 0 : pas de panne. */
    var failPwriteAt = 0
    var failPwriteCode = EngineError.FL_EIO
    /** Nombre de FL_EBUSY rendus par unlink/rename sur ce chemin avant d'aboutir (fichier encore ouvert). */
    val busy = mutableMapOf<String, Int>()
    private fun busyNow(p: String): Boolean {
        val n = busy[p] ?: return false
        if (n <= 0) return false
        busy[p] = n - 1
        return true
    }

    override fun openImage(path: ByteArray, readOnly: Boolean) = 1L
    override fun openUsb(fd: Int, iface: Int, epIn: Int, epOut: Int) = 0L
    override fun closeDisk(disk: Long) = 0
    override fun scan(disk: Long) = """{"sector_size":512,"size":$total,"table":"gpt","parts":[
        {"index":1,"first_lba":2048,"size":$total,"content":"ext4","label":"Mem","uuid":"$partUuid","supported":true}]}""".toByteArray()
    override fun mount(disk: Long, partIndex: Int, pass: ByteArray?, writable: Boolean) = 7L
    override fun unmount(vol: Long, force: Boolean) = 0
    override fun statfs(vol: Long) =
        """{"total":$total,"free":$free,"label":"Mem","read_only":$readOnly,"ro_reason":"$roReason","needs_recovery":false,"fs":"$fs"}""".toByteArray()
    override fun sync(vol: Long) = 0
    override fun truncate(file: Long, size: Long) = 0

    override fun stat(vol: Long, path: ByteArray): ByteArray {
        val p = key(s(path))
        return if (!nodes.containsKey(p)) err(EngineError.FL_ENOENT) else entry(p).toString().toByteArray()
    }

    override fun list(vol: Long, path: ByteArray): ByteArray {
        val p = s(path)
        hostile?.let { h ->
            val a = JSONArray()
            h(p).forEach { (n, t) -> a.put(JSONObject().put("name", n).put("type", t).put("size", 0).put("mtime", 0)) }
            return a.toString().toByteArray()
        }
        if (!nodes.containsKey(p)) return err(EngineError.FL_ENOENT)
        if (nodes[p] != null) return err(EngineError.FL_ENOTDIR)
        val a = JSONArray()
        children(p).forEach { a.put(entry(it)) }
        return a.toString().toByteArray()
    }

    override fun openFile(vol: Long, path: ByteArray, flags: Int): Long {
        val p = s(path)
        if (!nodes.containsKey(p)) {
            if (flags and OpenFlags.CREAT == 0) return EngineError.FL_ENOENT.toLong()
            if (!nodes.containsKey(parent(p))) return EngineError.FL_ENOENT.toLong()
            nodes[p] = ByteArray(0); ops++
        } else if (nodes[p] == null) {
            return EngineError.FL_EISDIR.toLong()
        } else if (flags and OpenFlags.TRUNC != 0) {
            nodes[p] = ByteArray(0)
        }
        files[next] = p
        return next++
    }

    override fun pread(file: Long, offset: Long, buf: ByteArray, len: Int): Int {
        val d = nodes[files[file] ?: return EngineError.FL_EINVAL] ?: return EngineError.FL_EISDIR
        if (offset >= d.size) return 0
        val n = minOf(len.toLong(), d.size - offset).toInt()
        System.arraycopy(d, offset.toInt(), buf, 0, n)
        return n
    }

    override fun pwrite(file: Long, offset: Long, buf: ByteArray, len: Int): Int {
        val p = files[file] ?: return EngineError.FL_EINVAL
        if (failPwriteAt > 0 && --failPwriteAt == 0) return failPwriteCode
        val d = nodes[p]!!
        val out = d.copyOf(maxOf(d.size, (offset + len).toInt()))
        System.arraycopy(buf, 0, out, offset.toInt(), len)
        nodes[p] = out
        return len
    }

    override fun closeFile(file: Long) = if (files.remove(file) != null) 0 else EngineError.FL_EINVAL

    override fun mkdir(vol: Long, path: ByteArray): Int {
        val p = s(path)
        if (nodes.containsKey(p)) return EngineError.FL_EEXIST
        if (!nodes.containsKey(parent(p))) return EngineError.FL_ENOENT
        nodes[p] = null; ops++
        return 0
    }

    override fun unlink(vol: Long, path: ByteArray): Int {
        val p = s(path)
        if (!nodes.containsKey(p)) return EngineError.FL_ENOENT
        if (nodes[p] == null) return EngineError.FL_EISDIR
        if (busyNow(p)) return EngineError.FL_EBUSY
        nodes.remove(p); ops++
        return 0
    }

    override fun rmdir(vol: Long, path: ByteArray): Int {
        val p = s(path)
        if (!nodes.containsKey(p)) return EngineError.FL_ENOENT
        if (children(p).isNotEmpty()) return EngineError.FL_ENOTEMPTY
        nodes.remove(p); ops++
        return 0
    }

    override fun rename(vol: Long, from: ByteArray, to: ByteArray): Int {
        val f = key(s(from)); val t = s(to)
        if (!nodes.containsKey(f)) return EngineError.FL_ENOENT
        if (nodes.containsKey(key(t)) && key(t) != f) return EngineError.FL_EEXIST
        if (t.startsWith("$f/")) return EngineError.FL_EINVAL
        if (busyNow(f)) return EngineError.FL_EBUSY
        val moved = nodes.keys.filter { it == f || it.startsWith("$f/") }
        for (k in moved) nodes[t + k.substring(f.length)] = nodes.remove(k)
        ops++
        return 0
    }

    /*
     * Faux age (phase 14) : vrai début d'en-tête age (magie, ligne scrypt avec log2 N, reconnus par CryptFormats), puis
     * « --- » et 8 octets de SHA-256 de la phrase en hexadécimal, puis le clair XOR la phrase. Réversible, phrase fausse
     * détectée (FL_EBADPASS), écriture abandonnée illisible (en-tête incomplet, FL_ECORRUPT). Sur les fichiers
     * du moteur seulement (descripteurs : FL_ENOTSUP). Comme le moteur, chaque phrase reçue est mise à zéro et la
     * poignée de fichier est fermée avec la poignée age, ou tout de suite en cas d'échec.
     */
    private class AgeW(val file: Long, val pass: ByteArray, val log2n: Int) { val data = java.io.ByteArrayOutputStream() }
    private class AgeR(val file: Long, val plain: ByteArray)
    private val ageWriters = HashMap<Long, AgeW>()
    private val ageReaders = HashMap<Long, AgeR>()
    /** Phrases reçues (copies faites avant la mise à zéro), pour les tests. */
    val agePasses = mutableListOf<String>()

    protected fun tag(pass: ByteArray): String =
        java.security.MessageDigest.getInstance("SHA-256").digest(pass).copyOf(8).joinToString("") { "%02x".format(it) }
    protected fun xor(d: ByteArray, pass: ByteArray) = ByteArray(d.size) { (d[it].toInt() xor pass[it % pass.size].toInt()).toByte() }
    protected fun take(pass: ByteArray): ByteArray = pass.copyOf().also { agePasses.add(String(it, Charsets.UTF_8)); pass.fill(0) }

    protected fun ageHead(log2n: Int) = "age-encryption.org/v1\n-> scrypt c2FsdHNhbHRzYWx0c2FsdA $log2n\n".toByteArray(Charsets.US_ASCII)

    protected fun ageEncode(plain: ByteArray, pass: ByteArray, log2n: Int): ByteArray =
        ageHead(log2n) + "--- ${tag(pass)}\n".toByteArray(Charsets.US_ASCII) + xor(plain, pass)

    /** Clair, ou fl_err. */
    protected fun ageDecode(d: ByteArray, pass: ByteArray): Any {
        val head = String(d, 0, minOf(d.size, 200), Charsets.ISO_8859_1)
        if (!head.startsWith("age-encryption.org/v1\n")) return EngineError.FL_ENOTSUP
        val at = head.indexOf("\n--- ")
        // « \n--- » fait 5 caractères ; puis 16 chiffres hexadécimaux et un saut de ligne
        if (at < 0 || head.length < at + 22 || head[at + 21] != '\n') return EngineError.FL_ECORRUPT
        if (head.substring(at + 5, at + 21) != tag(pass)) return EngineError.FL_EBADPASS
        return xor(d.copyOfRange(at + 22, d.size), pass)
    }

    override fun ageWriterOpenFile(file: Long, pass: ByteArray, log2n: Int): Long {
        val p = take(pass)
        if (files[file] == null || p.isEmpty()) {
            closeFile(file)
            return EngineError.FL_EINVAL.toLong()
        }
        ageWriters[next] = AgeW(file, p, log2n)
        return next++
    }

    override fun ageWrite(w: Long, buf: ByteArray, len: Int): Int {
        val a = ageWriters[w] ?: return EngineError.FL_EINVAL
        if (failPwriteAt > 0 && --failPwriteAt == 0) return failPwriteCode
        a.data.write(buf, 0, len)
        return 0
    }

    override fun ageWriterClose(w: Long, commit: Boolean): Int {
        val a = ageWriters.remove(w) ?: return EngineError.FL_EINVAL
        val out = if (commit) ageEncode(a.data.toByteArray(), a.pass, a.log2n) else ageHead(a.log2n)
        nodes[files[a.file]!!] = out
        a.pass.fill(0)
        return closeFile(a.file)
    }

    override fun ageReaderOpenFile(file: Long, size: Long, pass: ByteArray): Long {
        val p = take(pass)
        val d = files[file]?.let { nodes[it] }
        val r = if (d == null) EngineError.FL_EINVAL else ageDecode(d, p)
        p.fill(0)
        if (r !is ByteArray) {
            closeFile(file)
            return (r as Int).toLong()
        }
        ageReaders[next] = AgeR(file, r)
        return next++
    }

    override fun ageSize(r: Long): Long = ageReaders[r]?.plain?.size?.toLong() ?: EngineError.FL_EINVAL.toLong()

    override fun agePread(r: Long, offset: Long, buf: ByteArray, len: Int): Int {
        val a = ageReaders[r] ?: return EngineError.FL_EINVAL
        if (offset >= a.plain.size) return 0
        val n = minOf(len.toLong(), a.plain.size - offset).toInt()
        System.arraycopy(a.plain, offset.toInt(), buf, 0, n)
        return n
    }

    override fun ageReaderClose(r: Long): Int {
        val a = ageReaders.remove(r) ?: return EngineError.FL_EINVAL
        return closeFile(a.file)
    }

    override fun agePeekFile(file: Long, size: Long): Int {
        val d = files[file]?.let { nodes[it] } ?: return EngineError.FL_EINVAL
        return com.mawena.fluluks.crypt.CryptFormats.ageWorkFactor(d) ?: 0
    }

    override fun ageRewrap(inFd: Int, inFile: Long, inSize: Long, outFd: Int, outFile: Long, old: ByteArray, new: ByteArray,
                           log2n: Int): Int {
        val o = take(old)
        val n = take(new)
        val d = files[inFile]?.let { nodes[it] }
        val plain = if (inFd >= 0 || outFd >= 0 || d == null || files[outFile] == null) EngineError.FL_EINVAL else ageDecode(d, o)
        val rc = if (plain is ByteArray) {
            nodes[files[outFile]!!] = ageEncode(plain, n, log2n)
            0
        } else plain as Int
        o.fill(0)
        n.fill(0)
        if (inFile > 0) closeFile(inFile)
        if (outFile > 0) closeFile(outFile)
        return rc
    }
}
