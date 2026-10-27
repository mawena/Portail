package com.mawena.fluluks

import com.mawena.fluluks.analyzer.AnalysisProgress
import com.mawena.fluluks.analyzer.Analyzer
import com.mawena.fluluks.analyzer.DuEntry
import com.mawena.fluluks.analyzer.Lstat
import com.mawena.fluluks.analyzer.RawStat
import com.mawena.fluluks.analyzer.SizeKind
import com.mawena.fluluks.files.FileSource
import com.mawena.fluluks.files.Files
import com.mawena.fluluks.files.FilesException
import com.mawena.fluluks.files.DiskSource
import com.mawena.fluluks.files.LocalSource
import com.mawena.fluluks.files.ProtectedDirException
import com.mawena.fluluks.files.Trash
import com.mawena.fluluks.remote.RemoteSource
import com.mawena.fluluks.remote.ServerConfig
import com.mawena.fluluks.vaults.Vaults
import com.mawena.fluluks.volumes.VolumeManager
import java.io.File
import java.io.FileNotFoundException
import java.nio.file.LinkOption
import java.nio.file.Files as NioFiles
import java.nio.file.attribute.FileTime
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Analyseur (phase 16, T5) sur une source locale (dossier temporaire), parcours synchrone (répartiteur de test). */
@OptIn(ExperimentalCoroutinesApi::class)
class AnalyzerTest {
    @get:Rule val tmp = TemporaryFolder()

    /** lstat de la JVM : attributs « unix: » de NIO, blocs = taille arrondie à 4 Kio (le système de test peut différer). */
    private object JvmLstat : Lstat {
        override fun of(path: String): RawStat? {
            val p = File(path).toPath()
            if (!NioFiles.exists(p, LinkOption.NOFOLLOW_LINKS)) return null
            val a = NioFiles.readAttributes(p, "unix:*", LinkOption.NOFOLLOW_LINKS)
            val size = a["size"] as Long
            val dir = NioFiles.isDirectory(p, LinkOption.NOFOLLOW_LINKS)
            return RawStat(
                a["mode"] as Int, size, if (dir) 8 else (size + 4095) / 4096 * 8, (a["lastModifiedTime"] as FileTime).toMillis() / 1000,
                a["dev"] as Long, a["ino"] as Long, a["nlink"] as Int,
            )
        }
    }

    /** Source locale dont chaque `duList` est comptée et peut déclencher une action ; place occupée réglable. */
    private class Counting(val s: FileSource) : FileSource by s {
        var lists = 0
        var onList: (String, Int) -> Unit = { _, _ -> }
        var used: Long? = 0 // 0 : pas de part hors analyse (la place du vrai disque de test varie)
        var refuseDelete: String? = null
        override fun duList(path: String): List<DuEntry> {
            onList(path, ++lists)
            return s.duList(path)
        }
        override fun usedBytes(): Long? = used ?: s.usedBytes()
        override fun delete(path: String) {
            refuseDelete?.let { throw FileNotFoundException(it) }
            s.delete(path)
        }
        override fun deleteAll(paths: List<String>) = paths.forEach(::delete)
    }

    private val root: File get() = File(tmp.root, "racine").apply { mkdirs() }
    private lateinit var src: Counting
    private val progress = ArrayList<AnalysisProgress>()
    private var now = 0L

    private fun file(path: String, size: Int) = File(root, path).apply { parentFile!!.mkdirs(); writeBytes(ByteArray(size)) }

    @Before fun setup() {
        VolumeManager.resetForTests(MemEngine())
        src = Counting(LocalSource("phone", "phone", "Téléphone", root, JvmLstat) { true })
        Files.setResolverForTests { if (it == "phone") src else null }
        Analyzer.resetForTests(UnconfinedTestDispatcher(), { now }, tmp.newFolder("app"))
    }

    @After fun teardown() {
        Analyzer.cancel()
        Files.setResolverForTests(null)
    }

    /** Analyse synchrone : le répartiteur de test la mène à son terme dans start. */
    private fun analyse(path: String = "/"): String {
        val id = Analyzer.start("phone", path)
        assertFalse(Analyzer.progress.value!!.running)
        return id
    }

    private fun node(id: String, path: String): Int {
        val v = Analyzer.view(id, 0, 8, 1500)
        return v.nodes.first { it.path == path && it.id >= 0 }.id
    }

