import Foundation
#if !STANDALONE_TESTS
import XCTest
@testable import simpleRDP
#endif

final class SafetyTests: XCTestCase {
    private func descriptor(_ entries: [(String, UInt64, Bool)]) -> Data {
        var data = Data(repeating: 0, count: 4 + entries.count * 592)
        func put(_ value: UInt32, _ offset: Int) {
            for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
        }
        put(UInt32(entries.count), 0)
        for (index, entry) in entries.enumerated() {
            let base = 4 + index * 592
            put(0x44, base)
            put(entry.2 ? 0x10 : 0x80, base + 36)
            put(UInt32(truncatingIfNeeded: entry.1 >> 32), base + 64)
            put(UInt32(truncatingIfNeeded: entry.1), base + 68)
            for (i, unit) in entry.0.utf16.prefix(259).enumerated() {
                data[base + 72 + i * 2] = UInt8(truncatingIfNeeded: unit)
                data[base + 73 + i * 2] = UInt8(truncatingIfNeeded: unit >> 8)
            }
        }
        return data
    }

    func testAddressValidation() throws {
        XCTAssertEqual(try ConnectionAddress(" host:3390 ").display, "host:3390")
        XCTAssertEqual(try ConnectionAddress("[::1]:3390").host, "::1")
        XCTAssertEqual(try ConnectionAddress("::1").display, "[::1]")
        for invalid in ["", "server:-1", "server:0", "server:65536", "server:abc", "server:", "[::1]:-1", "[bad]", "host name", "https://host"] {
            XCTAssertThrowsError(try ConnectionAddress(invalid), invalid)
        }
    }

    func testUnsafeClipboardPathsRejected() {
        for path in ["folder/../../escaped.txt", "../escape", "/absolute", "C:\\file", "folder//file", ".", "..", "folder/./file", "folder/../file", "bad\nname"] {
            XCTAssertThrowsError(try parseFileGroupDescriptor(descriptor([(path, 0, false)])), path)
        }
    }

    func testDescriptorValidation() throws {
        let files = try parseFileGroupDescriptor(descriptor([("Folder", 0, true), ("Folder\\file.txt", 8, false)]))
        XCTAssertEqual(files[1].relativePath, "Folder/file.txt")
        XCTAssertEqual(files[1].listIndex, 1)
        XCTAssertEqual(files[1].size, 8)
        XCTAssertThrowsError(try parseFileGroupDescriptor(Data([1, 0, 0, 0])))
        XCTAssertThrowsError(try parseFileGroupDescriptor(descriptor([("A", 0, false), ("a", 0, false)])))
        XCTAssertThrowsError(try parseFileGroupDescriptor(descriptor([("a", 0, false), ("a/b", 0, false)])))
        XCTAssertThrowsError(try parseFileGroupDescriptor(descriptor([("a", UInt64.max, false)])))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func testStagingRejectsSymlinkEscape() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let area = try ClipboardStagingArea(parent: root)
        try FileManager.default.createSymbolicLink(at: area.url.appendingPathComponent("redirect"), withDestinationURL: root)
        let file = RemoteClipboardFile(listIndex: 0, relativePath: "redirect/escaped", size: 0, isDirectory: false)
        XCTAssertThrowsError(try area.create(file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped").path))
        let valid = RemoteClipboardFile(listIndex: 0, relativePath: "folder/file", size: 3, isDirectory: false)
        let handle = try XCTUnwrap(area.create(valid))
        try handle.write(contentsOf: Data("abc".utf8))
        try handle.close()
        XCTAssertEqual(try Data(contentsOf: area.url.appendingPathComponent("folder/file")), Data("abc".utf8))
        XCTAssertThrowsError(try area.create(valid))
    }

    func testFailedSavePreservesSource() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let invalidDestination = root.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: source)
        try Data().write(to: invalidDestination)
        let result = moveStagedFiles([source], to: invalidDestination)
        XCTAssertEqual(result.remaining, [source])
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), Data("keep".utf8))
    }

    func testSaveCollisionDoesNotOverwrite() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("file.txt")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination.appendingPathComponent("file.txt"))
        let result = moveStagedFiles([source], to: destination)
        XCTAssertTrue(result.remaining.isEmpty)
        XCTAssertEqual(result.destinations.first?.lastPathComponent, "file (2).txt")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("file.txt")), Data("old".utf8))
    }

    func testWheelSignedEncoding() {
        for steps: Int32 in [-3, -1, 0, 1, 3] {
            let flags = RemoteInput.wheelFlags(steps: steps, horizontal: false)
            let total = flags.reduce(0) { sum, flag in
                let bits = Int(flag & 0x1ff)
                return sum + (bits & 0x100 != 0 ? bits - 512 : bits)
            }
            XCTAssertEqual(total, Int(steps) * 120)
        }
    }

    func testTransferCancellationDoesNotReset() {
        let old = ClipboardTransfer(generation: UUID(), pasteboardChange: 1)
        old.cancel()
        let new = ClipboardTransfer(generation: UUID(), pasteboardChange: 2)
        XCTAssertTrue(old.isCancelled)
        XCTAssertFalse(new.isCancelled)
    }

    @MainActor func testFavoriteDraftPreservesOptions() throws {
        let vm = SessionViewModel()
        vm.host = "host:3390"
        vm.trustAllCertificates = true
        vm.sharePath = "/tmp"
        vm.resolution = RDPResolution(width: 1920, height: 1080)
        let draft = try vm.favoriteDraft()
        XCTAssertEqual(draft.host, "host")
        XCTAssertEqual(draft.port, 3390)
        XCTAssertTrue(draft.trustAllCertificates)
        XCTAssertEqual(draft.sharePath, "/tmp")
        XCTAssertEqual(draft.resolution, vm.resolution)
    }

    @MainActor func testCorruptFavoritesNeverOverwritten() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("favorites.json")
        let original = Data("invalid JSON".utf8)
        try original.write(to: file)
        let store = FavoritesStore(fileURL: file)
        store.add(ServerFavorite(name: "test", host: "host"))
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}