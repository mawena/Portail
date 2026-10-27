package com.mawena.fluluks

import com.mawena.fluluks.analyzer.DuEntry
import com.mawena.fluluks.analyzer.DuTree
import com.mawena.fluluks.analyzer.NodeKind
import com.mawena.fluluks.analyzer.Others
import com.mawena.fluluks.analyzer.ScanCounters
import com.mawena.fluluks.analyzer.ScanEnd
import com.mawena.fluluks.analyzer.Scanner
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.engine.FileType
import com.mawena.fluluks.files.ProtectedDirException
import java.io.FileNotFoundException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Parcours de l'analyseur (phase 16, T4) sur un stockage en mémoire. */
class ScannerTest {
    /** Stockage en mémoire : dossiers et leurs entrées, échecs par chemin, listes notées. */
    private class Fs {
        val dirs = HashMap<String, MutableList<DuEntry>>().apply { put("/", ArrayList()) }
        val fail = HashMap<String, Exception>()
        val listed = ArrayList<String>()
        private var ino = 100L

        private fun parentOf(p: String) = p.substringBeforeLast('/').ifEmpty { "/" }
        private fun nameOf(p: String) = p.substringAfterLast('/')

        fun dir(p: String, mtime: Long = 0, otherDevice: Boolean = false) {
            dirs.getValue(parentOf(p)) += DuEntry(nameOf(p), FileType.DIR, 4096, 4096, mtime, 1, ino++, 2, otherDevice)
            dirs[p] = ArrayList()
        }

        fun file(p: String, size: Long, alloc: Long = (size + 4095) / 4096 * 4096, mtime: Long = 0,
                 type: FileType = FileType.FILE, dev: Long = 1, inode: Long = ino++, nlink: Int = 1) {
            dirs.getValue(parentOf(p)) += DuEntry(nameOf(p), type, size, alloc, mtime, dev, inode, nlink)
        }

        fun list(p: String): List<DuEntry> {
            listed += p
            fail[p]?.let { throw it }
            return dirs[p] ?: throw FileNotFoundException(p)
        }
    }

    private fun scan(
        fs: Fs, tree: DuTree = DuTree(), excluded: Set<String> = emptySet(), start: String = "/",
        cancelled: () -> Boolean = { false }, progress: (ScanCounters) -> Unit = {},
    ): Pair<Scanner, ScanEnd> {
        val s = Scanner(fs::list, tree, excluded, cancelled, progress)
        return s to s.run(start)
    }

    @Test fun sizesSumAllocAndApparent() {
        val fs = Fs()
        fs.file("/a.bin", 100)
        fs.dir("/D"); fs.file("/D/b.bin", 200)
        fs.dir("/D/E"); fs.file("/D/E/c.bin", 300)
        fs.dir("/.cache"); fs.file("/.cache/x", 50) // caché : compté
        fs.dir("/vide")
        val t = DuTree()
        val (_, end) = scan(fs, t)
        assertEquals(ScanEnd.DONE, end)
        assertEquals(4L * 4096 + 4 * 4096, t.alloc(t.root)) // 4 fichiers et 4 dossiers d'un bloc
        assertEquals(100L + 200 + 300 + 50 + 4 * 4096, t.apparent(t.root))
        assertEquals(8L, t.items(t.root)) // a.bin, D, b.bin, E, c.bin, .cache, x, vide
        val d = t.find("/D")!!
        assertEquals(4096L + 4096 + 4096 + 4096, t.alloc(d)) // D, b.bin, E, c.bin
        assertTrue(t.complete(t.root) && t.complete(d) && t.complete(t.find("/vide")!!))
        assertEquals(NodeKind.DIR, t.kind(t.find("/vide")!!))
        assertFalse(t.truncated)
        assertFalse(t.simplified)
    }

    @Test fun hardLinksCountedOnce() {
        val fs = Fs()
        fs.dir("/A"); fs.dir("/B")
        fs.file("/A/l1", 100_000, inode = 7, nlink = 2)
        fs.file("/B/l2", 100_000, inode = 7, nlink = 2)
        fs.file("/B/autre", 100_000, inode = 8, dev = 2, nlink = 2) // même inode, autre appareil : compté
        val t = DuTree()
        scan(fs, t)
        val lien = 102_400L
        assertEquals(2 * 4096 + 2 * lien, t.alloc(t.root))
        assertEquals(lien, t.alloc(t.find("/A/l1")!!))
        assertEquals(0L, t.alloc(t.find("/B/l2")!!)) // la seconde à 0
        assertEquals(5L, t.items(t.root)) // A, B, l1, l2, autre : les deux liens restent des éléments
    }

    @Test fun symlinkNotFollowed() {
        val fs = Fs()
        fs.dir("/cible"); fs.file("/cible/gros", 1 shl 20)
        fs.file("/lien", 7, alloc = 0, type = FileType.SYMLINK)
        fs.dirs["/lien"] = mutableListOf() // un parcours qui suivrait le lien le listerait
        val t = DuTree()
        scan(fs, t)
        assertFalse("/lien" in fs.listed)
        val l = t.find("/lien")!!
        assertEquals(NodeKind.FILE, t.kind(l))
        assertEquals(0L, t.alloc(l))
        assertEquals(7L, t.apparent(l))
    }

