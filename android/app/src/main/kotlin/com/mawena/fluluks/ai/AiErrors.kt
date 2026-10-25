package com.mawena.fluluks.ai

import java.io.EOFException
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.ProtocolException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.security.cert.CertificateException
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException
import org.json.JSONException
import org.json.JSONObject

/**
 * Échec d'un appel à un serveur IA (phase 15) : [message] en français, qui dit quoi faire ; [serverMessage] : message
 * du serveur tel quel (montré sous le message français), jamais mis dans un journal ; [httpCode] : code HTTP s'il y en a
 * un ; [retryable] : un délai ou une erreur 5xx, qu'une automatisation planifiée peut réessayer une fois.
 */
class AiException(
    val kind: Kind,
    val serverMessage: String? = null,
    val httpCode: Int? = null,
    cause: Throwable? = null,
    /** Précision ajoutée au message français (« réponse du serveur illisible »). */
    detail: String? = null,
) : IOException(AiErrors.message(kind) + (detail?.let { " : $it" } ?: ""), cause) {
    enum class Kind {
        KEY_REFUSED, FORBIDDEN, MODEL_NOT_FOUND, NOT_FOUND, BAD_REQUEST, RATE_LIMITED, SERVER_ERROR,
        CONNECT_TIMEOUT, READ_TIMEOUT, STREAM_TIMEOUT, UNKNOWN_HOST, REFUSED, UNREACHABLE, CLOSED, CERTIFICATE,
        INTERRUPTED, STREAM_ERROR, PROTOCOL, OTHER,
    }

    override val message: String get() = super.message!!

    val retryable: Boolean
        get() = kind in setOf(Kind.SERVER_ERROR, Kind.CONNECT_TIMEOUT, Kind.READ_TIMEOUT, Kind.STREAM_TIMEOUT)
}

/** Traduction des réponses HTTP et des exceptions réseau en [AiException]. */
object AiErrors {
    fun message(k: AiException.Kind): String = when (k) {
        AiException.Kind.KEY_REFUSED -> "Clé API refusée : vérifiez la clé enregistrée pour ce serveur"
        AiException.Kind.FORBIDDEN -> "Accès refusé par le serveur : cette clé n'a pas le droit de faire cela"
        AiException.Kind.MODEL_NOT_FOUND -> "Modèle introuvable sur ce serveur : choisissez-en un autre"
        AiException.Kind.NOT_FOUND -> "Adresse introuvable sur ce serveur : vérifiez l'URL de base"
        AiException.Kind.BAD_REQUEST -> "Requête refusée par le serveur : vérifiez le modèle et les réglages"
        AiException.Kind.RATE_LIMITED ->
            "Le serveur est surchargé ou la limite de requêtes est atteinte : réessayez plus tard"
        AiException.Kind.SERVER_ERROR -> "Le serveur a rencontré une erreur : réessayez plus tard"
        AiException.Kind.CONNECT_TIMEOUT -> "Le serveur ne répond pas : vérifiez l'adresse et le réseau"
        AiException.Kind.READ_TIMEOUT -> "Le serveur met trop de temps à répondre : réessayez plus tard"
        AiException.Kind.STREAM_TIMEOUT -> "Le serveur ne répond plus"
        AiException.Kind.UNKNOWN_HOST -> "Serveur introuvable : vérifiez l'adresse"
        AiException.Kind.REFUSED -> "Connexion refusée : aucun serveur IA n'écoute à cette adresse"
        AiException.Kind.UNREACHABLE -> "Réseau injoignable : vérifiez la connexion du téléphone"
        AiException.Kind.CLOSED -> "Le serveur a fermé la connexion : réessayez"
        AiException.Kind.CERTIFICATE -> "Certificat du serveur refusé : connexion non sûre"
        AiException.Kind.INTERRUPTED -> "La réponse a été interrompue"
        AiException.Kind.STREAM_ERROR -> "Le serveur a signalé une erreur pendant la réponse"
        AiException.Kind.PROTOCOL -> "Réponse du serveur illisible : est-ce bien un serveur compatible OpenAI ?"
        AiException.Kind.OTHER -> "Échec de la requête au serveur IA"
    }

