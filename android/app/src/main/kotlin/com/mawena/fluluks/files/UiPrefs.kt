package com.mawena.fluluks.files

/**
 * Préférences d'interface (phase 11). [theme] : `system`, `light` ou `dark` ; [haptics] : retours haptiques ;
 * [welcomeSeen] : l'écran de bienvenue a été montré ; [terminalFontSize] : taille du texte du terminal SSH (8 à 32,
 * phase 13) ; [terminalSecure] : terminal masqué dans les captures et les applications récentes ;
 * [closeVaultsOnScreenOff] : coffres fermés quand l'écran s'éteint ; [hideVaults] : coffres parcourus et fichiers
 * déchiffrés masqués dans les captures et les applications récentes (phase 14, désactivés par défaut).
 */
data class UiSettings(
    val theme: String = "system",
    val haptics: Boolean = true,
    val welcomeSeen: Boolean = false,
    val terminalFontSize: Int = TERMINAL_FONT_DEFAULT,
    val terminalSecure: Boolean = false,
    val closeVaultsOnScreenOff: Boolean = false,
    val hideVaults: Boolean = false,
) {
    companion object {
        const val TERMINAL_FONT_DEFAULT = 13
        const val TERMINAL_FONT_MIN = 8
        const val TERMINAL_FONT_MAX = 32
    }
}

/** Persistées dans le même [PrefStore] que [ViewPrefs] ; une valeur absente ou inconnue revient au défaut. */
class UiPrefs(private val store: PrefStore) {
    fun get() = UiSettings(
        store.getString(THEME)?.takeIf { it in THEMES } ?: "system",
        store.getBoolean(HAPTICS, true),
        store.getBoolean(WELCOME, false),
        store.getString(TERMINAL_FONT)?.toIntOrNull()?.let(::font) ?: UiSettings.TERMINAL_FONT_DEFAULT,
        store.getBoolean(TERMINAL_SECURE, false),
        store.getBoolean(VAULTS_SCREEN_OFF, false),
        store.getBoolean(VAULTS_HIDDEN, false),
    )

    fun set(v: UiSettings) {
        store.putString(THEME, v.theme.takeIf { it in THEMES } ?: "system")
        store.putBoolean(HAPTICS, v.haptics)
        store.putBoolean(WELCOME, v.welcomeSeen)
        store.putString(TERMINAL_FONT, font(v.terminalFontSize).toString())
        store.putBoolean(TERMINAL_SECURE, v.terminalSecure)
        store.putBoolean(VAULTS_SCREEN_OFF, v.closeVaultsOnScreenOff)
        store.putBoolean(VAULTS_HIDDEN, v.hideVaults)
    }

    private fun font(size: Int) = size.coerceIn(UiSettings.TERMINAL_FONT_MIN, UiSettings.TERMINAL_FONT_MAX)

    companion object {
        private val THEMES = setOf("system", "light", "dark")
        private const val THEME = "ui_theme"
        private const val HAPTICS = "ui_haptics"
        private const val WELCOME = "ui_welcome_seen"
        private const val TERMINAL_FONT = "ui_terminal_font"
        private const val TERMINAL_SECURE = "ui_terminal_secure"
        private const val VAULTS_SCREEN_OFF = "coffres_ecran_eteint"
        private const val VAULTS_HIDDEN = "coffres_masques"
    }
}