    @Test fun otherFsNotEntered() {
        val fs = Fs()
        fs.dir("/carte", otherDevice = true); fs.file("/carte/x", 4096)
        val t = DuTree()
        scan(fs, t)
        assertFalse("/carte" in fs.listed)
        val c = t.find("/carte")!!
        assertEquals(NodeKind.OTHER_FS, t.kind(c))
        assertEquals(0L, t.alloc(c))
        assertEquals(0L, t.alloc(t.root))
    }

    @Test fun inaccessibleDirShown() {
        val fs = Fs()
        fs.dir("/Android"); fs.dir("/Android/data"); fs.file("/Android/data/x", 4096)
        fs.dir("/Android/media"); fs.file("/Android/media/y", 4096)
        fs.fail["/Android/data"] = ProtectedDirException()
        val t = DuTree()
        var last: ScanCounters? = null
        val (_, end) = scan(fs, t, progress = { last = it })
        assertEquals(ScanEnd.DONE, end)
        val d = t.find("/Android/data")!!
        assertEquals(NodeKind.INACCESSIBLE, t.kind(d))
        assertEquals(0L, t.alloc(d))
        assertEquals(1, last!!.inaccessible)
        assertEquals(4096L * 3, t.alloc(t.root)) // Android, media, y
        assertTrue(t.complete(t.root))
    }

    @Test fun engineErrorOnSubdirShownInaccessible() {
        val fs = Fs()
        fs.dir("/abime"); fs.dir("/sain"); fs.file("/sain/x", 4096)
        fs.fail["/abime"] = EngineError(EngineError.FL_ECORRUPT)
        val t = DuTree()
        var last: ScanCounters? = null
        assertEquals(ScanEnd.DONE, scan(fs, t, progress = { last = it }).second)
        assertEquals(NodeKind.INACCESSIBLE, t.kind(t.find("/abime")!!))
        assertEquals(1, last!!.inaccessible)
        assertEquals(4096L * 2, t.alloc(t.root))
        val fs2 = Fs()
        fs2.fail["/"] = EngineError(EngineError.FL_EIO)
        try {
            scan(fs2)
            throw AssertionError("accepté")
        } catch (_: EngineError) {
        }
    }

    @Test fun startDirUnreadableThrows() {
        val fs = Fs()
        fs.fail["/"] = ProtectedDirException()
        try {
            scan(fs)
            throw AssertionError("accepté")
        } catch (_: ProtectedDirException) {
        }
        val fs2 = Fs()
        try {
            scan(fs2, start = "/absent")
            throw AssertionError("accepté")
        } catch (_: FileNotFoundException) {
        }
    }

    @Test fun entryVanishingDuringScanSkipped() {
        val fs = Fs()
        fs.dir("/parti"); fs.file("/reste", 4096)
        fs.dirs.remove("/parti") // supprimé entre la liste de / et la sienne
        val t = DuTree()
        val (_, end) = scan(fs, t)
        assertEquals(ScanEnd.DONE, end)
        assertNull(t.find("/parti"))
        assertEquals(4096L, t.alloc(t.root))
        assertEquals(1L, t.items(t.root))
    }

    @Test fun excludedNotListed() {
        val fs = Fs()
        fs.dir("/Films"); fs.file("/Films/f.mkv", 1 shl 30)
        fs.dir("/Docs"); fs.file("/Docs/d.txt", 10)
        val t = DuTree()
        scan(fs, t, excluded = setOf("/Films"))
        assertFalse("/Films" in fs.listed)
        val f = t.find("/Films")!!
        assertEquals(NodeKind.EXCLUDED, t.kind(f))
        assertEquals(0L, t.alloc(f))
        assertEquals(4096L * 2, t.alloc(t.root))
    }

    @Test fun topFilesPerDirAndOthers() {
        val fs = Fs()
        for (i in 1..1000) fs.file("/f$i", i * 4096L)
        val t = DuTree()
        scan(fs, t)
        val kids = t.children(t.root)
        assertEquals(20, kids.size)
        assertEquals("f1000", t.name(kids[0]))
        assertEquals("f981", t.name(kids[19]))
        val others = (1..980).sumOf { it * 4096L }
        assertEquals(Others(980, others, others), t.others(t.root))
        assertEquals((1..1000).sumOf { it * 4096L }, t.alloc(t.root))
        assertEquals(1000L, t.items(t.root))
    }

    @Test fun hugeDirectoryKeepsTopFiles() {
        val n = 100_000
        val entries = List(n) { DuEntry("f$it", FileType.FILE, it.toLong(), it * 512L, 0, 1, it + 10L, 1) }
        val t = DuTree()
        val s = Scanner({ if (it == "/") entries else throw FileNotFoundException(it) }, t, emptySet(), { false }, {})
        assertEquals(ScanEnd.DONE, s.run("/"))
        assertEquals(21, t.nodeCount)
        assertEquals((0 until n).sumOf { it * 512L }, t.alloc(t.root))
        assertEquals(n.toLong(), t.items(t.root))
        assertEquals(n - 20L, t.others(t.root).count)
    }

