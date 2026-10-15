package io.github.mmerioles.drill.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UsernameTest {
    @Test fun rule() {
        assertTrue(Username.valid("abc"))
        assertTrue(Username.valid("matt_01"))
        assertTrue(Username.valid("a".repeat(20)))
        assertFalse(Username.valid("ab"))
        assertFalse(Username.valid("a".repeat(21)))
        assertFalse(Username.valid("Matt"))
        assertFalse(Username.valid("ma tt"))
        assertFalse(Username.valid("matt-1"))
        assertFalse(Username.valid(""))
    }

    @Test fun typingCleans() {
        assertEquals("matt", Username.clean("Matt"))
        assertEquals("matt_1", Username.clean(" ma tt_1 "))
        assertEquals("", Username.clean("   "))
    }

    @Test fun syntheticEmail() {
        assertEquals("matt@users.mmerioles.github.io", Username.email("matt"))
        assertEquals("matt", Username.fromEmail("matt@users.mmerioles.github.io"))
        assertEquals("matt", Username.fromEmail(Username.email("matt")))
    }
}
