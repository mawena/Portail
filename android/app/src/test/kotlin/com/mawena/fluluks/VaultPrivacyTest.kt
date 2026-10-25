package com.mawena.fluluks

import com.mawena.fluluks.files.PrefStore
import com.mawena.fluluks.files.UiPrefs
import com.mawena.fluluks.files.UiSettings
import com.mawena.fluluks.vaults.VaultPrivacy
import com.mawena.fluluks.volumes.VolumeState
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Phase 14, T13 : coffres fermés quand l'écran s'éteint (réglage), jamais au milieu d'une opération. */
class VaultPrivacyTest {
    private val closed = ArrayList<String>()
    private var vols = listOf<VolumeState>()
    private val busy = HashSet<String>()
    private var enabled = true

    private fun vol(id: String, vaultId: String? = null, encrypted: Boolean = true) =
        VolumeState(id, "d-$id", 0, "Volume $id", 1000, 500, false, "", readOnly = false, encrypted = encrypted, vaultId = vaultId)

    @Before fun setup() {
        VaultPrivacy.resetForTests(
            enabled = { enabled },
            volumes = { vols },
            close = { id -> closed.add(id); vols = vols.filter { it.vaultId != id } },
            busy = { it in busy },
        )
    }

    @After fun teardown() = VaultPrivacy.resetForTests()

    @Test fun screenOffClosesVaultsWhenEnabled() {
        vols = listOf(vol("vv1", "a1"), vol("vv2", "a2"))
        VaultPrivacy.onScreenOff()
        assertEquals(listOf("a1", "a2"), closed)
        // réglage désactivé : rien
        closed.clear()
        enabled = false
        vols = listOf(vol("vv3", "a3"))
        VaultPrivacy.onScreenOff()
        assertTrue(closed.isEmpty())
    }

    @Test fun screenOffWaitsForRunningOperation() {
        vols = listOf(vol("vv1", "a1"), vol("vv2", "a2"))
        busy.add("vv1") // une copie lit ou écrit ce coffre
        VaultPrivacy.onScreenOff()
        assertEquals(listOf("a2"), closed)
        VaultPrivacy.check() // toujours en cours
        assertEquals(listOf("a2"), closed)
        busy.clear()
        VaultPrivacy.check() // l'opération est finie : fermé
        assertEquals(listOf("a2", "a1"), closed)
        VaultPrivacy.check()
        assertEquals(2, closed.size)

        // écran rallumé avant la fin de l'opération : l'utilisateur est revenu, le coffre reste ouvert
        closed.clear()
        vols = listOf(vol("vv3", "a3"))
        busy.add("vv3")
        VaultPrivacy.onScreenOff()
        VaultPrivacy.onScreenOn()
        busy.clear()
        VaultPrivacy.check()
        assertTrue(closed.isEmpty())
    }

    @Test fun screenOffLeavesDisksAlone() {
        vols = listOf(vol("v1"), vol("v2", encrypted = false), vol("vv1", "a1"))
        VaultPrivacy.onScreenOff()
        assertEquals(listOf("a1"), closed) // seuls les coffres ; les disques suivent le verrouillage automatique
    }

    @Test fun bothSettingsOffByDefault() {
        val store = object : PrefStore {
            val m = HashMap<String, Any>()
            override fun getString(key: String) = m[key] as? String
            override fun putString(key: String, value: String) { m[key] = value }
            override fun getBoolean(key: String, default: Boolean) = m[key] as? Boolean ?: default
            override fun putBoolean(key: String, value: Boolean) { m[key] = value }
        }
        val s = UiPrefs(store).get()
        assertFalse(s.closeVaultsOnScreenOff)
        assertFalse(s.hideVaults)
        UiPrefs(store).set(UiSettings(closeVaultsOnScreenOff = true, hideVaults = true))
        assertTrue(UiPrefs(store).get().closeVaultsOnScreenOff)
        assertTrue(UiPrefs(store).get().hideVaults)
    }
}
