package com.mawena.fluluks.remote.ssh

import java.io.EOFException
import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/**
 * Échec d'une connexion SSH qui n'est ni une empreinte à approuver ni un refus d'identifiants (phase 13, spec § 21) :
 * [message] en français pour l'utilisateur, [detail] technique (messages de JSch et des causes) pour « Détails ».
 * Jamais de secret dans l'un ni l'autre : JSch ne met ni mot de passe ni phrase dans ses messages.
 */
class SshFailure(val reason: Reason, val detail: String, cause: Throwable? = null) :
    IOException(SshErrors.message(reason), cause) {
    enum class Reason {
        UNKNOWN_HOST, TIMEOUT, REFUSED, UNREACHABLE, CLOSED_BY_SERVER, TOO_MANY_TRIES, NO_COMMON_ALGORITHM,
        BAD_KEY_FILE, PROTOCOL, OTHER,
    }
}

/** Classement des exceptions de JSch et de leurs causes, et messages en français. */
object SshErrors {
    fun classify(e: Throwable): SshFailure.Reason {
        val chain = generateSequence(e) { it.cause }.take(8).toList()
        for (c in chain) {
            when (c) {
                is UnknownHostException -> return SshFailure.Reason.UNKNOWN_HOST
                is SocketTimeoutException -> return SshFailure.Reason.TIMEOUT
                // Linux et Android disent aussi « Connection timed out » ou « Network is unreachable » par cette classe
                is ConnectException -> return c.message.orEmpty().lowercase().let {
                    when {
                        "timed out" in it -> SshFailure.Reason.TIMEOUT
                        "unreachable" in it -> SshFailure.Reason.UNREACHABLE
                        else -> SshFailure.Reason.REFUSED
                    }
                }
                is NoRouteToHostException -> return SshFailure.Reason.UNREACHABLE
                is EOFException -> return SshFailure.Reason.CLOSED_BY_SERVER
                // connexion coupée par l'autre bout (EPIPE, ECONNRESET) ; message du système, parfois traduit
                // (« Relais brisé (pipe) »), donc jugé par la classe
                is SocketException -> return if ("unreachable" in c.message.orEmpty().lowercase()) {
                    SshFailure.Reason.UNREACHABLE
                } else {
                    SshFailure.Reason.CLOSED_BY_SERVER
                }
            }
        }
        val text = chain.joinToString("\n") { it.message.orEmpty() }.lowercase()
        return when {
            "unknownhostexception" in text -> SshFailure.Reason.UNKNOWN_HOST
            "timeout" in text || "timed out" in text -> SshFailure.Reason.TIMEOUT
            "connection refused" in text -> SshFailure.Reason.REFUSED
            "network is unreachable" in text || "no route to host" in text -> SshFailure.Reason.UNREACHABLE
            "algorithm negotiation fail" in text -> SshFailure.Reason.NO_COMMON_ALGORITHM
            "too many authentication failures" in text -> SshFailure.Reason.TOO_MANY_TRIES
            "closed by foreign host" in text || "end of io stream" in text || "connection reset" in text ||
                "broken pipe" in text -> SshFailure.Reason.CLOSED_BY_SERVER
            "invalid privatekey" in text -> SshFailure.Reason.BAD_KEY_FILE
            "invalid protocol" in text || "packet corrupt" in text || "invalid packet" in text ||
                "verify: false" in text -> SshFailure.Reason.PROTOCOL
            else -> SshFailure.Reason.OTHER
        }
    }

    fun message(r: SshFailure.Reason): String = when (r) {
        SshFailure.Reason.UNKNOWN_HOST -> "Serveur introuvable"
        SshFailure.Reason.TIMEOUT -> "Le serveur ne répond pas"
        SshFailure.Reason.REFUSED -> "Connexion refusée, aucun service SSH n'écoute sur ce port"
        SshFailure.Reason.UNREACHABLE -> "Réseau injoignable, vérifiez la connexion du téléphone"
        SshFailure.Reason.CLOSED_BY_SERVER ->
            "Le serveur a fermé la connexion (adresse refusée, trop de connexions ou protection contre les attaques)"
        SshFailure.Reason.TOO_MANY_TRIES -> "Le serveur a refusé trop d'essais d'authentification"
        SshFailure.Reason.NO_COMMON_ALGORITHM -> "Aucun algorithme de chiffrement commun avec le serveur"
        SshFailure.Reason.BAD_KEY_FILE -> "Clé privée illisible ou d'un format non pris en charge"
        SshFailure.Reason.PROTOCOL -> "Échange SSH incorrect avec le serveur"
        SshFailure.Reason.OTHER -> "Connexion impossible au serveur"
    }

    /** Messages de l'exception et de ses causes, du plus général au plus précis. */
    fun detail(e: Throwable): String = generateSequence(e) { it.cause }.take(8)
        .joinToString(" ← ") { "${it.javaClass.simpleName} : ${it.message.orEmpty()}".trimEnd() }

    fun failure(e: Throwable) = SshFailure(classify(e), detail(e), e)
}
