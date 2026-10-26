package com.mawena.fluluks.ai

import java.io.File
import java.net.Socket
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509ExtendedTrustManager
import javax.net.ssl.X509TrustManager
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.internal.tls.OkHostnameVerifier
import org.json.JSONObject

/** Certificat refusé : empreinte SHA-256 de celui présenté ; [changed] : une autre empreinte avait été approuvée. */
data class CertProblem(val fingerprint: String, val changed: Boolean)

/** Certificat inconnu du système et non approuvé (ou d'empreinte changée) ; lu par `AiErrors.fromException`. */
class UntrustedCertificateException(val problem: CertProblem, cause: Throwable?) :
    CertificateException(if (problem.changed) "certificat changé" else "certificat non approuvé", cause)

/**
 * Certificats de serveurs IA approuvés par l'utilisateur (phase 15, T10), comme les empreintes SSH de la phase 10 : un
 * VPS sans nom de domaine a souvent un certificat auto-signé. Pour chaque serveur (« hôte:port »), l'empreinte SHA-256
 * du certificat accepté sur « Faire confiance » ; elle est vérifiée à chaque connexion. Un certificat reconnu par le
 * système passe sans rien demander. [file] null : en mémoire seulement.
 */
class TrustedCerts(private val file: File?) {
    private val pins = HashMap<String, String>()

    init {
        val f = file
        if (f != null && f.exists()) {
            runCatching {
                val o = JSONObject(f.readText())
                for (k in o.keys()) pins[k] = o.getString(k)
            }
        }
    }

    @Synchronized fun get(hostPort: String): String? = pins[hostPort.lowercase()]

    @Synchronized fun trust(hostPort: String, fingerprint: String) {
        pins[hostPort.lowercase()] = fingerprint
        save()
    }

    @Synchronized fun forget(hostPort: String) {
        if (pins.remove(hostPort.lowercase()) != null) save()
    }

    private fun save() {
        val f = file ?: return
        val tmp = File(f.parentFile, f.name + ".tmp")
        tmp.writeText(JSONObject(pins as Map<*, *>).toString())
        if (!tmp.renameTo(f)) {
            f.delete()
            tmp.renameTo(f)
        }
    }

    /** Système d'abord ; sinon, l'empreinte approuvée pour ce serveur, ou un refus qui porte l'empreinte présentée. */
    private class PinningTrustManager(
        private val system: X509TrustManager,
        private val trusted: () -> TrustedCerts,
    ) : X509ExtendedTrustManager() {
        override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String, socket: Socket?) {
            val session = (socket as? SSLSocket)?.handshakeSession
            check(chain, session?.let { hostPort(it.peerHost, it.peerPort) }) {
                (system as? X509ExtendedTrustManager)?.checkServerTrusted(chain, authType, socket)
                    ?: system.checkServerTrusted(chain, authType)
            }
        }

        override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String, engine: SSLEngine?) {
            check(chain, engine?.let { hostPort(it.peerHost, it.peerPort) }) {
                (system as? X509ExtendedTrustManager)?.checkServerTrusted(chain, authType, engine)
                    ?: system.checkServerTrusted(chain, authType)
            }
        }

        override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) =
            check(chain, null) { system.checkServerTrusted(chain, authType) }

        private fun check(chain: Array<X509Certificate>, hostPort: String?, bySystem: () -> Unit) {
            try {
                bySystem()
            } catch (e: CertificateException) {
                val fp = fingerprint(chain.first())
                val pinned = hostPort?.let { trusted().get(it) }
                if (pinned == fp) return
                throw UntrustedCertificateException(CertProblem(fp, pinned != null), e)
            }
        }

        override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String, socket: Socket?) =
            throw CertificateException("client")

        override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String, engine: SSLEngine?) =
            throw CertificateException("client")

        override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = throw CertificateException("client")

        override fun getAcceptedIssuers(): Array<X509Certificate> = system.acceptedIssuers
    }

    companion object {
        /** Empreinte SHA-256 d'un certificat, en hexadécimal majuscule séparé par « : ». */
        fun fingerprint(cert: X509Certificate): String =
            MessageDigest.getInstance("SHA-256").digest(cert.encoded).joinToString(":") { "%02X".format(it) }

        fun hostPort(host: String, port: Int) = "${host.lowercase()}:$port"

        /**
         * « hôte:port » d'une URL de base (port par défaut du schéma), l'hôte écrit comme OkHttp le passe à la connexion
         * TLS : une adresse IPv6 sans crochets et sous sa forme abrégée.
         */
        fun hostPort(baseUrl: String): String {
            val u = baseUrl.toHttpUrl()
            return hostPort(u.host, u.port)
        }

        fun systemTrustManager(): X509TrustManager {
            val f = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
            f.init(null as KeyStore?)
            return f.trustManagers.filterIsInstance<X509TrustManager>().first()
        }

        /**
         * [builder] dont les connexions TLS acceptent aussi les certificats approuvés de [trusted] (consulté à chaque
         * connexion) ; le nom du serveur n'est alors pas exigé dans le certificat (adresse IP d'un VPS).
         */
        fun secure(
            builder: OkHttpClient.Builder,
            trusted: () -> TrustedCerts,
            system: X509TrustManager = systemTrustManager(),
        ): OkHttpClient.Builder {
            val tm = PinningTrustManager(system, trusted)
            val ctx = SSLContext.getInstance("TLS").apply { init(null, arrayOf(tm), null) }
            val names = HostnameVerifier { host, session ->
                OkHostnameVerifier.verify(host, session) || run {
                    val cert = session.peerCertificates.firstOrNull() as? X509Certificate
                    cert != null && trusted().get(hostPort(host, session.peerPort)) == fingerprint(cert)
                }
            }
            return builder.sslSocketFactory(ctx.socketFactory, tm).hostnameVerifier(names)
        }
    }
}
