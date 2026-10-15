package io.github.mmerioles.drill.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

// The palette spec's vectors, shared with every platform.
class FuzzyTest {
    @Test fun specVectors() {
        assertEquals(10, Fuzzy.score("st", "start"))
        assertEquals(0, Fuzzy.score("st", "reset"))
        assertEquals(10, Fuzzy.score("ST", "start"))
        assertEquals(10, Fuzzy.score("sw", "switch to stopwatch"))
        assertEquals(10, Fuzzy.score("op", "open settings"))
        assertEquals(9, Fuzzy.score("set", "open settings"))
        assertNull(Fuzzy.score("xyz", "start"))
        assertEquals(0, Fuzzy.score("", "anything"))
        assertEquals(12, Fuzzy.score("o s", "open settings"))
    }

    @Test fun matchedIndices() {
        assertEquals(listOf(5, 6, 7), Fuzzy.match("set", "open settings")!!.indices)
        assertEquals(listOf(0, 5), Fuzzy.match("o s", "open settings")!!.indices)
    }

    private fun cmd(id: String, vararg keywords: String) = Command(id, id, keywords = keywords.toList()) {}
    private fun ids(hits: List<Hit>) = hits.map { it.command.id }

    @Test fun ranksByScoreThenListOrder() {
        val list = listOf(cmd("reset"), cmd("start"), cmd("skip"), cmd("open settings", "preferences"))
        assertEquals(listOf("start", "skip", "open settings", "reset"), ids(Commands.rank("s", list)))
        assertEquals(listOf("open settings"), ids(Commands.rank("pref", list)))
        assertEquals(listOf("start", "open settings", "reset"), ids(Commands.rank("st", list)))
    }

    @Test fun emptyQueryPutsRecentFirst() {
        val list = listOf(cmd("a"), cmd("b"), cmd("c"))
        assertEquals(listOf("c", "a", "b"), ids(Commands.rank("", list, recent = listOf("c", "gone"))))
    }

    @Test fun fallbackIsAlwaysLast() {
        val list = listOf(cmd("start"))
        val new = cmd("studying \"zz\"")
        assertEquals(listOf("studying \"zz\""), ids(Commands.rank("zz", list, fallback = new)))
        assertEquals(listOf("start", "studying \"zz\""), ids(Commands.rank("st", list, fallback = new)))
    }
}
