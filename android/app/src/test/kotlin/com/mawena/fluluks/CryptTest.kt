package com.mawena.fluluks

import com.mawena.fluluks.crypt.Crypt
import com.mawena.fluluks.crypt.CryptFormats
import com.mawena.fluluks.engine.ArcMode
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.files.Archives
import com.mawena.fluluks.files.FileSource
import com.mawena.fluluks.files.Files
import com.mawena.fluluks.files.FilesException
import com.mawena.fluluks.files.LocalSource
import com.mawena.fluluks.files.NativeIn
import com.mawena.fluluks.files.NativeOut
import com.mawena.fluluks.files.TransferState
import com.mawena.fluluks.files.Transfers
import com.mawena.fluluks.volumes.VolumeManager
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.util.Base64
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Chiffrer, déchiffrer, vérifier et changer le mot de passe (phase 14, T5) entre une source locale (dossier temporaire)
 * et un dossier « distant » (tube), avec un faux moteur réversible : age par XOR (MemEngine) et un faux ZIP (en-tête
 * local réel, entrées en JSON), en clair, en AES (données XOR la phrase) ou dans age.
 */
class CryptTest {
    @get:Rule val tmp = TemporaryFolder()

    /** Faux moteur : flux age et archives sur des descripteurs simulés (fichiers), des tubes et des fichiers du moteur. */
    private class Engine : MemEngine() {
        val fds = HashMap<Int, File>()
        val closedFds = HashSet<Int>()
        private val pipes = HashMap<Int, PipedOutputStream>()
        private var nextFd = 100
        private var nextH = 9000L
        var onAgeWrite: (Int) -> Unit = {}
        var ageWrites = 0
        var onAgeReaderOpen: () -> Unit = {}
        /** Code rendu par le n-ième ageWrite (1 = le prochain) ; 0 : jamais. */
        var failAgeWriteAt = 0
        /** Le chiffré écrit est abîmé (une donnée retournée) : la vérification doit le voir. */
        var corruptOutput = false

        fun openFd(f: File, write: Boolean): Int {
            val fd = nextFd++
            fds[fd] = f
            if (write) f.writeBytes(ByteArray(0))
            return fd
        }

        fun pipe(): Pair<Int, InputStream> {
            val fd = nextFd++
            fds[fd] = File("tube-$fd")
            val out = PipedOutputStream()
            pipes[fd] = out
            return fd to PipedInputStream(out, 1 shl 16)
        }

        private fun closeFd(fd: Int) {
            pipes.remove(fd)?.close()
            closedFds.add(fd)
        }

        private fun bytesOf(fd: Int, file: Long): ByteArray? =
            if (fd >= 0) fds[fd]?.takeIf { it.exists() }?.readBytes() else files[file]?.let { nodes[it] }

        private fun store(fd: Int, file: Long, b: ByteArray) {
            when {
                fd in pipes -> pipes[fd]!!.write(b)
                fd >= 0 -> fds[fd]!!.writeBytes(b)
                else -> nodes[files[file]!!] = b
            }
        }

        private fun release(fd: Int, file: Long) {
            if (fd >= 0) closeFd(fd) else closeFile(file)
        }

        private fun damage(b: ByteArray) = if (corruptOutput && b.isNotEmpty()) b.copyOf().also { it[it.size - 1] = (it[it.size - 1] + 1).toByte() } else b

        // --- age sur descripteur (les fichiers du moteur passent par MemEngine) ---
        private class W(val fd: Int, val pass: ByteArray, val log2n: Int) { val data = ByteArrayOutputStream() }
        private class R(val fd: Int, val file: Long, val plain: ByteArray)
        private val ws = HashMap<Long, W>()
        private val rs = HashMap<Long, R>()

        override fun ageWriterOpenFd(fd: Int, pass: ByteArray, log2n: Int): Long {
            val p = take(pass)
            ws[nextH] = W(fd, p, log2n)
            return nextH++
        }

        override fun ageWriterOpenFile(file: Long, pass: ByteArray, log2n: Int): Long {
            val p = take(pass)
            ws[nextH] = W(-1, p, log2n).also { fileOf[it] = file }
            return nextH++
        }

