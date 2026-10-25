package com.mawena.fluluks

import com.mawena.fluluks.crypt.Passwords
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PasswordsTest {
    private fun u(s: String) = s.toByteArray(Charsets.UTF_8)

    @Test fun minLength8() {
        assertEquals(Passwords.MSG_TOO_SHORT, Passwords.check(u("1234567")))
        assertNull(Passwords.check(u("12345678")))
        // caractères, pas octets : « éééé » fait 8 octets mais 4 caractères
        assertEquals(Passwords.MSG_TOO_SHORT, Passwords.check(u("éééé")))
        assertNull(Passwords.check(u("éééééééé")))
        assertEquals(Passwords.MSG_TOO_SHORT, Passwords.check(ByteArray(0)))
    }

    @Test fun nulRefused() {
        assertEquals(Passwords.MSG_NUL, Passwords.check(u("abcd\u0000efgh")))
    }

    @Test fun invalidUtf8Refused() {
        assertEquals(Passwords.MSG_INVALID, Passwords.check(byteArrayOf(0xC3.toByte(), 0x28, 'a'.code.toByte(), 'b'.code.toByte(),
            'c'.code.toByte(), 'd'.code.toByte(), 'e'.code.toByte(), 'f'.code.toByte(), 'g'.code.toByte())))
    }
}
