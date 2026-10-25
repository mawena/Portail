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
import com.mawena.fluluks.vaults.BiometricBox
import com.mawena.fluluks.vaults.BiometricCancelled
import com.mawena.fluluks.vaults.BiometricInvalidated
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

        /** En-tête du faux coffre : version LUKS, empreinte de la phrase de chaque emplacement, système de fichiers. */
        fun header(pass: String, fs: String, version: Int = 2, others: Map<Int, String> = emptyMap()): ByteArray {
            val slots = JSONObject().put("0", tag(pass.toByteArray()))
            others.forEach { (k, v) -> slots.put(k.toString(), tag(v.toByteArray())) }
            return headerOf(JSONObject().put("v", version).put("slots", slots).put("fs", fs))
        }

        private fun headerOf(o: JSONObject) = MAGIC + ("\n" + o + "\n").toByteArray()

        /** Disques dont un volume est monté (emplacements intouchables, comme le moteur : FL_EBUSY). */
        private val mountedDisks = HashMap<Long, Long>()
        var lastKdfKib = 0
        var lastKdfTime = 0
        /** Phrases posées par luksSlotSet (copies), pour vérifier ce qui entre dans un emplacement. */
        val setPasses = HashMap<Int, ByteArray>()

        fun slotsOf(f: File): Map<Int, String> {
            val o = hdrOf(f.readBytes())!!.getJSONObject("slots")
            return o.keys().asSequence().associate { it.toInt() to o.getString(it) }
        }

        fun tagOf(pass: String) = tag(pass.toByteArray())

        private fun hdrOf(d: ByteArray): JSONObject? {
            if (d.size < 8 || !d.copyOf(6).contentEquals(MAGIC)) return null
            val t = String(d, 7, minOf(d.size - 7, 1024), Charsets.UTF_8)
            return JSONObject(t.substringBefore('\n'))
        }

        private fun writeHdr(b: Back, o: JSONObject) {
            val h = headerOf(o)
            when (b) {
                is Back.Local -> RandomAccessFile(b.file, "rw").use { it.seek(0); it.write(h) }
                is Back.Eng -> nodes[b.path] = h + nodes[b.path]!!.copyOfRange(minOf(h.size, nodes[b.path]!!.size), nodes[b.path]!!.size)
            }
        }

        private fun opens(h: JSONObject, pass: ByteArray, slot: Int = -1): Boolean {
            val slots = h.getJSONObject("slots")
            return slots.keys().asSequence().any { (slot < 0 || it == slot.toString()) && slots.getString(it) == tag(pass) }
        }

        private fun bytes(b: Back) = when (b) {
            is Back.Local -> b.file.readBytes()
            is Back.Eng -> nodes[b.path] ?: ByteArray(0)
        }

        private fun hdr(b: Back): JSONObject? = hdrOf(bytes(b))

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
                    "luks":{"version":${hdr(d.back)!!.optInt("v", 2)},"cipher":"aes-xts-plain64","primary_damaged":false,"max_kdf_memory_kib":1024}}"""
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
            return mountAt(disk, d, pass, -1)
        }

        override fun mountSlot(disk: Long, partIndex: Int, slot: Int, pass: ByteArray, writable: Boolean): Long {
            val d = vdisks[disk] ?: return EngineError.FL_ENOTSUP.toLong()
            val h = hdr(d.back) ?: return EngineError.FL_ENOTSUP.toLong()
            if (!h.getJSONObject("slots").has(slot.toString())) return EngineError.FL_ENOENT.toLong()
            return mountAt(disk, d, pass, slot)
        }

        val mountSlots = ArrayList<Int>()

        private fun mountAt(disk: Long, d: VDisk, pass: ByteArray?, slot: Int): Long {
            val h = hdr(d.back) ?: return EngineError.FL_ENOTSUP.toLong()
            if (pass == null || !opens(h, pass, slot)) return EngineError.FL_EBADPASS.toLong()
            mountSlots.add(slot)
            val v = nextH++
            vaultVols[v] = h.getString("fs")
            mountedDisks[v] = disk
            return v
        }

        override fun luksSlots(disk: Long): ByteArray {
            val d = vdisks[disk] ?: return super.luksSlots(disk)
            val h = hdr(d.back) ?: return """{"err":${EngineError.FL_ENOTSUP}}""".toByteArray()
            val slots = h.getJSONObject("slots").keys().asSequence().map { it.toInt() }.sorted().toList()
            return JSONObject().put("version", h.optInt("v", 2)).put("slots", org.json.JSONArray(slots)).toString().toByteArray()
        }

        /** Comme le moteur natif (take_pass) : les tableaux de phrases sont mis à zéro par l'appel. */
        override fun luksSlotSet(disk: Long, slot: Int, auth: ByteArray, new: ByteArray, kdfMemKib: Int, kdfTime: Int): Int =
            try {
                slotSet(disk, slot, auth, new, kdfMemKib, kdfTime)
            } finally {
                auth.fill(0)
                new.fill(0)
            }

        override fun luksSlotRemove(disk: Long, slot: Int, auth: ByteArray): Int =
            try {
                slotRemove(disk, slot, auth)
            } finally {
                auth.fill(0)
            }

        private fun slotSet(disk: Long, slot: Int, auth: ByteArray, new: ByteArray, kdfMemKib: Int, kdfTime: Int): Int {
            val d = vdisks[disk] ?: return EngineError.FL_ENOTSUP
            val h = hdr(d.back) ?: return EngineError.FL_ENOTSUP
            if (h.optInt("v", 2) != 2) return EngineError.FL_ENOTSUP
            if (disk in mountedDisks.values) return EngineError.FL_EBUSY
            if (!opens(h, auth)) return EngineError.FL_EBADPASS
            lastKdfKib = kdfMemKib
            lastKdfTime = kdfTime
            setPasses[slot] = new.copyOf()
            h.getJSONObject("slots").put(slot.toString(), tag(new))
            writeHdr(d.back, h)
            return 0
        }

        private fun slotRemove(disk: Long, slot: Int, auth: ByteArray): Int {
            val d = vdisks[disk] ?: return EngineError.FL_ENOTSUP
            val h = hdr(d.back) ?: return EngineError.FL_ENOTSUP
            if (h.optInt("v", 2) != 2) return EngineError.FL_ENOTSUP
            if (disk in mountedDisks.values) return EngineError.FL_EBUSY
            val slots = h.getJSONObject("slots")
            if (!slots.has(slot.toString())) return EngineError.FL_ENOENT
            if (!opens(h, auth)) return EngineError.FL_EBADPASS
            if (slots.length() == 1) return EngineError.FL_EBUSY
            slots.remove(slot.toString())
            writeHdr(d.back, h)
            return 0
        }

        override fun statfs(vol: Long): ByteArray {
            val fs = vaultVols[vol] ?: return super.statfs(vol)
            return """{"total":1000000,"free":500000,"label":"","read_only":$vaultRo,"ro_reason":"$vaultRoReason","needs_recovery":false,"fs":"$fs"}"""
                .toByteArray()
        }

        override fun unmount(vol: Long, force: Boolean): Int {
            unmounted.add(vol)
            vaultVols.remove(vol)
            mountedDisks.remove(vol)
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
    private val bioKeys = SoftBioKeys()
    private val bioPrompt = FakeBioPrompt()
    private lateinit var bioDir: File

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
        bioDir = tmp.newFolder("bio")
        Vaults.setBiometricForTests(BiometricBox(bioDir, bioKeys, bioPrompt))
        Files.setResolverForTests { id -> sources().firstOrNull { it.id == id } }
    }

    @After fun teardown() {
        Transfers.resetForTests()
        Archives.resetForTests(null, null, null)
        Vaults.resetForTests(null, null, null)
        Vaults.setBiometricForTests(null)
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

    @Test fun ejectAllClosesVaultsBeforeHosts() {
        // « Tout éjecter » reçoit l'hôte avant le coffre (ordre d'ouverture) : le coffre doit partir d'abord
        e.nodes["/D.luks"] = e.header(pw, "exFAT") + ByteArray(4096)
        val v = open(hostVol, "/D.luks")
        val vaultHandle = VolumeManager.nativeVolume(v.id)
        val hostHandle = VolumeManager.nativeVolume(hostVol)
        VolumeManager.ejectAll()
        assertEquals(listOf(vaultHandle, hostHandle), e.unmounted)
        assertTrue(VolumeManager.volumes.value.isEmpty())
        assertNull(VolumeManager.ejectError.value)
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

    // --- T11 : mot de passe et clé de secours -----------------------------------------------------------------

    private fun known(): String = Vaults.list().single().id

    /** Coffre « C.luks » du téléphone, connu (ouvert une fois) puis fermé. */
    private fun knownClosed(file: File = fakeVault(phoneRoot, "C.luks")): String {
        open("phone", "/${file.name}")
        val id = Vaults.list().single { it.path == "/${file.name}" }.id
        Vaults.close(id)
        return id
    }

    private fun opensWith(id: String, pass: String, recovery: Boolean = false): Boolean = try {
        runBlocking { Vaults.open(id, null, null, pass.toByteArray(), writable = true, recovery = recovery) }
        Vaults.close(id)
        true
    } catch (x: FilesException) {
        assertEquals(Crypt.MSG_BAD_PASSWORD, x.message)
        false
    }

    @Test fun changePasswordRequiresClosedVault() {
        fakeVault(phoneRoot, "C.luks")
        open("phone", "/C.luks")
        refused(Vaults.MSG_OPEN) {
            runBlocking { Vaults.changePassword(known(), pw.toByteArray(), "nouveau mot de passe".toByteArray()) }
        }
        refused(Vaults.MSG_OPEN) { runBlocking { Vaults.addRecoveryKey(known(), pw.toByteArray()) } }
    }

    @Test fun changePasswordKeepsSlot0() {
        val f = fakeVault(phoneRoot, "C.luks")
        val id = knownClosed(f)
        val old = pw.toByteArray()
        val nw = "nouveau mot de passe".toByteArray()
        runBlocking { Vaults.changePassword(id, old, nw) }
        assertTrue("mots de passe mis à zéro", old.all { it == 0.toByte() } && nw.all { it == 0.toByte() })
        assertEquals(setOf(0), e.slotsOf(f).keys)
        assertEquals(e.tagOf("nouveau mot de passe"), e.slotsOf(f)[0])
        assertEquals(1 shl 20, e.lastKdfKib) // même Argon2 que la création : 1 Gio
        assertFalse(opensWith(id, pw))
        assertTrue(opensWith(id, "nouveau mot de passe"))
        refused(Crypt.MSG_BAD_PASSWORD) {
            runBlocking { Vaults.changePassword(id, "faux mot de passe".toByteArray(), "autre chose".toByteArray()) }
        }
    }

    @Test fun recoveryKeyFormat() {
        val crockford = Regex("^[0-9ABCDEFGHJKMNPQRSTVWXYZ]{4}(-[0-9ABCDEFGHJKMNPQRSTVWXYZ]{4}){5}$")
        val keys = (1..50).map { String(Vaults.newRecoveryKey(), Charsets.US_ASCII) }
        keys.forEach { assertTrue(it, crockford.matches(it)) }
        assertEquals(50, keys.toSet().size)
        // saisie : tirets, espaces et casse ignorés, O lu 0, I et L lus 1 (Crockford)
        val k = "ABCD-EFGH-JKMN-PQRS-TVWX-YZ01"
        assertEquals(k, String(Vaults.normalizeRecoveryKey(" abcd efgh jkmn-pqrs tvwx yzoi ".toByteArray())!!, Charsets.US_ASCII))
        assertEquals(k, String(Vaults.normalizeRecoveryKey("ABCDEFGHJKMNPQRSTVWXYZOL".toByteArray())!!, Charsets.US_ASCII))
        assertNull(Vaults.normalizeRecoveryKey("ABCD-EFGH".toByteArray())) // trop courte
        assertNull(Vaults.normalizeRecoveryKey("ABCD-EFGH-JKMN-PQRS-TVWX-YZ0U".toByteArray())) // U absent de l'alphabet
    }

    @Test fun recoveryKeyOpensVault() {
        val f = fakeVault(phoneRoot, "C.luks")
        val id = knownClosed(f)
        val key = String(runBlocking { Vaults.addRecoveryKey(id, pw.toByteArray()) }, Charsets.US_ASCII)
        assertEquals(setOf(0, 1), e.slotsOf(f).keys) // emplacement 1 : clé de secours
        assertTrue(Vaults.get(id)!!.hasRecovery)
        val typed = key.lowercase().replace("-", " ")
        assertTrue(opensWith(id, typed, recovery = true))
        assertEquals(1, e.mountSlots.last()) // seul l'emplacement de la clé est essayé
        assertTrue(opensWith(id, pw)) // le mot de passe ouvre toujours
        assertFalse(opensWith(id, "ABCD-EFGH-JKMN-PQRS-TVWX-YZ01", recovery = true))
    }

    @Test fun recoveryKeyShownOnce() {
        val id = knownClosed()
        val key = String(runBlocking { Vaults.addRecoveryKey(id, pw.toByteArray()) }, Charsets.US_ASCII)
        // nulle part sur le téléphone : ni dans la liste des coffres, ni ailleurs dans les données
        val data = File(tmp.root, "donnees")
        data.walk().filter { it.isFile }.forEach { assertFalse(it.readText().contains(key)) }
        // une nouvelle clé remplace l'ancienne (même emplacement)
        val key2 = String(runBlocking { Vaults.addRecoveryKey(id, pw.toByteArray()) }, Charsets.US_ASCII)
        assertTrue(key != key2)
        assertFalse(opensWith(id, key, recovery = true))
        assertTrue(opensWith(id, key2, recovery = true))
    }

    @Test fun removeRecoveryKeepsPassword() {
        val f = fakeVault(phoneRoot, "C.luks")
        val id = knownClosed(f)
        val key = String(runBlocking { Vaults.addRecoveryKey(id, pw.toByteArray()) }, Charsets.US_ASCII)
        runBlocking { Vaults.removeRecoveryKey(id, pw.toByteArray()) }
        assertEquals(setOf(0), e.slotsOf(f).keys)
        assertFalse(Vaults.get(id)!!.hasRecovery)
        assertFalse(opensWith(id, key, recovery = true))
        assertTrue(opensWith(id, pw))
        refused(Vaults.MSG_NO_RECOVERY) { runBlocking { Vaults.removeRecoveryKey(id, pw.toByteArray()) } }
    }

    @Test fun luks1VaultOffersNothing() {
        val f = File(phoneRoot, "L.luks").apply { writeBytes(e.header(pw, "ext4", version = 1) + ByteArray(4096)) }
        val id = knownClosed(f)
        assertEquals(1, Vaults.get(id)!!.luksVersion)
        val before = f.readBytes()
        refused(Vaults.MSG_LUKS1) { runBlocking { Vaults.changePassword(id, pw.toByteArray(), "nouveau mot de passe".toByteArray()) } }
        refused(Vaults.MSG_LUKS1) { runBlocking { Vaults.addRecoveryKey(id, pw.toByteArray()) } }
        assertTrue(before.contentEquals(f.readBytes()))
    }

    @Test fun foreignSlotsKept() {
        // conteneur créé sous Linux : emplacements 1 et 5 à d'autres phrases, inconnus de Portail
        val f = File(phoneRoot, "Linux.luks").apply {
            writeBytes(e.header(pw, "ext4", others = mapOf(1 to "phrase de Paul", 5 to "phrase de Jeanne")) + ByteArray(4096))
        }
        val id = knownClosed(f)
        val foreign = e.slotsOf(f).filterKeys { it == 1 || it == 5 }
        val key = String(runBlocking { Vaults.addRecoveryKey(id, pw.toByteArray()) }, Charsets.US_ASCII)
        assertEquals(setOf(0, 1, 3, 5), e.slotsOf(f).keys) // ni 1 (pris), ni 2 (biométrie) : 3
        runBlocking { Vaults.changePassword(id, pw.toByteArray(), "nouveau mot de passe".toByteArray()) }
        runBlocking { Vaults.removeRecoveryKey(id, "nouveau mot de passe".toByteArray()) }
        assertEquals(foreign, e.slotsOf(f).filterKeys { it == 1 || it == 5 }) // intacts
        assertEquals(setOf(0, 1, 5), e.slotsOf(f).keys)
        assertFalse(opensWith(id, key, recovery = true))
    }

    // --- T12 : déverrouillage biométrique ---------------------------------------------------------------------

    private fun openBio(id: String) = runBlocking { Vaults.openBiometric(id, writable = true) }

    @Test fun enableAddsSlot2AndSealsSecret() {
        val f = fakeVault(phoneRoot, "C.luks")
        val id = knownClosed(f)
        val p = pw.toByteArray()
        runBlocking { Vaults.enableBiometric(id, p) }
        assertTrue(p.all { it == 0.toByte() })
        assertEquals(setOf(0, 2), e.slotsOf(f).keys) // emplacement 2 : biométrie
        assertEquals(64 * 1024, e.lastKdfKib) // Argon2 de 64 Mio, une passe
        assertEquals(1, e.lastKdfTime)
        assertTrue(File(bioDir, "$id.bio").exists())
        assertTrue(Vaults.get(id)!!.biometric)
        assertEquals(listOf(BiometricBox.enableTitle("C")), bioPrompt.titles) // la clé sert dès le scellement
        val v = openBio(id)
        assertEquals("Ouvrir le coffre C", bioPrompt.titles.last())
        assertEquals(id, v.vaultId)
        assertEquals(2, e.mountSlots.last()) // seul l'emplacement biométrique est essayé
        Vaults.close(id)
        assertTrue(opensWith(id, pw)) // le mot de passe ouvre toujours
    }

    @Test fun secretNeverEqualsPassword() {
        val f = fakeVault(phoneRoot, "C.luks")
        val id = knownClosed(f)
        runBlocking { Vaults.enableBiometric(id, pw.toByteArray()) }
        val secret = e.setPasses[2]!!
        assertEquals(32, secret.size)
        assertFalse(secret.contentEquals(pw.toByteArray().copyOf(32)))
        assertTrue(e.slotsOf(f)[2] != e.slotsOf(f)[0])
        // un second coffre a un autre secret
        val g = fakeVault(phoneRoot, "D.luks")
        val id2 = knownClosed(g)
        runBlocking { Vaults.enableBiometric(id2, pw.toByteArray()) }
        assertFalse(secret.contentEquals(e.setPasses[2]!!))
        // le secret n'est écrit nulle part en clair
        tmp.root.walk().filter { it.isFile && !it.name.endsWith(".luks") }.forEach { file ->
            assertFalse(file.path, file.readBytes().toList().windowed(32).any { it.toByteArray().contentEquals(secret) })
        }
    }

    @Test fun enrollmentChangeDisablesBiometric() {
        val id = knownClosed()
        runBlocking { Vaults.enableBiometric(id, pw.toByteArray()) }
        bioKeys.invalidate(BiometricBox.alias(id)) // nouveau visage ou nouvelle empreinte enregistré
        try {
            openBio(id)
            fail("ouvert")
        } catch (x: BiometricInvalidated) {
            assertEquals(BiometricBox.MSG_INVALIDATED, x.message)
        }
        assertFalse(Vaults.get(id)!!.biometric)
        assertFalse(File(bioDir, "$id.bio").exists())
        assertTrue(opensWith(id, pw)) // ouverture par mot de passe
    }

    @Test fun cancelFallsBackToPassword() {
        val f = fakeVault(phoneRoot, "C.luks")
        val id = knownClosed(f)
        bioPrompt.cancel = true
        try {
            runBlocking { Vaults.enableBiometric(id, pw.toByteArray()) }
            fail("activé")
        } catch (_: BiometricCancelled) {
        }
        assertEquals(setOf(0), e.slotsOf(f).keys) // rien d'écrit
        assertFalse(Vaults.get(id)!!.biometric)
        bioPrompt.cancel = false
        runBlocking { Vaults.enableBiometric(id, pw.toByteArray()) }
        bioPrompt.cancel = true
        try {
            openBio(id)
            fail("ouvert")
        } catch (_: BiometricCancelled) {
        }
        assertTrue(Vaults.get(id)!!.biometric) // toujours activée : l'écran propose le mot de passe
        assertTrue(opensWith(id, pw))
    }

    @Test fun disableWipesKeyAndSlot() {
        val f = fakeVault(phoneRoot, "C.luks")
        val id = knownClosed(f)
        runBlocking { Vaults.enableBiometric(id, pw.toByteArray()) }
        runBlocking { Vaults.disableBiometric(id, pw.toByteArray()) }
        assertEquals(setOf(0), e.slotsOf(f).keys)
        assertFalse(File(bioDir, "$id.bio").exists())
        assertTrue(BiometricBox.alias(id) in bioKeys.deleted)
        assertFalse(Vaults.get(id)!!.biometric)
        // coffre ouvert : la clé est effacée, l'emplacement (inutilisable sans le secret) attend la prochaine fois
        runBlocking { Vaults.enableBiometric(id, pw.toByteArray()) }
        open("phone", "/C.luks")
        runBlocking { Vaults.disableBiometric(id, null) }
        assertFalse(File(bioDir, "$id.bio").exists())
        assertFalse(Vaults.get(id)!!.biometric)
        Vaults.close(id)
        runBlocking { Vaults.enableBiometric(id, pw.toByteArray()) } // même emplacement, réécrit
        assertEquals(setOf(0, 2), e.slotsOf(f).keys)
    }

    @Test fun forgetVaultWipesKey() {
        val id = knownClosed()
        runBlocking { Vaults.enableBiometric(id, pw.toByteArray()) }
        Vaults.forget(id)
        assertFalse(File(bioDir, "$id.bio").exists())
        assertTrue(BiometricBox.alias(id) in bioKeys.deleted)
    }
}