        private val fileOf = HashMap<W, Long>()

        override fun ageWrite(w: Long, buf: ByteArray, len: Int): Int {
            val a = ws[w] ?: return EngineError.FL_EINVAL
            onAgeWrite(++ageWrites)
            if (failAgeWriteAt > 0 && --failAgeWriteAt == 0) return EngineError.FL_EIO
            a.data.write(buf, 0, len)
            return 0
        }

        override fun ageWriterClose(w: Long, commit: Boolean): Int {
            val a = ws.remove(w) ?: return EngineError.FL_EINVAL
            val file = fileOf.remove(a) ?: 0L
            store(a.fd, file, if (commit) damage(ageEncode(a.data.toByteArray(), a.pass, a.log2n)) else ageHead(a.log2n))
            a.pass.fill(0)
            release(a.fd, file)
            return 0
        }

        private fun openReader(fd: Int, file: Long, pass: ByteArray): Long {
            onAgeReaderOpen()
            val p = take(pass)
            val b = bytesOf(fd, file)
            val r = if (b == null) EngineError.FL_EINVAL else ageDecode(b, p)
            p.fill(0)
            if (r !is ByteArray) {
                release(fd, file)
                return (r as Int).toLong()
            }
            rs[nextH] = R(fd, file, r)
            return nextH++
        }

        override fun ageReaderOpenFd(fd: Int, pass: ByteArray) = openReader(fd, -1, pass)
        override fun ageReaderOpenFile(file: Long, size: Long, pass: ByteArray) = openReader(-1, file, pass)
        override fun ageSize(r: Long): Long = rs[r]?.plain?.size?.toLong() ?: EngineError.FL_EINVAL.toLong()

        override fun agePread(r: Long, offset: Long, buf: ByteArray, len: Int): Int {
            val a = rs[r] ?: return EngineError.FL_EINVAL
            if (offset >= a.plain.size) return 0
            val n = minOf(len.toLong(), a.plain.size - offset).toInt()
            System.arraycopy(a.plain, offset.toInt(), buf, 0, n)
            return n
        }

        override fun ageReaderClose(r: Long): Int {
            val a = rs.remove(r) ?: return EngineError.FL_EINVAL
            release(a.fd, a.file)
            return 0
        }

        override fun ageRewrap(inFd: Int, inFile: Long, inSize: Long, outFd: Int, outFile: Long, old: ByteArray, new: ByteArray,
                               log2n: Int): Int {
            val o = take(old)
            val n = take(new)
            val b = bytesOf(inFd, inFile)
            val plain = if (b == null) EngineError.FL_EINVAL else ageDecode(b, o)
            val rc = if (plain is ByteArray) {
                store(outFd, outFile, ageEncode(plain, n, log2n))
                0
            } else plain as Int
            release(inFd, inFile)
            release(outFd, outFile)
            return rc
        }

        // --- faux ZIP : en-tête local réel (drapeau et méthode AES), puis les entrées en JSON ---
        private class AW(val fd: Int, val file: Long, val mode: Int, val pass: ByteArray?) {
            val adds = ArrayList<JSONObject>()
            val data = ArrayList<ByteArrayOutputStream>()
        }
        private class AR(val fd: Int, val file: Long, val entries: JSONArray, val aes: Boolean, val pass: ByteArray?) {
            var idx = -1
            var pos = 0
        }
        private val aws = HashMap<Long, AW>()
        private val ars = HashMap<Long, AR>()
        val openHandles get() = ws.size + rs.size + aws.size + ars.size

        private fun zip(entries: JSONArray, aes: Boolean, tag: String): ByteArray {
            val json = JSONObject().put("tag", tag).put("e", entries).toString().toByteArray()
            val h = ByteArray(30)
            "PK\u0003\u0004".toByteArray().copyInto(h)
            if (aes) { h[6] = 1; h[8] = 99 }
            for (i in 0..3) { h[18 + i] = (json.size shr (8 * i)).toByte(); h[22 + i] = (json.size shr (8 * i)).toByte() }
            return h + json
        }

