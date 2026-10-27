package com.mawena.fluluks.ai

import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Texte reçu en flux, envoyé vers Dart par lots (phase 15) : réponses du chat et lancements manuels des automatisations.
 * Le texte s'accumule ; un lot part au plus toutes les [batchMs] ms ([run]), ou dès [maxBatch] caractères en attente ;
 * chaque lot prend un permis, rendu quand Dart l'a reçu (acquittement), [maxInflight] au plus : au-delà, [offer] attend
 * et le flux n'est plus lu tant que Dart n'a pas suivi. Un acquittement qui tarde plus de [ackTimeoutMs] ms est tenu
 * pour reçu (Dart parti). [send] rend le destinataire du moment (null : Dart absent, rien ne part). Après [close], plus
 * rien ne part : le texte restant est dans le résultat final. Un caractère hors du plan de base n'est jamais coupé.
 */
class DeltaPump(
    private val send: () -> ((text: String, delivered: () -> Unit) -> Unit)?,
    private val batchMs: Long,
    private val maxBatch: Int,
    maxInflight: Int,
    private val ackTimeoutMs: Long,
) {
    private val permits = Semaphore(maxInflight)
    private val pending = StringBuilder()
    @Volatile private var closed = false

    /** Envoie les lots toutes les [batchMs] ms pendant [block]. */
    suspend fun run(block: suspend () -> Unit) {
        coroutineScope {
            val ticker = launch {
                while (true) {
                    delay(batchMs)
                    flush()
                }
            }
            try {
                block()
            } finally {
                ticker.cancel()
            }
        }
    }

    suspend fun offer(t: String) {
        val full = synchronized(pending) {
            pending.append(t)
            pending.length >= maxBatch
        }
        if (full) flush()
    }

    suspend fun flush() {
        while (true) {
            if (closed) return
            val target = send() ?: return
            if (synchronized(pending) { pending.isEmpty() }) return
            // acquittement qui tarde trop (Dart parti sans répondre) : le lot part quand même, sans permis
            val permit = withTimeoutOrNull(ackTimeoutMs) { permits.acquire() } != null
            val chunk = synchronized(pending) {
                if (closed || pending.isEmpty()) {
                    null
                } else {
                    var n = minOf(pending.length, maxBatch)
                    if (n < pending.length && Character.isHighSurrogate(pending[n - 1])) n--
                    pending.substring(0, n).also { pending.delete(0, n) }
                }
            }
            if (chunk == null) {
                if (permit) permits.release()
                return
            }
            val acked = AtomicBoolean(!permit)
            val ack = { if (acked.compareAndSet(false, true)) permits.release() }
            try {
                target(chunk, ack)
            } catch (e: Exception) {
                ack()
            }
            if (synchronized(pending) { pending.length < maxBatch }) return
        }
    }

    fun close() {
        synchronized(pending) {
            closed = true
            pending.setLength(0)
        }
    }
}
