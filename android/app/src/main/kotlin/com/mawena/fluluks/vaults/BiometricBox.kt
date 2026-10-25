package com.mawena.fluluks.vaults

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import java.io.File
import java.lang.ref.WeakReference
import java.security.GeneralSecurityException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

/** Clé biométrique devenue inutilisable (nouvelle biométrie enregistrée, clé ou fichier absent ou abîmé). */
class BiometricInvalidated : Exception(BiometricBox.MSG_INVALIDATED)

/** Invite biométrique annulée (« Utiliser le mot de passe », retour) : l'écran propose le mot de passe. */
class BiometricCancelled : Exception(BiometricBox.MSG_CANCELLED)

/** Biométrie impossible maintenant ([message] : la raison, en français). */
class BiometricUnavailable(reason: String) : Exception(reason)

/** Clés AES-256-GCM qui exigent la biométrie forte (Keystore d'Android ; en logiciel dans les tests). */
interface BioKeys {
    /** Crée (ou remplace) la clé [alias]. */
    fun create(alias: String)

    /** Chiffre avec [alias] (après l'invite) ; [BiometricInvalidated] si la clé est inutilisable. */
    fun encryptor(alias: String): Cipher

    fun decryptor(alias: String, iv: ByteArray): Cipher

    fun delete(alias: String)
}

/** Invite biométrique : rend [cipher] autorisé, ou lève [BiometricCancelled]. */
fun interface BioPrompt {
    suspend fun authenticate(title: String, cipher: Cipher): Cipher
}

/**
 * Secret biométrique des coffres (phase 14) : 32 octets aléatoires, distincts du mot de passe, scellés par une clé
 * du Keystore qui exige la biométrie forte à chaque usage et devient inutilisable si une nouvelle biométrie est
 * enregistrée. Fichier `<dir>/<id>.bio` : magie, IV, puis le secret chiffré (AES-256-GCM). Le secret n'est jamais
 * écrit en clair ni gardé : rendu à l'appelant, qui le met à zéro.
 */
class BiometricBox(private val dir: File, private val keys: BioKeys, private val prompt: BioPrompt) {
    private fun file(id: String) = File(dir, "$id.bio")

    fun has(id: String): Boolean = file(id).exists()

    /** Scelle [secret] pour le coffre [id] (invite [title]) ; [secret] est mis à zéro. Rien n'est gardé en cas d'échec. */
    suspend fun seal(id: String, title: String, secret: ByteArray) {
        val alias = alias(id)
        try {
            keys.create(alias)
            val c = prompt.authenticate(title, keys.encryptor(alias))
            val ct = c.doFinal(secret)
            val iv = c.iv
            dir.mkdirs()
            val tmp = File(dir, "$id.bio.tmp")
            tmp.writeBytes(MAGIC + byteArrayOf(iv.size.toByte()) + iv + ct)
            if (!tmp.renameTo(file(id))) {
                tmp.delete()
                throw java.io.IOException(MSG_NOT_SAVED)
            }
        } catch (e: Throwable) {
            keys.delete(alias)
            file(id).delete()
            throw e
        } finally {
            secret.fill(0)
        }
    }

    /**
     * Rend le secret du coffre [id] après l'invite [title]. [BiometricInvalidated] (clé et fichier effacés) si la clé
     * n'est plus utilisable ; [BiometricCancelled] si l'invite est annulée.
     */
    suspend fun unseal(id: String, title: String): ByteArray {
        val f = file(id)
        val raw = runCatching { f.readBytes() }.getOrNull()
        val ivLen = raw?.getOrNull(MAGIC.size)?.toInt() ?: -1
        if (raw == null || !raw.copyOf(MAGIC.size).contentEquals(MAGIC) || ivLen !in 12..16 ||
            raw.size <= MAGIC.size + 1 + ivLen
        ) {
            wipe(id)
            throw BiometricInvalidated()
        }
        val iv = raw.copyOfRange(MAGIC.size + 1, MAGIC.size + 1 + ivLen)
        val ct = raw.copyOfRange(MAGIC.size + 1 + ivLen, raw.size)
        val cipher = try {
            keys.decryptor(alias(id), iv)
        } catch (e: BiometricInvalidated) {
            wipe(id)
            throw e
        }
        val c = prompt.authenticate(title, cipher)
        return try {
            c.doFinal(ct)
        } catch (e: GeneralSecurityException) {
            wipe(id)
            throw BiometricInvalidated()
        }
    }

    /** Efface la clé et le secret scellé du coffre [id]. */
    fun wipe(id: String) {
        runCatching { keys.delete(alias(id)) }
        file(id).delete()
    }

