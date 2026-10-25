package com.mawena.fluluks.engine

/**
 * Surface du moteur utilisée par le gestionnaire de volumes. [NativeEngine] l'implémente ; les tests
 * JVM fournissent un faux moteur. Même convention que NativeEngine : poignée > 0, valeur < 0 = fl_err.
 * Par défaut, tout s'ouvre en lecture seule.
 */
interface Engine {
    fun version(): String
    fun strerror(code: Int): ByteArray
    fun openImage(path: ByteArray, readOnly: Boolean = true): Long
    fun openUsb(fd: Int, iface: Int, epIn: Int, epOut: Int): Long
    fun closeDisk(disk: Long): Int
    fun scan(disk: Long): ByteArray
    fun mount(disk: Long, partIndex: Int, pass: ByteArray?, writable: Boolean = false): Long
    fun unmount(vol: Long, force: Boolean): Int
    fun statfs(vol: Long): ByteArray
    fun stat(vol: Long, path: ByteArray): ByteArray
    fun list(vol: Long, path: ByteArray): ByteArray
    fun openFile(vol: Long, path: ByteArray, flags: Int = OpenFlags.RDONLY): Long
    fun pread(file: Long, offset: Long, buf: ByteArray, len: Int): Int
    fun pwrite(file: Long, offset: Long, buf: ByteArray, len: Int): Int
    fun truncate(file: Long, size: Long): Int
    fun closeFile(file: Long): Int
    fun mkdir(vol: Long, path: ByteArray): Int
    fun unlink(vol: Long, path: ByteArray): Int
    fun rmdir(vol: Long, path: ByteArray): Int
    fun rename(vol: Long, from: ByteArray, to: ByteArray): Int
    fun sync(vol: Long): Int

    /**
     * Formate tout le disque (phase 8) : `opts` est le JSON UTF-8 de fj_format (fs, encrypted, label,
     * kdf_mem_kib, uid, gid). Refus FL_EBUSY si un volume du disque est ouvert, FL_EROFS si le disque est
     * protégé. [progress] reçoit un pourcentage croissant depuis le fil appelant. 0 ou fl_err.
     */
    fun format(disk: Long, opts: ByteArray, pass: ByteArray?, progress: FormatProgress?): Int = EngineError.FL_ENOTSUP

    /*
     * Archives (phase 9) : lecture de ZIP, 7z, RAR, TAR, GZ, XZ et écriture de ZIP. La source (descripteur
     * ou poignée de fichier) appartient à l'archive dès l'appel, même en cas d'échec ; une archive sur un
     * fichier du moteur est abandonnée si le fichier, le volume ou le disque est fermé.
     */

    /**
     * Poignée d'archive en lecture ; FL_ENOTSUP si le fichier n'est pas une archive reconnue. [mode] : [ArcMode] ;
     * [pass] (phase 14) lit un ZIP protégé ([ArcMode.PLAIN] ou [ArcMode.AES]) ou ouvre un ZIP dans un fichier age
     * ([ArcMode.AGE], FL_EBADPASS dès l'ouverture). Le tableau est mis à zéro par le moteur.
     */
    fun arcOpenFd(fd: Int, mode: Int = ArcMode.PLAIN, pass: ByteArray? = null): Long = EngineError.FL_ENOTSUP.toLong()

    /** [size] : taille du fichier (stat). */
    fun arcOpenFile(file: Long, size: Long, mode: Int = ArcMode.PLAIN, pass: ByteArray? = null): Long =
        EngineError.FL_ENOTSUP.toLong()

    /**
     * JSON UTF-8 de l'entrée suivante ({"name": base64 des octets bruts du nom, "type", "size", "mtime",
     * "encrypted"}), `{"err":<code>}` en cas d'erreur, null à la fin de l'archive.
     */
    fun arcNext(arc: Long): ByteArray? = """{"err":${EngineError.FL_ENOTSUP}}""".toByteArray()

    /** Données de l'entrée courante : octets lus (4 Mio au plus), 0 à la fin de l'entrée, ou fl_err. */
    fun arcRead(arc: Long, buf: ByteArray, len: Int): Int = EngineError.FL_ENOTSUP
    fun arcClose(arc: Long): Int = EngineError.FL_ENOTSUP
    /** [mode] : [ArcMode.PLAIN], [ArcMode.AES] (ZIP AES-256) ou [ArcMode.AGE] (ZIP dans un fichier age) ; [pass] exigé sauf en clair. */
    fun arcwOpenFd(fd: Int, mode: Int = ArcMode.PLAIN, pass: ByteArray? = null): Long = EngineError.FL_ENOTSUP.toLong()
    fun arcwOpenFile(file: Long, mode: Int = ArcMode.PLAIN, pass: ByteArray? = null): Long = EngineError.FL_ENOTSUP.toLong()

    /** `json` : {"name": chemin UTF-8 relatif, "type": "f"|"d", "size", "mtime", "store"}. */
    fun arcwAdd(arc: Long, json: ByteArray): Int = EngineError.FL_ENOTSUP
    fun arcwWrite(arc: Long, buf: ByteArray, len: Int): Int = EngineError.FL_ENOTSUP

    /** [commit] : termine le ZIP ; sinon abandon. Ferme la destination dans les deux cas. */
    fun arcwClose(arc: Long, commit: Boolean): Int = EngineError.FL_ENOTSUP

    /*
     * Fichiers age (phase 14), mêmes règles que les archives : la source ou la destination (descripteur, ou poignée de
     * fichier dont la poignée age devient l'enfant) appartient à la poignée dès l'appel, même en cas d'échec. Toute
     * phrase passée en ByteArray est mise à zéro par le moteur, succès comme échec.
     */

