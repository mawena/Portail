package com.mawena.fluluks.analyzer

import androidx.annotation.VisibleForTesting
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.files.Entry
import com.mawena.fluluks.files.Files
import com.mawena.fluluks.files.FilesException
import com.mawena.fluluks.files.PathRules
import com.mawena.fluluks.files.Sources
import com.mawena.fluluks.files.Trash
import com.mawena.fluluks.volumes.VolumeManager
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Avancement de l'analyse en cours (ou de la dernière). [bytes] : place comptée ; [usedBytes] : place occupée du
 * stockage, seulement pour un stockage entier en place occupée (sinon null, pas de pourcentage).
 */
data class AnalysisProgress(
    val scanId: String, val sourceId: String, val path: String, val running: Boolean, val cancelled: Boolean,
    val error: String?, val files: Long, val dirs: Long, val bytes: Long, val usedBytes: Long?, val current: String,
    val inaccessible: Int, val elapsedMs: Long,
) {
    /**
     * Part faite, de 0 à 1 : bornée à 0,99 avant la fin (liens physiques, compression, fichiers creux peuvent faire
     * dépasser la place occupée), 1 à la fin ; 0 sans [usedBytes].
     */
    val fraction: Double
        get() = when {
            !running -> 1.0
            usedBytes == null || usedBytes <= 0 -> 0.0
            else -> (bytes.toDouble() / usedBytes).coerceIn(0.0, 0.99)
        }
}

/** Analyse gardée en mémoire. [state] ∈ `running`, `done`, `cancelled`, `failed`. */
data class AnalysisSummary(
    val scanId: String, val sourceId: String, val label: String, val path: String, val startedAtMs: Long,
    val finishedAtMs: Long?, val bytes: Long, val files: Long, val state: String, val sizeKind: SizeKind,
)

/**
 * Analyseur de stockage (phase 16, remplace l'analyse de la phase 9) : une analyse à la fois, sur un fil de priorité
 * basse, qui continue si l'on quitte l'écran ; les [MAX_KEPT] dernières gardées en mémoire ([MAX_TOTAL_NODES] nœuds
 * en tout) pour descendre dans les dossiers sans relire le stockage. L'arbre est sous un verrou lecture-écriture :
 * le parcours le tient en écriture, sauf pendant la liste d'un dossier ; vues et pages d'enfants le lisent pendant
 * l'analyse. Un volume fermé (absent de [VolumeManager.volumes]) arrête son analyse, vu entre deux entrées, et fait
 * oublier les siennes à l'accès suivant : relu directement plutôt qu'observé, pour ne jamais attendre la fin d'un
 * parcours qui tient le fil.
 */
object Analyzer {
    const val MAX_KEPT = 3
    const val MAX_TOTAL_NODES = 1_000_000
    const val PROGRESS_MS = 250L
    const val MSG_SOURCE_CLOSED = "Le stockage a été fermé pendant l'analyse"
    const val MSG_ROOT = "La racine de l'analyse ne peut pas être supprimée"
    const val MSG_NOT_DELETABLE = "Cet élément ne peut pas être supprimé d'ici"
    const val MSG_GONE = "Cette analyse n'est plus disponible"

    private class Scan(
        val id: String, val sourceId: String, val label: String, val path: String, val stableKey: String,
        val startedAt: Long, val info: StorageInfo, val volume: Boolean, val tree: DuTree,
    ) {
        val lock = ReentrantReadWriteLock()
        @Volatile var state = "running"
        @Volatile var cancel = false
        @Volatile var error: String? = null
        @Volatile var finishedAt: Long? = null
        @Volatile var counters = ScanCounters(0, 0, 0, path, 0)
        @Volatile var biggest: List<Entry> = emptyList()
        var lastPublish = Long.MIN_VALUE
    }

    private val scans = LinkedHashMap<String, Scan>() // sous `this`, de la plus ancienne à la plus récente
    private val ids = AtomicInteger()
    private val _progress = MutableStateFlow<AnalysisProgress?>(null)
    val progress: StateFlow<AnalysisProgress?> = _progress.asStateFlow()

    /** Nombre d'avancements publiés (tests). */
    @VisibleForTesting @Volatile var published = 0
        private set

    @Volatile private var clock: () -> Long = System::currentTimeMillis
    @Volatile private var scanDispatcher: CoroutineDispatcher = Executors.newSingleThreadExecutor { r ->
        Thread({
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
            r.run()
        }, "analyseur").apply { isDaemon = true }
    }.asCoroutineDispatcher()
    @Volatile private var ioDispatcher: CoroutineDispatcher = Dispatchers.IO
    @Volatile private var scope = CoroutineScope(SupervisorJob() + scanDispatcher)
    @Volatile private var dir: File? = null

    /** Dossier privé de l'application (`analyzer.json`), posé au démarrage. */
    fun init(filesDir: File) {
        dir = filesDir
    }

