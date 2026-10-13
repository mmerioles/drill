import Testing
@testable import DrillCore

@Suite struct VersionTests {
    @Test func parsesTagsAndBundleVersions() {
        #expect(Version("v1.4.2") == Version(1, 4, 2))
        #expect(Version("0.1.3") == Version(0, 1, 3))
        #expect(Version("2") == Version(2, 0, 0))
        #expect(Version("1.10")?.description == "1.10.0")
    }

    @Test func rejectsJunk() {
        #expect(Version("") == nil)
        #expect(Version("v") == nil)
        #expect(Version("1.2.3.4") == nil)
        #expect(Version("1..2") == nil)
        #expect(Version("1.2-beta") == nil)
    }

    @Test func comparesNumerically() {
        #expect(Version(0, 1, 9) < Version(0, 1, 10))
        #expect(Version(0, 9, 9) < Version(1, 0, 0))
        #expect(!(Version(1, 2, 3) < Version(1, 2, 3)))
    }
}
