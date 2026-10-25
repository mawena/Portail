package com.mawena.fluluks.crypt

/**
 * Règles d'un mot de passe de fichier ou de coffre (phase 14) : 8 caractères au moins, UTF-8 valide, sans caractère
 * NUL. Un mot de passe reste un ByteArray de bout en bout : jamais de String, il n'est pas copié hors de ce tableau.
 */
object Passwords {
    const val MIN_CHARS = 8
    const val MSG_TOO_SHORT = "Le mot de passe doit faire au moins 8 caractères"
    const val MSG_NUL = "Le mot de passe contient un caractère interdit"
    const val MSG_INVALID = "Le mot de passe n'est pas un texte valide"
    const val MSG_BAD_PASSWORD = "Mot de passe incorrect"

    /** Message de refus, ou null si le mot de passe convient. Ne garde rien du tableau. */
    fun check(pw: ByteArray): String? {
        var chars = 0
        var i = 0
        while (i < pw.size) {
            val c = pw[i].toInt() and 0xFF
            if (c == 0) return MSG_NUL
            val n = when {
                c < 0x80 -> 1
                c in 0xC2..0xDF -> 2
                c in 0xE0..0xEF -> 3
                c in 0xF0..0xF4 -> 4
                else -> return MSG_INVALID
            }
            if (i + n > pw.size) return MSG_INVALID
            for (k in 1 until n) if ((pw[i + k].toInt() and 0xC0) != 0x80) return MSG_INVALID
            chars++
            i += n
        }
        return if (chars < MIN_CHARS) MSG_TOO_SHORT else null
    }
}
