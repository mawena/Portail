package com.mawena.fluluks

import android.os.Build
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.mawena.fluluks.vaults.BiometricBox
import com.mawena.fluluks.vaults.BiometricInvalidated
import com.mawena.fluluks.vaults.KeystoreBioKeys
import java.security.KeyStore
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Phase 14, T12, sur le téléphone : la clé qui scelle le secret biométrique d'un coffre est dans le Keystore
 * matériel, exige l'authentification de l'utilisateur à chaque usage (biométrie forte) et ne chiffre rien sans
 * l'invite. Aucune invite n'est montrée ici.
 */
@RunWith(AndroidJUnit4::class)
class BiometricBoxInstrumentedTest {
    private val alias = BiometricBox.alias("essai-instrumente")
    private val keys = KeystoreBioKeys()

    @After fun cleanup() = keys.delete(alias)

    @Test fun biometricSecretSealedWithAuthKey() {
        keys.create(alias)
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val key = ks.getKey(alias, null) as SecretKey
        val info = SecretKeyFactory.getInstance(key.algorithm, "AndroidKeyStore").getKeySpec(key, KeyInfo::class.java) as KeyInfo
        assertTrue(info.isUserAuthenticationRequired)
        assertTrue(info.isInvalidatedByBiometricEnrollment)
        assertEquals(256, info.keySize)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            assertTrue(
                "clé hors du matériel : ${info.securityLevel}",
                info.securityLevel == KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT ||
                    info.securityLevel == KeyProperties.SECURITY_LEVEL_STRONGBOX,
            )
            assertEquals(KeyProperties.AUTH_BIOMETRIC_STRONG, info.userAuthenticationType)
            assertEquals(0, info.userAuthenticationValidityDurationSeconds)
        } else {
            @Suppress("DEPRECATION")
            assertTrue(info.isInsideSecureHardware)
        }
        // sans l'invite biométrique, la clé ne chiffre rien
        val c = keys.encryptor(alias)
        try {
            c.doFinal(ByteArray(32))
            fail("chiffré sans authentification")
        } catch (_: Exception) {
        }
    }

    @Test fun deletedKeyIsInvalid() {
        keys.create(alias)
        keys.delete(alias)
        assertFalse(KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.containsAlias(alias))
        try {
            keys.encryptor(alias)
            fail("clé effacée utilisable")
        } catch (_: BiometricInvalidated) {
        }
    }
}
