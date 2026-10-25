package com.mawena.fluluks

import com.mawena.fluluks.crypt.Crypt
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.engine.FormatProgress
import com.mawena.fluluks.files.Archives
import com.mawena.fluluks.files.DiskSource
import com.mawena.fluluks.files.FileSource
import com.mawena.fluluks.files.Files
import com.mawena.fluluks.files.FilesException
import com.mawena.fluluks.files.LocalSource
import com.mawena.fluluks.files.Sources
import com.mawena.fluluks.files.TransferState
import com.mawena.fluluks.files.Transfers
import com.mawena.fluluks.vaults.VaultStore
import com.mawena.fluluks.vaults.Vaults
import com.mawena.fluluks.volumes.VolumeManager
import com.mawena.fluluks.volumes.VolumeState
import java.io.File
import java.io.FileNotFoundException
import java.io.RandomAccessFile
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Coffres (phase 14, T9) : création (place écrite, formatage, renommage à la fin), ouverture sur le téléphone
 * (descripteur) ou sur le volume d'un disque (fichier du moteur), fermeture en cascade, fichier protégé. Le faux
 * moteur garde un « en-tête LUKS » (magie, empreinte du mot de passe, système de fichiers) au début du fichier.
 */
class VaultsTest {
    @get:Rule val tmp = TemporaryFolder()

    private class Engine : MemEngine() {
        sealed class Back {
            class Local(val file: File) : Back()
            class Eng(val handle: Long, val path: String) : Back()
        }
        class VDisk(val back: Back, val ro: Boolean)

        val fds = HashMap<Int, File>()
        private var nextFd = 300
        private var nextH = 5000L
        val vdisks = HashMap<Long, VDisk>()
        val vaultVols = HashMap<Long, String>()
        val unmounted = ArrayList<Long>()
        val failSync = HashSet<Long>()
        var viaFd = 0
        var viaFile = 0
        var vaultRo = false
        var vaultRoReason = ""
        var onFormat: () -> Unit = {}
        var formats = 0

        fun openFd(f: File, @Suppress("UNUSED_PARAMETER") w: Boolean): Int {
            val fd = nextFd++
            fds[fd] = f
            return fd
        }

        fun header(pass: String, fs: String): ByteArray =
            MAGIC + ("\n" + JSONObject().put("pw", tag(pass.toByteArray())).put("fs", fs) + "\n").toByteArray()

        private fun bytes(b: Back) = when (b) {
            is Back.Local -> b.file.readBytes()
            is Back.Eng -> nodes[b.path] ?: ByteArray(0)
        }

        private fun hdr(b: Back): JSONObject? {
            val d = bytes(b)
            if (d.size < 8 || !d.copyOf(6).contentEquals(MAGIC)) return null
            val t = String(d, 7, minOf(d.size - 7, 512), Charsets.UTF_8)
            return JSONObject(t.substringBefore('\n'))
        }

        override fun openDiskFd(fd: Int, readOnly: Boolean): Long {
            viaFd++
            val f = fds.remove(fd) ?: return EngineError.FL_EINVAL.toLong()
            vdisks[nextH] = VDisk(Back.Local(f), readOnly)
            return nextH++
        }

        override fun openDiskOnFile(file: Long, size: Long): Long {
            viaFile++
            val p = files[file] ?: return EngineError.FL_EINVAL.toLong()
            vdisks[nextH] = VDisk(Back.Eng(file, p), false)
            return nextH++
        }

        override fun closeDisk(disk: Long): Int {
            val d = vdisks.remove(disk) ?: return super.closeDisk(disk)
            (d.back as? Back.Eng)?.let { closeFile(it.handle) }
            return 0
        }

        override fun scan(disk: Long): ByteArray {
            val d = vdisks[disk] ?: return super.scan(disk)
            val size = bytes(d.back).size
            val part = if (hdr(d.back) != null) {
                """{"index":0,"first_lba":0,"size":$size,"content":"LUKS2","label":"","uuid":"","supported":true,
                    "luks":{"version":2,"cipher":"aes-xts-plain64","primary_damaged":false,"max_kdf_memory_kib":1024}}"""
            } else {
                """{"index":0,"first_lba":0,"size":$size,"content":"inconnu","label":"","uuid":"","supported":false}"""
            }
            return """{"sector_size":512,"size":$size,"table":"none","parts":[$part]}""".toByteArray()
        }

