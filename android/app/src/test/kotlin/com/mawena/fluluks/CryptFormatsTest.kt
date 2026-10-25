package com.mawena.fluluks

import com.mawena.fluluks.crypt.CryptFormats
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Reconnaissance des fichiers chiffrés par leurs premiers octets, pas seulement par l'extension. */
class CryptFormatsTest {
    private fun b(s: String) = s.toByteArray(Charsets.ISO_8859_1)

    /** En-tête local ZIP : signature, version, drapeaux, méthode, puis le reste jusqu'au nom. */
    private fun local(name: String, flags: Int, method: Int, size: Int = 0): ByteArray {
        val n = b(name)
        val h = ByteArray(30)
        b("PK\u0003\u0004").copyInto(h)
        h[6] = flags.toByte(); h[7] = (flags shr 8).toByte()
        h[8] = method.toByte(); h[9] = (method shr 8).toByte()
        for (i in 0..3) { h[18 + i] = (size shr (8 * i)).toByte(); h[22 + i] = (size shr (8 * i)).toByte() }
        h[26] = n.size.toByte()
        return h + n + ByteArray(size)
    }

    @Test fun ageByMagic() {
        val head = b("age-encryption.org/v1\n-> scrypt c2FsdHNhbHRzYWx0c2FsdA 18\nabc\n--- xyz\n")
        assertEquals("age", CryptFormats.detect(head))
        assertEquals(18, CryptFormats.ageWorkFactor(head))
        assertEquals("age", CryptFormats.detect(head)) // le nom n'y est pour rien
    }

    @Test fun ageArmorIsNone() =
        assertEquals("none", CryptFormats.detect(b("-----BEGIN AGE ENCRYPTED FILE-----\n")))

    @Test fun zipAesAfterUnencryptedDirectory() {
        // un ZIP AES écrit par libarchive : dossier en clair d'abord, puis un fichier chiffré (méthode 99)
        val head = local("dossier/", 0, 0) + local("dossier/a.txt", 1, 99, 40)
        assertEquals("zip-aes", CryptFormats.detect(head))
    }

    @Test fun zipLegacyAndPlain() {
        assertEquals("zip-legacy", CryptFormats.detect(local("a.txt", 1, 8, 10)))
        assertEquals("none", CryptFormats.detect(local("a.txt", 0, 8, 10)))
        // taille inconnue (descripteur de données) avant toute entrée chiffrée : on ne sait pas, donc « none »
        assertEquals("none", CryptFormats.detect(local("a.txt", 8, 8, 0) + local("b.txt", 1, 99, 10)))
    }

    @Test fun luksByMagic() {
        assertEquals("luks", CryptFormats.detect(b("LUKSº¾\u0000\u0002") + ByteArray(100)))
        assertEquals("none", CryptFormats.detect(b("SKULº¾")))
    }

    @Test fun shortOrEmpty() {
        assertEquals("none", CryptFormats.detect(ByteArray(0)))
        assertEquals("none", CryptFormats.detect(b("PK")))
        assertNull(CryptFormats.ageWorkFactor(b("age-encryption.org/v1\n-> X25519 abc\n")))
    }

    @Test fun folderAndPlainNames() {
        assertEquals(true, CryptFormats.isFolder("photos.zip.age"))
        assertEquals(false, CryptFormats.isFolder("rapport.pdf.age"))
        assertEquals("rapport.pdf", CryptFormats.plainName("rapport.pdf.age"))
        assertEquals("photos", CryptFormats.plainName("photos.zip.age", folder = true))
        assertEquals("photos.zip", CryptFormats.plainName("photos.zip.age"))
        assertEquals("fichier", CryptFormats.plainName("fichier")) // sans extension .age : nom gardé
    }
}
