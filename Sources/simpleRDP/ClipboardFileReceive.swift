// Files are offers, never Mac pasteboard contents. The destination is chosen
// before requesting any bytes. Each worker owns its private staging directory.
import Foundation
import AppKit
import CFreeRDP

extension ClipboardChannel {
    func currentFileOffer() -> RemoteFileOffer? {
        lock.lock()
        defer { lock.unlock() }
        return remoteFileOffer
    }

    func dismissFileOffer(_ id: Foundation.UUID) {
        lock.lock()
        if remoteFileOffer?.id == id { remoteFileOffer = nil }
        lock.unlock()
    }

    func cancelDownloads() {
        lock.lock()
        currentTransfer?.cancel()
        // Remain active until the worker has removed partial files.
        let pending = pendingContents
        pendingContents.removeAll()
        lock.unlock()
        for handler in pending.values { handler(nil) }
    }

    func reportClipboardError(_ error: Error, generation: Foundation.UUID) {
        lock.lock()
        defer { lock.unlock() }
        if remoteGeneration == generation { downloadStatus.error = error.localizedDescription }
    }

    func offerRemoteFiles(_ files: [RemoteClipboardFile], generation: Foundation.UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard remoteGeneration == generation, clip != nil else { return }
        remoteFileOffer = RemoteFileOffer(id: generation, files: files)
    }

    /// Use the offer captured before showing the destination sheet; never accept
    /// a newer clipboard copy accidentally while the user is choosing a folder.
    func downloadRemoteFiles(_ offer: RemoteFileOffer, to destination: URL) {
        precondition(Thread.isMainThread)
        sendLock.lock()
        defer { sendLock.unlock() }
        lock.lock()
        guard clip != nil, remoteGeneration == offer.id, remoteFileOffer?.id == offer.id else {
            downloadStatus.error = "The remote clipboard changed. Copy the files again and retry."
            lock.unlock()
            return
        }
        guard !downloadStatus.isActive, fileDownloadQueue.operationCount == 0 else {
            downloadStatus.error = "Wait for this session’s current download to finish or cancel."
            lock.unlock()
            return
        }
        let transfer = ClipboardTransfer(generation: offer.id)
        currentTransfer = transfer
        remoteFileOffer = nil
        downloadStatus = ClipboardDownloadStatus(isActive: true,
            filesTotal: offer.files.filter { !$0.isDirectory }.count, bytesTotal: offer.bytesTotal)
        lock.unlock()
        let accessed = destination.startAccessingSecurityScopedResource()
        fileDownloadQueue.addOperation { [self] in
            defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
            download(offer.files, transfer: transfer, destination: destination)
        }
    }

    private func download(_ files: [RemoteClipboardFile], transfer: ClipboardTransfer, destination: URL) {
        var area: ClipboardStagingArea?
        var preserveStaging = false
        defer {
            if let area, !preserveStaging {
                do { try FileManager.default.removeItem(at: area.url) }
                catch {
                    updateStatus(for: transfer) {
                        $0.error = "Could not remove the temporary download folder at \(area.url.path): \(error.localizedDescription)"
                    }
                }
            }
            lock.lock()
            if currentTransfer?.id == transfer.id {
                currentTransfer = nil
                downloadStatus.isActive = false
            }
            lock.unlock()
        }
        do {
            guard !transfer.isCancelled else { throw CancellationError() }
            let stage = try ClipboardStagingArea(parent: destination, prefix: ".simpleRDP-download-")
            area = stage
            let free = try stage.url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
            if let free, files.reduce(UInt64(0), { $0 + $1.size }) > UInt64(max(0, free)) {
                throw ValidationError("There is not enough disk space at the selected destination.")
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
            guard transfer.beginCommit() else { throw CancellationError() }
            var names = Set<String>()
            let urls = files.compactMap { file -> URL? in
                names.insert(file.topLevel).inserted ? stage.url.appendingPathComponent(file.topLevel) : nil
            }
            let result = moveStagedFiles(urls, to: destination)
            if !result.remaining.isEmpty {
                // Preserve completed files when finalization fails. This location
                // is inside the selected destination, never an application cache.
                preserveStaging = true
                throw ValidationError(result.errors.joined(separator: "\n")
                    + "\nUnsaved files are preserved at: \(stage.url.path)")
            }
            updateStatus(for: transfer) { $0.savedDirectory = destination }
        } catch {
            if !transfer.isCancelled {
                updateStatus(for: transfer) { $0.error = error.localizedDescription }
            }
        }
    }

    private func updateStatus(for transfer: ClipboardTransfer, _ mutate: (inout ClipboardDownloadStatus) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard currentTransfer?.id == transfer.id else { return }
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