    @Test fun biggestTop500Global() {
        val fs = Fs()
        var k = 0L
        for (d in 0 until 10) {
            fs.dir("/d$d")
            for (f in 0 until 100) fs.file("/d$d/f$f", 0, alloc = ++k * 4096)
        }
        val (s, _) = scan(fs)
        val b = s.biggest
        assertEquals(DuTree.MAX_BIGGEST, b.size)
        assertEquals("/d9/f99", b.first().path)
        assertEquals("/d5/f0", b.last().path) // 1 000 − 500 + 1 = 501e : d5/f0
    }

    @Test fun mtimeIsNewestBelow() {
        val fs = Fs()
        fs.dir("/A", mtime = 5); fs.dir("/A/B", mtime = 6); fs.file("/A/B/x", 1, mtime = 99)
        fs.file("/y", 1, mtime = 50)
        val t = DuTree()
        scan(fs, t)
        assertEquals(99L, t.mtime(t.root))
        assertEquals(99L, t.mtime(t.find("/A")!!))
        assertEquals(50L, t.mtime(t.find("/y")!!))
    }

    @Test fun deepNesting300NoRecursion() {
        val fs = Fs()
        var p = ""
        for (i in 1..300) {
            p += "/n$i"
            fs.dir(p)
            fs.file("$p/f", 4096)
        }
        val t = DuTree()
        var end: ScanEnd? = null
        var err: Throwable? = null
        val th = Thread(null, {
            try { end = scan(fs, t).second } catch (e: Throwable) { err = e }
        }, "petite-pile", 256 * 1024)
        th.start(); th.join()
        assertNull(err)
        assertEquals(ScanEnd.DONE, end)
        assertTrue(t.truncated)
        assertEquals(300L * 4096 * 2, t.alloc(t.root)) // 300 dossiers et 300 fichiers, total exact
        assertEquals(600L, t.items(t.root))
        assertNotNull(t.find((1..256).joinToString("") { "/n$it" }))
        assertNull(t.find((1..257).joinToString("") { "/n$it" }))
    }

    @Test fun nodeCapFoldsIntoAncestors() {
        val fs = Fs()
        for (i in 0 until 200) {
            fs.dir("/d%03d".format(i))
            fs.file("/d%03d/x".format(i), 4096)
        }
        val t = DuTree(maxNodes = 50)
        scan(fs, t)
        assertTrue(t.nodeCount <= 50)
        assertTrue(t.simplified)
        assertEquals(200L * 4096 * 2, t.alloc(t.root))
        assertEquals(400L, t.items(t.root))
    }

    @Test fun millionFilesBounded() {
        val dirs = 10_000
        val per = 100
        val root = List(dirs) { DuEntry("d$it", FileType.DIR, 4096, 4096, 0, 1, it + 1L, 2) }
        val list: (String) -> List<DuEntry> = { p ->
            if (p == "/") root
            else List(per) { DuEntry("fichier-$it.jpg", FileType.FILE, it * 1000L, (it + 1) * 4096L, 0, 1, 0, 1) }
        }
        val t = DuTree()
        val s = Scanner(list, t, emptySet(), { false }, {})
        assertEquals(ScanEnd.DONE, s.run("/"))
        assertTrue("${t.nodeCount}", t.nodeCount <= 210_001)
        assertTrue("${t.bytesEstimate()}", t.bytesEstimate() < 32L shl 20)
        val perDir = (1..per).sumOf { it * 4096L }
        assertEquals(dirs * (4096L + perDir), t.alloc(t.root))
        assertEquals(dirs * (1L + per), t.items(t.root))
    }

    @Test fun cancelStopsAndKeepsPartial() {
        val fs = Fs()
        for (i in 0 until 10) { fs.dir("/d$i"); fs.file("/d$i/x", 4096) }
        val t = DuTree()
        val (_, end) = scan(fs, t, cancelled = { fs.listed.size >= 5 })
        assertEquals(ScanEnd.CANCELLED, end)
        assertEquals(5, fs.listed.size) // /, d0 … d3
        assertTrue(t.complete(t.find("/d0")!!))
        assertTrue(t.complete(t.find("/d2")!!))
        assertFalse(t.complete(t.root))
        assertTrue(t.truncated)
    }

    @Test fun progressCounters() {
        val fs = Fs()
        fs.dir("/A"); fs.file("/A/x", 4096); fs.dir("/B"); fs.file("/B/y", 4096); fs.file("/B/z", 4096)
        val seen = ArrayList<ScanCounters>()
        scan(fs, progress = { seen += it })
        assertEquals(listOf("/", "/A", "/B"), seen.map { it.current })
        assertEquals(listOf(1L, 2L, 3L), seen.map { it.dirs })
        assertEquals(listOf(0L, 1L, 3L), seen.map { it.files })
        assertTrue(seen.zipWithNext().all { (a, b) -> b.alloc >= a.alloc })
        assertEquals(4096L * 5, seen.last().alloc)
    }
}
