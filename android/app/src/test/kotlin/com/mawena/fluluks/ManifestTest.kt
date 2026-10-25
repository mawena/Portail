package com.mawena.fluluks

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Manifeste principal, le seul fusionné dans la version de publication : les manifestes de debug et de profile
 * ajoutent la permission INTERNET pour les outils de Flutter, ce qui la cache pendant les essais.
 */
class ManifestTest {
    private fun permissions(): Set<String> {
        val doc = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
            .newDocumentBuilder().parse(File("src/main/AndroidManifest.xml"))
        val nodes = doc.getElementsByTagName("uses-permission")
        return (0 until nodes.length).map {
            nodes.item(it).attributes.getNamedItemNS("http://schemas.android.com/apk/res/android", "name").nodeValue
        }.toSet()
    }

    /** SFTP, FTP, terminal et tunnels SSH : sans elle, toute connexion échoue en publication (« Permission denied »). */
    @Test fun internetDeclaredForRelease() {
        assertTrue(permissions().contains("android.permission.INTERNET"))
    }
}