    /**
     * Réponse HTTP en erreur : [body] (2 Kio lus au plus) donne le message du serveur ; un 404 sur une route de
     * modèle ([modelRoute]) avec une erreur au format du contrat veut dire « modèle introuvable », sinon la route
     * n'existe pas (URL de base fausse).
     */
    fun fromHttp(code: Int, body: String?, modelRoute: Boolean): AiException {
        val server = serverMessage(body)
        val kind = when {
            code == 401 -> AiException.Kind.KEY_REFUSED
            code == 403 -> AiException.Kind.FORBIDDEN
            code == 404 && modelRoute && server != null -> AiException.Kind.MODEL_NOT_FOUND
            code == 404 -> AiException.Kind.NOT_FOUND
            code == 429 -> AiException.Kind.RATE_LIMITED
            code >= 500 -> AiException.Kind.SERVER_ERROR
            code in 400..499 -> AiException.Kind.BAD_REQUEST
            else -> AiException.Kind.PROTOCOL
        }
        return AiException(kind, server ?: body?.trim()?.takeIf { it.isNotEmpty() && !it.startsWith("<") }?.take(300), code)
    }

    /** `{"error":{"message":…}}` (contrat), `{"message":…}` (vLLM ancien) ou `{"error":"…"}` ; null sinon. */
    fun serverMessage(body: String?): String? {
        if (body.isNullOrBlank()) return null
        return try {
            val o = JSONObject(body)
            val e = o.opt("error")
            when {
                e is JSONObject && e.opt("message") is String -> e.getString("message")
                e is String -> e
                o.opt("message") is String -> o.getString("message")
                else -> null
            }?.take(1000)
        } catch (e: JSONException) {
            null
        }
    }

    /** Exception réseau ; [streaming] : pendant la lecture d'un flux déjà commencé. */
    fun fromException(e: Throwable, streaming: Boolean): AiException {
        if (e is AiException) return e
        val chain = generateSequence(e) { it.cause }.take(8).toList()
        for (c in chain) {
            val m = c.message.orEmpty().lowercase()
            val kind = when (c) {
                is UnknownHostException -> AiException.Kind.UNKNOWN_HOST
                is SSLPeerUnverifiedException, is SSLHandshakeException, is CertificateException ->
                    AiException.Kind.CERTIFICATE
                is SocketTimeoutException -> when {
                    "connect" in m -> AiException.Kind.CONNECT_TIMEOUT
                    streaming -> AiException.Kind.STREAM_TIMEOUT
                    else -> AiException.Kind.READ_TIMEOUT
                }
                is ConnectException -> when {
                    "timed out" in m -> AiException.Kind.CONNECT_TIMEOUT
                    "unreachable" in m -> AiException.Kind.UNREACHABLE
                    else -> AiException.Kind.REFUSED
                }
                is NoRouteToHostException -> AiException.Kind.UNREACHABLE
                is InterruptedIOException -> if ("timeout" in m || "timed out" in m) {
                    if (streaming) AiException.Kind.STREAM_TIMEOUT else AiException.Kind.READ_TIMEOUT
                } else {
                    null
                }
                is EOFException, is ProtocolException -> if (streaming) AiException.Kind.INTERRUPTED else AiException.Kind.CLOSED
                is SocketException -> when {
                    "unreachable" in m -> AiException.Kind.UNREACHABLE
                    streaming -> AiException.Kind.INTERRUPTED
                    else -> AiException.Kind.CLOSED
                }
                else -> null
            }
            if (kind != null) return AiException(kind, cause = e)
        }
        val m = chain.joinToString("\n") { it.message.orEmpty() }.lowercase()
        val kind = when {
            "unexpected end of stream" in m -> if (streaming) AiException.Kind.INTERRUPTED else AiException.Kind.CLOSED
            streaming -> AiException.Kind.INTERRUPTED
            else -> AiException.Kind.OTHER
        }
        return AiException(kind, cause = e)
    }
}