        private fun openW(fd: Int, file: Long, mode: Int, pass: ByteArray?): Long {
            val p = pass?.let { take(it) }
            if (mode != ArcMode.PLAIN && (p == null || p.isEmpty())) {
                release(fd, file)
                return EngineError.FL_EINVAL.toLong()
            }
            aws[nextH] = AW(fd, file, mode, p)
            return nextH++
        }

        override fun arcwOpenFd(fd: Int, mode: Int, pass: ByteArray?) = openW(fd, -1, mode, pass)
        override fun arcwOpenFile(file: Long, mode: Int, pass: ByteArray?) = openW(-1, file, mode, pass)

        override fun arcwAdd(arc: Long, json: ByteArray): Int {
            val w = aws[arc] ?: return EngineError.FL_EINVAL
            w.adds.add(JSONObject(String(json, Charsets.UTF_8)))
            w.data.add(ByteArrayOutputStream())
            return 0
        }

        override fun arcwWrite(arc: Long, buf: ByteArray, len: Int): Int {
            val w = aws[arc] ?: return EngineError.FL_EINVAL
            w.data.last().write(buf, 0, len)
            return 0
        }

        override fun arcwClose(arc: Long, commit: Boolean): Int {
            val w = aws.remove(arc) ?: return EngineError.FL_EINVAL
            if (commit) {
                val aes = w.mode == ArcMode.AES
                val e = JSONArray()
                for ((i, a) in w.adds.withIndex()) {
                    val d = w.data[i].toByteArray().let { if (aes && a.getString("type") == "f") xor(it, w.pass!!) else it }
                    e.put(JSONObject(a.toString()).put("data", Base64.getEncoder().encodeToString(d)))
                }
                val z = zip(e, aes, if (aes) tag(w.pass!!) else "")
                store(w.fd, w.file, damage(if (w.mode == ArcMode.AGE) ageEncode(z, w.pass!!, 18) else z))
            }
            w.pass?.fill(0)
            release(w.fd, w.file)
            return 0
        }

        private fun openR(fd: Int, file: Long, mode: Int, pass: ByteArray?): Long {
            val p = pass?.let { take(it) }
            var b = bytesOf(fd, file)
            if (b != null && mode == ArcMode.AGE) {
                val r = if (p == null) EngineError.FL_EINVAL else ageDecode(b, p)
                if (r !is ByteArray) {
                    release(fd, file)
                    return (r as Int).toLong()
                }
                b = r
            }
            if (b == null || b.size < 30 || b[0] != 'P'.code.toByte()) {
                release(fd, file)
                return EngineError.FL_ENOTSUP.toLong()
            }
            val o = try {
                JSONObject(String(b, 30, b.size - 30, Charsets.UTF_8))
            } catch (e: Exception) {
                release(fd, file)
                return EngineError.FL_ECORRUPT.toLong()
            }
            val aes = b[8] == 99.toByte()
            val ok = !aes || (p != null && tag(p) == o.getString("tag"))
            ars[nextH] = AR(fd, file, o.getJSONArray("e"), aes, if (ok) p else null)
            return nextH++
        }

        override fun arcOpenFd(fd: Int, mode: Int, pass: ByteArray?) = openR(fd, -1, mode, pass)
        override fun arcOpenFile(file: Long, size: Long, mode: Int, pass: ByteArray?) = openR(-1, file, mode, pass)

        override fun arcNext(arc: Long): ByteArray? {
            val r = ars[arc] ?: return """{"err":${EngineError.FL_EINVAL}}""".toByteArray()
            r.idx++
            r.pos = 0
            if (r.idx >= r.entries.length()) return null
            val e = r.entries.getJSONObject(r.idx)
            return JSONObject().put("name", Base64.getEncoder().encodeToString(e.getString("name").toByteArray()))
                .put("type", e.getString("type")).put("size", e.getLong("size")).put("mtime", e.optLong("mtime"))
                .put("encrypted", r.aes && e.getString("type") == "f").put("raw", false).toString().toByteArray()
        }

        override fun arcRead(arc: Long, buf: ByteArray, len: Int): Int {
            val r = ars[arc] ?: return EngineError.FL_EINVAL
            val e = r.entries.getJSONObject(r.idx)
            var d = Base64.getDecoder().decode(e.getString("data"))
            if (r.aes && e.getString("type") == "f") {
                val p = r.pass ?: return EngineError.FL_EBADPASS
                d = xor(d, p)
            }
            val n = minOf(len, d.size - r.pos)
            if (n <= 0) return 0
            System.arraycopy(d, r.pos, buf, 0, n)
            r.pos += n
            return n
        }

