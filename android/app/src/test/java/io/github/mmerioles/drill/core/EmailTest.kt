package io.github.mmerioles.drill.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EmailTest {
    @Test fun rule() {
        assertTrue(Email.isValid("teto@example.com"))
        assertTrue(Email.isValid("miku+drill@mail.example.co.jp"))
        assertTrue(Email.isValid("a@b.c"))
        assertFalse(Email.isValid(""))
        assertFalse(Email.isValid("not-an-email"))
        assertFalse(Email.isValid("teto@example"))
        assertFalse(Email.isValid("@example.com"))
        assertFalse(Email.isValid("teto@@example.com"))
        assertFalse(Email.isValid("te to@example.com"))
        val local = "a".repeat(64)
        val long = "$local@" + "b".repeat(254 - local.length - 5) + ".com"
        assertEquals(254, long.length)
        assertTrue(Email.isValid(long))
        assertFalse(Email.isValid("a$long"))
    }

    @Test fun typingCleans() {
        assertEquals("teto@example.com", Email.clean(" Teto@Example.com "))
        assertEquals("miku+1.x@example.com", Email.clean("Miku+1.x @example.com"))
        assertEquals("", Email.clean("   "))
    }
}
