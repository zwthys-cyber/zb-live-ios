import XCTest
@testable import Live

final class LibraryTests: XCTestCase {
    func testFavoritesHistoryAndSettingsPersist() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("library.json")
            let item = LiveItem(name: "Test", url: try LinkValidator.parse("https://example.com/a.m3u8"))
            let store = LibraryStore(fileURL: path)
            store.toggleFavorite(item)
            store.record(item)
            store.record(item)
            store.setBackgroundAudio(true)
            let reopened = LibraryStore(fileURL: path)
            XCTAssertEqual(reopened.favorites, [item])
            XCTAssertEqual(reopened.history.count, 1)
            XCTAssertTrue(reopened.backgroundAudio)
            reopened.toggleFavorite(item)
            XCTAssertTrue(reopened.favorites.isEmpty)
        }
    }

    func testImportUpdatesWithoutDuplicatingAndClearKeepsFavorites() async throws {
        try await MainActor.run {
            let store = LibraryStore(ephemeral: true)
            var item = LiveItem(name: "Old", url: try LinkValidator.parse("https://example.com/a.m3u8"))
            store.toggleFavorite(item)
            _ = store.importItems([item], subscriptionURL: try LinkValidator.parse("https://example.com/channels.m3u"))
            item.name = "Updated"
            _ = store.importItems([item, item])
            XCTAssertEqual(store.channels.count, 1)
            XCTAssertEqual(store.channels[0].name, "Updated")
            XCTAssertEqual(store.subscriptions.count, 1)
            store.clearChannels()
            XCTAssertTrue(store.channels.isEmpty)
            XCTAssertTrue(store.subscriptions.isEmpty)
            XCTAssertEqual(store.favorites.count, 1)
        }
    }

    func testHistoryIsBoundedAndMostRecentComesFirst() async throws {
        try await MainActor.run {
            let store = LibraryStore(ephemeral: true)
            for index in 0..<205 {
                store.record(LiveItem(name: "\(index)", url: try LinkValidator.parse("https://example.com/\(index)")))
            }
            XCTAssertEqual(store.history.count, 200)
            XCTAssertEqual(store.history.first?.item.name, "204")
            store.clearHistory()
            XCTAssertTrue(store.history.isEmpty)
        }
    }

    func testCorruptFileIsBackedUpBeforeCreatingNewLibrary() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("library.json")
            let original = Data("broken-json".utf8)
            try original.write(to: path)
            let store = LibraryStore(fileURL: path)
            XCTAssertNotNil(store.notice)
            store.setBackgroundAudio(true)
            let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("backup-") }
            XCTAssertEqual(backups.count, 1)
            XCTAssertEqual(try Data(contentsOf: backups[0]), original)
            XCTAssertTrue(LibraryStore(fileURL: path).backgroundAudio)
        }
    }
}
