package com.mawena.fluluks

import com.mawena.fluluks.crypt.DecryptedSource
import com.mawena.fluluks.crypt.DecryptedSources
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.engine.FileType
import com.mawena.fluluks.files.Archives
import com.mawena.fluluks.files.DiskSource
import com.mawena.fluluks.files.FileSource
import com.mawena.fluluks.files.Files
import com.mawena.fluluks.files.FilesException
import com.mawena.fluluks.files.Sources
import com.mawena.fluluks.provider.StreamTokens
import com.mawena.fluluks.volumes.VolumeManager
import java.io.FileNotFoundException
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/**
 * Vue déchiffrée d'un fichier age (phase 14, T6) : une source en lecture seule qui lit le clair en mémoire par le
 * lecteur age du moteur, sans rien écrire nulle part, retirée avec la source d'origine.
 */
class DecryptedSourceTest {
    private class Engine : MemEngine() {
        fun encrypt(plain: ByteArray, pass: String) = ageEncode(plain, pass.toByteArray(), 18)
    }

    private lateinit var e: Engine
    private lateinit var volId: String
    private var originGone = false

    @Before fun setup() {
        e = Engine()
        VolumeManager.resetForTests(e, delayer = FakeDelayer())
        val diskId = VolumeManager.addImageDiskForTests("/x/mem.img", readOnly = false)
        volId = runBlocking { VolumeManager.mountPlain(diskId, 1, true) }.id
        Archives.resetForTests(e, null, null)
        DecryptedSources.resetForTests()
        StreamTokens.clearForTests()
        originGone = false
        Files.setResolverForTests { id ->
            if (id == volId && !originGone && VolumeManager.volume(volId) != null) DiskSource(volId, e) else null
        }
    }

    @After fun teardown() {
        DecryptedSources.resetForTests()
        Archives.resetForTests(null, null, null)
        Files.setResolverForTests(null)
        StreamTokens.clearForTests()
    }

    private fun data(n: Int) = ByteArray(n) { (it * 31 + it / 977).toByte() }

    private fun put(name: String, plain: ByteArray, pass: String = "correct horse") {
        e.nodes["/$name"] = e.encrypt(plain, pass)
    }

    private fun open(name: String, pass: String = "correct horse"): DecryptedSource =
        DecryptedSources.open(volId, "/$name", pass.toByteArray())

    private fun FileSource.readAll(path: String, offset: Long = 0) = openReadAt(path, offset).use { it.readBytes() }

    @Test fun decryptedViewReadsAtAnyOffset() {
        val plain = data(300 * 1024 + 17)
        put("rapport.pdf.age", plain)
        val v = open("rapport.pdf.age")
        assertTrue(v.id.startsWith("dec:"))
        assertEquals("decrypted", Sources.kind(v))
        val src = Files.source(v.id)
        assertEquals("/rapport.pdf", v.path)
        val list = src.list("/")
        assertEquals(1, list.size)
        assertEquals("rapport.pdf", list[0].name)
        assertEquals(FileType.FILE, list[0].type)
        assertEquals(plain.size.toLong(), list[0].size)
        assertEquals(FileType.DIR, src.stat("/")!!.type)
        assertNull(src.stat("/autre"))
        assertArrayEquals(plain, src.openRead("/rapport.pdf").use { it.readBytes() })
        for (off in longArrayOf(1, 65_535, 65_536, 123_457, plain.size - 1L)) {
            assertArrayEquals("décalage $off", plain.copyOfRange(off.toInt(), plain.size), src.readAll("/rapport.pdf", off))
        }
        assertEquals(0, src.readAll("/rapport.pdf", plain.size.toLong()).size)
        try {
            src.openRead("/autre")
            fail("chemin absent lu")
        } catch (_: FileNotFoundException) {
        }
    }

