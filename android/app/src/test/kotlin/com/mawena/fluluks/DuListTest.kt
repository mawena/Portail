package com.mawena.fluluks

import com.mawena.fluluks.analyzer.Lstat
import com.mawena.fluluks.analyzer.RawStat
import com.mawena.fluluks.analyzer.SizeKind
import com.mawena.fluluks.engine.FileType
import com.mawena.fluluks.files.DiskSource
import com.mawena.fluluks.files.LocalSource
import com.mawena.fluluks.files.ProtectedDirException
import com.mawena.fluluks.remote.RemoteSource
import com.mawena.fluluks.remote.ServerConfig
import com.mawena.fluluks.volumes.VolumeManager
import java.io.File
import java.nio.file.Files as NioFiles
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Liste d'un dossier avec sa place réelle (phase 16, T3) : téléphone par lstat, disque par le moteur, distant. */
class DuListTest {
    @get:Rule val tmp = TemporaryFolder()

    private lateinit var e: MemEngine
    private lateinit var delayer: FakeDelayer
    private lateinit var volId: String

    @Before fun setup() {
        e = MemEngine()
        delayer = FakeDelayer()
        VolumeManager.resetForTests(e, delayer = delayer, clock = { delayer.now })
        val disk = VolumeManager.addImageDiskForTests("/x/mem.img", readOnly = false)
        volId = runBlocking { VolumeManager.mountPlain(disk, 1, true) }.id
    }

    private val root: File get() = tmp.root

    /** lstat factice : [stats] par chemin absolu, [reads] note chaque appel. */
    private class FakeLstat(val root: File) : Lstat {
        val stats = HashMap<String, RawStat?>()
        val reads = ArrayList<String>()
        override fun of(path: String): RawStat? {
            reads += path
            return if (stats.containsKey(path)) stats[path] else RawStat(RawStat.S_IFDIR or 0x1ED, 0, 8, 0, 1, 2, 2)
        }
        fun put(name: String, mode: Int, size: Long, blocks: Long, dev: Long = 1, ino: Long = 100, nlink: Int = 1) {
            stats[File(root, name).path] = RawStat(mode, size, blocks, 1_700_000_000, dev, ino, nlink)
        }
    }

    private fun local(l: Lstat) = LocalSource("phone", "phone", "Téléphone", root, l) { true }

    @Test fun localAllocFromBlocks() {
        File(root, "un-octet.bin").writeText("x")
        val l = FakeLstat(root).apply { put("un-octet.bin", RawStat.S_IFREG or 0x1A4, 1, 8) }
        val d = local(l).duList("/").single()
        assertEquals("un-octet.bin", d.name)
        assertEquals(FileType.FILE, d.type)
        assertEquals(1L, d.size)
        assertEquals(4096L, d.alloc)
        assertEquals(1_700_000_000L, d.mtime)
        assertEquals(100L, d.ino)
        assertEquals(1, d.nlink)
        assertFalse(d.otherDevice)
    }

    @Test fun localSparseUsesBlocks() {
        File(root, "creux.bin").writeText("")
        val l = FakeLstat(root).apply { put("creux.bin", RawStat.S_IFREG or 0x1A4, 1L shl 30, 8) }
        val d = local(l).duList("/").single()
        assertEquals(1L shl 30, d.size)
        assertEquals(4096L, d.alloc)
    }

    @Test fun localSymlinkIsLinkNotFollowed() {
        File(root, "cible").mkdir()
        NioFiles.createSymbolicLink(File(root, "lien").toPath(), File(root, "cible").toPath())
        val l = FakeLstat(root).apply {
            put("lien", RawStat.S_IFLNK or 0x1FF, 5, 0)
            put("cible", RawStat.S_IFDIR or 0x1ED, 4096, 8)
        }
        val m = local(l).duList("/").associateBy { it.name }
        assertEquals(FileType.SYMLINK, m["lien"]!!.type)
        assertEquals(0L, m["lien"]!!.alloc)
        // un seul lstat par entrée, et rien sous la cible du lien
        assertEquals(1, l.reads.count { it == File(root, "lien").path })
        assertFalse(l.reads.any { it.startsWith(File(root, "lien").path + "/") })
    }

    @Test fun localAndroidPrivateIsProtected() {
        File(root, "Android/data/x").mkdirs()
        File(root, "Android/obb").mkdirs()
        val s = local(FakeLstat(root))
        for (p in listOf("/Android/data", "/Android/obb", "/android/DATA/x")) {
            try {
                s.duList(p)
                throw AssertionError("accepté : $p")
            } catch (_: ProtectedDirException) {
            }
        }
    }