        override fun arcClose(arc: Long): Int {
            val r = ars.remove(arc) ?: return EngineError.FL_EINVAL
            r.pass?.fill(0)
            release(r.fd, r.file)
            return 0
        }

        fun pipesClosed() = pipes.isEmpty()
    }

    private lateinit var e: Engine
    private val root: File get() = File(tmp.root, "racine")
    private val remoteRoot: File get() = File(tmp.root, "distant")
    private lateinit var local: LocalSource

    /** Source qui note chaque création et chaque renommage (destination des essais « rien en clair ailleurs »). */
    private inner class Recording(val inner: FileSource) : FileSource by inner {
        val created = ArrayList<String>()
        val renamed = ArrayList<Pair<String, String>>()
        override fun createNative(parent: String, name: String): Pair<String, NativeOut> =
            inner.createNative(parent, name).also { created.add(name) }
        override fun createFile(parent: String, name: String): Pair<String, OutputStream> =
            inner.createFile(parent, name).also { created.add(name) }
        override fun rename(path: String, newName: String): String = inner.rename(path, newName).also { renamed.add(path to newName) }
    }

    /** « Dossier distant » : lu par un descripteur mandataire, écrit par un tube. */
    private inner class RemoteLike(val inner: LocalSource) : FileSource by inner {
        override val id = "remote"
        override fun space() = -1L to -1L
        override fun openNative(path: String): NativeIn =
            NativeIn.Proxy(inner.stat(path)!!.size) { e.openFd(File(remoteRoot, path.substring(1)), false) }
        override fun createNative(parent: String, name: String): Pair<String, NativeOut> {
            val (p, out) = inner.createFile(parent, name)
            return p to NativeOut.Pipe(out) { }
        }
    }

    private var recording: Recording? = null

    @Before fun setup() {
        root.mkdir()
        remoteRoot.mkdir()
        e = Engine()
        VolumeManager.resetForTests(e, delayer = FakeDelayer())
        Transfers.resetForTests()
        Archives.resetForTests(e, e::openFd, e::pipe)
        Crypt.isOpenVaultFile = { _, _ -> false }
        local = LocalSource("phone", "phone", "Téléphone", root) { true }
        val remote = RemoteLike(LocalSource("remote", "remote", "Serveur", remoteRoot) { true })
        Files.setResolverForTests { id ->
            when (id) {
                "phone" -> recording ?: local
                "remote" -> remote
                else -> null
            }
        }
    }

    @After fun teardown() {
        Transfers.resetForTests()
        Archives.resetForTests(null, null, null)
        Files.setResolverForTests(null)
        Crypt.isOpenVaultFile = { id, p -> com.mawena.fluluks.vaults.Vaults.isOpenFile(id, p) } // crochet rendu aux coffres
    }

    private fun u(s: String) = s.toByteArray(Charsets.UTF_8)
    private val pass get() = u("phrase secrète")
    private fun data(n: Int, seed: Int = 7) = ByteArray(n) { (it * seed + it / 4093).toByte() }
    private fun put(path: String, bytes: ByteArray) = File(root, path).apply { parentFile!!.mkdirs(); writeBytes(bytes) }
    private fun names(dir: File = root) = dir.list()!!.sorted()

    private fun await(): TransferState {
        val end = System.currentTimeMillis() + 10_000
        while (true) {
            val s = Transfers.state.value
            if (s != null && s.finished && !Transfers.isBusy("phone") && !Transfers.isBusy("remote")) return s
            check(System.currentTimeMillis() < end) { "délai dépassé : $s" }
            Thread.sleep(10)
        }
    }

    private fun encrypt(paths: List<String>, format: String = "age", together: Boolean = false, name: String? = null,
                        delete: Boolean = false, dstId: String = "phone", dir: String = "/", pw: ByteArray = pass): TransferState {
        Crypt.startEncrypt(Crypt.EncryptRequest("phone", paths, dstId, dir, format, together, name, delete), pw)
        return await()
    }

