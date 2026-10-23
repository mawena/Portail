package com.mawena.fluluks

import com.mawena.fluluks.remote.ssh.TerminalInfo
import com.mawena.fluluks.service.SshServiceLogic
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Service des sessions SSH (phase 13, T3) : quand il tourne, ce que dit sa notification, l'action « Tout fermer ». */
class SshServiceLogicTest {
    private fun t(title: String, state: String) = TerminalInfo(title, "s1", title, state, null, 80, 24)

    @Test fun serviceStopsWithLastSession() {
        assertFalse(SshServiceLogic.shouldRun(emptyList()))
        assertTrue(SshServiceLogic.shouldRun(listOf(t("Maison", TerminalInfo.CONNECTING))))
        assertTrue(SshServiceLogic.shouldRun(listOf(t("Maison", TerminalInfo.OPEN), t("Cloud", TerminalInfo.CLOSED))))
        // une session tombée, gardée pour « Reconnecter », ne garde pas le service
        assertFalse(SshServiceLogic.shouldRun(listOf(t("Maison", TerminalInfo.CLOSED))))
    }

    @Test fun titlesInFrench() {
        assertEquals("1 session SSH ouverte", SshServiceLogic.title(1))
        assertEquals("3 sessions SSH ouvertes", SshServiceLogic.title(3))
        val text = SshServiceLogic.text(
            listOf(t("Maison", TerminalInfo.OPEN), t("Cloud", TerminalInfo.CONNECTING), t("Vieux", TerminalInfo.CLOSED)),
        )
        assertEquals("Maison, Cloud", text)
        assertEquals(2, SshServiceLogic.count(listOf(t("A", TerminalInfo.OPEN), t("B", TerminalInfo.OPEN), t("C", TerminalInfo.CLOSED))))
    }

    @Test fun closeAllFromNotification() {
        var closed = 0
        assertTrue(SshServiceLogic.onAction(SshServiceLogic.ACTION_CLOSE_ALL) { closed++ })
        assertEquals(1, closed)
        assertFalse(SshServiceLogic.onAction(null) { closed++ })
        assertFalse(SshServiceLogic.onAction("autre") { closed++ })
        assertEquals(1, closed)
    }
}
