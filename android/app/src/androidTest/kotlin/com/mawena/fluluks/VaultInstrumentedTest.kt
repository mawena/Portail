package com.mawena.fluluks

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.mawena.fluluks.crypt.Crypt
import com.mawena.fluluks.engine.NativeEngine
import com.mawena.fluluks.files.DiskSource
import com.mawena.fluluks.files.FileSource
import com.mawena.fluluks.files.Files
import com.mawena.fluluks.files.FilesException
import com.mawena.fluluks.files.LocalSource
import com.mawena.fluluks.files.Sources
import com.mawena.fluluks.vaults.VaultStore
import com.mawena.fluluks.vaults.Vaults
import com.mawena.fluluks.volumes.VolumeManager
import java.io.File
import java.security.MessageDigest
import kotlin.random.Random
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Coffres sur le Pixel (phase 14, T15), avec le vrai moteur : création (place écrite, LUKS2, Argon2 de 1 Gio),
 * ouverture, écriture, fermeture, réouverture, mot de passe changé, clé de secours ; coffre posé dans un fichier d'un
 * volume ext4 d'image et fermé avant l'éjection de ce volume ; conteneur LUKS1 créé sous Linux. Tout se passe dans
 * le dossier privé de l'application ; les coffres `coffre-exfat.luks` et `coffre-ext4.luks` et leurs manifestes
 * restent dans `files/essais-phase14/`, pour `tools/fixtures/verify_vault_with_kernel.sh` sur le PC. Mesures dans le
 * journal (étiquette `PortailMesure`).
 */
@RunWith(AndroidJUnit4::class)
class VaultInstrumentedTest {
    private val instr get() = InstrumentationRegistry.getInstrumentation()
    private val ctx get() = instr.targetContext
    private lateinit var root: File
    private lateinit var exports: File
    private lateinit var local: LocalSource
    private var diskId: String? = null

    /** Phrase attendue par verify_vault_with_kernel.sh. */
    private val pass = "phrase de passe du coffre"

    private fun sources(): List<FileSource> =
        listOf<FileSource>(local) + VolumeManager.volumes.value.map { DiskSource(it.id, NativeEngine) }

    @Before fun setUp() {
        Files.context = ctx.applicationContext
        Sources.init(ctx)
        VolumeManager.init(ctx)
        VolumeManager.ejectAll()
        waitFor { VolumeManager.volumes.value.isEmpty() }
        root = File(ctx.filesDir, "coffres-essai").apply { deleteRecursively(); mkdirs() }
        exports = File(ctx.filesDir, "essais-phase14").apply { mkdirs() }
        local = LocalSource("essai", "essai", "Essai", root) { true }
        val store = File(ctx.filesDir, "coffres-essai-liste").apply { deleteRecursively(); mkdirs() }
        Vaults.resetForTests(VaultStore(store), ::sources, null)
        Files.setResolverForTests { id -> sources().firstOrNull { it.id == id } }
    }

    @After fun tearDown() {
        VolumeManager.ejectAll()
        waitFor { VolumeManager.volumes.value.isEmpty() }
        diskId?.let { VolumeManager.removeDiskForTests(it) }
        Vaults.resetForTests(null, null, null)
        Files.setResolverForTests(null)
        root.deleteRecursively()
    }

    private fun waitFor(timeoutMs: Long = 30_000, cond: () -> Boolean) {
        val end = System.currentTimeMillis() + timeoutMs
        while (!cond()) {
            check(System.currentTimeMillis() < end) { "délai dépassé" }
            Thread.sleep(50)
        }
    }

    private fun mesure(what: String) = Log.i("PortailMesure", what)

    private fun <T> chrono(what: String, block: () -> T): T {
        val t0 = System.nanoTime()
        val r = block()
        mesure("$what : ${(System.nanoTime() - t0) / 1_000_000} ms")
        return r
    }

