package com.mawena.fluluks.analyzer

import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.engine.FileType
import com.mawena.fluluks.files.Entry
import com.mawena.fluluks.files.ProtectedDirException
import com.mawena.fluluks.provider.DocumentIds
import com.mawena.fluluks.provider.WriteOps
import java.io.FileNotFoundException
import java.util.PriorityQueue

/** Fin d'un parcours. */
enum class ScanEnd { DONE, CANCELLED }

/**
 * Avancement : éléments vus qui ne sont pas des dossiers, dossiers listés, place comptée (dossiers compris), dossier en
 * cours, dossiers refusés par Android.
 */
data class ScanCounters(val files: Long, val dirs: Long, val alloc: Long, val current: String, val inaccessible: Int)

/**
 * Parcours d'un dossier pour l'analyseur (phase 16), le même pour toutes les sources : en profondeur, **itératif**
 * (aucune récursion, quelle que soit l'imbrication), un appel à [list] par dossier. Liens physiques comptés une fois
 * (dev et inode si `nlink` > 1), liens symboliques jamais suivis, autre système de fichiers jamais parcouru ([NodeKind.OTHER_FS]),
 * chemins de [excluded] jamais listés ([NodeKind.EXCLUDED]), dossier refusé par Android ou illisible sur un disque
 * ([EngineError], comme en phase 9) montré ([NodeKind.INACCESSIBLE]),
 * dossier disparu entre la liste de son parent et la sienne oublié. Les [DuTree.FILES_PER_DIR] plus gros fichiers de
 * chaque dossier ont un nœud, les autres sont résumés ; au-delà de [WriteOps.MAX_DEPTH] niveaux ou du plafond de
 * l'arbre, le contenu est résumé dans l'ancêtre gardé. [cancelled] est relu entre deux entrées.
 */