        override fun format(disk: Long, opts: ByteArray, pass: ByteArray?, progress: FormatProgress?): Int {
            val d = vdisks[disk] ?: return EngineError.FL_ENOTSUP
            val o = JSONObject(String(opts, Charsets.UTF_8))
            check(o.getString("table") == "none" && o.getBoolean("encrypted"))
            formats++
            progress?.onProgress(0)
            onFormat()
            val h = header(String(pass!!, Charsets.UTF_8), if (o.getString("fs") == "ext4") "ext4" else "exFAT")
            when (val b = d.back) {
                is Back.Local -> RandomAccessFile(b.file, "rw").use { it.seek(0); it.write(h) }
                is Back.Eng -> nodes[b.path] = h + nodes[b.path]!!.copyOfRange(minOf(h.size, nodes[b.path]!!.size), nodes[b.path]!!.size)
            }
            pass.fill(0)
            progress?.onProgress(100)
            return 0
        }

        override fun mount(disk: Long, partIndex: Int, pass: ByteArray?, writable: Boolean): Long {
            val d = vdisks[disk] ?: return super.mount(disk, partIndex, pass, writable)
            val h = hdr(d.back) ?: return EngineError.FL_ENOTSUP.toLong()
            if (pass == null || tag(pass) != h.getString("pw")) return EngineError.FL_EBADPASS.toLong()
            val v = nextH++
            vaultVols[v] = h.getString("fs")
            return v
        }

        override fun statfs(vol: Long): ByteArray {
            val fs = vaultVols[vol] ?: return super.statfs(vol)
            return """{"total":1000000,"free":500000,"label":"","read_only":$vaultRo,"ro_reason":"$vaultRoReason","needs_recovery":false,"fs":"$fs"}"""
                .toByteArray()
        }

        override fun unmount(vol: Long, force: Boolean): Int {
            unmounted.add(vol)
            vaultVols.remove(vol)
            return 0
        }

        override fun sync(vol: Long) = if (vol in failSync) EngineError.FL_EIO else 0

        companion object {
            val MAGIC = byteArrayOf(0x4c, 0x55, 0x4b, 0x53, 0xba.toByte(), 0xbe.toByte())
        }
    }

    private lateinit var e: Engine
    private lateinit var phoneRoot: File
    private lateinit var sdRoot: File
    private lateinit var phone: LocalSource
    private lateinit var sd: LocalSource
    private lateinit var hostDisk: String
    private lateinit var hostVol: String
    private var sdPresent = true
    private val warnings = ArrayList<String>()
    private val pw = "mot de passe du coffre"

    private fun sources(): List<FileSource> = buildList {
        add(phone)
        if (sdPresent) add(sd)
        for (v in VolumeManager.volumes.value) add(DiskSource(v.id, e))
    }

    @Before fun setup() {
        e = Engine()
        phoneRoot = tmp.newFolder("telephone")
        sdRoot = tmp.newFolder("carte")
        phone = LocalSource("phone", "phone", "Téléphone", phoneRoot) { true }
        sd = LocalSource("sd:1", "sd:1", "Carte SD", sdRoot) { true }
        sdPresent = true
        warnings.clear()
        VolumeManager.resetForTests(e, delayer = FakeDelayer(), detachWarner = { warnings.add(it) })
        hostDisk = VolumeManager.addImageDiskForTests("/x/mem.img", readOnly = false)
        hostVol = runBlocking { VolumeManager.mountPlain(hostDisk, 1, true) }.id
        Transfers.resetForTests()
        Archives.resetForTests(e, e::openFd, null)
        Vaults.resetForTests(VaultStore(tmp.newFolder("donnees")), ::sources, e::openFd)
        Files.setResolverForTests { id -> sources().firstOrNull { it.id == id } }
    }

    @After fun teardown() {
        Transfers.resetForTests()
        Archives.resetForTests(null, null, null)
        Vaults.resetForTests(null, null, null)
        Files.setResolverForTests(null)
    }

    private fun fakeVault(root: File, name: String, pass: String = pw) =
        File(root, name).apply { writeBytes(e.header(pass, "exFAT") + ByteArray(4096)) }

    private fun open(srcId: String, path: String, pass: String = pw): VolumeState =
        runBlocking { Vaults.open(null, srcId, path, pass.toByteArray(), writable = true) }

    private fun refused(msg: String, block: () -> Unit) {
        try {
            block()
            fail("accepté : $msg")
        } catch (x: Exception) {
            assertEquals(msg, x.message)
        }
    }

