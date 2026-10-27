package com.mawena.fluluks.ai.auto

import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.files.FilesException
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

/**
 * Modèle de prompt d'une automatisation (phase 15, T8) : `{{nom}}` (espaces permis dans les accolades, lettres
 * accentuées comprises) est remplacé par la valeur saisie au lancement, ou par sa valeur par défaut pour une exécution
 * planifiée ; `{{date}}` (jj/mm/aaaa) et `{{heure}}` (hh:mm) sont fournies par Portail. Des accolades qui ne forment
 * pas un nom restent du texte. Le remplacement se fait en une passe : une valeur n'est jamais développée à son tour.
 */
object Template {
    const val DATE = "date"
    const val TIME = "heure"
    val BUILTINS = setOf(DATE, TIME)

    private val PLACEHOLDER = Regex("""\{\{\s*([\p{L}_][\p{L}\p{N}_]*)\s*\}\}""")
    private val DATE_FMT = DateTimeFormatter.ofPattern("dd/MM/yyyy")
    private val TIME_FMT = DateTimeFormatter.ofPattern("HH:mm")

    /** Variables à saisir, dans l'ordre de leur première apparition, sans doublon ni variable fournie. */
    fun variables(template: String): List<String> =
        PLACEHOLDER.findAll(template).map { it.groupValues[1] }.filter { it !in BUILTINS }.distinct().toList()

    /**
     * À l'enregistrement : modèle non vide, chaque variable déclarée dans [declared] ou fournie par Portail, aucune
     * variable déclarée sous le nom d'une variable fournie. [FilesException] FL_EINVAL sinon.
     */
    fun validate(template: String, declared: Set<String>) {
        if (template.isBlank()) throw FilesException(EngineError.FL_EINVAL, MSG_EMPTY)
        declared.firstOrNull { it in BUILTINS }?.let { throw FilesException(EngineError.FL_EINVAL, MSG_BUILTIN) }
        variables(template).firstOrNull { it !in declared }?.let {
            throw FilesException(EngineError.FL_EINVAL, "Variable inconnue : {{$it}}")
        }
    }

    /** Texte envoyé au modèle ; [FilesException] FL_EINVAL si une variable n'a pas de valeur. */
    fun render(template: String, values: Map<String, String>, now: LocalDateTime): String =
        PLACEHOLDER.replace(template) { m ->
            when (val name = m.groupValues[1]) {
                DATE -> now.format(DATE_FMT)
                TIME -> now.format(TIME_FMT)
                else -> values[name] ?: throw FilesException(EngineError.FL_EINVAL, "Valeur manquante pour {{$name}}")
            }
        }

    const val MSG_EMPTY = "Le modèle de prompt est vide"
    const val MSG_BUILTIN = "{{date}} et {{heure}} sont fournies par Portail : choisissez un autre nom"
}
