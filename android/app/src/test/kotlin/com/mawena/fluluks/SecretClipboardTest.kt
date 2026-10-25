package com.mawena.fluluks

import com.mawena.fluluks.crypt.ClipGuard
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Effacement de la copie protégée (phase 14, T7) : seulement si le presse-papiers n'a pas changé depuis. */
class SecretClipboardTest {
    @Test fun clearedAfterDelayIfUnchanged() {
        val g = ClipGuard()
        val t = g.ours()
        g.changed() // notification de notre propre copie
        assertTrue(g.shouldClear(t))
    }

    @Test fun keptIfSomethingElseCopied() {
        val g = ClipGuard()
        val t = g.ours()
        g.changed()
        g.changed() // l'utilisateur a copié autre chose
        assertFalse(g.shouldClear(t))
    }

    @Test fun onlyTheLastCopyIsCleared() {
        val g = ClipGuard()
        val first = g.ours()
        g.changed()
        val second = g.ours()
        g.changed()
        assertFalse(g.shouldClear(first))
        assertTrue(g.shouldClear(second))
    }

    @Test fun notificationArrivingLateStillCounted() {
        val g = ClipGuard()
        val t = g.ours()
        // la notification de notre copie n'est pas encore arrivée au moment de l'échéance
        assertTrue(g.shouldClear(t))
    }
}
