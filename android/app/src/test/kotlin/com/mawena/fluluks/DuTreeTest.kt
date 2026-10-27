package com.mawena.fluluks

import com.mawena.fluluks.analyzer.DuTree
import com.mawena.fluluks.analyzer.NodeKind
import com.mawena.fluluks.analyzer.Others
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Arbre compact de l'analyseur (phase 16, T4). */
class DuTreeTest {
    /** / → a.bin (100), D (4096 propre) → b.bin (8192), c.bin (8192). */
    private fun sample(): Triple<DuTree, Int, Int> {
        val t = DuTree()
        t.addFile(t.root, "a.bin", 4096, 100, 10)
        val d = t.addDir(t.root, "D", 4096, 4096)
        t.addFile(d, "c.bin", 8192, 8000, 20)
        val b = t.addFile(d, "b.bin", 8192, 8000, 30)
        return Triple(t, d, b)
    }

    @Test fun childrenSortedBySizeThenName() {
        val (t, d, _) = sample()
        assertEquals(listOf("D", "a.bin"), t.children(t.root).map { t.name(it) })
        assertEquals(listOf("b.bin", "c.bin"), t.children(d).map { t.name(it) }) // même place : par nom
        assertEquals(4096L + 4096 + 8192 + 8192, t.alloc(t.root))
        assertEquals(100L + 4096 + 8000 + 8000, t.apparent(t.root))
        assertEquals(4L, t.items(t.root))
        assertEquals(2L, t.items(d))
        assertEquals(30L, t.mtime(t.root))
        assertEquals(30L, t.mtime(d))
        assertEquals(NodeKind.DIR, t.kind(d))
        assertEquals(NodeKind.FILE, t.kind(t.children(d)[0]))
        assertTrue(t.complete(t.children(d)[0]))
        assertFalse(t.complete(d))
    }

    @Test fun pathRebuiltFromParents() {
        val (t, d, b) = sample()
        assertEquals("/", t.path(t.root))
        assertEquals("/D/b.bin", t.path(b))
        t.rootPath = "/DCIM"
        assertEquals("/DCIM", t.path(t.root))
        assertEquals("/DCIM/D", t.path(d))
        assertEquals(t.root, t.parent(d))
        assertEquals(-1, t.parent(t.root))
    }

    @Test fun findByPath() {
        val (t, d, b) = sample()
        assertEquals(t.root, t.find("/"))
        assertEquals(d, t.find("/D"))
        assertEquals(b, t.find("/D/b.bin"))
        assertNull(t.find("/D/x"))
        t.rootPath = "/DCIM"
        assertEquals(b, t.find("/DCIM/D/b.bin"))
        assertNull(t.find("/D/b.bin"))
        assertNull(t.find("/DCIMx/D"))
    }

    @Test fun removePropagatesToAncestors() {
        val (t, d, b) = sample()
        t.remove(b)
        assertEquals(4096L + 8192, t.alloc(d))
        assertEquals(1L, t.items(d))
        assertEquals(3L, t.items(t.root))
        assertEquals(listOf("c.bin"), t.children(d).map { t.name(it) })
        assertNull(t.find("/D/b.bin"))
        t.remove(d)
        assertEquals(4096L, t.alloc(t.root))
        assertEquals(1L, t.items(t.root))
        t.remove(d) // déjà retiré : sans effet
        assertEquals(4096L, t.alloc(t.root))
    }

    @Test fun addToPropagates() {
        val (t, d, _) = sample()
        t.addTo(d, 1000, 10, 2)
        assertEquals(4096L + 8192 + 8192 + 1000, t.alloc(d))
        assertEquals(4096L + 4096 + 8192 + 8192 + 1000, t.alloc(t.root))
        assertEquals(6L, t.items(t.root))
        t.addOthers(d, 5, 500, 50)
        assertEquals(Others(5, 500, 50), t.others(d))
        assertEquals(Others(0, 0, 0), t.others(t.root))
        assertEquals(11L, t.items(t.root))
    }

    @Test fun namesUtf8Pool() {
        val t = DuTree()
        val long = "é".repeat(127) + "x" // 255 octets
        val a = t.addDir(t.root, "été ☀")
        val b = t.addFile(a, long, 1, 1, 0)
        val c = t.addFile(t.root, "", 0, 0, 0)
        assertEquals("été ☀", t.name(a))
        assertEquals(long, t.name(b))
        assertEquals("", t.name(c))
        assertEquals("/été ☀/$long", t.path(b))
        assertEquals(b, t.find("/été ☀/$long"))
    }

    @Test fun capRefusesNodes() {
        val t = DuTree(maxNodes = 3)
        assertTrue(t.addDir(t.root, "a") >= 0)
        assertTrue(t.addFile(t.root, "b", 1, 1, 0) >= 0)
        assertTrue(t.full)
        assertEquals(-1, t.addDir(t.root, "c"))
        assertEquals(-1, t.addFile(t.root, "d", 1, 1, 0))
        assertEquals(3, t.nodeCount)
    }

    @Test fun bytesEstimateUnder64BytesPerNode() {
        val t = DuTree()
        var d = t.root
        for (i in 0 until 100_000) {
            val name = "nom-%08d".format(i) // 12 octets
            if (i % 100 == 0) d = t.addDir(t.root, name) else t.addFile(d, name, 4096, 10, 0)
        }
        assertEquals(100_001, t.nodeCount)
        assertTrue("${t.bytesEstimate()}", t.bytesEstimate() < 6_400_000)
    }
}
