package io.github.mmerioles.drill.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PasswordTest {
    @Test fun rule() {
        assertFalse(Password.valid(""))
        assertFalse(Password.valid("abcde"))
        assertTrue(Password.valid("abcdef"))
        assertTrue(Password.valid("a b é😀!"))
        assertFalse(Password.valid("😀😀😀😀😀"))
        assertTrue(Password.valid("a".repeat(72)))
        assertFalse(Password.valid("a".repeat(73)))
        assertFalse(Password.valid("é".repeat(37)))
    }

    @Test fun confirm() {
        assertTrue(Password.confirmed("abcdef", "abcdef"))
        assertFalse(Password.confirmed("abcdef", "abcdeg"))
        assertFalse(Password.confirmed("abc", "abc"))
        assertFalse(Password.confirmed("abcdef", ""))
    }
}