    /** Écrivain age ; [log2n] : facteur scrypt ([AGE_LOG2N] dans l'application). */
    fun ageWriterOpenFd(fd: Int, pass: ByteArray, log2n: Int = AGE_LOG2N): Long = EngineError.FL_ENOTSUP.toLong()
    fun ageWriterOpenFile(file: Long, pass: ByteArray, log2n: Int = AGE_LOG2N): Long = EngineError.FL_ENOTSUP.toLong()
    fun ageWrite(w: Long, buf: ByteArray, len: Int): Int = EngineError.FL_ENOTSUP

    /** [commit] : fichier terminé ; sinon abandon (destination incomplète, illisible). Ferme la destination. */
    fun ageWriterClose(w: Long, commit: Boolean): Int = EngineError.FL_ENOTSUP

    /** Lecteur age à accès aléatoire ; FL_EBADPASS, FL_ECORRUPT, FL_ENOTSUP (pas un fichier age scrypt), FL_ENOMEM. */
    fun ageReaderOpenFd(fd: Int, pass: ByteArray): Long = EngineError.FL_ENOTSUP.toLong()
    fun ageReaderOpenFile(file: Long, size: Long, pass: ByteArray): Long = EngineError.FL_ENOTSUP.toLong()

    /** Taille en clair, ou fl_err. */
    fun ageSize(r: Long): Long = EngineError.FL_ENOTSUP.toLong()

    /** Octets lus (4 Mio au plus) dans `buf[0..]`, 0 à la fin, ou fl_err. */
    fun agePread(r: Long, offset: Long, buf: ByteArray, len: Int): Int = EngineError.FL_ENOTSUP
    fun ageReaderClose(r: Long): Int = EngineError.FL_ENOTSUP

    /** log2 N d'un fichier age scrypt, 0 si ce n'en est pas un, ou fl_err. Ne prend ni le descripteur ni le fichier. */
    fun agePeekFd(fd: Int): Int = EngineError.FL_ENOTSUP
    fun agePeekFile(file: Long, size: Long): Int = EngineError.FL_ENOTSUP

    /**
     * Nouvelle phrase d'un fichier age (charge utile recopiée sans être déchiffrée, puis vérifiée). Source : [inFd] ≥ 0,
     * sinon [inFile] de [inSize] octets ; destination : [outFd] ≥ 0, sinon [outFile]. Les deux sont fermées.
     */
    fun ageRewrap(inFd: Int, inFile: Long, inSize: Long, outFd: Int, outFile: Long, old: ByteArray, new: ByteArray,
                  log2n: Int = AGE_LOG2N): Int = EngineError.FL_ENOTSUP

    /*
     * Coffres (phase 14) : disque LUKS2 sans table, sur un fichier du téléphone ou d'un volume du moteur.
     */

    /** Disque d'un coffre sur un descripteur, qui lui appartient dès l'appel (fermé avec lui, ou en cas d'échec). */
    fun openDiskFd(fd: Int, readOnly: Boolean): Long = EngineError.FL_ENOTSUP.toLong()

    /**
     * Disque d'un coffre sur le fichier [file] (openFile) d'un volume du moteur, de [size] octets : enfant du fichier,
     * qui lui appartient (fermé par [closeDisk], ou tout de suite en cas d'échec). Fermer le fichier, démonter son
     * volume ou fermer son disque démonte d'abord le coffre de force (synchronisé).
     */
    fun openDiskOnFile(file: Long, size: Long): Long = EngineError.FL_ENOTSUP.toLong()

    /** JSON {"version", "slots": [numéros]} des emplacements de clé d'un coffre, ou {"err"} (FL_ENOTSUP : disque avec une table). */
    fun luksSlots(disk: Long): ByteArray = """{"err":${EngineError.FL_ENOTSUP}}""".toByteArray()

    /** Crée ou remplace l'emplacement [slot] ; [auth] ouvre n'importe quel emplacement. FL_EBUSY si un volume du disque est monté. */
    fun luksSlotSet(disk: Long, slot: Int, auth: ByteArray, new: ByteArray, kdfMemKib: Int, kdfTime: Int): Int =
        EngineError.FL_ENOTSUP

    /** FL_EBUSY : dernier emplacement, ou volume monté ; FL_ENOENT : emplacement absent. */
    fun luksSlotRemove(disk: Long, slot: Int, auth: ByteArray): Int = EngineError.FL_ENOTSUP

    /** [mount] avec le seul emplacement [slot] (FL_ENOENT s'il n'existe pas). */
    fun mountSlot(disk: Long, partIndex: Int, slot: Int, pass: ByteArray, writable: Boolean): Long =
        EngineError.FL_ENOTSUP.toLong()

    companion object {
        /** Facteur scrypt des fichiers age écrits par Portail (256 Mio, comme l'outil age). */
        const val AGE_LOG2N = 18
    }
}

/** Mode d'une archive (phase 14) : en clair, ZIP AES-256, ou ZIP dans un fichier age. */
object ArcMode {
    const val PLAIN = 0
    const val AES = 1
    const val AGE = 2
}

/** Progression du formatage, appelée par le moteur natif (méthode `onProgress(I)V`). */
fun interface FormatProgress {
    fun onProgress(pct: Int)
}

/** Drapeaux de [Engine.openFile], ceux de fluluks/fs.h (FL_O_*), combinables. */
object OpenFlags {
    const val RDONLY = 0
    const val RDWR = 1
    const val CREAT = 2
    const val TRUNC = 4
}
