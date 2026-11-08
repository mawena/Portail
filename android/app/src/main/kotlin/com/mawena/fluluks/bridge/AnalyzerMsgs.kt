package com.mawena.fluluks.bridge

import com.mawena.fluluks.analyzer.AnalysisProgress
import com.mawena.fluluks.analyzer.AnalysisSummary
import com.mawena.fluluks.analyzer.AnalysisView
import com.mawena.fluluks.analyzer.Exclusion
import com.mawena.fluluks.analyzer.SizeKind
import com.mawena.fluluks.analyzer.ViewNode

/** Types de l'analyseur (phase 16) vers les messages Pigeon. */
object AnalyzerMsgs {
    fun sizeKind(k: SizeKind) = if (k == SizeKind.ALLOCATED) "allocated" else "apparent"

    fun node(n: ViewNode) = AnalysisNodeMsg(
        n.id.toLong(), n.parent.toLong(), n.name, n.path, n.kind, n.alloc, n.apparent, n.items, n.mtime, n.hasChildren,
        n.complete, n.depth.toLong(),
    )

    fun view(v: AnalysisView) = AnalysisViewMsg(
        v.scanId, v.root.toLong(), v.rootLabel, v.nodes.map(::node), v.running, v.truncated, v.simplified, sizeKind(v.sizeKind),
    )

    fun progress(p: AnalysisProgress) = AnalysisProgressMsg(
        p.scanId, p.sourceId, p.path, p.running, p.cancelled, p.error, p.files, p.dirs, p.bytes, p.usedBytes, p.current,
        p.inaccessible.toLong(), p.elapsedMs, p.fraction,
    )

    fun summary(s: AnalysisSummary) = AnalysisSummaryMsg(
        s.scanId, s.sourceId, s.label, s.path, s.startedAtMs, s.finishedAtMs, s.bytes, s.files, s.state, sizeKind(s.sizeKind),
    )

    fun exclusion(e: Exclusion) = AnalysisExclusionMsg(e.stableKey, e.sourceLabel, e.path)
}
