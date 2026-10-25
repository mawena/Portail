package com.mawena.fluluks

import com.mawena.fluluks.bridge.FlutterError
import com.mawena.fluluks.bridge.HostApiImpl
import com.mawena.fluluks.engine.EngineError
import com.mawena.fluluks.files.Files
import com.mawena.fluluks.files.FilesException
import com.mawena.fluluks.files.TransferState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Erreurs envoyées à Flutter par le pont. */
class HostApiErrorsTest {
    /** Relecture finale : « Ouvrir avec » sans application garde son message français. */
    @Test fun flutterErrorKeptAsIs() {
        val e = HostApiImpl.toFlutterError(FlutterError(EngineError.FL_ENOTSUP.toString(), Files.MSG_NO_VIEWER))
        assertEquals(Files.MSG_NO_VIEWER, e.message)
        assertEquals(EngineError.FL_ENOTSUP.toString(), e.code)
    }

    /** Un mauvais mot de passe a son propre code : l'écran redemande le mot de passe au lieu d'afficher une erreur. */
    @Test fun badPasswordHasOwnCode() {
        val e = HostApiImpl.toFlutterError(FilesException(EngineError.FL_EBADPASS, "Mot de passe incorrect"))
        assertEquals("badPassword", e.code)
        assertEquals("Mot de passe incorrect", e.message)
        val n = HostApiImpl.toFlutterError(EngineError(EngineError.FL_EBADPASS))
        assertEquals("badPassword", n.code)
        assertEquals(EngineError.FL_EIO.toString(), HostApiImpl.toFlutterError(FilesException(EngineError.FL_EIO, "x")).code)
    }

    @Test fun transferMsgCarriesBadPassword() {
        val t = TransferState(move = false, currentName = "a.age", fileIndex = 1, fileCount = 1, doneBytes = 0, totalBytes = 0,
            finished = true, cancelled = false, error = "Mot de passe incorrect", elapsedMs = 0, kind = "decrypt", badPassword = true)
        assertTrue(HostApiImpl.transferMsg(t).badPassword)
        assertFalse(HostApiImpl.transferMsg(t.copy(badPassword = false)).badPassword)
    }
}
