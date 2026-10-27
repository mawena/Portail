package com.mawena.fluluks.ai

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Journal de tentative des appels à un serveur IA (phase 15), montré dans « Détails » : horodatage, méthode, chemin,
 * code HTTP, durées et tailles, et la raison d'un échec (en français). Jamais de clé, d'en-tête, de prompt, de message,
 * de réponse ni de message d'erreur du serveur (qui peut recopier la requête). [MAX_LINES] au plus.
 */
class AiAttemptLog {
    private val lines = ArrayDeque<String>()
    private val clock = SimpleDateFormat("HH:mm:ss.SSS", Locale.ROOT)

    @Synchronized fun add(text: String) {
        lines.addLast("${clock.format(Date())}  $text")
        while (lines.size > MAX_LINES) lines.removeFirst()
    }

    @Synchronized fun lines(): List<String> = lines.toList()

    companion object {
        const val MAX_LINES = 200
    }
}