    private fun hex(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    private fun open(id: String, pw: String = pass, writable: Boolean = true, recovery: Boolean = false) =
        runBlocking { Vaults.open(id, null, null, pw.toByteArray(), writable, recovery = recovery) }

    private fun close(id: String) {
        Vaults.close(id)
        waitFor { VolumeManager.vaultVolume(id) == null }
    }

    private fun refusedBadPassword(block: () -> Unit) {
        try {
            block()
            fail("ouvert")
        } catch (e: FilesException) {
            assertEquals(Crypt.MSG_BAD_PASSWORD, e.message)
        }
    }

    /** Écrit [files] dans le coffre ouvert [volId] ; rend le manifeste `sha256sum`. */
    private fun write(volId: String, files: Map<String, ByteArray>): String {
        val src = Files.source(volId)
        val m = StringBuilder()
        for ((name, data) in files) {
            src.createFile("/", name).second.use { it.write(data) }
            m.append(hex(data)).append("  ./").append(name).append('\n')
        }
        return m.toString()
    }

    private fun export(name: String, manifest: String) {
        File(root, "$name.luks").copyTo(File(exports, "$name.luks"), overwrite = true)
        File(exports, "$name.sha256").writeText(manifest)
    }

    @Test fun vaultLifecycle128MiB() {
        val info = chrono("création d'un coffre exFAT de 128 Mio (zéros, LUKS2 Argon2 1 Gio, exFAT)") {
            runBlocking { Vaults.create("essai", "/", "coffre-exfat", 128L shl 20, "exfat", pass.toByteArray()) }
        }
        assertEquals(128L shl 20, File(root, "coffre-exfat.luks").length())
        val vol = chrono("ouverture (Argon2 1 Gio)") { open(info.id) }
        val files = (1..50).associate { "f%02d.bin".format(it) to Random(it).nextBytes(1000 + it * 997) }.toMutableMap()
        val big = Random(99).nextBytes(32 shl 20)
        var manifest = chrono("écriture de 50 fichiers") { write(vol.id, files) }
        val t0 = System.nanoTime()
        manifest += write(vol.id, mapOf("gros.bin" to big))
        close(info.id) // synchronisé
        val ms = (System.nanoTime() - t0) / 1_000_000
        mesure("écriture de 32 Mio dans le coffre, fermeture comprise : $ms ms (${32_000 / maxOf(ms, 1)} Mo/s)")

        val ro = open(info.id, writable = false)
        val src = Files.source(ro.id)
        val t1 = System.nanoTime()
        val back = src.openRead("/gros.bin").use { it.readBytes() }
        mesure("lecture de 32 Mio dans le coffre : ${(System.nanoTime() - t1) / 1_000_000} ms")
        assertArrayEquals(big, back)
        for ((name, data) in files) assertArrayEquals(name, data, src.openRead("/$name").use { it.readBytes() })
        close(info.id)

        // mot de passe changé, puis remis (le PC vérifie le coffre avec la phrase d'origine)
        chrono("changement du mot de passe") {
            runBlocking { Vaults.changePassword(info.id, pass.toByteArray(), "nouveau mot de passe".toByteArray()) }
        }
        refusedBadPassword { open(info.id) }
        open(info.id, "nouveau mot de passe")
        close(info.id)
        runBlocking { Vaults.changePassword(info.id, "nouveau mot de passe".toByteArray(), pass.toByteArray()) }

        // clé de secours : tapée en minuscules, sans tirets
        val key = String(runBlocking { Vaults.addRecoveryKey(info.id, pass.toByteArray()) }, Charsets.US_ASCII)
        assertTrue(Vaults.get(info.id)!!.hasRecovery)
        chrono("ouverture par la clé de secours") { open(info.id, key.lowercase().replace("-", ""), recovery = true) }
        close(info.id)
        runBlocking { Vaults.removeRecoveryKey(info.id, pass.toByteArray()) }
        refusedBadPassword { open(info.id, key, recovery = true) }
        assertFalse(Vaults.get(info.id)!!.hasRecovery)
        export("coffre-exfat", manifest)
    }

    @Test fun ext4VaultForLinux() {
        val info = runBlocking { Vaults.create("essai", "/", "coffre-ext4", 64L shl 20, "ext4", pass.toByteArray()) }
        val vol = open(info.id)
        assertEquals("ext4", Vaults.get(info.id)!!.fs.lowercase())
        val manifest = write(vol.id, (1..10).associate { "linux-%02d.txt".format(it) to "ligne $it\n".repeat(it * 50).toByteArray() })
        close(info.id)
        export("coffre-ext4", manifest)
    }

    @Test fun vaultOnExt4ImageClosedBeforeEject() {
        val img = File(ctx.cacheDir, "coffre-hote.img")
        Fixtures.file("ext4-rw-reel.img").copyTo(img, overwrite = true)
        val id = VolumeManager.addImageDiskForTests(img.absolutePath, readOnly = false)
        diskId = id
        val part = VolumeManager.disks.value.first { it.id == id }.scan!!.parts.first()
        val host = runBlocking { VolumeManager.mountPlain(id, part.index, true) }.id
        val info = chrono("création d'un coffre de 64 Mio sur un volume ext4 d'image") {
            runBlocking { Vaults.create(host, "/", "dans-image", 64L shl 20, "exfat", pass.toByteArray()) }
        }
        val vol = open(info.id)
        write(vol.id, mapOf("note.txt" to "écrit dans un coffre posé sur un disque".toByteArray()))
        // éjecter le volume porteur : le coffre se ferme d'abord, puis le volume
        VolumeManager.eject(host)
        waitFor { VolumeManager.volumes.value.isEmpty() }
        assertNull(VolumeManager.vaultVolume(info.id))
        // remonté, le coffre se rouvre avec son contenu
        val host2 = runBlocking { VolumeManager.mountPlain(id, part.index, true) }.id
        assertNotNull(Files.source(host2).stat("/dans-image.luks"))
        val again = open(info.id, writable = false)
        assertEquals(
            "écrit dans un coffre posé sur un disque",
            String(Files.source(again.id).openRead("/note.txt").use { it.readBytes() }),
        )
    }

    @Test fun linuxLuks1ContainerOpens() {
        Fixtures.file("whole-luks1-xts.img").copyTo(File(root, "linux.img"), overwrite = true)
        val vol = runBlocking {
            Vaults.open(null, "essai", "/linux.img", Fixtures.bytes("pass.txt"), writable = false)
        }
        val id = vol.vaultId!!
        assertTrue(Files.source(vol.id).list("/").isNotEmpty()) // l'arbre ext4 de référence
        assertEquals(1, Vaults.get(id)!!.luksVersion)
        close(id)
        try {
            runBlocking { Vaults.changePassword(id, Fixtures.bytes("pass.txt"), "nouveau mot de passe".toByteArray()) }
            fail("changé")
        } catch (e: FilesException) {
            assertEquals(Vaults.MSG_LUKS1, e.message)
        }
    }
}
