package com.mawena.fluluks.remote.ssh

import com.jcraft.jsch.Logger
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/**
 * Journal d'une tentative de connexion SSH (phase 13, T1) : messages de JSch de niveau INFO et plus, et ceux de
 * Portail, horodatés, [MAX_LINES] au plus (les plus anciens tombent). Montré dans « Détails » ; JSch n'y écrit jamais
 * de mot de passe, de phrase ni de réponse d'invite, et Portail non plus.
 */
class AttemptLog {
    private val lines = ArrayDeque<String>()
    private val clock = SimpleDateFormat("HH:mm:ss.SSS", Locale.ROOT)

    @Synchronized fun add(text: String) {
        lines.addLast("${clock.format(Date())}  $text")
        while (lines.size > MAX_LINES) lines.removeFirst()
    }

    @Synchronized fun lines(): List<String> = lines.toList()

    /** Pour `JSch.setInstanceLogger`. */
    val logger: Logger = object : Logger {
        override fun isEnabled(level: Int) = level >= Logger.INFO

        override fun log(level: Int, message: String?) {
            if (level >= Logger.INFO && message != null) add(message)
        }
    }

    companion object {
        const val MAX_LINES = 200
    }
}

/** Dernier journal de connexion de chaque serveur, en mémoire seulement (« Détails » après un échec). */
object AttemptLogs {
    private val last = ConcurrentHashMap<String, List<String>>()

    fun put(serverId: String, log: AttemptLog) {
        last[serverId] = log.lines()
    }

    fun get(serverId: String): List<String> = last[serverId].orEmpty()

    fun forget(serverId: String) {
        last.remove(serverId)
    }
}
