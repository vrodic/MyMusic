import XCTest

final class MergeServerIndexTests: XCTestCase {
    private var db: LibraryDB!
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "mymusic-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try LibraryDB(path: dir.appending(path: "library.sqlite").path, extraMigrations: [LibraryDB.favoriteAtMigration])
    }

    override func tearDownWithError() throws {
        db = nil
        try FileManager.default.removeItem(at: dir)
    }

    private func song(_ path: String, size: Int64 = 100, mtime: Double = 1000) -> Track {
        Track(relPath: path, size: size, mtime: mtime, title: path, origin: .remote)
    }

    private var paths: Set<String> { Set(db.allTracks().map(\.relPath)) }

    func testAddsNewSongsAsRegularLibrarySongs() throws {
        try db.mergeServerIndex([song("a.mp3")], updateKnown: false)
        XCTAssertEqual(paths, ["a.mp3"])
        XCTAssertEqual(db.track(relPath: "a.mp3")?.origin, .server)
    }

    func testKnownSongKeepsItsSpellingInsteadOfDuplicating() throws {
        let scanned = "Cafe\u{301}.mp3", served = "Caf\u{E9}.mp3"
        try db.upsert([song(scanned)])
        try db.mergeServerIndex([song(served)], updateKnown: true)
        XCTAssertEqual(db.allTracks().map { Array($0.relPath.unicodeScalars) }, [Array(scanned.unicodeScalars)])
    }

    func testWithAMusicFolderKnownStampsStayForItsNextScan() throws {
        try db.upsert([song("a.mp3", size: 100, mtime: 1000)])
        try db.mergeServerIndex([song("a.mp3", size: 200, mtime: 2000)], updateKnown: false)
        XCTAssertEqual(db.track(relPath: "a.mp3")?.size, 100)
        XCTAssertEqual(db.track(relPath: "a.mp3")?.mtime, 1000)
    }

    func testServerOnlyFollowsChangedFiles() throws {
        try db.upsert([song("a.mp3", size: 100, mtime: 1000)])
        try db.mergeServerIndex([song("a.mp3", size: 200, mtime: 2000)], updateKnown: true)
        XCTAssertEqual(db.track(relPath: "a.mp3")?.size, 200)
    }

    func testSongsTheServerNoLongerListsAreDroppedInBothModes() throws {
        for updateKnown in [false, true] {
            try db.upsert([song("keep.mp3"), song("gone.mp3")])
            try db.mergeServerIndex([song("keep.mp3")], updateKnown: updateKnown)
            XCTAssertEqual(paths, ["keep.mp3"])
        }
    }

    func testEmptyListRemovesNothing() throws {
        try db.upsert([song("a.mp3")])
        try db.mergeServerIndex([], updateKnown: true)
        XCTAssertEqual(paths, ["a.mp3"])
    }

    func testDroppedSongKeepsItsStatsForWhenItReturns() throws {
        try db.upsert([song("gone.mp3"), song("keep.mp3")])
        db.setFavorite("gone.mp3", true)
        db.recordPlay("gone.mp3")
        try db.mergeServerIndex([song("keep.mp3")], updateKnown: true)
        try db.mergeServerIndex([song("keep.mp3"), song("gone.mp3")], updateKnown: true)
        db.refreshCache()
        XCTAssertEqual(db.track(relPath: "gone.mp3")?.playCount, 1)
        XCTAssertEqual(db.track(relPath: "gone.mp3")?.favorite, true)
    }
}
