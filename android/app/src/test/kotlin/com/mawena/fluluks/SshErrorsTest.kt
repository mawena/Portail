package com.mawena.fluluks

import com.jcraft.jsch.JSchException
import com.mawena.fluluks.remote.ssh.SshErrors
import com.mawena.fluluks.remote.ssh.SshFailure.Reason
import java.io.EOFException
import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Échecs de connexion SSH (phase 13, T1) : exceptions telles que JSch les lève, classées puis dites en français. */
class SshErrorsTest {
    private fun jsch(msg: String, cause: Throwable? = null) = JSchException(msg, cause)

    @Test fun classifiesRealJschFailures() {
        val cases = listOf(
            jsch("java.net.UnknownHostException: serveur.invalid", UnknownHostException("serveur.invalid")) to
                Reason.UNKNOWN_HOST,
            jsch("timeout: socket is not established") to Reason.TIMEOUT,
            jsch("java.net.SocketTimeoutException: Read timed out", SocketTimeoutException("Read timed out")) to
                Reason.TIMEOUT,
            jsch("java.net.ConnectException: Connection refused", ConnectException("Connection refused")) to
                Reason.REFUSED,
            jsch("java.net.NoRouteToHostException: No route to host", NoRouteToHostException("No route to host")) to
                Reason.UNREACHABLE,
            jsch("java.net.SocketException: Network is unreachable", SocketException("Network is unreachable")) to
                Reason.UNREACHABLE,
            jsch("Algorithm negotiation fail: algorithmName=\"kex\" jschProposal=\"x\" serverProposal=\"y\"") to
                Reason.NO_COMMON_ALGORITHM,
            jsch("SSH_MSG_DISCONNECT: 2 Too many authentication failures ") to Reason.TOO_MANY_TRIES,
            jsch("connection is closed by foreign host") to Reason.CLOSED_BY_SERVER,
            jsch("Session.connect: java.io.IOException: End of IO Stream Read", IOException("End of IO Stream Read")) to
                Reason.CLOSED_BY_SERVER,
            jsch("java.net.SocketException: Connection reset", SocketException("Connection reset")) to
                Reason.CLOSED_BY_SERVER,
            jsch("Session.connect: java.io.EOFException", EOFException()) to Reason.CLOSED_BY_SERVER,
            jsch("invalid privatekey: [B@1234") to Reason.BAD_KEY_FILE,
            jsch("invalid protocol(ssh): SSH-1.5-Ancien") to Reason.PROTOCOL,
            jsch("Packet corrupt") to Reason.PROTOCOL,
            jsch("quelque chose d'imprévu") to Reason.OTHER,
        )
        for ((e, r) in cases) assertEquals(e.message, r, SshErrors.classify(e))
    }

    @Test fun causeFoundDeepInChain() {
        val e = jsch("Session.connect: wrapped", IOException("x", UnknownHostException("h")))
        assertEquals(Reason.UNKNOWN_HOST, SshErrors.classify(e))
    }

    @Test fun messagesInFrench() {
        for (r in Reason.entries) {
            val m = SshErrors.message(r)
            assertTrue(r.name, m.isNotBlank())
            assertFalse(r.name, m.contains("null") || m.contains("Exception") || m.contains("java."))
            // typographie française : espace insécable avant les deux-points
            assertFalse(r.name, m.contains(" :"))
        }
        assertEquals("Serveur introuvable", SshErrors.message(Reason.UNKNOWN_HOST)) // inchangé depuis la phase 10
        assertEquals("Le serveur ne répond pas", SshErrors.message(Reason.TIMEOUT))
    }

    @Test fun detailKeepsTechnicalChainWithoutClassNamesOfOurOwn() {
        val e = jsch("Session.connect: java.net.ConnectException: Connection refused", ConnectException("Connection refused"))
        val d = SshErrors.detail(e)
        assertTrue(d, d.contains("Connection refused"))
    }
}