class Scanner(
    val list: (String) -> List<DuEntry>,
    val tree: DuTree,
    val excluded: Set<String>,
    val cancelled: () -> Boolean,
    val onProgress: (ScanCounters) -> Unit,
) {
    /** Dossier à parcourir : [node] est son nœud, ou celui de l'ancêtre gardé s'il est résumé ([folded]). */
    private class Frame(val path: String, val node: Int, val depth: Int, val folded: Boolean) {
        var subdirs: ArrayDeque<DuEntry>? = null // null : pas encore listé
    }

    private var files = 0L
    private var dirs = 0L
    private var alloc = 0L
    private var inaccessible = 0
    private var current = ""
    private val links = HashSet<Pair<Long, Long>>()
    private val top = PriorityQueue<Pair<Long, Entry>>(compareBy { it.first })

    /** Les [DuTree.MAX_BIGGEST] plus gros fichiers vus, par place occupée décroissante. */
    val biggest: List<Entry> get() = top.sortedByDescending { it.first }.map { it.second }

    private fun counters() = ScanCounters(files, dirs, alloc, current, inaccessible)

    /** Parcourt [start] (racine de [tree]). Dossier de départ illisible : l'exception sort. */
    fun run(start: String): ScanEnd {
        tree.rootPath = start
        val stack = ArrayDeque<Frame>()
        stack.addLast(Frame(start, tree.root, 0, false))
        while (stack.isNotEmpty()) {
            if (cancelled()) {
                tree.truncated = true
                return ScanEnd.CANCELLED
            }
            val f = stack.last()
            if (f.subdirs == null) {
                current = f.path
                f.subdirs = listDir(f, start = stack.size == 1) ?: run {
                    tree.truncated = true
                    return ScanEnd.CANCELLED
                }
                dirs++
                onProgress(counters())
            }
            val e = f.subdirs!!.removeFirstOrNull()
            if (e != null) {
                stack.addLast(enter(f, e))
            } else {
                if (!f.folded) tree.setComplete(f.node)
                stack.removeLast()
            }
        }
        return ScanEnd.DONE
    }

    /** Cadre du sous-dossier [e] de [f] : son nœud, ou résumé dans le nœud de [f] (plafond, profondeur). */
    private fun enter(f: Frame, e: DuEntry): Frame {
        val path = DocumentIds.child(f.path, e.name)
        val depth = f.depth + 1
        alloc += e.alloc
        tree.touch(f.node, e.mtime)
        if (!f.folded && depth <= WriteOps.MAX_DEPTH) {
            val n = tree.addDir(f.node, e.name, e.alloc, e.size)
            if (n >= 0) return Frame(path, n, depth, false)
            tree.simplified = true
        } else if (depth > WriteOps.MAX_DEPTH) {
            tree.truncated = true
        }
        tree.addOthers(f.node, 1, e.alloc, e.size)
        return Frame(path, f.node, depth, true)
    }

    /** Liste [f] et range ses entrées ; rend ses sous-dossiers à parcourir (par nom), ou null si annulé. */
    private fun listDir(f: Frame, start: Boolean): ArrayDeque<DuEntry>? {
        val entries = try {
            list(f.path)
        } catch (e: ProtectedDirException) {
            if (start) throw e
            return unreadable(f)
        } catch (e: EngineError) {
            if (start) throw e
            return unreadable(f)
        } catch (e: FileNotFoundException) {
            if (start) throw e
            if (!f.folded) tree.remove(f.node) // disparu depuis la liste de son parent
            return ArrayDeque()
        }
        val kept = ArrayList<DuEntry>()
        val subdirs = ArrayList<DuEntry>()
        for (e in entries) {
            if (cancelled()) return null
            if (e.type == FileType.DIR) {
                val path = DocumentIds.child(f.path, e.name)
                when {
                    path in excluded -> marker(f, e, NodeKind.EXCLUDED)
                    e.otherDevice -> marker(f, e, NodeKind.OTHER_FS)
                    else -> subdirs += e
                }
                continue
            }
            val counted = if (e.nlink > 1 && e.ino != 0L && !links.add(e.dev to e.ino)) e.copy(alloc = 0, size = 0) else e
            files++
            alloc += counted.alloc
            tree.touch(f.node, e.mtime)
            noteBiggest(f.path, counted)
            kept += counted
        }
        kept.sortWith(compareByDescending<DuEntry> { it.alloc }.thenBy { it.name })
        var i = 0
        if (!f.folded) {
            while (i < kept.size && i < DuTree.FILES_PER_DIR) {
                val e = kept[i]
                if (tree.addFile(f.node, e.name, e.alloc, e.size, e.mtime) < 0) {
                    tree.simplified = true
                    break
                }
                i++
            }
        }
        var n = 0L
        var a = 0L
        var s = 0L
        while (i < kept.size) {
            n++
            a += kept[i].alloc
            s += kept[i].size
            i++
        }
        tree.addOthers(f.node, n, a, s)
        subdirs.sortBy { it.name }
        return ArrayDeque(subdirs)
    }

    /** Dossier illisible : nœud [NodeKind.INACCESSIBLE] de taille 0, compté dans `inaccessible`. */
    private fun unreadable(f: Frame): ArrayDeque<DuEntry> {
        inaccessible++
        if (!f.folded) {
            tree.setKind(f.node, NodeKind.INACCESSIBLE)
            tree.addTo(f.node, -tree.alloc(f.node), -tree.apparent(f.node), 0)
        }
        return ArrayDeque()
    }

    /** Dossier jamais listé (exclu, autre système de fichiers) : un nœud de taille 0, sauf dans un dossier résumé. */
    private fun marker(f: Frame, e: DuEntry, kind: NodeKind) {
        if (f.folded) return
        val n = tree.addDir(f.node, e.name)
        if (n < 0) {
            tree.simplified = true
            return
        }
        tree.setKind(n, kind)
        tree.setComplete(n)
    }

    private fun noteBiggest(dir: String, e: DuEntry) {
        if (top.size >= DuTree.MAX_BIGGEST && e.alloc <= top.peek()!!.first) return
        top += e.alloc to Entry(e.name, DocumentIds.child(dir, e.name), e.type, e.size, e.mtime)
        if (top.size > DuTree.MAX_BIGGEST) top.poll()
    }
}
