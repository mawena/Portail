package com.mawena.fluluks

import com.mawena.fluluks.ai.auto.Template
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.files.FilesException
import java.time.LocalDateTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Modèles de prompt des automatisations (phase 15, T8) : variables `{{nom}}`, `{{date}}` et `{{heure}}` fournies. */
class TemplateTest {
    private val now = LocalDateTime.of(2026, 10, 25, 9, 5)

    private fun refused(code: Int, block: () -> Unit): String {
        try {
            block()
        } catch (e: FilesException) {
            assertEquals(code, e.code)
            return e.message!!
        }
        fail("refus attendu")
        error("")
    }

    @Test fun variablesInOrderWithoutDuplicatesOrBuiltins() {
        assertEquals(
            listOf("ville", "sujet"),
            Template.variables("Météo à {{ville}} le {{date}} : {{sujet}}, encore {{ville}} à {{heure}}"),
        )
    }

    @Test fun spacesInsideBracesAndAccentedNames() {
        assertEquals(listOf("été", "nom_2"), Template.variables("{{ été }} et {{nom_2}}"))
    }

    @Test fun malformedBracesAreText() {
        assertEquals(emptyList<String>(), Template.variables("{{}} {{a b}} {x} {{2x}} {{ }}"))
        assertEquals("{{}} {{a b}} {x}", Template.render("{{}} {{a b}} {x}", emptyMap(), now))
    }

    @Test fun renderReplacesValuesAndBuiltins() {
        assertEquals(
            "Météo à Lomé le 25/10/2026 à 09:05",
            Template.render("Météo à {{ ville }} le {{date}} à {{heure}}", mapOf("ville" to "Lomé"), now),
        )
    }

    @Test fun renderIsSinglePass() {
        // une valeur qui contient « {{x}} » n'est pas développée à son tour
        assertEquals("A {{b}} B", Template.render("A {{a}} B", mapOf("a" to "{{b}}", "b" to "non"), now))
    }

    @Test fun missingValueRefused() {
        val msg = refused(EngineError.FL_EINVAL) { Template.render("Bonjour {{nom}}", emptyMap(), now) }
        assertTrue(msg, msg.contains("{{nom}}"))
    }

    @Test fun unknownVariableRefusedAtSave() {
        Template.validate("Bonjour {{nom}} le {{date}}", setOf("nom"))
        val msg = refused(EngineError.FL_EINVAL) { Template.validate("Bonjour {{nom}} de {{ville}}", setOf("nom")) }
        assertTrue(msg, msg.contains("{{ville}}"))
    }

    @Test fun builtinNamesCannotBeDeclared() {
        refused(EngineError.FL_EINVAL) { Template.validate("{{date}}", setOf("date")) }
    }

    @Test fun emptyTemplateRefused() {
        refused(EngineError.FL_EINVAL) { Template.validate("   ", emptySet()) }
    }
}