    @Test fun drillDownNeverRelists() {
        file("D/E/c.bin", 300); file("D/b.bin", 200); file("a.bin", 100)
        val id = analyse()
        val before = src.lists
        file("D/nouveau.bin", 999) // invisible jusqu'à la prochaine analyse
        val v = Analyzer.view(id, 0, 4, 1500)
        val d = node(id, "/D")
        Analyzer.view(id, d, 4, 1500)
        Analyzer.children(id, d, "name", 0, 200)
        Analyzer.biggest(id, d)
        assertEquals(before, src.lists)
        assertEquals(listOf("E", "b.bin"), Analyzer.children(id, d, "size", 0, 200).map { it.name })
        assertEquals(5 * 4096L, v.nodes[0].alloc) // 3 fichiers, D et E ; la racine ne compte pas son propre bloc
        assertEquals(setOf("/D/E/c.bin", "/D/b.bin"), Analyzer.biggest(id, d).map { it.path }.toSet()) // sous /D seulement
        // une nouvelle analyse voit le nouveau fichier
        val id2 = analyse("/D")
        assertEquals(listOf("E", "b.bin", "nouveau.bin"), Analyzer.children(id2, 0, "size", 0, 200).map { it.name })
    }

    @Test fun unreadableDirSkipped() {
        file("a.bin", 100); file("D/b.bin", 200); file("D/P/secret.bin", 5000)
        src.onList = { path, _ -> if (path == "/D/P") throw ProtectedDirException() }
        val id = analyse()
        val p = Analyzer.progress.value!!
        assertNull(p.error)
        assertEquals(1, p.inaccessible)
        // taille 0 : absent des graphiques, montré dans l'arbre
        val pNode = Analyzer.children(id, node(id, "/D"), "name", 0, 200).single { it.path == "/D/P" }
        assertEquals("inaccessible", pNode.kind)
        assertEquals(0L, pNode.alloc)
        // le dossier de départ illisible : analyse en échec, message français
        src.onList = { path, _ -> if (path == "/") throw ProtectedDirException() }
        val id2 = Analyzer.start("phone", "/")
        val f = Analyzer.progress.value!!
        assertEquals(id2, f.scanId)
        assertFalse(f.running)
        assertEquals(Files.MSG_PROTECTED, f.error)
        assertEquals("failed", Analyzer.list().first().state)
    }

    @Test fun cancelStops() {
        for (i in 1..20) file("d$i/f.bin", 10)
        src.onList = { _, n -> if (n == 5) Analyzer.cancel() }
        val id = analyse()
        assertTrue(Analyzer.progress.value!!.cancelled)
        assertEquals("cancelled", Analyzer.list().first { it.scanId == id }.state)
        assertTrue(Analyzer.view(id, 0, 2, 1500).truncated)
        src.onList = { _, _ -> }
        val full = analyse()
        assertFalse(Analyzer.progress.value!!.cancelled)
        assertEquals("done", Analyzer.list().first { it.scanId == full }.state)
        assertEquals(20L * 4096 * 2, Analyzer.view(full, 0, 1, 1500).nodes[0].alloc)
    }

    @Test fun oneScanAtATime() {
        for (i in 1..5) file("d$i/f.bin", 10)
        val pool = Executors.newSingleThreadExecutor()
        Analyzer.resetForTests(pool.asCoroutineDispatcher(), { now }, tmp.newFolder("app2"))
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        src.onList = { path, _ -> if (path == "/d1") { entered.countDown(); release.await(5, TimeUnit.SECONDS) } }
        val first = Analyzer.start("phone", "/")
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        src.onList = { _, _ -> }
        val second = Analyzer.start("phone", "/d2") // arrête la première
        release.countDown()
        pool.submit {}.get(5, TimeUnit.SECONDS) // la première se termine, puis la seconde
        pool.submit {}.get(5, TimeUnit.SECONDS)
        val states = Analyzer.list().associate { it.scanId to it.state }
        assertEquals("cancelled", states[first])
        assertEquals("done", states[second])
        assertEquals(second, Analyzer.progress.value!!.scanId)
        pool.shutdown()
    }

    @Test fun threeAnalysesKept() {
        for (i in 1..4) file("d$i/a.bin", 1)
        val ids = (1..4).map { analyse("/d$it") }
        assertEquals(ids.drop(1).reversed(), Analyzer.list().map { it.scanId })
        try {
            Analyzer.view(ids[0], 0, 2, 1500)
            throw AssertionError("gardée")
        } catch (e: FilesException) {
            assertEquals(Analyzer.MSG_GONE, e.message)
        }
        Analyzer.forget(ids[3])
        assertEquals(listOf(ids[2], ids[1]), Analyzer.list().map { it.scanId })
    }

