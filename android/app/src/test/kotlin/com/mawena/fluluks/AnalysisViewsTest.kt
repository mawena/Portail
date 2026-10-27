package com.mawena.fluluks

import com.mawena.fluluks.analyzer.AnalysisViews
import com.mawena.fluluks.analyzer.DuTree
import com.mawena.fluluks.analyzer.SizeKind
import com.mawena.fluluks.analyzer.StorageInfo
import com.mawena.fluluks.engine.FileType
import com.mawena.fluluks.files.Entry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Vues élaguées de l'analyseur (phase 16, T5). */
class AnalysisViewsTest {
    private val sub = StorageInfo(null, SizeKind.ALLOCATED, phone = true)

    /** / → A (B → c.bin 400 000), d.bin 600 000. */
    private fun sample(): DuTree {
        val t = DuTree()
        val a = t.addDir(t.root, "A", 4096, 4096)
        val b = t.addDir(a, "B", 4096, 4096)
        t.addFile(b, "c.bin", 400_000, 400_000, 5)
        t.addFile(t.root, "d.bin", 600_000, 600_000, 9)
        return t
    }

    @Test fun viewDepthLimited() {
        val t = sample()
        val v = AnalysisViews.build("a1", t, t.root, 1, 1500, sub, running = false)
        assertEquals(listOf("", "d.bin", "A"), v.nodes.map { it.name })
        assertEquals(listOf(0, 1, 1), v.nodes.map { it.depth })
        val a = v.nodes.first { it.name == "A" }
        assertTrue(a.hasChildren) // B n'est pas dans la vue, mais existe
        assertEquals("dir", a.kind)
        assertEquals(t.root, v.nodes[0].id)
        assertEquals(t.root, a.parent)
        val deep = AnalysisViews.build("a1", t, t.root, 3, 1500, sub, running = false)
        assertEquals(listOf("", "d.bin", "A", "B", "c.bin"), deep.nodes.map { it.name }) // largeur d'abord
        assertEquals("/A/B/c.bin", deep.nodes.last().path)
        // vue d'un sous-dossier : il est la racine, profondeurs relatives
        val fromA = AnalysisViews.build("a1", t, t.find("/A")!!, 2, 1500, sub, running = true)
        assertEquals(listOf(0, 1, 2), fromA.nodes.map { it.depth })
        assertEquals("A", fromA.rootLabel)
        assertTrue(fromA.running)
    }

    @Test fun smallNodesMergedIntoOthers() {
        val t = DuTree()
        t.addFile(t.root, "gros", 1_000_000, 1_000_000, 0)
        t.addFile(t.root, "moyen", 3_000, 3_000, 0) // 0,3 % : gardé
        t.addFile(t.root, "petit1", 1_000, 1_000, 0) // 0,1 % : fondu
        t.addFile(t.root, "petit2", 500, 400, 0)
        val v = AnalysisViews.build("a1", t, t.root, 2, 1500, sub, running = false)
        assertEquals(listOf("gros", "moyen", ""), v.nodes.drop(1).map { it.name })
        val o = v.nodes.last()
        assertEquals("others", o.kind)
        assertEquals(AnalysisViews.othersId(t.root), o.id)
        assertEquals(t.root, AnalysisViews.othersParent(o.id))
        assertEquals(1_500L, o.alloc)
        assertEquals(1_400L, o.apparent)
        assertEquals(2L, o.items)
        assertEquals(v.nodes[0].alloc, v.nodes.drop(1).sumOf { it.alloc }) // le tour est complet
    }

    @Test fun viewNeverExceedsMaxNodes() {
        val t = DuTree()
        for (i in 0 until 50_000) t.addDir(t.root, "d$i", 4096, 4096)
        val v = AnalysisViews.build("a1", t, t.root, 4, 1500, sub, running = false)
        assertTrue(v.nodes.size <= 1500)
        assertEquals(t.alloc(t.root), v.nodes.drop(1).sumOf { it.alloc })
        // 400 chaînes de 4 niveaux, chaque nœud à 0,25 % : 1 601 nœuds gardables, le plafond coupe au 4e niveau
        val big = DuTree()
        for (i in 0 until 400) {
            val s = big.addDir(big.addDir(big.root, "d$i"), "s")
            big.addFile(big.addDir(s, "u"), "f", 1 shl 20, 1 shl 20, 0)
        }
        val v2 = AnalysisViews.build("a1", big, big.root, 4, 1500, sub, running = false)
        assertEquals(1500, v2.nodes.size)
        assertEquals("others", v2.nodes.last().kind)
        assertEquals(big.alloc(big.root), v2.nodes.filter { it.depth == 1 }.sumOf { it.alloc })
        assertNull(AnalysisViews.othersParent(5))
    }