    private fun prefs(): AnalyzerPrefs? = dir?.let(::AnalyzerPrefs)

    @VisibleForTesting
    fun resetForTests(dispatcher: CoroutineDispatcher, clock: () -> Long, dir: File) {
        cancel()
        scope.cancel()
        synchronized(this) { scans.clear() }
        _progress.value = null
        published = 0
        this.clock = clock
        this.dir = dir
        scanDispatcher = dispatcher
        ioDispatcher = dispatcher
        scope = CoroutineScope(SupervisorJob() + dispatcher)
    }

    /**
     * Analyse [path] de [sourceId] (arrête celle en cours) ; rend son identifiant. Dossier de départ illisible : l'erreur
     * est dans [progress] (`failed`).
     */
    fun start(sourceId: String, path: String): String {
        val p = Files.guard("queryChildDocuments") { PathRules.require(path) }
        val src = Files.source(sourceId)
        cancel()
        val kind = src.sizeKind
        val used = if (p == "/" && kind == SizeKind.ALLOCATED) runCatching { src.usedBytes() }.getOrNull() else null
        val info = StorageInfo(used, kind, sourceId == Sources.PHONE)
        val stableKey = runCatching { src.stableKey }.getOrDefault(sourceId)
        val label = runCatching { src.label }.getOrDefault("")
        val excluded = prefs()?.exclusions()?.filter { it.stableKey == stableKey }?.map { it.path }?.toSet() ?: emptySet()
        val scan = Scan(
            "a${ids.incrementAndGet()}", sourceId, label, p, stableKey, clock(), info,
            VolumeManager.volume(sourceId) != null, DuTree(),
        )
        synchronized(this) {
            // Réanalyser remplace l'analyse du même emplacement, sans chasser les autres
            scans.values.removeAll { it.sourceId == sourceId && it.path == p }
            scans[scan.id] = scan
            trim()
        }
        publish(scan)
        scope.launch { runScan(scan, excluded) }
        return scan.id
    }

    private fun runScan(scan: Scan, excluded: Set<String>) {
        val w = scan.lock.writeLock()
        w.lock()
        try {
            val src = Files.source(scan.sourceId)
            val scanner = Scanner(
                list = { path ->
                    w.unlock() // les vues lisent l'arbre pendant la liste
                    try { src.duList(path) } finally { w.lock() }
                },
                tree = scan.tree,
                excluded = excluded,
                cancelled = { scan.cancel || closed(scan) },
                onProgress = { c ->
                    scan.counters = c
                    if (clock() - scan.lastPublish >= PROGRESS_MS) publish(scan)
                },
            )
            val end = scanner.run(scan.path)
            scan.biggest = scanner.biggest
            scan.state = when {
                scan.error != null -> "failed"
                end == ScanEnd.DONE -> "done"
                else -> "cancelled"
            }
        } catch (e: Throwable) {
            scan.state = "failed"
            if (scan.error == null) scan.error = Files.toFilesException(e, "queryChildDocuments").message
        } finally {
            w.unlock()
        }
        scan.finishedAt = clock()
        publish(scan)
        synchronized(this) { trim() }
    }

    private fun publish(scan: Scan) {
        scan.lastPublish = clock()
        val c = scan.counters
        val running = scan.state == "running"
        _progress.value = AnalysisProgress(
            scan.id, scan.sourceId, scan.path, running, scan.state == "cancelled", scan.error, c.files, c.dirs, c.alloc,
            scan.info.usedBytes, c.current, c.inaccessible, (scan.finishedAt ?: clock()) - scan.startedAt,
        )
        published++
    }

    /** Oublie les plus anciennes analyses finies au-delà de [MAX_KEPT] ou de [MAX_TOTAL_NODES] nœuds (sous `this`). */
    private fun trim() {
        while (true) {
            val total = scans.values.sumOf { it.tree.nodeCount.toLong() }
            if (scans.size <= MAX_KEPT && total <= MAX_TOTAL_NODES) return
            val oldest = scans.values.firstOrNull { it.state != "running" } ?: return
            if (oldest === scans.values.last()) return // la plus récente reste
            scans.remove(oldest.id)
        }
    }

    /** Arrête l'analyse en cours ; elle garde ce qu'elle a vu. */
    fun cancel() {
        synchronized(this) { scans.values.filter { it.state == "running" } }.forEach { it.cancel = true }
    }

    /** Volume de [scan] fermé : l'analyse en cours s'arrête avec [MSG_SOURCE_CLOSED]. */
    private fun closed(scan: Scan): Boolean {
        if (!scan.volume || VolumeManager.volume(scan.sourceId) != null) return false
        if (scan.state == "running" && scan.error == null) scan.error = MSG_SOURCE_CLOSED
        scan.cancel = true
        return true
    }

