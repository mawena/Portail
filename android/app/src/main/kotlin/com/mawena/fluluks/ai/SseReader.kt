package com.mawena.fluluks.ai

import java.io.ByteArrayOutputStream
import java.io.InputStream

/**
 * Lecteur de flux `text/event-stream` (phase 15), indépendant du transport : [next] rend la donnée de l'événement
 * suivant (lignes `data:` jointes par `\n`), ou null à la fin du flux. Les octets sont accumulés jusqu'à la fin de la
 * ligne avant d'être décodés en UTF-8 : un caractère ou un champ JSON coupé entre deux paquets reste entier. Fins de
 * ligne `\n`, `\r\n` ou `\r` ; commentaires (`:`) et champs `event`, `id`, `retry` ignorés. Un dernier événement sans
 * ligne vide finale est rendu quand même.
 */
class SseReader(private val input: InputStream) {
    private val buf = ByteArray(8192)
    private var len = 0
    private var pos = 0
    private var eof = false
    private var skipLf = false
    private val line = ByteArrayOutputStream()

    /** Octets lus depuis le début (journal de tentative : taille seulement). */
    var bytesRead = 0L
        private set

    fun next(): String? {
        val data = StringBuilder()
        var hasData = false
        while (true) {
            val l = readLine()
            if (l == null) return if (hasData) data.toString() else null
            if (l.isEmpty()) {
                if (hasData) return data.toString()
                continue
            }
            if (l.startsWith(":")) continue
            val colon = l.indexOf(':')
            val field = if (colon < 0) l else l.substring(0, colon)
            if (field != "data") continue
            var value = if (colon < 0) "" else l.substring(colon + 1)
            if (value.startsWith(" ")) value = value.substring(1)
            if (hasData) data.append('\n')
            data.append(value)
            hasData = true
        }
    }

    private fun fill(): Boolean {
        if (eof) return false
        val n = input.read(buf, 0, buf.size)
        if (n < 0) {
            eof = true
            return false
        }
        len = n
        pos = 0
        bytesRead += n
        return true
    }

    /** Ligne suivante sans sa fin, ou null à la fin du flux (une ligne commencée est rendue). */
    private fun readLine(): String? {
        line.reset()
        while (true) {
            if (pos >= len && !fill()) {
                return if (line.size() > 0) line.toString(Charsets.UTF_8.name()) else null
            }
            val b = buf[pos++]
            if (skipLf) {
                skipLf = false
                if (b == '\n'.code.toByte()) continue
            }
            when (b) {
                '\n'.code.toByte() -> return line.toString(Charsets.UTF_8.name())
                '\r'.code.toByte() -> {
                    skipLf = true
                    return line.toString(Charsets.UTF_8.name())
                }
                else -> line.write(b.toInt())
            }
        }
    }
}