    @Test fun nodeBudgetForgetsOldest() {
        // 3 analyses de 400 000 nœuds dépassent 1 000 000 : la plus ancienne est oubliée
        val big = object : FileSource by src {
            override fun duList(path: String): List<DuEntry> = if (path in setOf("/", "/x", "/y")) {
                List(20_000) { DuEntry("d$it", com.mawena.fluluks.engine.FileType.DIR, 4096, 4096, 0, 1, 0, 1) }
            } else {
                List(19) { DuEntry("f$it", com.mawena.fluluks.engine.FileType.FILE, 1, 4096, 0, 1, 0, 1) }
            }
        }
        Files.setResolverForTests { if (it == "phone") big else null }
        val ids = listOf("/", "/x", "/y").map { analyse(it) }
        assertEquals(listOf(ids[2], ids[1]), Analyzer.list().map { it.scanId })
    }

    /** Essai du 2026-10-27 sur le Pixel : Réanalyser gardait l'ancienne analyse et chassait celle du téléphone. */
    @Test fun rescanReplacesSameLocation() {
        file("d/a.bin", 1)
        val whole = analyse()
        analyse("/d")
        val again = analyse("/d")
        assertEquals(listOf(again, whole), Analyzer.list().map { it.scanId })
    }

    @Test fun progressThrottled250ms() {
        for (i in 1..40) file("d$i/f.bin", 10)
        src.onList = { _, _ -> now += 100 } // 100 ms par dossier
        analyse()
        // 41 dossiers en 4,1 s : départ, une publication toutes les 250 ms au plus (soit toutes les 3 listes), fin
        assertTrue("${Analyzer.published}", Analyzer.published in 10..17)
        assertEquals(4100L, Analyzer.progress.value!!.elapsedMs)
        assertEquals(41L, Analyzer.progress.value!!.dirs)
    }

    @Test fun progressClampedTo99UntilDone() {
        for (i in 1..10) file("d$i/f.bin", 100_000)
        src.used = 50_000 // moins que ce qui sera compté (liens physiques, compression…)
        val seen = ArrayList<Double>()
        src.onList = { _, _ -> now += 300; Analyzer.progress.value?.let { if (it.running) seen += it.fraction } }
        analyse()
        assertTrue(seen.size >= 5)
        assertTrue(seen.all { it <= 0.99 })
        assertEquals(0.99, seen.last(), 0.0)
        assertEquals(1.0, Analyzer.progress.value!!.fraction, 0.0)
        assertEquals(50_000L, Analyzer.progress.value!!.usedBytes)
        // un sous-dossier : pas de place de référence
        analyse("/d1")
        assertNull(Analyzer.progress.value!!.usedBytes)
    }

    @Test fun closingVolumeDropsItsAnalyses() {
        val e = MemEngine()
        VolumeManager.resetForTests(e)
        val disk = VolumeManager.addImageDiskForTests("/x/mem.img", readOnly = false)
        val vol = runBlocking { VolumeManager.mountPlain(disk, 1, true) }.id
        e.nodes["/D"] = null
        e.nodes["/D/x"] = ByteArray(10)
        val ds = DiskSource(vol, e)
        Files.setResolverForTests { if (it == vol) ds else if (it == "phone") src else null }
        file("a.bin", 1)
        val kept = Analyzer.start(vol, "/")
        val phone = analyse()
        assertEquals(2, Analyzer.list().size)
        // fermeture pendant l'analyse suivante : arrêtée avec le message, analyses du volume oubliées
        var closed = false
        val wrapped = object : FileSource by ds {
            override fun duList(path: String): List<DuEntry> {
                if (path == "/D" && !closed) { closed = true; VolumeManager.eject(vol) }
                return ds.duList(path)
            }
        }
        Files.setResolverForTests { if (it == vol) wrapped else if (it == "phone") src else null }
        val running = Analyzer.start(vol, "/")
        val p = Analyzer.progress.value!!
        assertEquals(running, p.scanId)
        assertFalse(p.running)
        assertEquals(Analyzer.MSG_SOURCE_CLOSED, p.error)
        assertEquals(listOf(phone), Analyzer.list().map { it.scanId })
        assertFalse(kept in Analyzer.list().map { it.scanId })
    }

    @Test fun deleteUpdatesAncestors() {
        file("D/E/gros.bin", 40_000); file("D/b.bin", 100)
        val id = analyse()
        val d = node(id, "/D")
        val dBefore = Analyzer.view(id, d, 1, 1500).nodes[0].alloc
        val rootBefore = Analyzer.view(id, 0, 1, 1500).nodes[0].alloc
        runBlocking { Analyzer.delete(id, node(id, "/D/E/gros.bin"), permanent = true) }
        assertFalse(File(root, "D/E/gros.bin").exists())
        val after = Analyzer.view(id, d, 2, 1500)
        assertEquals(dBefore - 40_960, after.nodes[0].alloc)
        assertFalse(after.nodes.any { it.name == "gros.bin" })
        assertEquals(rootBefore - 40_960, Analyzer.view(id, 0, 1, 1500).nodes[0].alloc)
        assertEquals(4096L, after.nodes.single { it.path == "/D/E" }.alloc)
    }

