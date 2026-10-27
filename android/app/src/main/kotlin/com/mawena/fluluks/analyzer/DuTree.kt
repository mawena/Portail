package com.mawena.fluluks.analyzer

/** Nature d'un nœud de l'arbre d'analyse. */
enum class NodeKind { DIR, FILE, INACCESSIBLE, EXCLUDED, OTHER_FS }

/** Contenu d'un dossier qui n'a pas de nœud : fichiers au-delà des [DuTree.FILES_PER_DIR] plus gros, dossiers résumés. */
data class Others(val count: Long, val alloc: Long, val apparent: Long)

/**
 * Arbre d'une analyse (phase 16), en tableaux primitifs qui grandissent par doublement : environ 50 octets par nœud
 * plus son nom en UTF-8. Les nœuds ne sont jamais réutilisés ; [remove] détache un nœud et diminue ses ancêtres.
 * [alloc] et [apparent] d'un nœud comptent sa place propre (bloc d'un dossier) et tout ce qui est dessous, [others]
 * compris ; [items] compte les éléments strictement dessous. Pas de verrou : l'appelant sérialise (verrou
 * lecture-écriture de l'analyse).
 */
class DuTree(val maxNodes: Int = MAX_NODES) {
    companion object {
        const val MAX_NODES = 500_000
        const val FILES_PER_DIR = 20
        const val MAX_BIGGEST = 500
        private const val COMPLETE = 0x10
        private const val KIND_MASK = 0x0F
    }

    /** Chemin de la racine dans sa source (« / » par défaut). */
    var rootPath: String = "/"

    private var cap = 1024
    private var parents = IntArray(cap)
    private var firstChild = IntArray(cap)
    private var nextSibling = IntArray(cap)
    private var nameStart = IntArray(cap)
    private var allocs = LongArray(cap)
    private var apparents = LongArray(cap)
    private var itemCounts = LongArray(cap)
    private var mtimes = LongArray(cap)
    private var flags = ByteArray(cap)
    private var names = ByteArray(16 * 1024)
    private var namesUsed = 0
    private val folded = HashMap<Int, LongArray>() // nœud → (nombre, alloc, apparent) de others

    var nodeCount = 0
        private set

    /** Des nœuds n'ont pas été créés (plafond [maxNodes]) : leur place est dans [others] d'un ancêtre. */
    var simplified = false

    /** Contenu au-delà de la profondeur permise résumé, ou analyse arrêtée avant la fin. */
    var truncated = false

    val root: Int = newNode(-1, "", NodeKind.DIR)

    /** Plus de nœud possible. */
    val full: Boolean get() = nodeCount >= maxNodes

    private fun grow() {
        cap *= 2
        parents = parents.copyOf(cap)
        firstChild = firstChild.copyOf(cap)
        nextSibling = nextSibling.copyOf(cap)
        nameStart = nameStart.copyOf(cap)
        allocs = allocs.copyOf(cap)
        apparents = apparents.copyOf(cap)
        itemCounts = itemCounts.copyOf(cap)
        mtimes = mtimes.copyOf(cap)
        flags = flags.copyOf(cap)
    }

    private fun newNode(parent: Int, name: String, kind: NodeKind): Int {
        if (nodeCount == cap) grow()
        val n = nodeCount++
        val b = name.toByteArray(Charsets.UTF_8)
        if (namesUsed + b.size > names.size) names = names.copyOf(maxOf(names.size * 2, namesUsed + b.size))
        b.copyInto(names, namesUsed)
        nameStart[n] = namesUsed
        namesUsed += b.size
        parents[n] = parent
        firstChild[n] = -1
        nextSibling[n] = -1
        flags[n] = kind.ordinal.toByte()
        if (parent >= 0) {
            nextSibling[n] = firstChild[parent]
            firstChild[parent] = n
        }
        return n
    }

    private fun check(n: Int) = require(n in 0 until nodeCount) { "nœud inconnu : $n" }

    fun kind(n: Int): NodeKind = NodeKind.entries[flags[n].toInt() and KIND_MASK]
    fun setKind(n: Int, kind: NodeKind) {
        flags[n] = ((flags[n].toInt() and KIND_MASK.inv()) or kind.ordinal).toByte()
    }

    /** Nom (UTF-8 du pool) ; les noms se suivent dans l'ordre des nœuds. */
    fun name(n: Int): String {
        check(n)
        val end = if (n + 1 < nodeCount) nameStart[n + 1] else namesUsed
        return String(names, nameStart[n], end - nameStart[n], Charsets.UTF_8)
    }

    fun parent(n: Int) = parents[n]
    fun alloc(n: Int) = allocs[n]
    fun apparent(n: Int) = apparents[n]
    fun items(n: Int) = itemCounts[n]

