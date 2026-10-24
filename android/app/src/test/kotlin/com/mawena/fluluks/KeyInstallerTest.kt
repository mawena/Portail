package com.mawena.fluluks

import com.jcraft.jsch.Session
import com.mawena.fluluks.remote.HostKeyChanged
import com.mawena.fluluks.remote.RemoteIOException
import com.mawena.fluluks.remote.RemoteServers
import com.mawena.fluluks.remote.Remotes
import com.mawena.fluluks.remote.SecretBox
import com.mawena.fluluks.remote.Secrets
import com.mawena.fluluks.remote.ServerConfig
import com.mawena.fluluks.remote.ssh.KeyInstaller
import com.mawena.fluluks.remote.ssh.SshConnector
import com.mawena.fluluks.remote.ssh.SshKeys
import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PublicKey
import java.util.Base64
import org.apache.sshd.common.config.keys.PublicKeyEntry
import org.apache.sshd.common.file.virtualfs.VirtualFileSystemFactory
import org.apache.sshd.common.keyprovider.KeyPairProvider
import org.apache.sshd.server.SshServer
import org.apache.sshd.server.auth.password.PasswordAuthenticator
import org.apache.sshd.sftp.server.SftpSubsystemFactory
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Installation d'une clé publique dans `~/.ssh/authorized_keys` par SFTP (phase 13, T8), contre MINA SSHD dont le
 * dossier personnel est un dossier temporaire.
 */
class KeyInstallerTest {
    @get:Rule val tmp = TemporaryFolder()

    private object Box : SecretBox {
        override fun seal(plain: ByteArray) = plain.reversedArray().map { (it + 7).toByte() }.toByteArray()
        override fun open(sealed: ByteArray) = sealed.map { (it - 7).toByte() }.toByteArray().reversedArray()
    }

    private val hostKeys: KeyPair = KeyPairGenerator.getInstance("EC").apply { initialize(256) }.generateKeyPair()
    private var sshd: SshServer? = null
    private lateinit var home: File
    private var session: Session? = null

    private val line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGtUbmxQ portail@Pixel 4 XL"

    @Before fun setup() {
        home = tmp.newFolder("home")
        sshd = SshServer.setUpDefaultServer().apply {
            host = "127.0.0.1"
            port = 0
            keyPairProvider = KeyPairProvider.wrap(hostKeys)
            passwordAuthenticator = PasswordAuthenticator { u, p, _ -> u == "portail" && p == "mdp" }
            subsystemFactories = listOf(SftpSubsystemFactory())
            fileSystemFactory = VirtualFileSystemFactory(home.toPath())
            start()
        }
    }

    @After fun teardown() {
        session?.disconnect()
        sshd?.stop(true)
        Remotes.resetForTests(null, null)
    }

    private fun fingerprint(k: PublicKey): String {
        val (type, b64) = PublicKeyEntry.toString(k).split(" ")
        val sha = MessageDigest.getInstance("SHA-256").digest(Base64.getDecoder().decode(b64))
        return "$type SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(sha)
    }

    private fun cfg(hostKey: String = fingerprint(hostKeys.public)) =
        ServerConfig("", "sftp", "Maison", "127.0.0.1", sshd!!.port, "portail", "/", false, hostKey, null)

    private fun session(): Session =
        SshConnector(cfg(), Secrets("mdp".toByteArray(), null, null)).open().also { session = it }

    private val ssh get() = File(home, ".ssh")
    private val keys get() = File(ssh, "authorized_keys")

    private fun mode(f: File) = PosixFilePermissions.toString(Files.getPosixFilePermissions(f.toPath()))

    @Test fun installCreatesSshDir() {
        assertEquals(KeyInstaller.Result.ADDED, KeyInstaller.install(session(), line))
        assertEquals("rwx------", mode(ssh))
        assertEquals("rw-------", mode(keys))
        assertEquals("$line\n", keys.readText())
        assertFalse(File(ssh, "authorized_keys.portail-tmp").exists())
    }