    private fun decrypt(path: String, srcId: String = "phone", extract: Boolean = true, pw: ByteArray = pass): TransferState {
        Crypt.startDecrypt(srcId, path, "phone", "/out", pw, extract)
        return await()
    }

    /** Aucun flux du moteur, aucun descripteur ni tube laissé ouvert, aucun fichier partiel. */
    private fun noLeak() {
        assertEquals(0, e.openHandles)
        assertTrue(e.files.isEmpty())
        assertEquals(e.fds.keys, e.closedFds)
        assertTrue(e.pipesClosed())
        assertEquals(emptyList<File>(), tmp.root.walk().filter { it.name.endsWith(Transfers.PARTIAL_SUFFIX) }.toList())
    }

    /** Vrai si [hay] contient [needle] (fenêtre de 64 octets du clair). */
    private fun contains(hay: ByteArray, needle: ByteArray): Boolean {
        if (needle.size > hay.size) return false
        outer@ for (i in 0..hay.size - needle.size) {
            for (j in needle.indices) if (hay[i + j] != needle[j]) continue@outer
            return true
        }
        return false
    }

    @Test fun encryptFileToAgeSameFolder() {
        val d = data(300_000)
        put("rapport.pdf", d)
        put("rapport.pdf.age", u("déjà là"))
        val s = encrypt(listOf("/rapport.pdf"))
        assertNull(s.error)
        assertEquals("encrypt", s.kind)
        val out = names().filter { it != "rapport.pdf" && it != "rapport.pdf.age" }
        assertEquals(1, out.size)
        assertTrue(out[0], out[0].startsWith("rapport.pdf") && out[0].endsWith(".age"))
        assertEquals(out[0], s.currentName) // nom final rendu à l'écran (Partager le fichier chiffré)
        assertEquals("age", CryptFormats.detect(File(root, out[0]).readBytes()))
        assertArrayEquals(d, File(root, "rapport.pdf").readBytes()) // original gardé (pas demandé)
        File(root, "out").mkdir()
        assertNull(decrypt("/${out[0]}").error)
        assertArrayEquals(d, File(root, "out/${CryptFormats.plainName(out[0])}").readBytes())
        noLeak()
    }

    private fun tree() {
        put("photos/a.jpg", data(5000, 3))
        put("photos/sous/b.txt", u("bonjour"))
        File(root, "photos/vide").mkdirs()
    }

    @Test fun encryptFolderToZipAge() {
        tree()
        assertNull(encrypt(listOf("/photos")).error)
        assertTrue(names().toString(), "photos.zip.age" in names())
        val info = Crypt.info("phone", "/photos.zip.age")
        assertEquals("age", info.format)
        assertTrue(info.folder)
        assertEquals(18, info.workFactor)
        File(root, "out").mkdir()
        val s = decrypt("/photos.zip.age")
        assertNull(s.error)
        assertArrayEquals(data(5000, 3), File(root, "out/photos/a.jpg").readBytes())
        assertEquals("bonjour", File(root, "out/photos/sous/b.txt").readText())
        assertTrue(File(root, "out/photos/vide").isDirectory)
        noLeak()
    }

    @Test fun encryptSelectionTogether() {
        put("a.txt", u("aaa"))
        put("b.txt", u("bbb"))
        assertNull(encrypt(listOf("/a.txt", "/b.txt"), together = true).error)
        assertTrue(names().toString(), "Archive.zip.age" in names())
        assertNull(encrypt(listOf("/a.txt", "/b.txt"), together = true, name = "Vacances").error)
        assertTrue(names().toString(), "Vacances.zip.age" in names())
        File(root, "out").mkdir()
        assertNull(decrypt("/Vacances.zip.age").error)
        assertEquals("bbb", File(root, "out/Vacances/b.txt").readText())
        noLeak()
    }