    @Test fun createWritesZerosThenFormats() {
        val states = ArrayList<TransferState>()
        var partialSeen = false
        e.onFormat = {
            partialSeen = File(phoneRoot, Transfers.partialName("Photos.luks")).exists() && !File(phoneRoot, "Photos.luks").exists()
            states.add(Transfers.state.value!!)
        }
        val info = runBlocking { Vaults.create("phone", "/", "Photos", Vaults.MIN_SIZE, "exfat", pw.toByteArray()) }
        assertTrue("le partiel existe pendant le formatage, pas le nom final", partialSeen)
        assertEquals(Vaults.MIN_SIZE * 8 / 10, states.single().doneBytes) // place écrite : 80 %
        val f = File(phoneRoot, "Photos.luks")
        assertEquals(Vaults.MIN_SIZE, f.length())
        assertFalse(File(phoneRoot, Transfers.partialName("Photos.luks")).exists())
        assertEquals(1, e.formats)
        assertEquals(listOf("Photos"), Vaults.list().map { it.name })
        assertEquals("closed", info.state)
        assertEquals("/Photos.luks", info.path)
        val end = Transfers.state.value!!
        assertTrue(end.finished && end.error == null && end.kind == "vault")
        assertEquals(Vaults.MIN_SIZE, end.doneBytes)
        // il s'ouvre ensuite avec son mot de passe
        val v = runBlocking { Vaults.open(info.id, null, null, pw.toByteArray(), writable = true) }
        assertEquals(info.id, v.vaultId)
    }

    @Test fun createCancelRemovesPartial() {
        e.onFormat = { Transfers.cancel() }
        refused(Vaults.MSG_CANCELLED) {
            runBlocking { Vaults.create("phone", "/", "Photos", Vaults.MIN_SIZE, "exfat", pw.toByteArray()) }
        }
        assertTrue(phoneRoot.list()!!.isEmpty()) // ni partiel ni coffre
        assertTrue(Vaults.list().isEmpty())
        assertTrue(Transfers.state.value!!.cancelled)
    }

    @Test fun createChecksSizeBounds() {
        refused(Vaults.MSG_TOO_SMALL) {
            runBlocking { Vaults.create("phone", "/", "A", Vaults.MIN_SIZE - 1, "exfat", pw.toByteArray()) }
        }
        refused(Vaults.MSG_TOO_BIG) {
            runBlocking { Vaults.create("phone", "/", "A", Long.MAX_VALUE / 4, "exfat", pw.toByteArray()) }
        }
        // stockage FAT32 : 4 Gio − 1 octet au plus
        e.fs = "FAT32"
        e.free = 10L shl 30
        e.total = 20L shl 30
        VolumeManager.eject(hostVol) // remonté : le système de fichiers est relu
        hostVol = runBlocking { VolumeManager.mountPlain(hostDisk, 1, true) }.id
        refused(Vaults.MSG_FAT_LIMIT) {
            runBlocking { Vaults.create(hostVol, "/", "A", 4L shl 30, "exfat", pw.toByteArray()) }
        }
        refused(Vaults.MSG_FS) {
            runBlocking { Vaults.create("phone", "/", "A", Vaults.MIN_SIZE, "ntfs", pw.toByteArray()) }
        }
        assertTrue(phoneRoot.list()!!.isEmpty())
    }

    @Test fun createRefusedOnRemote() {
        val remote = object : FileSource by phone {
            override val id = "remote"
        }
        Files.setResolverForTests { id -> if (id == "remote") remote else sources().firstOrNull { it.id == id } }
        refused(Vaults.MSG_REMOTE) {
            runBlocking { Vaults.create("remote", "/", "A", Vaults.MIN_SIZE, "exfat", pw.toByteArray()) }
        }
        fakeVault(phoneRoot, "C.luks")
        refused(Vaults.MSG_REMOTE) { open("remote", "/C.luks") }
    }

    @Test fun createRefusedInsideVault() {
        fakeVault(phoneRoot, "C.luks")
        val v = open("phone", "/C.luks")
        refused(Vaults.MSG_IN_VAULT) {
            runBlocking { Vaults.create(v.id, "/", "Dedans", Vaults.MIN_SIZE, "exfat", pw.toByteArray()) }
        }
    }

    @Test fun openOnPhoneUsesFd() {
        fakeVault(phoneRoot, "C.luks")
        val v = open("phone", "/C.luks")
        assertEquals(1, e.viaFd)
        assertEquals(0, e.viaFile)
        assertTrue(v.encrypted)
        assertEquals("C", v.title)
        assertEquals(listOf("C"), Vaults.list().map { it.name }) // enregistré à sa première ouverture
        assertEquals("open", Vaults.list().single().state)
    }

    @Test fun openOnDiskUsesEngineFile() {
        e.nodes["/D.luks"] = e.header(pw, "ext4") + ByteArray(4096)
        val v = open(hostVol, "/D.luks")
        assertEquals(0, e.viaFd)
        assertEquals(1, e.viaFile)
        assertEquals("ext4", v.fs)
    }