    @Test fun trashMovesSizeToTrashNode() {
        file("D/gros.bin", 40_000); file("autre.bin", 10)
        val id = analyse()
        val total = Analyzer.view(id, 0, 1, 1500).nodes[0].alloc
        runBlocking { Analyzer.delete(id, node(id, "/D/gros.bin"), permanent = false) }
        assertTrue(File(root, ".Portail-corbeille/files/gros.bin").exists())
        val v = Analyzer.view(id, 0, 2, 1500)
        assertEquals(total, v.nodes[0].alloc) // pas libéré : reporté sur la corbeille
        val bin = v.nodes.single { it.path == Trash.DIR && it.id >= 0 }
        assertEquals("trash", bin.kind)
        assertEquals(40_960L, bin.alloc)
        assertEquals(4096L, v.nodes.single { it.path == "/D" }.alloc)
    }

    @Test fun deleteRefusesAnalysisRoot() {
        file("a.bin", 1)
        val id = analyse()
        for (n in listOf(0, -1, -2)) {
            try {
                runBlocking { Analyzer.delete(id, n, permanent = true) }
                throw AssertionError("accepté : $n")
            } catch (e: FilesException) {
                assertEquals(if (n == 0) Analyzer.MSG_ROOT else Analyzer.MSG_NOT_DELETABLE, e.message)
            }
        }
        assertTrue(File(root, "a.bin").exists())
    }

    @Test fun deleteRefusesOpenVaultFile() {
        file("C.luks", 50_000)
        val id = analyse()
        val total = Analyzer.view(id, 0, 1, 1500).nodes[0].alloc
        src.refuseDelete = Vaults.MSG_OPEN // refus de Files.delete pour le fichier d'un coffre ouvert
        try {
            runBlocking { Analyzer.delete(id, node(id, "/C.luks"), permanent = true) }
            throw AssertionError("accepté")
        } catch (e: FilesException) {
            assertEquals(Vaults.MSG_OPEN, e.message)
        }
        assertEquals(total, Analyzer.view(id, 0, 1, 1500).nodes[0].alloc)
        assertNotNull(Analyzer.view(id, 0, 1, 1500).nodes.singleOrNull { it.path == "/C.luks" })
    }

    @Test fun excludeStoresAndMarksNode() {
        file("Films/f.mkv", 80_000); file("Docs/d.txt", 10)
        val id = analyse()
        val total = Analyzer.view(id, 0, 1, 1500).nodes[0].alloc
        Analyzer.exclude(id, node(id, "/Films"))
        val v = Analyzer.view(id, 0, 1, 1500)
        val f = Analyzer.children(id, 0, "name", 0, 200).single { it.path == "/Films" }
        assertEquals("excluded", f.kind)
        assertEquals(0L, f.alloc)
        assertEquals(total - 4096 - 81_920, v.nodes[0].alloc)
        assertEquals(listOf("/Films"), Analyzer.exclusions().map { it.path })
        assertEquals("phone", Analyzer.exclusions().single().stableKey)
        // l'analyse suivante ne la liste pas
        analyse()
        assertEquals("excluded", Analyzer.children(Analyzer.list().first().scanId, 0, "name", 0, 200).single { it.path == "/Films" }.kind)
        Analyzer.removeExclusion("phone", "/Films")
        assertTrue(Analyzer.exclusions().isEmpty())
    }

    @Test fun remoteUsesApparentSizes() {
        val server = tmp.newFolder("serveur")
        File(server, "D").mkdir()
        File(server, "D/f.txt").writeText("12345")
        val r = RemoteSource(ServerConfig("s1", "sftp", "Maison", "h", 22, "u", "/", false, null, null), FakeRemoteClient(server))
        Files.setResolverForTests { if (it == r.id) r else null }
        val id = Analyzer.start(r.id, "/")
        val s = Analyzer.list().single { it.scanId == id }
        assertEquals(SizeKind.APPARENT, s.sizeKind)
        assertEquals("done", s.state)
        val v = Analyzer.view(id, 0, 2, 1500)
        assertEquals(SizeKind.APPARENT, v.sizeKind)
        assertEquals(5L, v.nodes.single { it.name == "f.txt" }.alloc)
        assertNull(Analyzer.progress.value!!.usedBytes)
        assertFalse(v.nodes.any { it.kind == "unscanned" })
    }
}