    @Test fun encryptToZipAes() {
        val d = data(10_000)
        put("rapport.pdf", d)
        assertNull(encrypt(listOf("/rapport.pdf"), format = "zip").error)
        val z = File(root, "rapport.zip")
        assertTrue(names().toString(), z.exists())
        assertEquals("zip-aes", CryptFormats.detect(z.readBytes()))
        assertFalse(contains(z.readBytes(), d.copyOf(64)))
        File(root, "out").mkdir()
        assertNull(decrypt("/rapport.zip").error)
        assertArrayEquals(d, File(root, "out/rapport/rapport.pdf").readBytes())
        noLeak()
    }

    @Test fun encryptToRemoteDestination() {
        val d = data(200_000)
        put("x.bin", d)
        assertNull(encrypt(listOf("/x.bin"), dstId = "remote").error)
        assertEquals(listOf("x.bin.age"), remoteRoot.list()!!.toList())
        File(root, "out").mkdir()
        assertNull(decrypt("/x.bin.age", srcId = "remote").error)
        assertArrayEquals(d, File(root, "out/x.bin").readBytes())
        noLeak()
    }

    @Test fun noPlaintextOutsideDestination() {
        val d = data(400_000)
        put("secret.doc", d)
        val rec = Recording(local).also { recording = it }
        assertNull(encrypt(listOf("/secret.doc")).error)
        assertEquals(listOf(Transfers.partialName("secret.doc.age")), rec.created)
        assertEquals(listOf("/${Transfers.partialName("secret.doc.age")}" to "secret.doc.age"), rec.renamed)
        // rien d'autre n'existe nulle part, et le chiffré ne contient pas le clair
        val all = tmp.root.walk().filter { it.isFile }.map { it.relativeTo(tmp.root).path }.sorted().toList()
        assertEquals(listOf("racine/secret.doc", "racine/secret.doc.age"), all)
        val enc = File(root, "secret.doc.age").readBytes()
        for (off in listOf(0, 100_000, 399_000)) assertFalse(contains(enc, d.copyOfRange(off, off + 64)))
        noLeak()
    }

    @Test fun partialRemovedOnFailureAndCancel() {
        put("gros.bin", data(3 shl 20))
        e.failAgeWriteAt = 2
        val s = encrypt(listOf("/gros.bin"))
        assertTrue(s.error != null)
        assertEquals(listOf("gros.bin"), names())
        e.onAgeWrite = { if (it == 3) Transfers.cancel() }
        val c = encrypt(listOf("/gros.bin"))
        assertTrue(c.cancelled)
        assertEquals(listOf("gros.bin"), names())
        noLeak()
    }

    @Test fun originalKeptUntilVerified() {
        put("a.txt", u("contenu du fichier"))
        var seenAtVerify = false
        e.onAgeReaderOpen = { seenAtVerify = File(root, "a.txt").exists() }
        assertNull(encrypt(listOf("/a.txt"), delete = true).error)
        assertTrue(seenAtVerify)
        assertEquals(listOf("a.txt.age"), names())
        noLeak()
    }

    @Test fun originalKeptIfChangedDuringEncrypt() {
        val f = put("journal.log", data(2 shl 20))
        e.onAgeWrite = { if (it == 1) { f.appendBytes(u("une ligne de plus")); f.setLastModified(f.lastModified() + 5000) } }
        val s = encrypt(listOf("/journal.log"), delete = true)
        assertEquals(Crypt.MSG_ORIGINAL_CHANGED, s.error)
        assertTrue(f.exists())
        assertTrue("journal.log.age" in names())
        noLeak()
    }

    @Test fun originalKeptIfVerifyFails() {
        put("a.txt", data(5000))
        e.corruptOutput = true
        val s = encrypt(listOf("/a.txt"), delete = true)
        assertEquals(Crypt.MSG_VERIFY_FAILED, s.error)
        assertEquals(listOf("a.txt"), names())
        // ZIP aussi
        val z = encrypt(listOf("/a.txt"), format = "zip", delete = true)
        assertEquals(Crypt.MSG_VERIFY_FAILED, z.error)
        assertEquals(listOf("a.txt"), names())
        noLeak()
    }

    @Test fun deleteOriginalIsPermanentNotTrash() {
        val d = data(50_000)
        put("dossier/a.bin", d)
        assertNull(encrypt(listOf("/dossier"), delete = true).error)
        assertEquals(listOf("dossier.zip.age"), names())
        // aucune copie en clair nulle part (corbeille comprise)
        for (f in tmp.root.walk().filter { it.isFile }) assertFalse(f.path, contains(f.readBytes(), d.copyOf(64)))
        noLeak()
    }

