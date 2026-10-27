package com.mawena.fluluks.analyzer

import com.mawena.fluluks.engine.FileType

/** Taille comptée par l'analyseur : place réellement occupée (blocs alloués), ou taille apparente (dossier distant). */
enum class SizeKind { ALLOCATED, APPARENT }

/**
 * Élément d'un dossier pour l'analyseur (phase 16) : [alloc] octets occupés sur le support, [dev] et [ino] pour
 * compter une seule fois les liens physiques ([nlink] > 1), [otherDevice] s'il est sur un autre système de fichiers
 * que la racine du stockage (point de montage : jamais parcouru). `mtime` en secondes UTC.
 */
data class DuEntry(
    val name: String, val type: FileType, val size: Long, val alloc: Long, val mtime: Long, val dev: Long,
    val ino: Long, val nlink: Int, val otherDevice: Boolean = false,
)
