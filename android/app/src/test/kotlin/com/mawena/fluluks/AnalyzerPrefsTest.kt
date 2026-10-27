package com.mawena.fluluks

import com.mawena.fluluks.analyzer.AnalyzerPrefs
import com.mawena.fluluks.analyzer.Exclusion
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Emplacements exclus de l'analyseur (phase 16, T5). */
class AnalyzerPrefsTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test fun roundTrip() {
        val p = AnalyzerPrefs(tmp.root)
        assertEquals(emptyList<Exclusion>(), p.exclusions())
        val a = Exclusion("phone", "Téléphone", "/Films")
        val b = Exclusion("disk:uuid", "Disque été ☀", "/Sauvegardes")
        p.add(a); p.add(b); p.add(a) // une seule fois
        assertEquals(listOf(a, b), AnalyzerPrefs(tmp.root).exclusions())
        p.remove("phone", "/Films")
        assertEquals(listOf(b), AnalyzerPrefs(tmp.root).exclusions())
        assertFalse(File(tmp.root, ".analyzer.json.tmp").exists())
    }

    @Test fun damagedFileGivesEmptyList() {
        File(tmp.root, "analyzer.json").writeText("{ abîmé")
        assertEquals(emptyList<Exclusion>(), AnalyzerPrefs(tmp.root).exclusions())
        File(tmp.root, "analyzer.json").writeText("""{"exclusions":[{"key":"phone","path":"relatif"},{"path":"/x"},3]}""")
        assertEquals(emptyList<Exclusion>(), AnalyzerPrefs(tmp.root).exclusions())
        AnalyzerPrefs(tmp.root).add(Exclusion("phone", "Téléphone", "/x")) // réécrit proprement
        assertEquals(listOf(Exclusion("phone", "Téléphone", "/x")), AnalyzerPrefs(tmp.root).exclusions())
    }
}