    @Test fun openVaultFileNeverEncrypted() {
        put("coffre.luks", data(1000))
        Crypt.isOpenVaultFile = { id, p -> id == "phone" && p == "/coffre.luks" }
        val s = encrypt(listOf("/coffre.luks"))
        assertEquals(Crypt.MSG_VAULT_OPEN, s.error)
        assertEquals(listOf("coffre.luks"), names())
        noLeak()
    }

    @Test fun decryptAgeFile() {
        val d = data(123_456)
        put("x.pdf", d)
        assertNull(encrypt(listOf("/x.pdf"), delete = true).error)
        File(root, "out").mkdir()
        val s = decrypt("/x.pdf.age")
        assertNull(s.error)
        assertEquals("decrypt", s.kind)
        assertArrayEquals(d, File(root, "out/x.pdf").readBytes())
        assertTrue(File(root, "x.pdf.age").exists()) // le chiffré reste
        noLeak()
    }

    @Test fun decryptFolderExtractsWithoutZip() {
        tree()
        assertNull(encrypt(listOf("/photos"), delete = true).error)
        File(root, "out").mkdir()
        assertNull(decrypt("/photos.zip.age").error)
        assertFalse(tmp.root.walk().any { it.name.endsWith(".zip") })
        assertEquals("bonjour", File(root, "out/photos/sous/b.txt").readText())
        noLeak()
    }

    @Test fun decryptKeepZipWhenAsked() {
        tree()
        assertNull(encrypt(listOf("/photos")).error)
        File(root, "out").mkdir()
        assertNull(decrypt("/photos.zip.age", extract = false).error)
        val z = File(root, "out/photos.zip")
        assertTrue(z.exists())
        assertEquals("none", CryptFormats.detect(z.readBytes())) // un ZIP en clair, prêt à ouvrir ailleurs
        noLeak()
    }

    @Test fun wrongPasswordIsBadPassword() {
        put("x.pdf", data(1000))
        assertNull(encrypt(listOf("/x.pdf")).error)
        File(root, "out").mkdir()
        val s = decrypt("/x.pdf.age", pw = u("mauvaise phrase"))
        assertTrue(s.badPassword)
        assertEquals(Crypt.MSG_BAD_PASSWORD, s.error)
        // ZIP AES : les noms se lisent, les données refusent
        assertNull(encrypt(listOf("/x.pdf"), format = "zip").error)
        val z = decrypt("/x.zip", pw = u("mauvaise phrase"))
        assertTrue(z.badPassword)
        assertEquals(Crypt.MSG_BAD_PASSWORD, z.error)
        assertEquals(emptyList<String>(), File(root, "out").walk().filter { it.isFile }.toList().map { it.name })
        // une erreur ordinaire n'est pas un mauvais mot de passe
        val n = decrypt("/x.pdf")
        assertFalse(n.badPassword)
        assertEquals(Crypt.MSG_NOT_ENCRYPTED, n.error)
        noLeak()
    }

    @Test fun verifyReportsIntactOrDamaged() {
        put("x.pdf", data(1000))
        assertNull(encrypt(listOf("/x.pdf")).error)
        Crypt.startVerify("phone", "/x.pdf.age", pass)
        val ok = await()
        assertEquals("verify", ok.kind)
        assertNull(ok.error)
        // fichier tronqué : en-tête incomplet
        val f = File(root, "x.pdf.age")
        f.writeBytes(f.readBytes().copyOf(40))
        Crypt.startVerify("phone", "/x.pdf.age", pass)
        assertEquals(Crypt.MSG_DAMAGED, await().error)
        Crypt.startVerify("phone", "/x.pdf", pass)
        assertEquals(Crypt.MSG_NOT_ENCRYPTED, await().error)
        noLeak()
    }