    @Test fun foldedContentShownAsOthers() {
        val t = DuTree()
        val d = t.addDir(t.root, "D", 4096, 4096)
        t.addFile(d, "f", 100_000, 100_000, 0)
        t.addOthers(d, 980, 50_000, 40_000)
        val v = AnalysisViews.build("a1", t, t.root, 2, 1500, sub, running = false)
        val o = v.nodes.single { it.kind == "others" }
        assertEquals(d, o.parent)
        assertEquals(50_000L, o.alloc)
        assertEquals(980L, o.items)
        assertEquals("/D", o.path)
        assertTrue(v.nodes.single { it.name == "D" }.hasChildren)
    }

    @Test fun childrenPagedAndSorted() {
        val t = DuTree()
        for (i in 0 until 450) t.addFile(t.root, "f%03d".format(i), (i + 1) * 10L, 1, (450 - i).toLong())
        t.addOthers(t.root, 7, 5, 5)
        val p1 = AnalysisViews.children(t, t.root, "size", 0, 200)
        assertEquals(200, p1.size)
        assertEquals("f449", p1[0].name)
        val p3 = AnalysisViews.children(t, t.root, "size", 400, 200)
        assertEquals(51, p3.size) // 50 fichiers et le contenu résumé
        assertEquals("others", p3.last().kind)
        assertEquals(listOf("f000", "f001"), AnalysisViews.children(t, t.root, "name", 0, 2).map { it.name })
        assertEquals("f000", AnalysisViews.children(t, t.root, "date", 0, 1)[0].name)
        assertTrue(AnalysisViews.children(t, t.root, "size", 451, 200).isEmpty())
        val d = t.addDir(t.root, "D")
        t.addFile(d, "x", 1, 1, 0); t.addFile(d, "y", 1, 1, 0)
        assertEquals("D", AnalysisViews.children(t, t.root, "items", 0, 1)[0].name)
    }

    @Test fun biggestUnderNode() {
        val all = (0 until 300).map { Entry("f$it", if (it % 2 == 0) "/A/f$it" else "/AB/f$it", FileType.FILE, 1, 0) }
        val a = AnalysisViews.biggest(all, "/A")
        assertEquals(100, a.size)
        assertTrue(a.all { it.path.startsWith("/A/") })
        assertEquals(100, AnalysisViews.biggest(all, "/").size)
        assertTrue(AnalysisViews.biggest(all, "/C").isEmpty())
    }

    @Test fun unscannedPartForWholeStorage() {
        val t = sample() // 1 008 192 comptés
        val phone = StorageInfo(2_000_000, SizeKind.ALLOCATED, phone = true)
        val v = AnalysisViews.build("a1", t, t.root, 2, 1500, phone, running = false)
        val u = v.nodes.single { it.kind == "unscanned" }
        assertEquals(AnalysisViews.UNSCANNED_ID, u.id)
        assertEquals(2_000_000L - t.alloc(t.root), u.alloc)
        assertEquals(AnalysisViews.UNSCANNED_PHONE, u.name)
        assertEquals(2_000_000L, v.nodes[0].alloc) // le tour complet vaut la place occupée
        val disk = AnalysisViews.build("a1", t, t.root, 2, 1500, phone.copy(phone = false), running = false)
        assertEquals(AnalysisViews.UNSCANNED_FS, disk.nodes.single { it.kind == "unscanned" }.name)
        // part trop petite (≤ 0,5 %), sous-dossier, taille apparente : aucune
        val tiny = StorageInfo(t.alloc(t.root) + 100, SizeKind.ALLOCATED, phone = true)
        assertFalse(AnalysisViews.build("a1", t, t.root, 2, 1500, tiny, false).nodes.any { it.kind == "unscanned" })
        assertFalse(AnalysisViews.build("a1", t, t.find("/A")!!, 2, 1500, phone, false).nodes.any { it.kind == "unscanned" })
        assertFalse(AnalysisViews.build("a1", t, t.root, 2, 1500, phone.copy(sizeKind = SizeKind.APPARENT), false).nodes.any { it.kind == "unscanned" })
        t.rootPath = "/DCIM"
        assertFalse(AnalysisViews.build("a1", t, t.root, 2, 1500, phone, false).nodes.any { it.kind == "unscanned" })
    }

    @Test fun trashDirMarked() {
        val t = DuTree()
        val bin = t.addDir(t.root, ".Portail-corbeille", 4096, 4096)
        t.addFile(bin, "x", 1 shl 20, 1 shl 20, 0)
        t.addDir(t.root, "autre", 4096, 4096)
        val v = AnalysisViews.build("a1", t, t.root, 1, 1500, sub, running = false)
        assertEquals("trash", v.nodes.single { it.name == ".Portail-corbeille" }.kind)
        assertEquals("dir", v.nodes.single { it.name == "autre" }.kind)
    }
}
