package com.mawena.fluluks

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.ParcelFileDescriptor
import android.system.Os
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.mawena.fluluks.crypt.Crypt
import com.mawena.fluluks.crypt.DecryptedSources
import com.mawena.fluluks.files.TransferState
import com.mawena.fluluks.files.Transfers
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.engine.NativeEngine
import com.mawena.fluluks.files.Files
import com.mawena.fluluks.files.LocalSource
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.random.Random
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Vues déchiffrées sur le téléphone (phase 14, T6) : un fichier age écrit par le vrai moteur, ouvert en vue
 * déchiffrée, lu par le fournisseur de flux comme le font Media3 (sauts) et le décodeur d'images. Tout se passe
 * dans le cache de l'application.
 */
@RunWith(AndroidJUnit4::class)
class CryptInstrumentedTest {
    private val ctx get() = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var root: File
    private val pass = "phrase de l'essai"

    @Before fun setUp() {
        Files.context = ctx.applicationContext
        root = File(ctx.cacheDir, "dechiffre-essai").apply { deleteRecursively(); mkdirs() }
        val local = LocalSource("essai", "essai", "Essai", root) { true }
        Files.setResolverForTests { id -> local.takeIf { id == "essai" } }
    }

    @After fun tearDown() {
        DecryptedSources.closeAll()
        Files.setResolverForTests(null)
        root.deleteRecursively()
    }

    /** Chiffre [plain] dans [name] sous la racine, par le vrai moteur (scrypt 2^18). */
    private fun encrypt(name: String, plain: ByteArray) {
        val f = File(root, name)
        val fd = ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_CREATE or ParcelFileDescriptor.MODE_WRITE_ONLY or
            ParcelFileDescriptor.MODE_TRUNCATE).detachFd()
        val w = EngineError.check(NativeEngine.ageWriterOpenFd(fd, pass.toByteArray(), 18))
        var off = 0
        while (off < plain.size) {
            val n = minOf(1 shl 20, plain.size - off)
            EngineError.check(NativeEngine.ageWrite(w, plain.copyOfRange(off, off + n), n))
            off += n
        }
        EngineError.check(NativeEngine.ageWriterClose(w, true))
    }

    private fun preadFully(fd: java.io.FileDescriptor, buf: ByteArray, off: Long): Int {
        var got = 0
        while (got < buf.size) {
            val k = Os.pread(fd, buf, got, buf.size - got, off + got)
            if (k <= 0) break
            got += k
        }
        return got
    }

    @Test fun decryptedVideoSeeks() {
        val plain = Random(3).nextBytes(20 shl 20)
        encrypt("film.mp4.age", plain)
        val v = DecryptedSources.open("essai", "/film.mp4.age", pass.toByteArray())
        assertEquals(plain.size.toLong(), v.size)
        val uri = v.contentUri(v.path)
        ctx.contentResolver.openFileDescriptor(uri, "r")!!.use { pfd ->
            assertEquals(plain.size.toLong(), pfd.statSize)
            val buf = ByteArray(256 * 1024)
            for (pct in intArrayOf(50, 90, 10, 99)) { // sauts en avant et en arrière, comme une barre de lecture
                val off = plain.size.toLong() * pct / 100
                val n = preadFully(pfd.fileDescriptor, buf, off)
                val want = minOf(buf.size.toLong(), plain.size - off).toInt()
                assertEquals("$pct %", want, n)
                assertArrayEquals("$pct %", plain.copyOfRange(off.toInt(), off.toInt() + n), buf.copyOf(n))
            }
        }
        // rien d'autre que le chiffré dans le dossier
        assertEquals(listOf("film.mp4.age"), root.list()!!.toList())
    }

    /** Fin de l'opération en cours (chiffrement, déchiffrement), créneau libéré. */
    private fun await(timeoutMs: Long = 300_000): TransferState {
        val end = System.currentTimeMillis() + timeoutMs
        while (true) {
            val st = Transfers.state.value
            if (st != null && st.finished && !Transfers.isBusy("essai")) return st
            check(System.currentTimeMillis() < end) { "délai dépassé : $st" }
            Thread.sleep(20)
        }
    }

    private fun sha(b: ByteArray) = java.security.MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    /** Dossier de 200 fichiers (tailles variées, quatre sous-dossiers) ; rend le manifeste `sha256sum`. */
    private fun folder200(name: String): Map<String, ByteArray> {
        val r = Random(200)
        val files = (1..200).associate { i -> "$name/s${i % 4}/f%03d.bin".format(i) to r.nextBytes(r.nextInt(1, 64 * 1024)) }
        for ((p, d) in files) File(root, p).apply { parentFile!!.mkdirs() }.writeBytes(d)
        return files
    }

    private fun checkFolder(files: Map<String, ByteArray>) {
        for ((p, d) in files) assertArrayEquals(p, d, File(root, p).readBytes())
    }

    @Test fun encryptFolder200AgeAndZip() {
        val exports = File(ctx.filesDir, "essais-phase14").apply { mkdirs() }
        // age : original supprimé après vérification, puis déchiffré et comparé
        val files = folder200("dossier-200")
        var t0 = System.nanoTime()
        Crypt.startEncrypt(Crypt.EncryptRequest("essai", listOf("/dossier-200"), "essai", "/", "age", false, null, true),
            pass.toByteArray())
        var st = await()
        Log.i("PortailMesure", "chiffrement age de 200 fichiers (scrypt 2^18) : ${(System.nanoTime() - t0) / 1_000_000} ms")
        assertNull(st.error)
        assertFalse("original supprimé", File(root, "dossier-200").exists())
        val age = File(root, "dossier-200.zip.age")
        assertTrue(age.exists())
        age.copyTo(File(exports, "dossier-200.zip.age"), overwrite = true)
        t0 = System.nanoTime()
        Crypt.startDecrypt("essai", "/dossier-200.zip.age", "essai", "/", pass.toByteArray(), true)
        st = await()
        Log.i("PortailMesure", "déchiffrement et extraction : ${(System.nanoTime() - t0) / 1_000_000} ms")
        assertNull(st.error)
        checkFolder(files)
        File(exports, "dossier-200.sha256").writeText(files.entries.joinToString("") { (p, d) -> "${sha(d)}  $p\n" })

        // ZIP AES-256 du même dossier, original gardé
        File(root, "dossier-200.zip.age").delete()
        Crypt.startEncrypt(Crypt.EncryptRequest("essai", listOf("/dossier-200"), "essai", "/", "zip", false, null, false),
            pass.toByteArray())
        st = await()
        assertNull(st.error)
        val zip = File(root, "dossier-200.zip")
        assertTrue(zip.exists())
        zip.copyTo(File(exports, "dossier-200-aes.zip"), overwrite = true)
        checkFolder(files)
    }

    @Test fun decryptedImageViewer() {
        val bmp = Bitmap.createBitmap(64, 48, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.rgb(200, 30, 90)) }
        val png = ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        encrypt("photo.png.age", png)
        val v = DecryptedSources.open("essai", "/photo.png.age", pass.toByteArray())
        assertEquals("photo.png", v.name)
        val decoded = ctx.contentResolver.openInputStream(v.contentUri(v.path)).use { BitmapFactory.decodeStream(it) }
        assertNotNull(decoded)
        assertEquals(64, decoded.width)
        assertEquals(48, decoded.height)
        assertEquals(Color.rgb(200, 30, 90), decoded.getPixel(10, 10))
        DecryptedSources.close(v.id)
        assertEquals(listOf("photo.png.age"), root.list()!!.toList())
    }
}