    @Test fun changePasswordReplacesAtomically() {
        val d = data(77_777)
        put("x.pdf", d)
        assertNull(encrypt(listOf("/x.pdf"), delete = true).error)
        val before = File(root, "x.pdf.age").readBytes()
        // ancien mot de passe faux : rien ne change
        try {
            runBlocking { Crypt.changePassword("phone", "/x.pdf.age", u("faux mot de passe"), u("nouvelle phrase")) }
            fail("mot de passe faux accepté")
        } catch (x: FilesException) {
            assertEquals(EngineError.FL_EBADPASS, x.code)
        }
        assertArrayEquals(before, File(root, "x.pdf.age").readBytes())
        assertEquals(listOf("x.pdf.age"), names())
        runBlocking { Crypt.changePassword("phone", "/x.pdf.age", pass, u("nouvelle phrase")) }
        assertEquals(listOf("x.pdf.age"), names())
        File(root, "out").mkdir()
        assertTrue(decrypt("/x.pdf.age").badPassword)
        assertNull(decrypt("/x.pdf.age", pw = u("nouvelle phrase")).error)
        assertArrayEquals(d, File(root, "out/x.pdf").readBytes())
        noLeak()
    }

    @Test fun passwordsZeroedOnAllPaths() {
        put("x.pdf", data(1000))
        fun zero(a: ByteArray) = assertTrue("mot de passe non effacé", a.all { it == 0.toByte() })
        var p = pass
        encrypt(listOf("/x.pdf"), pw = p); zero(p)
        p = u("court")
        try { Crypt.startEncrypt(Crypt.EncryptRequest("phone", listOf("/x.pdf"), "phone", "/", "age", false, null, false), p) } catch (_: FilesException) {}
        zero(p)
        p = pass
        try { Crypt.startEncrypt(Crypt.EncryptRequest("phone", listOf("/x.pdf"), "phone", "/", "rot13", false, null, false), p) } catch (_: FilesException) {}
        zero(p)
        File(root, "out").mkdir()
        p = u("mauvaise phrase"); decrypt("/x.pdf.age", pw = p); zero(p)
        p = pass; decrypt("/x.pdf.age", pw = p); zero(p)
        p = pass; Crypt.startVerify("phone", "/x.pdf.age", p); await(); zero(p)
        val o = pass
        val n = u("nouvelle phrase")
        runBlocking { Crypt.changePassword("phone", "/x.pdf.age", o, n) }
        zero(o); zero(n)
        val o2 = u("faux mot de passe")
        val n2 = u("autre phrase")
        runCatching { runBlocking { Crypt.changePassword("phone", "/x.pdf.age", o2, n2) } }
        zero(o2); zero(n2)
        // créneau pris : le mot de passe est effacé quand même
        e.onAgeWrite = { Thread.sleep(50) }
        put("gros.bin", data(1 shl 20))
        Crypt.startEncrypt(Crypt.EncryptRequest("phone", listOf("/gros.bin"), "phone", "/", "age", false, null, false), pass)
        p = pass
        try { Crypt.startDecrypt("phone", "/x.pdf.age", "phone", "/out", p, true); fail("créneau pris accepté") } catch (_: FilesException) {}
        zero(p)
        await()
        noLeak()
    }

    @Test fun lowMemoryRefusesScrypt() {
        put("x.pdf", data(1000))
        VolumeManager.resetForTests(e, availMem = { 200L shl 20 }, delayer = FakeDelayer()) // 0,8 × 200 Mio < 256 Mio
        val p = pass
        try {
            Crypt.startEncrypt(Crypt.EncryptRequest("phone", listOf("/x.pdf"), "phone", "/", "age", false, null, false), p)
            fail("chiffrement accepté sans mémoire")
        } catch (x: FilesException) {
            assertEquals(Crypt.MSG_LOW_MEMORY, x.message)
        }
        assertTrue(p.all { it == 0.toByte() })
        // le ZIP AES n'utilise pas scrypt
        assertNull(encrypt(listOf("/x.pdf"), format = "zip").error)
        noLeak()
    }

    @Test fun autoLockWaitsForCrypt() {
        put("gros.bin", data(2 shl 20))
        var busy = false
        e.onAgeWrite = { busy = busy || Transfers.isBusy("phone") }
        assertNull(encrypt(listOf("/gros.bin")).error)
        assertTrue(busy)
        assertFalse(Transfers.isBusy("phone"))
        noLeak()
    }
}