    companion object {
        const val MSG_INVALIDATED =
            "Déverrouillage biométrique désactivé : la biométrie du téléphone a changé. Ouvrez le coffre avec son mot de passe."
        const val MSG_CANCELLED = "Déverrouillage biométrique annulé"
        const val MSG_OLD_ANDROID = "Le déverrouillage biométrique demande Android 9 ou plus récent"
        const val MSG_NO_STRONG = "Ce téléphone n'a pas de biométrie forte (visage ou empreinte)"
        const val MSG_NONE_ENROLLED = "Aucun visage ni empreinte enregistré dans les réglages d'Android"
        const val MSG_NO_SCREEN = "Ouvrez Portail pour utiliser le déverrouillage biométrique"
        const val MSG_OFF = "Le déverrouillage biométrique n'est pas activé pour ce coffre"
        const val MSG_FAILED = "Déverrouillage biométrique impossible"
        const val MSG_USE_PASSWORD = "Utiliser le mot de passe"
        const val MSG_NOT_SAVED = "Secret biométrique non enregistré"
        private val MAGIC = "PBIO1".toByteArray(Charsets.US_ASCII)

        fun alias(id: String) = "portail-coffre-$id"

        fun openTitle(name: String) = "Ouvrir le coffre $name"

        fun enableTitle(name: String) = "Coffre $name : déverrouillage biométrique"

        /**
         * Raison pour laquelle la biométrie forte n'est pas utilisable ([status] : résultat de
         * `BiometricManager.canAuthenticate`, null si inconnu), ou null si elle l'est.
         */
        fun unavailableReason(sdk: Int, status: Int?): String? = when {
            sdk < Build.VERSION_CODES.P -> MSG_OLD_ANDROID
            status == BiometricManager.BIOMETRIC_SUCCESS -> null
            status == BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> MSG_NONE_ENROLLED
            else -> MSG_NO_STRONG
        }

        /** [unavailableReason] pour ce téléphone. */
        fun unavailableReason(context: Context): String? {
            val sdk = Build.VERSION.SDK_INT
            val status = when {
                sdk >= Build.VERSION_CODES.R -> context.getSystemService(BiometricManager::class.java)
                    ?.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                sdk >= Build.VERSION_CODES.Q -> @Suppress("DEPRECATION")
                context.getSystemService(BiometricManager::class.java)?.canAuthenticate()
                sdk >= Build.VERSION_CODES.P -> {
                    // Android 9 : pas de BiometricManager ; le lecteur d'empreinte est la biométrie forte annoncée
                    val pm = context.packageManager
                    if (pm.hasSystemFeature(PackageManager.FEATURE_FINGERPRINT)) BiometricManager.BIOMETRIC_SUCCESS else null
                }
                else -> null
            }
            return unavailableReason(sdk, status)
        }
    }
}

/** Clés du Keystore d'Android : matérielles, biométrie forte à chaque usage, invalidées par une nouvelle biométrie. */
class KeystoreBioKeys : BioKeys {
    private fun store() = KeyStore.getInstance(STORE).apply { load(null) }

    override fun create(alias: String) {
        val b = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            b.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
        }
        KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, STORE).apply { init(b.build()) }.generateKey()
    }

    private fun key(alias: String): SecretKey = store().getKey(alias, null) as? SecretKey ?: throw BiometricInvalidated()

    private fun cipher(init: Cipher.() -> Unit): Cipher = try {
        Cipher.getInstance(TRANSFORMATION).apply(init)
    } catch (e: KeyPermanentlyInvalidatedException) {
        throw BiometricInvalidated()
    }

    override fun encryptor(alias: String): Cipher = cipher { init(Cipher.ENCRYPT_MODE, key(alias)) }

    override fun decryptor(alias: String, iv: ByteArray): Cipher =
        cipher { init(Cipher.DECRYPT_MODE, key(alias), GCMParameterSpec(128, iv)) }

    override fun delete(alias: String) {
        val ks = store()
        if (ks.containsAlias(alias)) ks.deleteEntry(alias)
    }

    companion object {
        private const val STORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}

/** Invite `BiometricPrompt` d'Android sur l'activité au premier plan (renseignée par MainActivity). */
object BiometricUi : BioPrompt {
    @Volatile private var activity: WeakReference<Activity>? = null

    fun attach(a: Activity) {
        activity = WeakReference(a)
    }

    fun detach(a: Activity) {
        if (activity?.get() === a) activity = null
    }

    override suspend fun authenticate(title: String, cipher: Cipher): Cipher = withContext(Dispatchers.Main) {
        val act = activity?.get() ?: throw BiometricUnavailable(BiometricBox.MSG_NO_SCREEN)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) throw BiometricUnavailable(BiometricBox.MSG_OLD_ANDROID)
        suspendCancellableCoroutine { cont ->
            val signal = CancellationSignal()
            cont.invokeOnCancellation { signal.cancel() }
            val exec = act.mainExecutor
            val b = BiometricPrompt.Builder(act)
                .setTitle(title)
                .setNegativeButton(BiometricBox.MSG_USE_PASSWORD, exec) { _, _ ->
                    if (cont.isActive) cont.resumeWithException(BiometricCancelled())
                }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) b.setConfirmationRequired(false)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                b.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            }
            b.build().authenticate(
                BiometricPrompt.CryptoObject(cipher), signal, exec,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        val c = result.cryptoObject?.cipher
                        if (!cont.isActive) return
                        if (c == null) cont.resumeWithException(BiometricUnavailable(BiometricBox.MSG_FAILED))
                        else cont.resume(c)
                    }

                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence?) {
                        if (!cont.isActive) return
                        // le bouton « Utiliser le mot de passe » a son propre rappel
                        val cancelled = errorCode == BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED ||
                            errorCode == BiometricPrompt.BIOMETRIC_ERROR_CANCELED
                        cont.resumeWithException(
                            if (cancelled) BiometricCancelled()
                            else BiometricUnavailable(errString?.toString()?.takeIf { it.isNotBlank() } ?: BiometricBox.MSG_FAILED),
                        )
                    }
                    // échec d'une tentative (visage non reconnu) : l'invite reste ouverte et réessaie
                },
            )
        }
    }
}
