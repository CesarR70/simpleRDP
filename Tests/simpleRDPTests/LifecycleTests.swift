import Foundation
#if !STANDALONE_TESTS
import XCTest
@testable import simpleRDP
#endif

final class LifecycleTests: XCTestCase {
    @MainActor func testViewModelReleasesWithoutStreamCycle() {
        weak var weakModel: SessionViewModel?
        var model: SessionViewModel? = SessionViewModel()
        weakModel = model
        model = nil
        XCTAssertTrue(weakModel == nil)
    }

    func testCancelledConnectionCleansUpAndCanBeRetried() throws {
        let session = RDPSession()
        for _ in 0..<3 {
            // Immediate cancellation does not require an RDP test server.
            try session.connect(to: "127.0.0.1:1", username: nil, password: nil)
            session.disconnect()
            let deadline = Date().addingTimeInterval(10)
            while session.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertFalse(session.isRunning, "Connection worker failed to exit after cancellation")
            XCTAssertTrue(session.isQuiescent())
        }
    }

    func testDetachedClipboardDoesNotSend() {
        let channel = ClipboardChannel()
        channel.detach()
        XCTAssertTrue(channel.clipSnapshot() == nil)
        channel.cancelDownloads()
        channel.detach()
        XCTAssertFalse(channel.currentDownloadStatus().isActive)
    }

    func testRefusedConnectionCleansUp() throws {
        let session = RDPSession()
        try session.connect(to: "127.0.0.1:1", username: nil, password: nil)
        let deadline = Date().addingTimeInterval(10)
        while session.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if session.isRunning { session.disconnect() }
        XCTAssertFalse(session.isRunning, "Refused loopback connection should complete and clean up")
        XCTAssertTrue(session.clipboard.clipSnapshot() == nil)
    }
}