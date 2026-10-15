package io.github.mmerioles.drill.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.Base64

class LocalStoresTest {
    /** SessionStore's rules, in memory. */
    private class Rows : SessionRows {
        val rows = linkedMapOf<String, Pair<FocusSession, Boolean>>()
        override fun all() = rows.values.map { it.first }
        override fun dirty() = rows.values.filter { it.second }.map { it.first }
        override fun save(rows: List<FocusSession>, local: Boolean): Int {
            var changed = 0
            for (row in rows) {
                val mine = this.rows[row.id]?.first
                if (!local && mine != null && mine.updatedAt >= row.updatedAt) continue
                this.rows[row.id] = row to local
                changed++
            }
            return changed
        }
        override fun clear() = rows.clear()
        fun pushed() = rows.replaceAll { _, v -> v.first to false }
    }

    /** One store per file name, like the phone's database folder. */
    private class Disk {
        val files = mutableMapOf<String, Rows>()
        fun open(userID: String?) = files.getOrPut(LocalStores.fileName(userID)) { Rows() }
    }

    private fun session(id: String, at: Long = 1_000L) =
        FocusSession(id, at, at + 1_500_000, 1500.0, 1500.0, true, null, "android-TEST", at)

    @Test fun eachAccountHasItsOwnFile() {
        assertEquals("drill.sqlite", LocalStores.fileName(null))
        assertEquals("drill-abc.sqlite", LocalStores.fileName("abc"))
        assertNotEquals(LocalStores.fileName("a"), LocalStores.fileName("b"))
    }

    @Test fun signingInToBAfterAUploadsNothingOfAs() {
        val disk = Disk()
        val a = disk.open("user-a")
        a.save(listOf(session("A1"), session("A2", 2_000)), local = true)
        a.pushed()
        a.save(listOf(session("A3", 3_000)), local = true) // unpushed when A signs out

        val b = disk.open("user-b")
        assertTrue(b.all().isEmpty())
        assertTrue(b.dirty().isEmpty())
        assertEquals(1, a.dirty().size)
    }

    @Test fun signingInLeavesOfflineAlone() {
        val disk = Disk()
        disk.open(null).save(listOf(session("O1")), local = true)
        val b = disk.open("user-b")
        assertTrue(b.dirty().isEmpty())
        assertEquals(1, disk.open(null).all().size)
    }

    @Test fun createAccountMovesOfflineRowsAndEmptiesOffline() {
        val disk = Disk()
        val offline = disk.open(null)
        offline.save(listOf(session("O1"), session("O2", 2_000)), local = true)
        offline.pushed() // even rows that were never meant for any account
        val account = disk.open("new")
        LocalStores.handOver(offline, account)
        assertTrue(offline.all().isEmpty())
        assertEquals(setOf("O1", "O2"), account.dirty().map { it.id }.toSet())
        assertEquals(2_000L, account.all().first { it.id == "O2" }.updatedAt)
    }

    @Test fun welcomeOnlyWhenSignedOutAndNotChosenOffline() {
        assertTrue(LocalStores.showWelcome(signedIn = false, welcomed = false))
        assertFalse(LocalStores.showWelcome(signedIn = false, welcomed = true))
        assertFalse(LocalStores.showWelcome(signedIn = true, welcomed = false))
    }

    @Test fun upgradeMovesTheFileOnceAndKeepsItsContents() {
        val dir = Files.createTempDirectory("drill").toFile()
        val bytes = byteArrayOf(1, 2, 3, 0, 42) // stands in for rows and their push marks
        File(dir, "drill.sqlite").writeBytes(bytes)
        File(dir, "drill.sqlite-journal").writeBytes(byteArrayOf(9))

        var done = LocalStores.upgrade(done = false, dir, "uid")
        assertTrue(done)
        assertFalse(File(dir, "drill.sqlite").exists())
        assertTrue(File(dir, "drill-uid.sqlite").readBytes().contentEquals(bytes))
        assertTrue(File(dir, "drill-uid.sqlite-journal").exists())

        // A fresh offline store appears; later launches leave it be.
        File(dir, "drill.sqlite").writeBytes(byteArrayOf(7))
        done = LocalStores.upgrade(done, dir, "uid")
        assertTrue(done)
        assertTrue(File(dir, "drill.sqlite").readBytes().contentEquals(byteArrayOf(7)))
        assertTrue(File(dir, "drill-uid.sqlite").readBytes().contentEquals(bytes))
        dir.deleteRecursively()
    }

    @Test fun upgradeWithNobodySignedInMovesNothing() {
        val dir = Files.createTempDirectory("drill").toFile()
        File(dir, "drill.sqlite").writeBytes(byteArrayOf(1))
        assertTrue(LocalStores.upgrade(done = false, dir, null))
        assertTrue(File(dir, "drill.sqlite").exists())
        assertEquals(1, dir.listFiles()!!.size)
        dir.deleteRecursively()
    }

    @Test fun subjectFromAccessToken() {
        val payload = Base64.getUrlEncoder().withoutPadding()
            .encodeToString("""{"aud":"authenticated","sub":"6f1c-42","role":"authenticated"}""".toByteArray())
        assertEquals("6f1c-42", LocalStores.subject("eyJhbGciOiJIUzI1NiJ9.$payload.sig"))
        assertNull(LocalStores.subject("garbage"))
    }
}
