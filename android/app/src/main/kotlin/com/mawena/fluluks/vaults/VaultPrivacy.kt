package com.mawena.fluluks.vaults

import android.content.Context
import androidx.annotation.VisibleForTesting
import com.mawena.fluluks.files.SharedPrefStore
import com.mawena.fluluks.files.Transfers
import com.mawena.fluluks.files.UiPrefs
import com.mawena.fluluks.volumes.VolumeManager
import com.mawena.fluluks.volumes.VolumeState

/**
 * Réglage « Fermer les coffres quand l'écran s'éteint » (phase 14) : à l'extinction de l'écran, chaque coffre ouvert
 * est fermé (synchronisé, démonté, clé effacée) ; un coffre que lit ou écrit l'opération en cours est fermé à la fin
 * de celle-ci ([check]), sauf si l'écran s'est rallumé entre-temps. Les disques ne sont pas touchés : ils suivent le
 * verrouillage automatique.
 */
object VaultPrivacy {
    @Volatile private var enabled: () -> Boolean = { false }
    @Volatile private var volumes: () -> List<VolumeState> = { VolumeManager.volumes.value }
    @Volatile private var close: (String) -> Unit = Vaults::close
    @Volatile private var busy: (String) -> Boolean = Transfers::isBusy

    /** Coffres à fermer dès la fin de l'opération qui les utilise. */
    private val pending = LinkedHashSet<String>()

    /** Branche le réglage sur les préférences (service des volumes). */
    fun bind(context: Context) {
        val prefs = UiPrefs(SharedPrefStore(context.applicationContext))
        enabled = { prefs.get().closeVaultsOnScreenOff }
    }

    @Synchronized
    fun onScreenOff() {
        if (!enabled()) return
        for (v in volumes()) {
            val id = v.vaultId ?: continue
            if (busy(v.id)) pending.add(id) else runCatching { close(id) }
        }
    }

    /** Écran rallumé : l'utilisateur est revenu, les coffres en attente restent ouverts. */
    @Synchronized
    fun onScreenOn() = pending.clear()

    /** Ferme les coffres en attente dont l'opération est finie (fin d'opération, contrôle périodique). */
    @Synchronized
    fun check() {
        if (pending.isEmpty()) return
        val open = volumes().filter { it.vaultId != null }.associateBy { it.vaultId!! }
        val it = pending.iterator()
        while (it.hasNext()) {
            val id = it.next()
            val v = open[id]
            if (v == null) {
                it.remove() // déjà fermé
            } else if (!busy(v.id)) {
                it.remove()
                runCatching { close(id) }
            }
        }
    }

    @VisibleForTesting
    @Synchronized
    fun resetForTests(
        enabled: () -> Boolean = { false },
        volumes: () -> List<VolumeState> = { VolumeManager.volumes.value },
        close: (String) -> Unit = Vaults::close,
        busy: (String) -> Boolean = Transfers::isBusy,
    ) {
        pending.clear()
        this.enabled = enabled
        this.volumes = volumes
        this.close = close
        this.busy = busy
    }
}
