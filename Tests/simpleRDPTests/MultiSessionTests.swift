import AppKit
import CFreeRDP
#if !STANDALONE_TESTS
import XCTest
@testable import simpleRDP
#endif

final class MultiSessionTests: XCTestCase {
    private func pasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("simpleRDP-tests-\(Foundation.UUID())"))
    }

    private func connectedChannel() -> (ClipboardChannel, UnsafeMutablePointer<CliprdrClientContext>) {
        let pointer = UnsafeMutablePointer<CliprdrClientContext>.allocate(capacity: 1)
        pointer.initialize(to: CliprdrClientContext())
        let channel = ClipboardChannel()
        channel.clip = pointer
        channel.isReady = true
        return (channel, pointer)
    }

    private func dispose(_ channel: ClipboardChannel, _ pointer: UnsafeMutablePointer<CliprdrClientContext>) {
        channel.detach()
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    @MainActor func testRemoteTextOwnershipAndNoEcho() {
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        let coordinator = ClipboardCoordinator(pasteboard: pb, maySendLocal: { true })
        let (a, pa) = connectedChannel(), (b, pbContext) = connectedChannel()
        defer { dispose(a, pa); dispose(b, pbContext) }
        coordinator.select(a)
        let token = coordinator.selectionID
        XCTAssertTrue(coordinator.publishRemoteText("from A", from: a, selection: token, pasteboardChange: pb.changeCount))
        coordinator.poll()
        XCTAssertTrue(a.servedText == nil)
        coordinator.select(b)
        XCTAssertTrue(b.servedText == nil)
        XCTAssertFalse(coordinator.publishRemoteText("late A", from: a, selection: token, pasteboardChange: pb.changeCount))
        coordinator.select(a)
        XCTAssertFalse(coordinator.publishRemoteText("old epoch", from: a, selection: token, pasteboardChange: pb.changeCount))
        XCTAssertEqual(pb.string(forType: .string), "from A")
        let beforeCopy = pb.changeCount
        pb.clearContents()
        pb.setString("new Mac copy", forType: .string)
        XCTAssertFalse(coordinator.publishRemoteText("late reply", from: a, selection: coordinator.selectionID,
                                                    pasteboardChange: beforeCopy))
    }

    @MainActor func testLocalCopyRoutesOnceAndKeepsSnapshot() {
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        var active = false
        let coordinator = ClipboardCoordinator(pasteboard: pb, maySendLocal: { active })
        let (a, pa) = connectedChannel(), (b, pbContext) = connectedChannel()
        defer { dispose(a, pa); dispose(b, pbContext) }
        coordinator.select(a)
        pb.clearContents()
        pb.setString("Mac copy", forType: .string)
        coordinator.poll()
        XCTAssertTrue(a.servedText == nil)
        coordinator.select(b)
        active = true
        coordinator.poll()
        XCTAssertEqual(b.servedText, "Mac copy")
        XCTAssertTrue(a.servedText == nil)
        coordinator.select(a)
        XCTAssertTrue(a.servedText == nil, "Tab selection must not replay old Mac contents")
        XCTAssertTrue(coordinator.publishRemoteText("remote A", from: a, selection: coordinator.selectionID,
                                                   pasteboardChange: pb.changeCount))
        XCTAssertEqual(b.servedText, "Mac copy")
    }

    @MainActor func testRemoteFileOfferIsLazyAndStaleAcceptanceFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(Foundation.UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let (channel, pointer) = connectedChannel()
        defer { dispose(channel, pointer) }
        let generation = channel.remoteGeneration
        let file = RemoteClipboardFile(listIndex: 0, relativePath: "empty.txt", size: 0, isDirectory: false)
        channel.offerRemoteFiles([file], generation: generation)
        let offer = try XCTUnwrap(channel.currentFileOffer())
        XCTAssertEqual(channel.fileDownloadQueue.operationCount, 0)
        XCTAssertFalse(channel.currentDownloadStatus().isActive)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 0)
        channel.remoteGeneration = Foundation.UUID()
        channel.downloadRemoteFiles(offer, to: root)
        XCTAssertNotNil(channel.currentDownloadStatus().error)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 0)
    }

    @MainActor func testDestinationFirstDownloadLeavesNoStagingOrPasteboardWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(Foundation.UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        pb.setString("keep local clipboard", forType: .string)
        let originalChange = pb.changeCount
        let coordinator = ClipboardCoordinator(pasteboard: pb, maySendLocal: { false })
        let (channel, pointer) = connectedChannel()
        defer { dispose(channel, pointer) }
        coordinator.select(channel)
        // Exercise real chunk request/response code without an RDP server.
        pointer.pointee.custom = Unmanaged.passUnretained(channel).toOpaque()
        pointer.pointee.ClientFileContentsRequest = { context, request in
            guard let raw = context?.pointee.custom, let request else { return 1 }
            let channel = Unmanaged<ClipboardChannel>.fromOpaque(raw).takeUnretainedValue()
            let bytes: [UInt8] = [97, 98, 99]
            bytes.withUnsafeBufferPointer { buffer in
                var response = CLIPRDR_FILE_CONTENTS_RESPONSE()
                response.streamId = request.pointee.streamId
                response.cbRequested = 3
                response.common.dataLen = 7
                response.requestedData = buffer.baseAddress
                channel.onServerFileContentsResponse(response)
            }
            return 0
        }
        channel.offerRemoteFiles([
            RemoteClipboardFile(listIndex: 0, relativePath: "folder", size: 0, isDirectory: true),
            RemoteClipboardFile(listIndex: 1, relativePath: "folder/test.txt", size: 3, isDirectory: false)
        ], generation: channel.remoteGeneration)
        channel.downloadRemoteFiles(try XCTUnwrap(channel.currentFileOffer()), to: root)
        channel.fileDownloadQueue.waitUntilAllOperationsAreFinished()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("folder/test.txt")), Data("abc".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["folder"])
        XCTAssertEqual(channel.currentDownloadStatus().savedDirectory, root)
        XCTAssertFalse(channel.currentDownloadStatus().isActive)
        XCTAssertEqual(pb.changeCount, originalChange)
        XCTAssertEqual(pb.string(forType: .string), "keep local clipboard")
    }

    @MainActor func testCancelledDownloadRemovesPartialDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(Foundation.UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let (channel, pointer) = connectedChannel()
        defer { dispose(channel, pointer) }
        pointer.pointee.custom = Unmanaged.passUnretained(channel).toOpaque()
        pointer.pointee.ClientFileContentsRequest = { context, _ in
            guard let raw = context?.pointee.custom else { return 1 }
            Unmanaged<ClipboardChannel>.fromOpaque(raw).takeUnretainedValue().cancelDownloads()
            return 0
        }
        channel.offerRemoteFiles([RemoteClipboardFile(listIndex: 0, relativePath: "partial", size: 10, isDirectory: false)],
                                 generation: channel.remoteGeneration)
        channel.downloadRemoteFiles(try XCTUnwrap(channel.currentFileOffer()), to: root)
        channel.fileDownloadQueue.waitUntilAllOperationsAreFinished()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 0)
        XCTAssertFalse(channel.currentDownloadStatus().isActive)
        XCTAssertTrue(channel.currentDownloadStatus().savedDirectory == nil)
    }

    @MainActor func testTabLifecycleIsIndependent() throws {
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        let store = SessionStore(clipboard: ClipboardCoordinator(pasteboard: pb, maySendLocal: { false }))
        let a = try XCTUnwrap(store.selected)
        a.host = "server-a"
        store.addTab()
        let b = try XCTUnwrap(store.selected)
        XCTAssertFalse(a.session === b.session)
        store.select(a.id)
        XCTAssertEqual(store.selected?.host, "server-a")
        store.close(b.id)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.selectedID, a.id)
        store.close(a.id)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertFalse(store.selectedID == a.id)
        store.disconnectAll()
        XCTAssertTrue(store.allSessions.allSatisfy { $0.isQuiescent() })
        XCTAssertTrue(store.clipboard.selectedChannel == nil)
    }

    func testCommitCannotBeCancelledHalfwayThroughLocalSave() {
        let cancelled = ClipboardTransfer(generation: Foundation.UUID())
        cancelled.cancel()
        XCTAssertFalse(cancelled.beginCommit())
        let complete = ClipboardTransfer(generation: Foundation.UUID())
        XCTAssertTrue(complete.beginCommit())
        complete.cancel()
        XCTAssertFalse(complete.isCancelled)
    }

    @MainActor func testProtocolFileNotificationOnlyFetchesMetadata() throws {
        let (channel, pointer) = connectedChannel()
        defer { dispose(channel, pointer) }
        // Accept the metadata request without supplying file bytes.
        pointer.pointee.ClientFormatDataRequest = { _, _ in 0 }
        let name = strdup("FileGroupDescriptorW")!
        defer { free(name) }
        var format = CLIPRDR_FORMAT()
        format.formatId = 0xC010
        format.formatName = name
        withUnsafeMutablePointer(to: &format) { formats in
            var list = CLIPRDR_FORMAT_LIST()
            list.numFormats = 1
            list.formats = formats
            channel.onServerFormatList(list)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(channel.pendingFormat?.formatID, 0xC010)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(Foundation.UUID().uuidString)
        try Data("abc".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = ClipboardChannel.makeFileGroupDescriptor([try XCTUnwrap(ServedFile(url: root))])
        descriptor.withUnsafeBytes { bytes in
            var response = CLIPRDR_FORMAT_DATA_RESPONSE()
            response.common.msgFlags = UInt16(CB_RESPONSE_OK)
            response.common.dataLen = UInt32(descriptor.count)
            response.requestedFormatData = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
            channel.onServerFormatDataResponse(response)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(channel.currentFileOffer()?.bytesTotal, 3)
        XCTAssertEqual(channel.fileDownloadQueue.operationCount, 0)
        XCTAssertFalse(channel.currentDownloadStatus().isActive)
    }

    @MainActor func testBackgroundTextNotificationDoesNotRequestText() {
        let (channel, pointer) = connectedChannel()
        defer { dispose(channel, pointer) }
        pointer.pointee.ClientFormatDataRequest = { _, _ in 0 }
        var format = CLIPRDR_FORMAT()
        format.formatId = UInt32(CF_UNICODETEXT)
        withUnsafeMutablePointer(to: &format) { formats in
            var list = CLIPRDR_FORMAT_LIST()
            list.numFormats = 1
            list.formats = formats
            channel.onServerFormatList(list)
        }
        // Even selecting this channel before the queued work runs must not replay
        // the background notification into the Mac clipboard.
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        let coordinator = ClipboardCoordinator(pasteboard: pb, maySendLocal: { false })
        coordinator.select(channel)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(channel.pendingFormat == nil)
    }

    func testConcurrentSessionWorkersCancelIndependently() throws {
        let a = RDPSession(), b = RDPSession()
        try a.connect(to: "127.0.0.1:1", username: nil, password: nil)
        try b.connect(to: "127.0.0.1:1", username: nil, password: nil)
        a.disconnect()
        b.disconnect()
        let deadline = Date().addingTimeInterval(10)
        while (!a.isQuiescent() || !b.isQuiescent()) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(a.isQuiescent())
        XCTAssertTrue(b.isQuiescent())
    }
}