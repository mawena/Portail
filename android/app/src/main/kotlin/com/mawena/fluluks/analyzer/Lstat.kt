package com.mawena.fluluks.analyzer

import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import com.mawena.fluluks.engine.FileType
import com.mawena.fluluks.files.Files
import java.io.FileNotFoundException

/** Résultat d'un lstat : [blocks] en unités de 512 octets (st_blocks), `mtime` en secondes UTC. */
data class RawStat(val mode: Int, val size: Long, val blocks: Long, val mtime: Long, val dev: Long, val ino: Long, val nlink: Int) {
    /** Type d'après les bits S_IFMT du mode (valeurs de Linux, sans OsConstants : utilisable hors d'Android). */
    val type: FileType
        get() = when (mode and S_IFMT) {
            S_IFDIR -> FileType.DIR
            S_IFREG -> FileType.FILE
            S_IFLNK -> FileType.SYMLINK
            else -> FileType.OTHER
        }

    companion object {
        const val S_IFMT = 0xF000
        const val S_IFDIR = 0x4000
        const val S_IFREG = 0x8000
        const val S_IFLNK = 0xA000
    }
}

/** lstat d'un chemin du téléphone : un lien symbolique n'est jamais suivi. */
fun interface Lstat {
    /** null : l'entrée a disparu entre la liste du dossier et son lstat. */
    fun of(path: String): RawStat?
}

/** lstat d'Android ; ENOENT → null, autre erreur → [FileNotFoundException]. */
object AndroidLstat : Lstat {
    override fun of(path: String): RawStat? = try {
        val s = Os.lstat(path)
        RawStat(s.st_mode, s.st_size, s.st_blocks, s.st_mtime, s.st_dev, s.st_ino, s.st_nlink.toInt())
    } catch (e: ErrnoException) {
        if (e.errno == OsConstants.ENOENT) null else throw FileNotFoundException(Files.MSG_BAD_PATH)
    }
}
