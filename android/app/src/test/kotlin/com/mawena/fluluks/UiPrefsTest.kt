package com.mawena.fluluks

import com.mawena.fluluks.files.PrefStore
import com.mawena.fluluks.files.UiPrefs
import com.mawena.fluluks.files.UiSettings
import org.junit.Assert.assertEquals
import org.junit.Test

class UiPrefsTest {
    private class MapStore : PrefStore {
        val m = HashMap<String, Any>()
        override fun getString(key: String) = m[key] as? String
        override fun putString(key: String, value: String) { m[key] = value }
        override fun getBoolean(key: String, default: Boolean) = m[key] as? Boolean ?: default
        override fun putBoolean(key: String, value: Boolean) { m[key] = value }
    }

    private val store = MapStore()

    @Test fun uiPrefsDefaultsWhenAbsent() {
        assertEquals(UiSettings(theme = "system", haptics = true, welcomeSeen = false), UiPrefs(store).get())
    }

    @Test fun badThemeFallsBackToSystem() {
        store.m["ui_theme"] = "violet"
        assertEquals("system", UiPrefs(store).get().theme)
    }

    @Test fun roundTrip() {
        val v = UiSettings(theme = "dark", haptics = false, welcomeSeen = true)
        UiPrefs(store).set(v)
        assertEquals(v, UiPrefs(store).get())
        assertEquals("dark", store.m["ui_theme"])
        assertEquals(false, store.m["ui_haptics"])
        assertEquals(true, store.m["ui_welcome_seen"])
        UiPrefs(store).set(UiSettings(theme = "violet"))
        assertEquals("system", store.m["ui_theme"]) // une valeur inconnue n'est jamais écrite
    }

    @Test fun terminalPrefsDefaultsAndBounds() {
        val d = UiPrefs(store).get()
        assertEquals(13, d.terminalFontSize)
        assertEquals(false, d.terminalSecure)
        UiPrefs(store).set(UiSettings(terminalFontSize = 20, terminalSecure = true))
        assertEquals(20, UiPrefs(store).get().terminalFontSize)
        assertEquals(true, UiPrefs(store).get().terminalSecure)
        UiPrefs(store).set(UiSettings(terminalFontSize = 99))
        assertEquals(32, UiPrefs(store).get().terminalFontSize) // bornes 8 à 32
        store.m["ui_terminal_font"] = "abc"
        assertEquals(13, UiPrefs(store).get().terminalFontSize)
        store.m["ui_terminal_font"] = "2"
        assertEquals(8, UiPrefs(store).get().terminalFontSize)
    }
}
