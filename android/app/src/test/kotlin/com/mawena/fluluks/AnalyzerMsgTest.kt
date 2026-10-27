package com.mawena.fluluks

import com.mawena.fluluks.analyzer.AnalysisProgress
import com.mawena.fluluks.analyzer.AnalysisSummary
import com.mawena.fluluks.analyzer.AnalysisView
import com.mawena.fluluks.analyzer.Exclusion
import com.mawena.fluluks.analyzer.SizeKind
import com.mawena.fluluks.analyzer.ViewNode
import com.mawena.fluluks.bridge.AnalyzerMsgs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Messages Pigeon de l'analyseur (phase 16, T6). */
class AnalyzerMsgTest {
    @Test fun msgConversionKeepsFields() {
        val n = ViewNode(-3, 1, "", "/D", "others", 5000, 4000, 12, 77, false, true, 2)
        val m = AnalyzerMsgs.node(n)
        assertEquals(-3L, m.id); assertEquals(1L, m.parent); assertEquals("others", m.kind); assertEquals(5000L, m.alloc)
        assertEquals(4000L, m.apparent); assertEquals(12L, m.items); assertEquals(77L, m.mtime); assertEquals(2L, m.depth)
        val v = AnalyzerMsgs.view(AnalysisView("a1", 0, "Téléphone", listOf(n), true, false, true, SizeKind.APPARENT))
        assertEquals("apparent", v.sizeKind); assertEquals("Téléphone", v.rootLabel); assertEquals(1, v.nodes.size)
        assertEquals(true, v.simplified)
        val p = AnalyzerMsgs.progress(AnalysisProgress("a1", "phone", "/D", true, false, null, 3, 2, 900, null, "/D/x", 1, 1500))
        assertNull(p.usedBytes); assertNull(p.error); assertEquals(0.0, p.fraction, 0.0); assertEquals(1L, p.inaccessible)
        val p2 = AnalyzerMsgs.progress(AnalysisProgress("a1", "phone", "/", true, false, null, 3, 2, 500, 1000, "/", 0, 10))
        assertEquals(1000L, p2.usedBytes); assertEquals(0.5, p2.fraction, 0.0)
        val s = AnalyzerMsgs.summary(AnalysisSummary("a1", "phone", "Téléphone", "/", 1, null, 10, 2, "running", SizeKind.ALLOCATED))
        assertEquals("allocated", s.sizeKind); assertNull(s.finishedAtMs); assertEquals("running", s.state)
        val e = AnalyzerMsgs.exclusion(Exclusion("phone", "Téléphone", "/Films"))
        assertEquals("phone", e.stableKey); assertEquals("/Films", e.path); assertEquals("Téléphone", e.sourceLabel)
    }
}