    /** Oublie les analyses des volumes fermés. */
    private fun dropClosed() {
        val gone = synchronized(this) { scans.values.filter { closed(it) }.onEach { scans.remove(it.id) } }
        gone.forEach { it.cancel = true }
    }

    private fun scan(scanId: String): Scan {
        dropClosed()
        return synchronized(this) { scans[scanId] } ?: throw FilesException(EngineError.FL_ENOENT, MSG_GONE)
    }

    /** Analyses gardées, de la plus récente à la plus ancienne. */
    fun list(): List<AnalysisSummary> = dropClosed().let { synchronized(this) { scans.values.toList() } }.asReversed().map { s ->
        s.lock.read {
            AnalysisSummary(
                s.id, s.sourceId, s.label, s.path, s.startedAt, s.finishedAt, s.tree.alloc(s.tree.root),
                s.counters.files, s.state, s.info.sizeKind,
            )
        }
    }

    fun forget(scanId: String) {
        val s = synchronized(this) { scans.remove(scanId) } ?: return
        s.cancel = true
    }

    /** Vue de [node] pour les graphiques ([AnalysisViews.build]). */
    fun view(scanId: String, node: Int, depth: Int, maxNodes: Int): AnalysisView {
        val s = scan(scanId)
        return s.lock.read {
            val n = if (node in 0 until s.tree.nodeCount) node else s.tree.root
            val v = AnalysisViews.build(s.id, s.tree, n, depth, maxNodes.coerceAtMost(AnalysisViews.MAX_NODES), s.info, s.state == "running")
            if (n != s.tree.root) v else v.copy(rootLabel = if (s.path == "/") s.label else s.path.substringAfterLast('/'))
        }
    }

    fun children(scanId: String, node: Int, sort: String, offset: Int, limit: Int): List<ViewNode> {
        val s = scan(scanId)
        return s.lock.read {
            if (node !in 0 until s.tree.nodeCount) emptyList()
            else AnalysisViews.children(s.tree, node, sort, offset, limit.coerceAtMost(AnalysisViews.PAGE))
        }
    }

    fun biggest(scanId: String, node: Int): List<Entry> {
        val s = scan(scanId)
        val path = s.lock.read { if (node in 0 until s.tree.nodeCount) s.tree.path(node) else return emptyList() }
        return AnalysisViews.biggest(s.biggest, path)
    }

    /** Nœud réel qu'une action peut viser : ni la racine, ni une part virtuelle, ni un dossier jamais lu. */
    private fun target(s: Scan, node: Int): String = s.lock.read {
        val t = s.tree
        if (node == t.root) throw FilesException(EngineError.FL_EINVAL, MSG_ROOT)
        if (node !in 0 until t.nodeCount || t.parent(node) < 0 || t.kind(node) !in setOf(NodeKind.DIR, NodeKind.FILE)) {
            throw FilesException(EngineError.FL_EINVAL, MSG_NOT_DELETABLE)
        }
        t.path(node)
    }

    /**
     * Supprime [node] par [Files.delete] (mêmes refus que l'explorateur), puis met l'arbre à jour sans réanalyse : à la
     * corbeille, sa place passe sur le nœud de la corbeille du stockage, puisqu'elle n'est pas libérée.
     */
    suspend fun delete(scanId: String, node: Int, permanent: Boolean) {
        val s = scan(scanId)
        val path = target(s, node)
        val trash = withContext(ioDispatcher) {
            val src = Files.source(s.sourceId)
            Files.delete(s.sourceId, listOf(path), permanent)
            !permanent && src.hasTrash && !Trash.isInTrash(path)
        }
        s.lock.write {
            val t = s.tree
            if (t.parent(node) < 0) return@write
            val alloc = t.alloc(node)
            val apparent = t.apparent(node)
            val items = t.items(node) + 1
            t.remove(node)
            if (!trash || t.rootPath != "/") return@write
            val bin = t.find(Trash.DIR) ?: t.addDir(t.root, Trash.DIR.removePrefix("/")).also { if (it >= 0) t.setComplete(it) }
            if (bin >= 0) t.addOthers(bin, items, alloc, apparent) else t.addOthers(t.root, items, alloc, apparent)
        }
    }

    /** Exclut [node] des analyses suivantes de ce stockage ; il est montré exclu, ses ancêtres diminués. */
    fun exclude(scanId: String, node: Int) {
        val s = scan(scanId)
        val path = target(s, node)
        prefs()?.add(Exclusion(s.stableKey, s.label, path))
        s.lock.write {
            val t = s.tree
            val parent = t.parent(node)
            val name = t.name(node)
            t.remove(node)
            val e = t.addDir(parent, name)
            if (e >= 0) {
                t.setKind(e, NodeKind.EXCLUDED)
                t.setComplete(e)
            }
        }
    }

    fun exclusions(): List<Exclusion> = prefs()?.exclusions() ?: emptyList()

    fun removeExclusion(stableKey: String, path: String) {
        prefs()?.remove(stableKey, path)
    }
}
