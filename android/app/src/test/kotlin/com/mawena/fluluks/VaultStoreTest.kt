package com.mawena.fluluks

import com.mawena.fluluks.vaults.VaultRecord
import com.mawena.fluluks.vaults.VaultStore
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Liste des coffres connus (phase 14, T9) : aucun secret, écriture atomique, fichier abîmé sans perte. */
class VaultStoreTest {
    @get:Rule val tmp = TemporaryFolder()

    private val r = VaultRecord("a1", "Photos", "disk:uuid-1", "/coffres/Photos.luks", 1L shl 30, "exfat",
        mapOf(0 to "password", 1 to "recovery"), biometric = true)

    @Test fun roundTrip() {
        val s = VaultStore(tmp.root)
        s.put(r)
        s.put(r.copy(id = "b2", name = "Papiers"))
        assertEquals(listOf(r, r.copy(id = "b2", name = "Papiers")), VaultStore(tmp.root).list())
        s.put(r.copy(name = "Photos 2024")) // même identifiant : remplacé
        assertEquals(setOf("Photos 2024", "Papiers"), s.list().map { it.name }.toSet())
        s.remove("b2")
        assertEquals(listOf("a1"), s.list().map { it.id })
        assertFalse(File(tmp.root, "vaults.json.tmp").exists())
        // aucun secret : seulement ces champs
        val o = org.json.JSONObject(File(tmp.root, "vaults.json").readText()).getJSONArray("vaults").getJSONObject(0)
        assertEquals(setOf("id", "name", "source", "path", "size", "fs", "slots", "biometric", "luks"), o.keys().asSequence().toSet())
    }

    /** Pixel (T16) : un coffre mis à jour à l'ouverture passait en fin de liste, l'accueil changeait d'ordre. */
    @Test fun updateKeepsPlace() {
        val s = VaultStore(tmp.root)
        s.put(r)
        s.put(r.copy(id = "b2", name = "Papiers"))
        s.put(r.copy(luksVersion = 1)) // a1 mis à jour
        assertEquals(listOf("a1", "b2"), s.list().map { it.id })
        assertEquals(1, s.get("a1")!!.luksVersion)
    }

    @Test fun storeSurvivesDamage() {
        File(tmp.root, "vaults.json").writeText("{\"vaults\": [ {\"id\": tronqué")
        val s = VaultStore(tmp.root)
        assertTrue(s.list().isEmpty())
        assertTrue(File(tmp.root, "vaults.json.abime").exists()) // gardé à part
        s.put(r)
        assertEquals(listOf(r), s.list())
    }
}
