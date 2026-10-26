package com.mawena.fluluks

import com.mawena.fluluks.ai.AiException
import com.mawena.fluluks.ai.OpenAiCompatibleProvider
import com.mawena.fluluks.ai.TrustedCerts
import java.io.File
import java.net.InetAddress
import java.nio.file.Files
import java.security.KeyStore
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Certificats auto-signés de confiance (phase 15, T10) : refusés d'abord avec leur empreinte SHA-256, acceptés ensuite
 * seulement si cette empreinte a été approuvée pour ce serveur (même sans nom correspondant, cas d'une adresse IP),
 * refusés avec une explication si elle a changé ; un certificat reconnu par le système n'a besoin de rien.
 */
class TrustedCertsTest {
    private val dir: File = Files.createTempDirectory("certs").toFile()
    private val store = TrustedCerts(File(dir, "ai-certs.json"))
    private val servers = mutableListOf<MockWebServer>()

    @After fun tearDown() {
        servers.forEach { it.shutdown() }
        dir.deleteRecursively()
    }

    private fun systemTrust(): X509TrustManager {
        val f = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        f.init(null as KeyStore?)
        return f.trustManagers.filterIsInstance<X509TrustManager>().first()
    }

    private val models = "{\"object\":\"list\",\"data\":[{\"id\":\"essai-court\",\"object\":\"model\"}]}"

    /** Serveur HTTPS au certificat [cert] (auto-signé par défaut, au nom « localhost »). */
    private fun https(
        cert: HeldCertificate = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build(),
        address: InetAddress? = null,
    ): MockWebServer {
        val s = MockWebServer()
        s.useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory(), false)
        repeat(3) { s.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(models)) }
        if (address != null) s.start(address, 0) else s.start()
        servers += s
        return s
    }

    private fun client(system: X509TrustManager = systemTrust()): OkHttpClient =
        TrustedCerts.secure(OkHttpClient.Builder(), { store }, system).build()

    private fun provider(url: String, http: OkHttpClient) = OpenAiCompatibleProvider(url, null, http = http)

    private fun refused(block: () -> Unit): AiException {
        try {
            block()
        } catch (e: AiException) {
            return e
        }
        fail("refus attendu")
        error("")
    }

    @Test fun fingerprintIsSha256InColonHex() {
        val cert = HeldCertificate.Builder().build()
        val fp = TrustedCerts.fingerprint(cert.certificate)
        assertEquals(32 * 3 - 1, fp.length)
        assertTrue(fp, fp.matches(Regex("([0-9A-F]{2}:){31}[0-9A-F]{2}")))
    }

    @Test fun hostPortOfBaseUrl() {
        assertEquals("atelier.mawena.cloud:443", TrustedCerts.hostPort("https://Atelier.Mawena.cloud"))
        assertEquals("10.0.0.2:11434", TrustedCerts.hostPort("http://10.0.0.2:11434/v1"))
        assertEquals("exemple.fr:80", TrustedCerts.hostPort("http://exemple.fr"))
    }

    @Test fun storePersistsTrustAndForget() {
        store.trust("a:443", "AA")
        assertEquals("AA", TrustedCerts(File(dir, "ai-certs.json")).get("a:443"))
        store.forget("a:443")
        assertNull(TrustedCerts(File(dir, "ai-certs.json")).get("a:443"))
    }

    @Test fun selfSignedRefusedWithItsFingerprint() {
        val cert = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val s = https(cert)
        val e = refused { runBlocking { provider("https://localhost:${s.port}", client()).models() } }
        assertEquals(AiException.Kind.CERTIFICATE, e.kind)
        assertEquals(TrustedCerts.fingerprint(cert.certificate), e.certificate!!.fingerprint)
        assertFalse(e.certificate!!.changed)
    }

    @Test fun trustedFingerprintAcceptedEvenForAnAddressNotInTheCertificate() {
        val cert = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val s = https(cert)
        val http = client()
        val e = refused { runBlocking { provider("https://127.0.0.1:${s.port}", http).models() } }
        store.trust("127.0.0.1:${s.port}", e.certificate!!.fingerprint)
        assertEquals(listOf("essai-court"), runBlocking { provider("https://127.0.0.1:${s.port}", http).models() }.map { it.id })
    }

    /** « Faire confiance » enregistre l'empreinte sous l'hôte de l'adresse saisie : entre crochets pour une IPv6. */
    @Test fun trustedFingerprintAcceptedForAnIpv6Address() {
        val cert = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val s = https(cert, InetAddress.getByName("::1"))
        val url = "https://[::1]:${s.port}"
        val http = client()
        val e = refused { runBlocking { provider(url, http).models() } }
        store.trust(TrustedCerts.hostPort(url), e.certificate!!.fingerprint)
        assertEquals(listOf("essai-court"), runBlocking { provider(url, http).models() }.map { it.id })
    }

    @Test fun changedFingerprintRefusedAndExplained() {
        val s = https()
        store.trust("localhost:${s.port}", TrustedCerts.fingerprint(HeldCertificate.Builder().build().certificate))
        val e = refused { runBlocking { provider("https://localhost:${s.port}", client()).models() } }
        assertEquals(AiException.Kind.CERT_CHANGED, e.kind)
        assertTrue(e.certificate!!.changed)
        assertTrue(e.message, e.message.contains("a changé"))
    }

    @Test fun certificateRecognisedBySystemNeedsNoTrust() {
        val root = HeldCertificate.Builder().certificateAuthority(0).build()
        val cert = HeldCertificate.Builder().addSubjectAlternativeName("localhost").signedBy(root).build()
        val s = https(cert)
        val system = HandshakeCertificates.Builder().addTrustedCertificate(root.certificate).build().trustManager
        assertEquals(1, runBlocking { provider("https://localhost:${s.port}", client(system)).models() }.size)
    }

    @Test fun trustForAnotherServerDoesNotApply() {
        val cert = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val s = https(cert)
        store.trust("localhost:${s.port + 1}", TrustedCerts.fingerprint(cert.certificate))
        val e = refused { runBlocking { provider("https://localhost:${s.port}", client()).models() } }
        assertEquals(AiException.Kind.CERTIFICATE, e.kind)
    }
}
