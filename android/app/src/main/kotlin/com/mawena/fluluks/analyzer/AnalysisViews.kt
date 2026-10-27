package com.mawena.fluluks.analyzer

import com.mawena.fluluks.files.Entry
import com.mawena.fluluks.files.Trash

/**
 * Nœud montré à l'écran. [kind] ∈ `dir`, `file`, `others`, `inaccessible`, `excluded`, `otherFs`, `unscanned`, `trash` ;
 * `others` (contenu trop petit ou résumé d'un dossier, nom vide : libellé côté Dart) et `unscanned` (part hors analyse)
 * ont un identifiant négatif. [depth] : relative à la racine de la vue.
 */
data class ViewNode(
    val id: Int, val parent: Int, val name: String, val path: String, val kind: String, val alloc: Long,
    val apparent: Long, val items: Long, val mtime: Long, val hasChildren: Boolean, val complete: Boolean, val depth: Int,
)

/** Vue d'une analyse pour les graphiques : nœuds en largeur d'abord, la racine de la vue en premier. */
data class AnalysisView(
    val scanId: String, val root: Int, val rootLabel: String, val nodes: List<ViewNode>, val running: Boolean,
    val truncated: Boolean, val simplified: Boolean, val sizeKind: SizeKind,
)

/** Ce que la vue d'une analyse doit savoir de son stockage pour la part hors analyse. */
data class StorageInfo(val usedBytes: Long?, val sizeKind: SizeKind, val phone: Boolean)

/**
 * Vues élaguées d'un [DuTree] (phase 16) : jamais plus de [MAX_NODES] nœuds envoyés à Dart, un élément gardé s'il pèse
 * au moins [MIN_FRACTION] de la racine de la vue (sinon fondu dans le `others` de son parent, avec le contenu résumé
 * du dossier) ; part hors analyse pour un stockage entier si elle dépasse [UNSCANNED_MIN] de la place occupée.
 */
object AnalysisViews {
    const val MAX_NODES = 1500
    const val MIN_FRACTION = 0.002
    const val UNSCANNED_MIN = 0.005
    const val PAGE = 200
    const val MAX_BIGGEST = 100
    const val UNSCANNED_ID = -1
    const val UNSCANNED_PHONE = "Applications, système et dossiers protégés"
    const val UNSCANNED_FS = "Réservé par le système de fichiers"

    fun othersId(parent: Int) = -(parent + 2)

    /** Parent d'un nœud `others`, ou null pour un autre identifiant. */
    fun othersParent(id: Int): Int? = if (id <= -2) -id - 2 else null

    fun kindOf(t: DuTree, n: Int): String = when (t.kind(n)) {
        NodeKind.DIR -> if (t.path(n) == Trash.DIR) "trash" else "dir"
        NodeKind.FILE -> "file"
        NodeKind.INACCESSIBLE -> "inaccessible"
        NodeKind.EXCLUDED -> "excluded"
        NodeKind.OTHER_FS -> "otherFs"
    }

    private fun hasContent(t: DuTree, n: Int) = t.hasChildren(n) || t.others(n).count > 0

    private fun node(t: DuTree, n: Int, depth: Int) = ViewNode(
        n, t.parent(n), t.name(n), t.path(n), kindOf(t, n), t.alloc(n), t.apparent(n), t.items(n), t.mtime(n),
        hasContent(t, n), t.complete(n), depth,
    )

    private fun others(t: DuTree, p: Int, count: Long, alloc: Long, apparent: Long, depth: Int) =
        ViewNode(othersId(p), p, "", t.path(p), "others", alloc, apparent, count, 0, false, true, depth)

    /** Part hors analyse sous la racine de l'arbre, ou null (sous-dossier, taille apparente, part trop petite). */
    fun unscanned(t: DuTree, info: StorageInfo): Long? {
        val used = info.usedBytes ?: return null
        if (t.rootPath != "/" || info.sizeKind != SizeKind.ALLOCATED) return null
        val rest = used - t.alloc(t.root)
        return rest.takeIf { it > used * UNSCANNED_MIN }
    }

    /**
     * Vue de [root] sur [depth] niveaux, [maxNodes] nœuds au plus. La racine de l'arbre d'un stockage entier compte la
     * part hors analyse dans sa place, pour que ses parts fassent le tour complet.
     */
    fun build(scanId: String, t: DuTree, root: Int, depth: Int, maxNodes: Int, info: StorageInfo, running: Boolean): AnalysisView {
        val out = ArrayList<ViewNode>()
        val rest = if (root == t.root) unscanned(t, info) else null
        val top = node(t, root, 0)
        out += if (rest != null) top.copy(alloc = top.alloc + rest, apparent = top.apparent + rest) else top
        val threshold = (t.alloc(root) * MIN_FRACTION).toLong()
        val queue = ArrayDeque<Pair<Int, Int>>().apply { addLast(root to 0) }
        while (queue.isNotEmpty() && out.size < maxNodes) {
            val (n, d) = queue.removeFirst()
            if (d >= depth) continue
            val o = t.others(n)
            var count = o.count
            var alloc = o.alloc
            var apparent = o.apparent
            for (c in t.children(n)) {
                if (t.alloc(c) >= threshold && t.alloc(c) > 0 && out.size < maxNodes - 1) {
                    out += node(t, c, d + 1)
                    queue.addLast(c to d + 1)
                } else {
                    count += 1 + t.items(c)
                    alloc += t.alloc(c)
                    apparent += t.apparent(c)
                }
            }
            if ((count > 0 || alloc > 0) && out.size < maxNodes) out += others(t, n, count, alloc, apparent, d + 1)
            if (n == root && rest != null && out.size < maxNodes) {
                val label = if (info.phone) UNSCANNED_PHONE else UNSCANNED_FS
                out += ViewNode(UNSCANNED_ID, root, label, "", "unscanned", rest, rest, 0, 0, false, true, 1)
            }
        }
        return AnalysisView(scanId, root, t.name(root).ifEmpty { t.path(root) }, out, running, t.truncated, t.simplified, info.sizeKind)
    }

    /**
     * Enfants de [n] pour l'arbre de l'écran, triés par [sort] (`size`, `name`, `items`, `date`), page de [limit] à
     * partir de [offset] ; le contenu résumé du dossier vient en dernier, dans un nœud `others`.
     */
    fun children(t: DuTree, n: Int, sort: String, offset: Int, limit: Int): List<ViewNode> {
        val kids = t.children(n).toList()
        val sorted = when (sort) {
            "name" -> kids.sortedWith(compareBy<Int> { t.name(it).lowercase() }.thenBy { t.name(it) })
            "items" -> kids.sortedWith(compareByDescending<Int> { t.items(it) }.thenBy { t.name(it) })
            "date" -> kids.sortedWith(compareByDescending<Int> { t.mtime(it) }.thenBy { t.name(it) })
            else -> kids // déjà par place décroissante
        }
        val all = sorted.map { node(t, it, 1) } + listOfNotNull(
            t.others(n).takeIf { it.count > 0 }?.let { others(t, n, it.count, it.alloc, it.apparent, 1) },
        )
        if (offset >= all.size || limit <= 0) return emptyList()
        return all.subList(offset.coerceAtLeast(0), minOf(all.size, offset.coerceAtLeast(0) + limit))
    }

    /** Les [MAX_BIGGEST] plus gros fichiers sous [path] (lui compris), parmi ceux gardés par l'analyse. */
    fun biggest(all: List<Entry>, path: String): List<Entry> {
        val prefix = if (path == "/") "/" else "$path/"
        return all.filter { it.path.startsWith(prefix) }.take(MAX_BIGGEST)
    }
}
