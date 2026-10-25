package com.mawena.fluluks.crypt

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle

/**
 * Suivi des copies de Portail dans le presse-papiers : la copie [ours] n'est effacée ([shouldClear]) que si rien
 * d'autre n'a été copié depuis. Chaque copie produit une notification de changement ([changed]) ; elles sont
 * comptées pour ne pas les prendre pour une copie de l'utilisateur, même si elles arrivent en retard.
 */
class ClipGuard {
    private var gen = 0
    private var pending = 0
    private var foreign = false

    /** Portail vient de copier ; rend le jeton de cette copie. */
    @Synchronized
    fun ours(): Int {
        gen++
        pending++
        foreign = false
        return gen
    }

    /** Le presse-papiers a changé (notre copie ou celle de quelqu'un d'autre). */
    @Synchronized
    fun changed() {
        if (pending > 0) pending-- else foreign = true
    }

    /** Vrai si la copie [token] est toujours la dernière et que rien d'autre n'a été copié depuis. */
    @Synchronized
    fun shouldClear(token: Int) = token == gen && !foreign
}

/**
 * Copie protégée d'un mot de passe (phase 14) : marquée sensible (Android 13 et plus n'en montre pas l'aperçu, le
 * clavier ne la propose pas), puis effacée après [CLEAR_MS] si elle est toujours dans le presse-papiers. Le texte
 * passe forcément par une chaîne (ClipData) ; les octets reçus sont mis à zéro tout de suite.
 */
object SecretClipboard {
    const val CLEAR_MS = 60_000L

    /** Clé de ClipDescription.EXTRA_IS_SENSITIVE, lue aussi par les versions antérieures à Android 13. */
    private const val EXTRA_SENSITIVE = "android.content.extra.IS_SENSITIVE"

    private val guard = ClipGuard()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var listening = false

    fun copy(context: Context, bytes: ByteArray) {
        val text = String(bytes, Charsets.UTF_8)
        bytes.fill(0)
        val cm = context.applicationContext.getSystemService(ClipboardManager::class.java) ?: return
        main.post {
            if (!listening) {
                cm.addPrimaryClipChangedListener { guard.changed() }
                listening = true
            }
            val clip = ClipData.newPlainText("", text)
            clip.description.extras = PersistableBundle().apply {
                putBoolean(if (Build.VERSION.SDK_INT >= 33) ClipDescription.EXTRA_IS_SENSITIVE else EXTRA_SENSITIVE, true)
            }
            val token = guard.ours()
            cm.setPrimaryClip(clip)
            main.postDelayed({
                if (!guard.shouldClear(token)) return@postDelayed
                guard.ours() // la notification de l'effacement n'est pas une copie de l'utilisateur
                if (Build.VERSION.SDK_INT >= 28) cm.clearPrimaryClip() else cm.setPrimaryClip(ClipData.newPlainText("", ""))
            }, CLEAR_MS)
        }
    }
}
