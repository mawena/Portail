package com.mawena.fluluks

import com.mawena.fluluks.crypt.ClipGuard
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Effacement de la copie protégée (phase 14, T7) : seulement si le presse-papiers n'a pas changé depuis. */
class SecretClipboardTest {
    @Test fun clearedAfterDelayIfUnchanged() {
        val g = ClipGuard()
        val t = g.ours(0)
        g.changed(1) // notification de notre propre copie
        assertTrue(g.shouldClear(t))
    }

    /** Pixel 4 XL, Android 13 : une copie produit deux notifications à 95 ms d'écart (essai T16). */
    @Test fun echoOfOwnCopyIgnored() {
        val g = ClipGuard()
        val t = g.ours(0)
        g.changed(3)
        g.changed(95)
        assertTrue(g.shouldClear(t))
    }

    @Test fun keptIfSomethingElseCopied() {
        val g = ClipGuard()
        val t = g.ours(0)
        g.changed(1)
        g.changed(20_000) // l'utilisateur a copié autre chose
        assertFalse(g.shouldClear(t))
    }

    @Test fun onlyTheLastCopyIsCleared() {
        val g = ClipGuard()
        val first = g.ours(0)
        g.changed(1)
        val second = g.ours(10_000)
        g.changed(10_001)
        assertFalse(g.shouldClear(first))
        assertTrue(g.shouldClear(second))
    }

    @Test fun notificationArrivingLateStillCounted() {
        val g = ClipGuard()
        val t = g.ours(0)
        // la notification de notre copie n'est pas encore arrivée au moment de l'échéance
        assertTrue(g.shouldClear(t))
        // elle arrive bien après la fenêtre : toujours la nôtre
        g.changed(30_000)
        assertTrue(g.shouldClear(t))
    }

    @Test fun copyByUserAfterEchoesIsSeen() {
        val g = ClipGuard()
        val t = g.ours(0)
        g.changed(2)
        g.changed(90)
        g.changed(40_000) // copie de l'utilisateur, bien après
        assertFalse(g.shouldClear(t))
    }
}
