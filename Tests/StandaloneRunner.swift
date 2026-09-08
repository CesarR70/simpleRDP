// The Command Line Tools ship neither XCTest nor Swift Testing. This runner
// executes the same regression methods without requiring the full Xcode IDE.
import Foundation

class XCTestCase {}

func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) rethrows {
    if try !value() { fatalError("Assertion failed: \(message)", file: file, line: line) }
}
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) rethrows {
    if try value() { fatalError("Expected false: \(message)", file: file, line: line) }
}
func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
                                 file: StaticString = #file, line: UInt = #line) {
    do {
        let a = try lhs(), b = try rhs()
        if a != b { fatalError("Expected \(a) == \(b)", file: file, line: line) }
    } catch { fatalError("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: String = "",
                            file: StaticString = #file, line: UInt = #line) {
    do { _ = try expression() } catch { return }
    fatalError("Expected an error: \(message)", file: file, line: line)
}
func XCTAssertNotNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    if value == nil { fatalError("Expected non-nil", file: file, line: line) }
}
func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw ValidationError("Expected non-nil value") }
    return value
}

@main struct RegressionRunner {
    @MainActor static func main() throws {
        let suite = SafetyTests()
        try suite.testAddressValidation()
        suite.testUnsafeClipboardPathsRejected()
        try suite.testDescriptorValidation()
        try suite.testStagingRejectsSymlinkEscape()
        try suite.testFailedSavePreservesSource()
        try suite.testSaveCollisionDoesNotOverwrite()
        suite.testWheelSignedEncoding()
        suite.testTransferCancellationDoesNotReset()
        try suite.testFavoriteDraftPreservesOptions()
        try suite.testCorruptFavoritesNeverOverwritten()
        let lifecycle = LifecycleTests()
        lifecycle.testViewModelReleasesWithoutStreamCycle()
        try lifecycle.testCancelledConnectionCleansUpAndCanBeRetried()
        lifecycle.testDetachedClipboardDoesNotSend()
        try lifecycle.testRefusedConnectionCleansUp()
        let multi = MultiSessionTests()
        multi.testRemoteTextOwnershipAndNoEcho()
        multi.testLocalCopyRoutesOnceAndKeepsSnapshot()
        try multi.testRemoteFileOfferIsLazyAndStaleAcceptanceFails()
        try multi.testDestinationFirstDownloadLeavesNoStagingOrPasteboardWrite()
        try multi.testCancelledDownloadRemovesPartialDirectory()
        try multi.testTabLifecycleIsIndependent()
        multi.testCommitCannotBeCancelledHalfwayThroughLocalSave()
        try multi.testProtocolFileNotificationOnlyFetchesMetadata()
        multi.testBackgroundTextNotificationDoesNotRequestText()
        try multi.testConcurrentSessionWorkersCancelIndependently()
        print("PASS: 24 regression tests (same test methods as the XCTest target).")
    }
}