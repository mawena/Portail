package com.mawena.fluluks.remote.ssh

import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * Sortie d'un terminal vers Dart (phase 13, T2) : les octets reçus par [offer] partent par lots vers [emit], au plus
 * un lot toutes les [batchMs] ms et [maxBatch] octets par lot. Le lot en attente plein, [offer] attend : le fil de
 * lecture cesse de lire et la mémoire reste bornée, même sous un `cat` géant. Les [backlogMax] derniers octets
 * envoyés restent en mémoire ([backlog]) pour rouvrir l'écran ; rien n'est écrit sur le disque.
 */
class OutputPump(
    private val emit: (ByteArray) -> Unit,
    private val scheduler: ScheduledExecutorService = SHARED,
    batchMs: Long = BATCH_MS,
    private val maxBatch: Int = MAX_BATCH,
    backlogMax: Int = BACKLOG_MAX,
) {
    private val batchNs = TimeUnit.MILLISECONDS.toNanos(batchMs)
    private val lock = Object()
    private val emitLock = Any()
    private val pending = ByteArray(maxBatch)
    private var size = 0
    private var scheduled = false
    private var closed = false
    private var lastEmitNs = System.nanoTime() - batchNs
    private val ring = Ring(backlogMax)

    /** Octets reçus ; attend tant que le lot en attente est plein. Sans effet après [close]. */
    fun offer(b: ByteArray, off: Int = 0, len: Int = b.size) {
        var o = off
        var left = len
        synchronized(lock) {
            while (left > 0) {
                while (size == maxBatch && !closed) lock.wait()
                if (closed) return
                val n = minOf(left, maxBatch - size)
                System.arraycopy(b, o, pending, size, n)
                size += n
                o += n
                left -= n
                if (!scheduled) {
                    scheduled = true
                    val delay = maxOf(0L, lastEmitNs + batchNs - System.nanoTime())
                    scheduler.schedule(::flush, delay, TimeUnit.NANOSECONDS)
                }
            }
        }
    }

    /** Copie des derniers octets envoyés, dans l'ordre. */
    fun backlog(): ByteArray = ring.copy()

    /** Envoie ce qui reste, sur le fil appelant, puis refuse tout nouvel octet. */
    fun close() {
        synchronized(emitLock) {
            val rest = synchronized(lock) {
                closed = true
                lock.notifyAll()
                take()
            }
            rest?.let(::send)
        }
    }

    /** Efface la sortie récente (session retirée). */
    fun clear() = ring.clear()

    private fun flush() {
        synchronized(emitLock) {
            val chunk = synchronized(lock) {
                scheduled = false
                take()?.also {
                    lastEmitNs = System.nanoTime()
                    lock.notifyAll()
                }
            }
            chunk?.let(::send)
        }
    }

    private fun take(): ByteArray? {
        if (size == 0) return null
        return pending.copyOf(size).also { size = 0 }
    }

    private fun send(chunk: ByteArray) {
        ring.add(chunk)
        runCatching { emit(chunk) }
    }

    /** Tampon circulaire des [cap] derniers octets. */
    private class Ring(private val cap: Int) {
        private val buf = ByteArray(cap)
        private var start = 0
        private var len = 0

        @Synchronized fun add(b: ByteArray) {
            var off = maxOf(0, b.size - cap)
            while (off < b.size) {
                val end = (start + len) % cap
                val n = minOf(b.size - off, cap - end)
                System.arraycopy(b, off, buf, end, n)
                off += n
                val over = len + n - cap
                if (over > 0) {
                    start = (start + over) % cap
                    len = cap
                } else {
                    len += n
                }
            }
        }

        @Synchronized fun copy(): ByteArray = ByteArray(len) { buf[(start + it) % cap] }

        @Synchronized fun clear() {
            buf.fill(0)
            start = 0
            len = 0
        }
    }

    companion object {
        const val BATCH_MS = 16L
        const val MAX_BATCH = 64 * 1024
        const val BACKLOG_MAX = 256 * 1024

        /** Un seul fil pour les lots de tous les terminaux. */
        val SHARED: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { r ->
            Thread(r, "terminal-sortie").apply { isDaemon = true }
        }
    }
}
