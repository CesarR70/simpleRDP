// Each transfer owns its directory until completion. Only a current offer may
// publish, and only if the user has not replaced the local pasteboard meanwhile.
import Foundation
import AppKit
import CFreeRDP

extension ClipboardChannel {
    static var clipboardCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("simpleRDP/RemoteClipboard", isDirectory: true)
    }
    var hasStagedFiles: Bool { !stagedURLs.isEmpty }

    // Startup only: never remove the shared parent while workers are writing.
    static func cleanClipboardCache() {
        try? FileManager.default.removeItem(at: clipboardCacheDirectory)
    }

    func clearStagedFiles() {
        precondition(Thread.isMainThread)
        if let directory = stagedDirectory { try? FileManager.default.removeItem(at: directory) }
        stagedDirectory = nil
        stagedURLs = []
    }

    func pruneStagedURLs() {
        precondition(Thread.isMainThread)
        stagedURLs.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        if stagedURLs.isEmpty { clearStagedFiles() }
    }

    @discardableResult
    func moveStaged(to directory: URL) -> Bool {
        precondition(Thread.isMainThread)
        let accessed = directory.startAccessingSecurityScopedResource()
        defer { if accessed { directory.stopAccessingSecurityScopedResource() } }
        let ownsPasteboard = NSPasteboard.general.changeCount == stagedPasteboardChange
        let result = moveStagedFiles(stagedURLs, to: directory)
        stagedURLs = result.remaining
        if stagedURLs.isEmpty { clearStagedFiles() }
        if ownsPasteboard, !result.destinations.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects((result.destinations + result.remaining) as [NSURL])
            swallowPasteboardChange()
            stagedPasteboardChange = pb.changeCount
        }
        updateDownloadStatus { $0.error = result.errors.isEmpty ? nil : result.errors.joined(separator: "\n") }
        return result.errors.isEmpty && !result.destinations.isEmpty
    }

    func cancelDownloads() {
        lock.lock()
        currentTransfer?.cancel()
        currentTransfer = nil
        let pending = pendingContents
        pendingContents.removeAll()
        lock.unlock()
        for handler in pending.values { handler(nil) }
        updateDownloadStatus { $0 = .idle }
    }

    func reportClipboardError(_ error: Error, generation: Foundation.UUID) {
        lock.lock()
        defer { lock.unlock() }
        if remoteGeneration == generation { downloadStatus.error = error.localizedDescription }
    }

    func offerRemoteFiles(_ files: [RemoteClipboardFile], generation: Foundation.UUID, pasteboardChange: Int) {
        precondition(Thread.isMainThread)
        guard NSPasteboard.general.changeCount == pasteboardChange else { return }
        lock.lock()
        guard remoteGeneration == generation, clip != nil else { lock.unlock(); return }
        lock.unlock()
        cancelDownloads()
        clearStagedFiles()
        let transfer = ClipboardTransfer(generation: generation, pasteboardChange: pasteboardChange)
        lock.lock()
        guard remoteGeneration == generation else { lock.unlock(); return }
        currentTransfer = transfer
        lock.unlock()
        updateDownloadStatus {
            $0 = ClipboardDownloadStatus(isActive: true, filesTotal: files.filter { !$0.isDirectory }.count,
                                         bytesTotal: files.reduce(0) { $0 + $1.size })
        }
        fileDownloadQueue.addOperation { [self] in download(files, transfer: transfer) }
    }

    private func download(_ files: [RemoteClipboardFile], transfer: ClipboardTransfer) {
        var area: ClipboardStagingArea?
        do {
            guard !transfer.isCancelled else { return }
            let stage = try ClipboardStagingArea(parent: Self.clipboardCacheDirectory)
            area = stage
            let free = try stage.url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
            if let free, files.reduce(UInt64(0), { $0 + $1.size }) > UInt64(max(0, free)) {
                throw ValidationError("There is not enough disk space for this clipboard download.")
            }
            for file in files {
                guard !transfer.isCancelled else { throw CancellationError() }
                updateStatus(for: transfer) { $0.currentFile = file.relativePath }
                guard let handle = try stage.create(file) else { continue }
                defer { try? handle.close() }
                var offset: UInt64 = 0
                while offset < file.size {
                    guard !transfer.isCancelled else { throw CancellationError() }
                    let wanted = UInt32(min(4 * 1024 * 1024, file.size - offset))
                    guard let data = requestFileContentsSync(listIndex: file.listIndex, offset: offset,
                                                              count: wanted, transfer: transfer),
                          !data.isEmpty, data.count <= Int(wanted) else {
                        throw ValidationError("The server did not return valid data for \(file.relativePath).")
                    }
                    guard !transfer.isCancelled else { throw CancellationError() }
                    try handle.write(contentsOf: data)
                    offset += UInt64(data.count)
                    updateStatus(for: transfer) { $0.bytesDone += UInt64(data.count) }
                }
                updateStatus(for: transfer) { $0.filesDone += 1 }
            }
            var names = Set<String>()
            let urls = files.compactMap { file -> URL? in
                names.insert(file.topLevel).inserted ? stage.url.appendingPathComponent(file.topLevel) : nil
            }
            DispatchQueue.main.async { [self] in
                lock.lock()
                let valid = currentTransfer?.id == transfer.id && remoteGeneration == transfer.generation
                lock.unlock()
                guard valid, !transfer.isCancelled,
                      NSPasteboard.general.changeCount == transfer.pasteboardChange else {
                    try? FileManager.default.removeItem(at: stage.url)
                    updateStatus(for: transfer) { $0 = .idle }
                    return
                }
                stagedDirectory = stage.url
                stagedURLs = urls
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects(urls as [NSURL])
                swallowPasteboardChange()
                stagedPasteboardChange = pb.changeCount
                updateStatus(for: transfer) { $0.isActive = false }
            }
        } catch {
            if let area { try? FileManager.default.removeItem(at: area.url) }
            updateStatus(for: transfer) {
                $0.isActive = false
                if !transfer.isCancelled { $0.error = error.localizedDescription }
            }
        }
    }

    private func updateStatus(for transfer: ClipboardTransfer, _ mutate: (inout ClipboardDownloadStatus) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard currentTransfer?.id == transfer.id, !transfer.isCancelled else { return }
        mutate(&downloadStatus)
    }

    private func requestFileContentsSync(listIndex: UInt32, offset: UInt64, count: UInt32,
                                         transfer: ClipboardTransfer) -> Data? {
        final class ResponseBox: @unchecked Sendable {
            let lock = NSLock()
            var data: Data?
            func set(_ value: Data?) { lock.lock(); data = value; lock.unlock() }
            func get() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
        }
        let box = ResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        sendLock.lock()
        guard let clip = clipSnapshot(), !transfer.isCancelled else { sendLock.unlock(); return nil }
        lock.lock()
        let streamID = nextStreamId
        nextStreamId &+= 1
        pendingContents[streamID] = { data in box.set(data); semaphore.signal() }
        lock.unlock()
        var request = CLIPRDR_FILE_CONTENTS_REQUEST()
        request.streamId = streamID
        request.listIndex = listIndex
        request.dwFlags = UInt32(FILECONTENTS_RANGE)
        request.nPositionLow = UInt32(truncatingIfNeeded: offset)
        request.nPositionHigh = UInt32(offset >> 32)
        request.cbRequested = count
        let rc = clip.pointee.ClientFileContentsRequest?(clip, &request)
        sendLock.unlock()
        let deadline = Date().addingTimeInterval(30)
        var received = false
        if rc == 0 {
            while !transfer.isCancelled && Date() < deadline {
                if semaphore.wait(timeout: .now() + 0.1) == .success { received = true; break }
            }
        }
        lock.lock()
        pendingContents.removeValue(forKey: streamID)
        lock.unlock()
        return received && !transfer.isCancelled ? box.get() : nil
    }

    func onServerFileContentsResponse(_ response: CLIPRDR_FILE_CONTENTS_RESPONSE) {
        lock.lock()
        let handler = pendingContents.removeValue(forKey: response.streamId)
        lock.unlock()
        guard let handler else { return }
        guard response.common.msgFlags & UInt16(CB_RESPONSE_FAIL) == 0,
              response.cbRequested <= 4 * 1024 * 1024,
              response.common.dataLen >= 4,
              response.cbRequested <= response.common.dataLen - 4 else { handler(nil); return }
        if response.cbRequested == 0 { handler(Data()); return }
        guard let pointer = response.requestedData else { handler(nil); return }
        handler(Data(bytes: pointer, count: Int(response.cbRequested)))
    }
}