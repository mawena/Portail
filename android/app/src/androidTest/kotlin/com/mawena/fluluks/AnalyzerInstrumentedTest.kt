package com.mawena.fluluks

import android.os.Debug
import android.os.Environment
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.mawena.fluluks.analyzer.Analyzer
import com.mawena.fluluks.analyzer.DuEntry
import com.mawena.fluluks.analyzer.DuTree
import com.mawena.fluluks.analyzer.Scanner
import com.mawena.fluluks.engine.DirEntry
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.engine.NativeEngine
import com.mawena.fluluks.files.FileSource
import com.mawena.fluluks.files.Files
import com.mawena.fluluks.files.LocalSource
import com.mawena.fluluks.files.Sources
import com.mawena.fluluks.files.Trash
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.Executors
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Analyseur de stockage sur le Pixel (phase 16, T12) : place occupée lue par lstat (blocs, fichiers creux, liens
 * physiques), analyse du stockage partagé entier (durée, mémoire, dossiers protégés, part hors analyse), image ext4
 * lue par le moteur et comparée au manifeste de debugfs, 50 000 fichiers, corbeille depuis l'analyse. Mesures dans le
 * journal (étiquette « AnalyseurEssai »). N'écrit que dans le dossier privé de l'application.
 */
@RunWith(AndroidJUnit4::class)
class AnalyzerInstrumentedTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val work = File(context.filesDir, "essai-analyseur")
    private val pool = Executors.newSingleThreadExecutor()
    private val sources = HashMap<String, FileSource>()

    @Before fun setUp() {
        work.deleteRecursively()
        work.mkdirs()
        Files.setResolverForTests { sources[it] }
        Analyzer.resetForTests(pool.asCoroutineDispatcher(), System::currentTimeMillis, File(work, "app").apply { mkdirs() })
    }

    @After fun tearDown() {
        Analyzer.cancel()
        Files.setResolverForTests(null)
        pool.shutdown()
        work.deleteRecursively()
    }

    private fun note(msg: String) = Log.i("AnalyseurEssai", msg)

    private fun local(id: String, root: File) = LocalSource(id, id, id, root, hasAccess = { true }).also { sources[id] = it }

    /** Lance l'analyse et attend sa fin (10 min au plus). */
    private fun analyse(id: String, path: String = "/"): String {
        val scan = Analyzer.start(id, path)
        val end = System.currentTimeMillis() + 600_000
        while (Analyzer.progress.value?.let { it.scanId != scan || it.running } != false) {
            assertTrue("analyse trop longue", System.currentTimeMillis() < end)
            Thread.sleep(50)
        }
        assertEquals(null, Analyzer.progress.value!!.error)
        return scan
    }

    private fun usedJava(): Long = Runtime.getRuntime().let { it.totalMemory() - it.freeMemory() }

    @Test fun phoneLstatAllocated() {
        // sous-dossier : la racine d'une source compte la place de tout son système de fichiers (part hors analyse)
        val d = File(work, "lstat/x").apply { mkdirs() }
        File(d, "un-octet.bin").writeBytes(byteArrayOf(1))
        RandomAccessFile(File(d, "creux.bin"), "rw").use { it.setLength(64L shl 20) }
        // Un lien physique est refusé par Android dans le dossier privé (EACCES) : les liens sont jugés par
        // diskImageAllocMatchesJudge (lien-a.bin et lien-b.bin de ext4-du.img) et par les tests JVM.
        val entries = local("essai", d.parentFile!!).duList("/x").associateBy { it.name }
        assertTrue(entries.getValue("un-octet.bin").alloc >= 4096)
        assertTrue(entries.getValue("creux.bin").alloc < (1L shl 20))
        assertEquals(64L shl 20, entries.getValue("creux.bin").size)
        val scan = analyse("essai", "/x")
        val total = Analyzer.view(scan, 0, 1, 1500).nodes[0].alloc
        assertEquals(entries.getValue("un-octet.bin").alloc + entries.getValue("creux.bin").alloc, total)
        note("lstat : 1 o -> ${entries.getValue("un-octet.bin").alloc} o ; creux 64 Mio -> ${entries.getValue("creux.bin").alloc} o")
    }

    @Test fun sharedStorageScanTimed() {
        val root = Environment.getExternalStorageDirectory()
        assertTrue("accès à tous les fichiers requis", Environment.isExternalStorageManager())
        sources[Sources.PHONE] = LocalSource(Sources.PHONE, Sources.PHONE, "Téléphone", root, hasAccess = { true })
        System.gc()
        val java0 = usedJava()
        val native0 = Debug.getNativeHeapAllocatedSize()
        val t0 = System.currentTimeMillis()
        val scan = analyse(Sources.PHONE)
        val ms = System.currentTimeMillis() - t0
        val p = Analyzer.progress.value!!
        val v = Analyzer.view(scan, 0, 3, 1500)
        val android = v.nodes.first { it.path == "/Android" && it.id >= 0 }.id
        val data = Analyzer.children(scan, android, "name", 0, 200).firstOrNull { it.name == "data" }
        assertEquals("inaccessible", data?.kind)
        assertTrue("part hors analyse attendue", v.nodes.any { it.kind == "unscanned" && it.alloc > 0 })
        note(
            "stockage partagé : $ms ms, ${p.files} fichiers, ${p.dirs} dossiers, ${p.bytes} o vus sur ${p.usedBytes} o, " +
                "${v.nodes.size} nœuds dans la vue, Java +${(usedJava() - java0) shr 20} Mio, natif +" +
                "${(Debug.getNativeHeapAllocatedSize() - native0) shr 20} Mio",
        )
    }

    @Test fun diskImageAllocMatchesJudge() {
        val manifest = Fixtures.file("ext4-du.alloc").readLines().filter { it.isNotBlank() }.map { it.split('\t') }
        val disk = EngineError.check(NativeEngine.openImage(Fixtures.file("ext4-du.img").absolutePath.toByteArray()))
        try {
            val vol = EngineError.check(NativeEngine.mount(disk, 0, null))
            val tree = DuTree()
            val end = Scanner(
                list = { path ->
                    DirEntry.parseList(NativeEngine.list(vol, path.toByteArray())).map {
                        DuEntry(it.name, it.type, it.size, it.alloc, it.mtime, dev = 0, ino = it.ino, nlink = it.nlink)
                    }
                },
                tree = tree,
                excluded = setOf("/lost+found"), // créé par mke2fs, absent du manifeste
                cancelled = { false },
                onProgress = {},
            ).run("/")
            assertEquals(com.mawena.fluluks.analyzer.ScanEnd.DONE, end)
            // place de toutes les entrées sauf la racine, un inode compté une fois (liens physiques)
            val expected = manifest.filter { it[0] != "/" }.distinctBy { it[2] }.sumOf { it[1].toLong() }
            assertEquals(expected, tree.alloc(tree.root))
            assertEquals(0, NativeEngine.unmount(vol, false))
            note("ext4-du.img : ${manifest.size} entrées, $expected o, ${tree.nodeCount} nœuds")
        } finally {
            NativeEngine.closeDisk(disk)
        }
    }

    @Test fun fiftyThousandFilesBounded() {
        val d = File(work, "cinquante-mille").apply { mkdirs() }
        val t0 = System.currentTimeMillis()
        for (i in 0 until 500) {
            val sub = File(d, "d%03d".format(i)).apply { mkdir() }
            for (j in 0 until 100) File(sub, "f%03d".format(j)).createNewFile()
        }
        note("50 000 fichiers créés en ${System.currentTimeMillis() - t0} ms")
        local("cinquante", d)
        System.gc()
        val java0 = usedJava()
        val t1 = System.currentTimeMillis()
        val scan = analyse("cinquante")
        val ms = System.currentTimeMillis() - t1
        val p = Analyzer.progress.value!!
        assertEquals(50_000L, p.files)
        assertEquals(501L, p.dirs)
        val gained = usedJava() - java0
        assertTrue("mémoire Java gagnée : ${gained shr 20} Mio", gained < (64L shl 20))
        assertFalse(Analyzer.view(scan, 0, 2, 1500).nodes.size > 1500)
        note("50 000 fichiers : analyse en $ms ms, Java +${gained shr 20} Mio")
    }

    @Test fun trashFromAnalysisMovesSize() {
        val d = File(work, "corbeille").apply { mkdirs() }
        File(d, "D").mkdirs()
        File(d, "D/gros.bin").writeBytes(ByteArray(40_000))
        File(d, "autre.bin").writeBytes(ByteArray(10))
        local("corbeille", d)
        val scan = analyse("corbeille")
        val total = Analyzer.view(scan, 0, 1, 1500).nodes[0].alloc
        val gros = Analyzer.view(scan, 0, 8, 1500).nodes.first { it.path == "/D/gros.bin" && it.id >= 0 }.id
        runBlocking { Analyzer.delete(scan, gros, permanent = false) }
        assertTrue(File(d, "${Trash.DIR.trimStart('/')}/files/gros.bin").exists())
        val v = Analyzer.view(scan, 0, 2, 1500)
        assertEquals(total, v.nodes[0].alloc) // pas libéré : reporté sur la corbeille
        assertEquals("trash", v.nodes.single { it.path == Trash.DIR && it.id >= 0 }.kind)
    }
}