    @Test fun vaultVolumeIsEncryptedAndListed() {
        fakeVault(phoneRoot, "C.luks")
        val v = open("phone", "/C.luks")
        val listed = VolumeManager.volumes.value.single { it.id == v.id }
        assertTrue(listed.encrypted)
        assertNotNull(listed.vaultId)
        assertEquals("vault", Sources.kind(DiskSource(v.id, e)))
        assertEquals(v.id, Vaults.list().single().volumeId)
    }

    @Test fun vaultNotInDisksList() {
        fakeVault(phoneRoot, "C.luks")
        open("phone", "/C.luks")
        assertEquals(listOf(hostDisk), VolumeManager.disks.value.map { it.id })
    }

    @Test fun ejectHostClosesVaultFirst() {
        e.nodes["/D.luks"] = e.header(pw, "exFAT") + ByteArray(4096)
        val v = open(hostVol, "/D.luks")
        val vaultHandle = VolumeManager.nativeVolume(v.id)
        val hostHandle = VolumeManager.nativeVolume(hostVol)
        VolumeManager.eject(hostVol)
        assertEquals(listOf(vaultHandle, hostHandle), e.unmounted) // le coffre d'abord
        assertTrue(VolumeManager.volumes.value.isEmpty())
        assertTrue(e.vdisks.isEmpty()) // disque du coffre fermé (avec son fichier)
        assertEquals("unavailable", Vaults.list().single().state)

        // le coffre refuse de se fermer : l'hôte reste ouvert, avec le message
        hostVol = runBlocking { VolumeManager.mountPlain(hostDisk, 1, true) }.id
        val w = runBlocking { Vaults.open(Vaults.list().single().id, null, null, pw.toByteArray(), writable = true) }
        e.failSync.add(VolumeManager.nativeVolume(w.id))
        VolumeManager.eject(hostVol)
        assertNotNull(VolumeManager.volume(hostVol))
        assertNotNull(VolumeManager.volume(w.id))
        assertEquals(VolumeManager.msgEjectFailed(VolumeManager.msgVaultOpen("D")), VolumeManager.ejectError.value)
    }

    @Test fun detachHostForceClosesVault() {
        e.nodes["/D.luks"] = e.header(pw, "exFAT") + ByteArray(4096)
        val v = open(hostVol, "/D.luks")
        VolumeManager.removeDiskForTests(hostDisk)
        assertNull(VolumeManager.volume(v.id))
        assertTrue(VolumeManager.volumes.value.isEmpty())
        assertTrue(e.vdisks.isEmpty())
        assertEquals(listOf(VolumeManager.MSG_VAULT_DETACHED), warnings)
    }

    @Test fun sdCardRemovedClosesVault() {
        fakeVault(sdRoot, "S.luks")
        val v = open("sd:1", "/S.luks")
        Vaults.checkSources()
        assertNotNull(VolumeManager.volume(v.id)) // carte toujours là
        sdPresent = false
        Vaults.checkSources()
        assertNull(VolumeManager.volume(v.id))
        assertEquals(listOf(VolumeManager.MSG_VAULT_REMOVED), warnings)
        assertEquals("unavailable", Vaults.list().single().state)
    }

    @Test fun autoLockClosesVault() {
        fakeVault(phoneRoot, "C.luks")
        val v = open("phone", "/C.luks")
        var locked = false
        VolumeManager.autoLock(v.id, VolumeManager.lastActivity(v.id)!!, { false }) { locked = true }
        assertTrue(locked)
        assertNull(VolumeManager.volume(v.id))
        assertTrue(e.vdisks.isEmpty())
    }

    @Test fun vaultActivityKeepsHostActive() {
        var now = 0L
        VolumeManager.resetForTests(e, delayer = FakeDelayer(), clock = { now })
        hostDisk = VolumeManager.addImageDiskForTests("/x/mem.img", readOnly = false)
        hostVol = runBlocking { VolumeManager.mountPlain(hostDisk, 1, true) }.id
        e.nodes["/D.luks"] = e.header(pw, "exFAT") + ByteArray(4096)
        val v = open(hostVol, "/D.luks")
        now = 60_000
        VolumeManager.noteActivity(v.id)
        assertEquals(60_000L, VolumeManager.lastActivity(hostVol))
    }

