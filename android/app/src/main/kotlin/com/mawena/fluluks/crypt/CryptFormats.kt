package com.mawena.fluluks.crypt

/**
 * Reconnaissance d'un fichier chiffré par ses premiers octets (phase 14), sans mot de passe : `age` (format age v1),
 * `zip-aes` (ZIP dont une entrée est chiffrée en AES, méthode 99), `zip-legacy` (ZIP chiffré à l'ancienne,
 * ZipCrypto), `luks` (coffre ou disque LUKS), `none` sinon. L'extension ne décide de rien ; elle ne sert qu'aux noms.
 */
object CryptFormats {
    /** Octets lus pour reconnaître un fichier : assez pour plusieurs en-têtes locaux ZIP. */
    const val HEAD_BYTES = 64 * 1024

    private val AGE_MAGIC = "age-encryption.org/v1\n".toByteArray(Charsets.US_ASCII)
    private val LUKS_MAGIC = byteArrayOf('L'.code.toByte(), 'U'.code.toByte(), 'K'.code.toByte(), 'S'.code.toByte(), 0xBA.toByte(), 0xBE.toByte())

    private fun startsWith(b: ByteArray, p: ByteArray) = b.size >= p.size && (p.indices).all { b[it] == p[it] }
    private fun u16(b: ByteArray, o: Int) = (b[o].toInt() and 0xFF) or ((b[o + 1].toInt() and 0xFF) shl 8)
    private fun u32(b: ByteArray, o: Int) = u16(b, o).toLong() or (u16(b, o + 2).toLong() shl 16)

    fun detect(head: ByteArray): String = when {
        startsWith(head, AGE_MAGIC) -> "age"
        startsWith(head, LUKS_MAGIC) -> "luks"
        head.size >= 4 && head[0] == 'P'.code.toByte() && head[1] == 'K'.code.toByte() && head[2] == 3.toByte() &&
            head[3] == 4.toByte() -> zip(head)
        else -> "none"
    }

    /** Parcourt les en-têtes locaux tant que leur taille est connue ; la première entrée chiffrée décide. */
    private fun zip(b: ByteArray): String {
        var o = 0
        while (o + 30 <= b.size && u32(b, o) == 0x04034b50L) {
            val flags = u16(b, o + 6)
            val method = u16(b, o + 8)
            if (flags and 1 != 0) return if (method == 99) "zip-aes" else "zip-legacy"
            if (flags and 8 != 0) return "none" // taille dans un descripteur de données : on s'arrête là
            val size = u32(b, o + 18)
            val next = o.toLong() + 30 + u16(b, o + 26) + u16(b, o + 28) + size
            if (next > Int.MAX_VALUE) return "none"
            o = next.toInt()
        }
        return "none"
    }

    /** Facteur log2 N du destinataire scrypt d'un en-tête age, null si ce n'en est pas un (ou pas lisible). */
    fun ageWorkFactor(head: ByteArray): Int? {
        if (!startsWith(head, AGE_MAGIC)) return null
        val text = String(head, AGE_MAGIC.size, minOf(head.size - AGE_MAGIC.size, 512), Charsets.US_ASCII)
        val line = text.lineSequence().firstOrNull() ?: return null
        val parts = line.split(' ')
        if (parts.size != 4 || parts[0] != "->" || parts[1] != "scrypt") return null
        return parts[3].toIntOrNull()?.takeIf { it in 1..30 && parts[3] == it.toString() }
    }

    /** Fichier age qui contient un dossier (ZIP dans age) : « nom.zip.age ». */
    fun isFolder(name: String) = name.endsWith(".zip.age", ignoreCase = true)

    /**
     * Nom en clair : sans « .age » ; [folder] (dossier extrait) : sans « .zip.age » non plus. Un nom sans extension
     * reconnue est gardé tel quel (le nom unique de la destination évite alors l'écrasement).
     */
    fun plainName(name: String, folder: Boolean = false): String = when {
        folder && isFolder(name) -> name.dropLast(".zip.age".length)
        name.endsWith(".age", ignoreCase = true) && name.length > 4 -> name.dropLast(4)
        else -> name
    }.ifEmpty { name }
}