    @Test fun localOtherDeviceFlagged() {
        File(root, "carte").mkdir()
        File(root, "dossier").mkdir()
        val l = FakeLstat(root).apply {
            stats[root.path] = RawStat(RawStat.S_IFDIR or 0x1ED, 4096, 8, 0, 1, 2, 4)
            put("carte", RawStat.S_IFDIR or 0x1ED, 4096, 8, dev = 9)
            put("dossier", RawStat.S_IFDIR or 0x1ED, 4096, 8, dev = 1)
        }
        val m = local(l).duList("/").associateBy { it.name }
        assertTrue(m["carte"]!!.otherDevice)
        assertFalse(m["dossier"]!!.otherDevice)
    }

    /**
     * Sur le Pixel (essai du 2026-10-27), `Android/data` et `Android/obb` sont des points de montage à part : ils restent
     * « protégés par Android » (listés puis refusés), pas « autre système de fichiers ».
     */
    @Test fun localAndroidPrivateMountNotOtherDevice() {
        File(root, "Android/data").mkdirs()
        File(root, "Android/obb").mkdirs()
        File(root, "Android/media").mkdirs()
        val l = FakeLstat(root).apply {
            stats[root.path] = RawStat(RawStat.S_IFDIR or 0x1ED, 4096, 8, 0, 1, 2, 4)
            put("Android/data", RawStat.S_IFDIR or 0x1ED, 4096, 8, dev = 9)
            put("Android/obb", RawStat.S_IFDIR or 0x1ED, 4096, 8, dev = 9)
            put("Android/media", RawStat.S_IFDIR or 0x1ED, 4096, 8, dev = 9)
        }
        val m = local(l).duList("/Android").associateBy { it.name }
        assertFalse(m["data"]!!.otherDevice)
        assertFalse(m["obb"]!!.otherDevice)
        assertTrue(m["media"]!!.otherDevice)
    }

    @Test fun localVanishedEntrySkipped() {
        File(root, "reste.txt").writeText("r")
        File(root, "parti.txt").writeText("p")
        val l = FakeLstat(root).apply {
            put("reste.txt", RawStat.S_IFREG or 0x1A4, 1, 8)
            stats[File(root, "parti.txt").path] = null
        }
        assertEquals(listOf("reste.txt"), local(l).duList("/").map { it.name })
    }

    private fun disk() = DiskSource(volId, e)

    @Test fun diskListCarriesAllocInoNlink() {
        e.nodes["/a.bin"] = ByteArray(5000)
        e.nodes["/D"] = null
        val m = disk().duList("/").associateBy { it.name }
        assertEquals(8192L, m["a.bin"]!!.alloc)
        assertEquals(5000L, m["a.bin"]!!.size)
        assertEquals(4096L, m["D"]!!.alloc)
        assertEquals(FileType.DIR, m["D"]!!.type)
        assertTrue(m["a.bin"]!!.ino > 0 && m["a.bin"]!!.ino != m["D"]!!.ino)
        assertEquals(1, m["a.bin"]!!.nlink)
        assertEquals(SizeKind.ALLOCATED, disk().sizeKind)
    }

    @Test fun diskListOldEngineFallsBack() {
        // liste « hostile » de MemEngine : seulement name, type, size et mtime, comme un moteur ancien
        e.hostile = { listOf("ancien.bin" to "f") }
        val d = disk().duList("/").single()
        assertEquals(d.size, d.alloc)
        assertEquals(0L, d.ino)
        assertEquals(1, d.nlink)
    }

    @Test fun diskListCountsAsActivity() {
        delayer.now = 1234
        disk().duList("/")
        assertEquals(1234L, VolumeManager.lastActivity(volId))
    }

    @Test fun remoteDefaultIsApparent() {
        val server = tmp.newFolder("serveur")
        File(server, "f.txt").writeText("12345")
        val s = RemoteSource(ServerConfig("s1", "sftp", "Maison", "h", 22, "u", "/", false, null, null), FakeRemoteClient(server))
        assertEquals(SizeKind.APPARENT, s.sizeKind)
        val d = s.duList("/").single()
        assertEquals(5L, d.size)
        assertEquals(5L, d.alloc)
        assertEquals(0L, d.ino)
        assertEquals(1, d.nlink)
        assertNull(s.usedBytes())
    }

    @Test fun usedBytesPerSource() {
        val s = local(FakeLstat(root))
        assertEquals(SizeKind.ALLOCATED, s.sizeKind)
        assertEquals(root.totalSpace - root.freeSpace, s.usedBytes())
        e.total = 10_000; e.free = 2_500
        assertEquals(7_500L, disk().usedBytes())
    }
}