    /** Date de modification la plus récente sous le nœud (secondes UTC). */
    fun mtime(n: Int) = mtimes[n]
    fun complete(n: Int) = flags[n].toInt() and COMPLETE != 0
    fun setComplete(n: Int) {
        flags[n] = (flags[n].toInt() or COMPLETE).toByte()
    }

    fun others(n: Int): Others = folded[n]?.let { Others(it[0], it[1], it[2]) } ?: Others(0, 0, 0)

    /** Enfants, par place décroissante, puis par nom. */
    fun children(n: Int): IntArray {
        check(n)
        val l = ArrayList<Int>()
        var c = firstChild[n]
        while (c >= 0) {
            l += c
            c = nextSibling[c]
        }
        return l.sortedWith(compareByDescending<Int> { allocs[it] }.thenBy { name(it) }).toIntArray()
    }

    fun hasChildren(n: Int) = firstChild[n] >= 0

    fun path(n: Int): String {
        check(n)
        if (n == root) return rootPath
        val parts = ArrayList<String>()
        var c = n
        while (c != root && c >= 0) {
            parts += name(c)
            c = parents[c]
        }
        val base = if (rootPath == "/") "" else rootPath
        return base + "/" + parts.asReversed().joinToString("/")
    }

    /** Nœud de [path] (absolu dans la source, sous [rootPath]), ou null. */
    fun find(path: String): Int? {
        if (path == rootPath) return root
        val prefix = if (rootPath == "/") "/" else "$rootPath/"
        if (!path.startsWith(prefix)) return null
        var n = root
        for (part in path.substring(prefix.length).split('/')) {
            var c = firstChild[n]
            while (c >= 0 && name(c) != part) c = nextSibling[c]
            if (c < 0) return null
            n = c
        }
        return n
    }

    /** Dossier [name] sous [parent], de place propre [alloc] et [apparent] (ses ancêtres suivent) ; −1 si [full]. */
    fun addDir(parent: Int, name: String, alloc: Long = 0, apparent: Long = 0): Int =
        add(parent, name, NodeKind.DIR, alloc, apparent)

    /** Fichier [name] sous [parent] (ses ancêtres suivent), complet ; −1 si [full]. */
    fun addFile(parent: Int, name: String, alloc: Long, apparent: Long, mtime: Long): Int {
        val n = add(parent, name, NodeKind.FILE, alloc, apparent)
        if (n >= 0) {
            touch(n, mtime)
            setComplete(n)
        }
        return n
    }

    private fun add(parent: Int, name: String, kind: NodeKind, alloc: Long, apparent: Long): Int {
        check(parent)
        if (full) return -1
        val n = newNode(parent, name, kind)
        allocs[n] = alloc
        apparents[n] = apparent
        addTo(parent, alloc, apparent, 1)
        return n
    }

    /** Ajoute à [n] et à tous ses ancêtres. */
    fun addTo(n: Int, alloc: Long, apparent: Long, items: Long) {
        var c = n
        while (c >= 0) {
            allocs[c] += alloc
            apparents[c] += apparent
            itemCounts[c] += items
            c = parents[c]
        }
    }

    /** Contenu sans nœud, compté dans [others] de [n] et dans [n] et ses ancêtres. */
    fun addOthers(n: Int, count: Long, alloc: Long, apparent: Long) {
        if (count == 0L && alloc == 0L && apparent == 0L) return
        val o = folded.getOrPut(n) { LongArray(3) }
        o[0] += count
        o[1] += alloc
        o[2] += apparent
        addTo(n, alloc, apparent, count)
    }

    /** Date de [n] et de ses ancêtres portée au moins à [mtime]. */
    fun touch(n: Int, mtime: Long) {
        var c = n
        while (c >= 0 && mtimes[c] < mtime) {
            mtimes[c] = mtime
            c = parents[c]
        }
    }

    /** Détache [n] (pas la racine) ; ses ancêtres perdent sa place et ses éléments (lui compris). */
    fun remove(n: Int) {
        check(n)
        require(n != root) { "la racine ne se retire pas" }
        val p = parents[n]
        if (p < 0) return // déjà retiré
        addTo(p, -allocs[n], -apparents[n], -(itemCounts[n] + 1))
        if (firstChild[p] == n) {
            firstChild[p] = nextSibling[n]
        } else {
            var c = firstChild[p]
            while (c >= 0 && nextSibling[c] != n) c = nextSibling[c]
            if (c >= 0) nextSibling[c] = nextSibling[n]
        }
        parents[n] = -1
        nextSibling[n] = -1
    }

    /** Mémoire occupée, à peu près : tableaux des nœuds créés, noms, contenus résumés. */
    fun bytesEstimate(): Long = nodeCount.toLong() * (4 * 4 + 4 * 8 + 1) + namesUsed + folded.size * 80L
}