    @Test fun openVaultFileProtected() {
        fakeVault(phoneRoot, "C.luks")
        File(phoneRoot, "dossier").mkdir()
        fakeVault(File(phoneRoot, "dossier"), "D.luks")
        open("phone", "/C.luks")
        open("phone", "/dossier/D.luks")
        refused(Vaults.MSG_OPEN) { phone.delete("/C.luks") }
        refused(Vaults.MSG_OPEN) { phone.rename("/C.luks", "X.luks") }
        refused(Vaults.MSG_OPEN) { phone.move("/C.luks", "/dossier") }
        refused(Vaults.MSG_OPEN) { phone.openOverwrite("/C.luks").close() }
        refused(Vaults.MSG_OPEN) { phone.delete("/dossier") } // le dossier qui le contient aussi
        assertTrue(Crypt.isOpenVaultFile("phone", "/C.luks"))
        assertFalse(Crypt.isOpenVaultFile("phone", "/autre.txt"))
        File(phoneRoot, "copie").mkdir()
        Transfers.start("phone", listOf("/C.luks"), "phone", "/copie", move = false)
        val end = await()
        assertEquals(Vaults.MSG_OPEN, end.error)
        assertTrue(File(phoneRoot, "copie").list()!!.isEmpty())
        // fermé : tout redevient possible
        Vaults.close(Vaults.list().first { it.name == "C" }.id)
        phone.rename("/C.luks", "X.luks")

        // sur un disque, même règle
        e.nodes["/E.luks"] = e.header(pw, "exFAT") + ByteArray(4096)
        open(hostVol, "/E.luks")
        refused(Vaults.MSG_OPEN) { DiskSource(hostVol, e).delete("/E.luks") }
    }

    private fun await(): TransferState {
        val end = System.currentTimeMillis() + 10_000
        while (true) {
            val s = Transfers.state.value
            if (s != null && s.finished && !Transfers.isBusy("phone")) return s
            check(System.currentTimeMillis() < end) { "délai dépassé : $s" }
            Thread.sleep(10)
        }
    }

    @Test fun maxVolumesCountsVaults() {
        // l'hôte + 7 coffres = 8 volumes ; le 9e est refusé
        for (i in 1..7) {
            fakeVault(phoneRoot, "C$i.luks")
            open("phone", "/C$i.luks")
        }
        fakeVault(phoneRoot, "C8.luks")
        refused(VolumeManager.MSG_TOO_MANY) { open("phone", "/C8.luks") }
        assertEquals(8, VolumeManager.volumes.value.size)
        assertEquals(7, e.vdisks.size) // le 8e disque n'a pas été ouvert
    }

    @Test fun notALuksFileRefused() {
        File(phoneRoot, "faux.luks").writeBytes(ByteArray(8192) { 7 })
        refused(VolumeManager.MSG_NOT_VAULT) { open("phone", "/faux.luks") }
        assertTrue(VolumeManager.volumes.value.none { it.vaultId != null })
        assertTrue(e.vdisks.isEmpty())
        assertTrue(Vaults.list().isEmpty()) // pas enregistré
    }

    @Test fun wrongPasswordLeavesNothing() {
        fakeVault(phoneRoot, "C.luks")
        val pass = "mauvais".toByteArray()
        try {
            runBlocking { Vaults.open(null, "phone", "/C.luks", pass, writable = true) }
            fail("ouvert")
        } catch (x: FilesException) {
            assertEquals(EngineError.FL_EBADPASS, x.code)
        }
        assertTrue(pass.all { it == 0.toByte() })
        assertTrue(e.vdisks.isEmpty())
        assertTrue(Vaults.list().isEmpty())
    }

    @Test fun dirtyExfatOpensReadOnlyWithAdvice() {
        e.vaultRo = true
        e.vaultRoReason = "système de fichiers à vérifier"
        fakeVault(phoneRoot, "C.luks")
        val v = open("phone", "/C.luks")
        assertTrue(v.readOnly)
        assertEquals("système de fichiers à vérifier ; vérifiez-le sous Linux : cryptsetup open, puis fsck.exfat", v.roReason)
    }

    @Test fun forgetKeepsTheFile() {
        fakeVault(phoneRoot, "C.luks")
        open("phone", "/C.luks")
        Vaults.forget(Vaults.list().single().id)
        assertTrue(Vaults.list().isEmpty())
        assertTrue(VolumeManager.volumes.value.none { it.vaultId != null })
        assertTrue(File(phoneRoot, "C.luks").exists())
    }

    @Test fun openErrorsAreFrench() {
        refused(Vaults.MSG_UNKNOWN) { runBlocking { Vaults.open("inconnu", null, null, pw.toByteArray(), true) } }
        try {
            open("phone", "/absent.luks")
            fail("ouvert")
        } catch (x: FileNotFoundException) {
            fail("exception brute : $x")
        } catch (x: FilesException) {
            assertEquals(EngineError.FL_ENOENT, x.code)
        }
    }
}