    @Test fun decryptedViewIsReadOnly() {
        put("a.txt.age", "secret".toByteArray())
        val src = Files.source(open("a.txt.age").id)
        assertEquals(DecryptedSources.MSG_READ_ONLY, src.readOnlyReason)
        val writes: List<Pair<String, () -> Unit>> = listOf(
            "mkdir" to { src.mkdir("/", "d") },
            "createFile" to { src.createFile("/", "b") },
            "rename" to { src.rename("/a.txt", "b.txt") },
            "delete" to { src.delete("/a.txt") },
            "move" to { src.move("/a.txt", "/") },
            "openOverwrite" to { src.openOverwrite("/a.txt") },
            "createNative" to { src.createNative("/", "b") },
        )
        for ((name, w) in writes) {
            try {
                w()
                fail("$name permis")
            } catch (x: FileNotFoundException) {
                assertEquals(name, DecryptedSources.MSG_READ_ONLY, x.message)
            }
        }
    }

    @Test fun decryptedViewNeverWritesToDisk() {
        val plain = data(70_000)
        put("film.mkv.age", plain)
        val before = e.nodes.mapValues { it.value?.copyOf() }
        val src = Files.source(open("film.mkv.age").id)
        src.readAll("/film.mkv")
        src.readAll("/film.mkv", 40_000)
        src.list("/")
        DecryptedSources.close(src.id)
        assertEquals(before.keys, e.nodes.keys)
        for ((k, b) in before) assertArrayEquals(k, b, e.nodes[k])
    }

    @Test fun decryptedViewDroppedWithSource() {
        put("a.pdf.age", data(1000))
        put("b.pdf.age", data(2000))
        val v = open("a.pdf.age")
        val token = StreamTokens.register(v.id, v.path, v.size)
        assertEquals(1, e.openAgeReaders)
        VolumeManager.eject(volId) // éjection du disque d'origine
        assertNull(Files.sourceOrNull(v.id))
        assertNull(StreamTokens.get(token))
        assertEquals(0, e.openAgeReaders)

        // source d'origine disparue sans prévenir (dossier distant coupé) : retirée au premier accès
        val disk2 = VolumeManager.addImageDiskForTests("/x/mem2.img", readOnly = false)
        volId = runBlocking { VolumeManager.mountPlain(disk2, 1, true) }.id
        val w = open("b.pdf.age")
        val t2 = StreamTokens.register(w.id, w.path, w.size)
        originGone = true
        assertNull(Files.sourceOrNull(w.id))
        assertNull(StreamTokens.get(t2))
        assertEquals(0, e.openAgeReaders)
    }

    @Test fun closeDecryptedWipes() {
        put("a.pdf.age", data(1000))
        val v = open("a.pdf.age")
        val token = StreamTokens.register(v.id, v.path, v.size)
        DecryptedSources.close(v.id)
        assertEquals(0, e.openAgeReaders)
        assertNull(Files.sourceOrNull(v.id))
        assertNull(StreamTokens.get(token))
        try {
            v.openRead(v.path).use { it.read() }
            fail("vue fermée encore lue")
        } catch (_: FileNotFoundException) {
        }
        DecryptedSources.close(v.id) // deux fois : sans effet
    }

    @Test fun atMostFourDecryptedViews() {
        val views = (1..5).map { i -> put("f$i.txt.age", data(100 + i)); open("f$i.txt.age") }
        assertNull(Files.sourceOrNull(views[0].id))
        for (v in views.drop(1)) assertNotNull(Files.sourceOrNull(v.id))
        assertEquals(DecryptedSources.MAX, e.openAgeReaders)
        assertEquals(views.drop(1).map { it.id }, DecryptedSources.all().map { it.id })
    }

    @Test fun folderAgeNotOpenable() {
        put("photos.zip.age", "PK\u0003\u0004".toByteArray())
        try {
            open("photos.zip.age")
            fail("dossier chiffré ouvert en vue")
        } catch (x: FilesException) {
            assertEquals(DecryptedSources.MSG_FOLDER, x.message)
        }
        assertEquals(0, e.openAgeReaders)
        assertTrue(DecryptedSources.all().isEmpty())
    }

    @Test fun wrongPasswordOpensNothing() {
        put("a.pdf.age", data(10))
        val pw = "mauvais".toByteArray()
        try {
            DecryptedSources.open(volId, "/a.pdf.age", pw)
            fail("ouvert avec un mauvais mot de passe")
        } catch (x: FilesException) {
            assertEquals(EngineError.FL_EBADPASS, x.code)
        }
        assertTrue(pw.all { it == 0.toByte() })
        assertEquals(0, e.openAgeReaders)
        assertTrue(DecryptedSources.all().isEmpty())
    }
}
