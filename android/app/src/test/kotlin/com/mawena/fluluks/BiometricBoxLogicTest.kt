package com.mawena.fluluks

import android.hardware.biometrics.BiometricManager
import com.mawena.fluluks.vaults.BioKeys
import com.mawena.fluluks.vaults.BioPrompt
import com.mawena.fluluks.vaults.BiometricBox
import com.mawena.fluluks.vaults.BiometricCancelled
import com.mawena.fluluks.vaults.BiometricInvalidated
import java.io.File
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Clés « du Keystore » en logiciel (AES-256-GCM du JDK) ; [invalidate] imite une nouvelle biométrie enregistrée. */
class SoftBioKeys : BioKeys {
    val keys = HashMap<String, SecretKey>()
    val invalidated = HashSet<String>()
    val deleted = ArrayList<String>()

    override fun create(alias: String) {
        keys[alias] = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        invalidated.remove(alias)
    }

    private fun key(alias: String): SecretKey {
        if (alias in invalidated) throw BiometricInvalidated()
        return keys[alias] ?: throw BiometricInvalidated()
    }

    override fun encryptor(alias: String): Cipher =
        Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key(alias)) }

    override fun decryptor(alias: String, iv: ByteArray): Cipher =
        Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, key(alias), GCMParameterSpec(128, iv)) }

    override fun delete(alias: String) {
        keys.remove(alias)
        deleted.add(alias)
    }

    fun invalidate(alias: String) = invalidated.add(alias)
}

/** Invite biométrique de test : réussit, ou est annulée (« Utiliser le mot de passe »). */
class FakeBioPrompt : BioPrompt {
    var cancel = false
    val titles = ArrayList<String>()

    override suspend fun authenticate(title: String, cipher: Cipher): Cipher {
        titles.add(title)
        if (cancel) throw BiometricCancelled()
        return cipher
    }
}

/** Phase 14, T12 : secret biométrique scellé par une clé du Keystore (logique, sans Android). */
class BiometricBoxLogicTest {
    @get:Rule val tmp = TemporaryFolder()

    private val keys = SoftBioKeys()
    private val prompt = FakeBioPrompt()
    private fun box() = BiometricBox(tmp.root, keys, prompt)
    private val secret = ByteArray(32) { (it * 7 + 3).toByte() }

    @Test fun sealThenUnseal() {
        val b = box()
        runBlocking { b.seal("a1", "Ouvrir le coffre Photos", secret.copyOf()) }
        assertTrue(b.has("a1"))
        val f = File(tmp.root, "a1.bio")
        assertTrue(f.exists())
        val raw = f.readBytes()
        assertFalse("secret en clair dans le fichier", raw.toList().windowed(32).any { it.toByteArray().contentEquals(secret) })
        assertArrayEquals(secret, runBlocking { b.unseal("a1", "Ouvrir le coffre Photos") })
        assertEquals(listOf("Ouvrir le coffre Photos", "Ouvrir le coffre Photos"), prompt.titles)
        assertEquals(BiometricBox.alias("a1"), "portail-coffre-a1")
    }

    @Test fun invalidatedKeyWipesBox() {
        val b = box()
        runBlocking { b.seal("a1", "t", secret.copyOf()) }
        keys.invalidate(BiometricBox.alias("a1"))
        try {
            runBlocking { b.unseal("a1", "t") }
            fail("ouvert")
        } catch (e: BiometricInvalidated) {
            assertEquals(BiometricBox.MSG_INVALIDATED, e.message)
        }
        assertFalse(b.has("a1"))
        assertTrue(BiometricBox.alias("a1") in keys.deleted)
    }

    @Test fun cancelLeavesNothingSealed() {
        val b = box()
        prompt.cancel = true
        try {
            runBlocking { b.seal("a1", "t", secret.copyOf()) }
            fail("scellé")
        } catch (_: BiometricCancelled) {
        }
        assertFalse(b.has("a1"))
        assertTrue(BiometricBox.alias("a1") in keys.deleted) // clé neuve retirée
    }

    @Test fun tamperedFileIsInvalid() {
        val b = box()
        runBlocking { b.seal("a1", "t", secret.copyOf()) }
        val f = File(tmp.root, "a1.bio")
        val raw = f.readBytes()
        raw[raw.size - 1] = (raw[raw.size - 1].toInt() xor 1).toByte()
        f.writeBytes(raw)
        try {
            runBlocking { b.unseal("a1", "t") }
            fail("ouvert")
        } catch (_: BiometricInvalidated) {
        }
        assertFalse(b.has("a1"))
    }

    @Test fun wipeRemovesKeyAndFile() {
        val b = box()
        runBlocking { b.seal("a1", "t", secret.copyOf()) }
        b.wipe("a1")
        assertFalse(b.has("a1"))
        assertFalse(BiometricBox.alias("a1") in keys.keys)
    }

    @Test fun hiddenWithoutStrongBiometric() {
        assertEquals(BiometricBox.MSG_OLD_ANDROID, BiometricBox.unavailableReason(27, null))
        assertNull(BiometricBox.unavailableReason(33, BiometricManager.BIOMETRIC_SUCCESS))
        assertEquals(BiometricBox.MSG_NONE_ENROLLED, BiometricBox.unavailableReason(33, BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED))
        assertEquals(BiometricBox.MSG_NO_STRONG, BiometricBox.unavailableReason(33, BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE))
        assertEquals(BiometricBox.MSG_NO_STRONG, BiometricBox.unavailableReason(30, BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE))
        assertEquals(BiometricBox.MSG_NO_STRONG, BiometricBox.unavailableReason(28, null)) // API 28 : pas de lecteur annoncé
        assertNull(BiometricBox.unavailableReason(28, BiometricManager.BIOMETRIC_SUCCESS))
    }
}