    @Test fun installKeepsExistingKeys() {
        ssh.mkdirs()
        val before = "# clés de Charles\nssh-rsa AAAAB3NzaC1yc2E charles@portable\n\nssh-ed25519 AAAAautre ordi\n"
        keys.writeText(before)
        KeyInstaller.install(session(), line)
        assertEquals(before + "$line\n", keys.readText()) // octet pour octet, puis la nouvelle ligne
    }

    @Test fun installIsIdempotent() {
        KeyInstaller.install(session(), line)
        val first = keys.readBytes()
        val stamp = keys.lastModified()
        Thread.sleep(20)
        // même clé, autre commentaire : déjà présente
        assertEquals(KeyInstaller.Result.ALREADY_PRESENT, KeyInstaller.install(session!!, line.replace("portail@Pixel 4 XL", "autre")))
        assertArrayEquals(first, keys.readBytes())
        assertEquals(stamp, keys.lastModified())
    }

    @Test fun installAddsMissingFinalNewline() {
        ssh.mkdirs()
        keys.writeText("ssh-rsa AAAAB3 charles@portable")
        KeyInstaller.install(session(), line)
        assertEquals("ssh-rsa AAAAB3 charles@portable\n$line\n", keys.readText())
    }

    @Test fun installSetsModes() {
        ssh.mkdirs()
        Files.setPosixFilePermissions(ssh.toPath(), PosixFilePermissions.fromString("rwxrwxr-x"))
        keys.writeText("ssh-rsa AAAAB3 charles@portable\n")
        Files.setPosixFilePermissions(keys.toPath(), PosixFilePermissions.fromString("rw-r--r--"))
        KeyInstaller.install(session(), line)
        assertEquals("rw-------", mode(keys))
        assertEquals("rwxr-xr-x", mode(ssh)) // plus d'écriture pour le groupe ni les autres (StrictModes de sshd)
    }

    @Test fun installRefusesSymlinkedFile() {
        ssh.mkdirs()
        val target = File(home, "ailleurs").apply { writeText("ssh-rsa AAAAB3 x\n") }
        Files.createSymbolicLink(keys.toPath(), target.toPath())
        val e = assertThrows(RemoteIOException::class.java) { KeyInstaller.install(session(), line) }
        assertEquals(".ssh/authorized_keys est un lien symbolique : installation annulée", e.message)
        assertEquals("ssh-rsa AAAAB3 x\n", target.readText())
    }

    @Test fun installRefusesChangedHostKey() {
        val store = RemoteServers(tmp.newFolder("app"), Box)
        Remotes.resetForTests(store, null)
        SshKeys.defaultComment = "portail@test"
        val k = store.keys.generate("Pixel", "ed25519", null)
        val other = KeyPairGenerator.getInstance("EC").apply { initialize(256) }.generateKeyPair()
        val s = store.save(cfg(hostKey = fingerprint(other.public)), null, null)
        assertThrows(HostKeyChanged::class.java) { Remotes.installPublicKey(s.id, k.id, "mdp".toByteArray()) }
        assertFalse(keys.exists())
    }

    @Test fun installThroughRemotes() {
        val store = RemoteServers(tmp.newFolder("app"), Box)
        Remotes.resetForTests(store, null)
        SshKeys.defaultComment = "portail@test"
        val k = store.keys.generate("Pixel", "ed25519", null)
        val s = store.save(cfg(), null, null)
        val pw = "mdp".toByteArray()
        assertEquals(KeyInstaller.Result.ADDED, Remotes.installPublicKey(s.id, k.id, pw))
        assertEquals(store.keys.publicKey(k.id) + "\n", keys.readText())
        assertEquals(KeyInstaller.Result.ALREADY_PRESENT, Remotes.installPublicKey(s.id, k.id, "mdp".toByteArray()))
    }
}
