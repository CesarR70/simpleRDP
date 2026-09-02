//
// ClipboardFileReceive.swift — server → Mac FILE clipboard (CLIPRDR).
//
// Flow (reverse of ClipboardChannel's Mac→server path):
//   1. Server announces FileGroupDescriptorW in its format list. Its format ID
//      is server-assigned, so we match by NAME.
//   2. We eagerly fetch the (small) descriptor list and parse the
//      FILEDESCRIPTORW array — a FLAT list: directories arrive pre-flattened
//      with relative paths in cFileName (no "list directory" PDU exists).
//   3. We download the referenced files (FileContents RANGE requests, 4 MB
//      chunks, correlated by streamId) into a cache dir, on a serial
//      background queue.
//   4. We put the REAL local file URLs on the Mac pasteboard.
//
// Note on the design: the first cut used NSFilePromiseProvider (lazy
// download on paste). Finder does not honor file promises on plain ⌘V, so
// the paste silently did nothing. Eager download to a cache dir + real file
// URLs is what Finder reliably pastes, and matches clipboard "snapshot at
// copy time" semantics.
//

import Foundation
import AppKit
import CFreeRDP

/// What an outstanding ClientFormatDataRequest asked for.
enum ClipboardDataRequestKind {
    case text
    case fileGroup
}

/// One entry in the server's FileGroupDescriptorW (a single file or a
/// directory marker within the flattened tree).
struct RemoteClipboardFile {
    let listIndex: UInt32
    let relativePath: String // normalized to '/' separators
    let size: UInt64
    let isDirectory: Bool

    var name: String {
        relativePath.split(separator: "/").last.map(String.init) ?? relativePath
    }

    var topLevel: String {
        relativePath.split(separator: "/").first.map(String.init) ?? relativePath
    }
}

/// A top-level copied item (what the user sees): either a single file or a
/// directory plus every file beneath it.
struct RemoteClipboardItem {
    let name: String
    var isDirectory: Bool
    var files: [RemoteClipboardFile]
}

// MARK: - FILEDESCRIPTORW parsing (MS-RDPECLIP 2.2.5.2.3.1)

/// Parses a FileGroupDescriptorW payload: cItems (UInt32) + 592-byte
/// FILEDESCRIPTORW entries. Mirror of ClipboardChannel.makeFileGroupDescriptor.
func parseFileGroupDescriptor(_ data: Data) -> [RemoteClipboardFile] {
    func u32(_ at: Int) -> UInt32 {
        UInt32(data[at]) | UInt32(data[at + 1]) << 8
            | UInt32(data[at + 2]) << 16 | UInt32(data[at + 3]) << 24
    }

    guard data.count >= 4 else { return [] }
    let count = min(Int(u32(0)), 10_000)
    var files: [RemoteClipboardFile] = []
    var base = 4

    for index in 0..<count {
        guard base + 592 <= data.count else { break }

        let attributes = u32(base + 36)                       // fileAttributes
        let size = UInt64(u32(base + 64)) << 32               // fileSizeHigh
            | UInt64(u32(base + 68))                          // fileSizeLow

        // cFileName at offset 72: WCHAR[260], UTF-16LE, NUL-terminated.
        var units = [UInt16]()
        var p = base + 72
        let end = base + 592
        while p + 1 < end {
            let unit = UInt16(data[p]) | UInt16(data[p + 1]) << 8
            if unit == 0 { break }
            units.append(unit)
            p += 2
        }
        let rawName = String(utf16CodeUnits: units, count: units.count)
        let path = rawName.replacingOccurrences(of: "\\", with: "/")
        if !path.isEmpty {
            files.append(RemoteClipboardFile(listIndex: UInt32(index),
                                             relativePath: path,
                                             size: size,
                                             isDirectory: attributes & 0x10 != 0))
        }
        base += 592
    }
    return files
}

/// Groups the flat descriptor list into top-level items (single files stay
/// single; a directory gathers every file whose path starts with its name).
func groupRemoteClipboardItems(_ files: [RemoteClipboardFile]) -> [RemoteClipboardItem] {
    var itemsByName: [String: RemoteClipboardItem] = [:]
    var order: [String] = []

    for file in files {
        let top = file.topLevel
        if itemsByName[top] == nil {
            order.append(top)
            itemsByName[top] = RemoteClipboardItem(name: top, isDirectory: false, files: [])
        }
        var item = itemsByName[top]!
        if file.isDirectory || file.relativePath.contains("/") {
            item.isDirectory = true
        }
        item.files.append(file)
        itemsByName[top] = item
    }
    return order.compactMap { itemsByName[$0] }
}

// MARK: - Download status (polled by SessionView's refresh timer)

/// Snapshot of an in-progress server→Mac clipboard download.
struct ClipboardDownloadStatus: Equatable {
    var isActive = false
    var currentFile = ""
    var filesDone = 0
    var filesTotal = 0
    var bytesDone: UInt64 = 0
    var bytesTotal: UInt64 = 0

    static let idle = ClipboardDownloadStatus()
}

// MARK: - Pasteboard publishing

extension ClipboardChannel {
    /// Where server→Mac clipboard files are staged. Wiped on every new offer
    /// and on application quit (see AppDelegate).
    static var clipboardCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("simpleRDP/RemoteClipboard", isDirectory: true)
    }

    /// Housekeeping: remove everything under the clipboard cache dir.
    static func cleanClipboardCache() {
        try? FileManager.default.removeItem(at: clipboardCacheDirectory)
    }

    /// Whether there are staged remote files ready to be saved/moved.
    /// Read on the main thread (SessionView polls it on its refresh timer).
    /// (`stagedURLs` itself is a stored property on the class — extensions
    /// can't hold stored properties.)
    var hasStagedFiles: Bool { !stagedURLs.isEmpty }

    /// Move-on-paste support. When the user saves a staged remote file, we
    /// MOVE (rename) it out of the cache into `destinationDir` instead of
    /// copying — a rename on the same volume is metadata-only, so we avoid
    /// writing the bytes a second time.
    ///
    /// Note: pasting into another app (Finder ⌘V) still COPIES, because we
    /// can't intercept another process's paste. This explicit Save-to action
    /// is the no-double-write path.
    @MainActor
    @discardableResult
    func moveStaged(to destinationDir: URL) -> Bool {
        guard !stagedURLs.isEmpty else { return false }
        let fm = FileManager.default
        var ok = true
        for src in stagedURLs {
            var dest = destinationDir.appendingPathComponent(src.lastPathComponent)
            // Avoid clobbering an existing file: append -1, -2, …
            var n = 1
            while fm.fileExists(atPath: dest.path) {
                let stem = src.deletingPathExtension().lastPathComponent
                let ext = src.pathExtension
                let name = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
                dest = destinationDir.appendingPathComponent(name)
                n += 1
            }
            do {
                try fm.moveItem(at: src, to: dest) // rename — no second write
                print("[Clipboard] moved \(src.lastPathComponent) -> \(dest.path)")
            } catch {
                print("[Clipboard] move failed, falling back to copy: \(error.localizedDescription)")
                do { try fm.copyItem(at: src, to: dest) } catch { ok = false }
            }
        }
        stagedURLs = []
        Self.cleanClipboardCache()
        return ok
    }

    /// Downloads the server's files into the cache dir, then puts the real
    /// local file URLs on the Mac pasteboard. Called on the main thread when
    /// a server file-group descriptor arrives; returns immediately.
    func offerRemoteFiles(_ files: [RemoteClipboardFile]) {
        let items = groupRemoteClipboardItems(files)
        guard !items.isEmpty else { return }

        let totalBytes = items.reduce(UInt64(0)) { sum, item in
            sum + item.files.reduce(UInt64(0)) { $0 + $1.size }
        }
        updateDownloadStatus {
            $0 = ClipboardDownloadStatus(isActive: true, currentFile: "",
                                         filesDone: 0, filesTotal: items.count,
                                         bytesDone: 0, bytesTotal: totalBytes)
        }

        fileDownloadQueue.cancelAllOperations()
        resetDownloadCancellation()
        fileDownloadQueue.addOperation { [self] in
            let fm = FileManager.default
            let cacheDir = Self.clipboardCacheDirectory
            try? fm.removeItem(at: cacheDir)
            try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

            var urls: [URL] = []
            for item in items {
                if isDownloadCancelled { break }
                updateDownloadStatus { $0.currentFile = item.name }
                let dest = cacheDir.appendingPathComponent(item.name)
                let totalKB = item.files.reduce(UInt64(0)) { $0 + $1.size } / 1024
                if let error = writeRemoteItem(item, to: dest) {
                    if isDownloadCancelled { break }
                    print("[Clipboard] download of \(item.name) failed: \(error.localizedDescription)")
                } else {
                    print("[Clipboard] fetched \(item.name) (\(totalKB) KB) from server")
                    urls.append(dest)
                }
                updateDownloadStatus { $0.filesDone += 1 }
            }
            updateDownloadStatus { $0.isActive = false }

            // If cancelled, don't publish anything to the pasteboard — the
            // user aborted, and cancelDownloads() already cleared the cache.
            if isDownloadCancelled { return }

            DispatchQueue.main.async {
                guard !urls.isEmpty else { return }
                self.stagedURLs = urls
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects(urls as [NSURL])
                self.swallowPasteboardChange() // don't echo our own write back
            }
        }
    }
}


// MARK: - Download engine (ClipboardChannel)

extension ClipboardChannel {
    /// Writes a top-level remote item (file or directory tree) to a local URL.
    /// Called on the promise delegate's serial queue; blocks per chunk.
    func writeRemoteItem(_ item: RemoteClipboardItem, to url: URL) -> Error? {
        if item.isDirectory {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch { return error }

            for file in item.files where !file.isDirectory {
                if isDownloadCancelled {
                    return NSError(domain: "simpleRDP.clipboard", code: 5,
                                   userInfo: [NSLocalizedDescriptionKey: "Download cancelled"])
                }
                // Strip the top-level component — `url` IS that directory.
                var sub = String(file.relativePath.dropFirst(item.name.count))
                if sub.hasPrefix("/") { sub.removeFirst() }
                guard !sub.isEmpty else { continue }
                let dest = url.appendingPathComponent(sub)
                if let error = downloadToFile(listIndex: file.listIndex, size: file.size, to: dest) {
                    return error
                }
            }
            return nil
        }

        guard let file = item.files.first else {
            return NSError(domain: "simpleRDP.clipboard", code: 3,
                           userInfo: [NSLocalizedDescriptionKey: "Empty remote clipboard item"])
        }
        return downloadToFile(listIndex: file.listIndex, size: file.size, to: url)
    }

    /// Downloads one remote file in 4 MB FileContents RANGE chunks.
    func downloadToFile(listIndex: UInt32, size: UInt64, to url: URL) -> Error? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
        } catch { return error }

        guard let handle = try? FileHandle(forWritingTo: url) else {
            return NSError(domain: "simpleRDP.clipboard", code: 4,
                           userInfo: [NSLocalizedDescriptionKey: "Cannot write \(url.lastPathComponent)"])
        }
        defer { try? handle.close() }

        var offset: UInt64 = 0
        let maxChunk: UInt64 = 4 * 1024 * 1024
        while offset < size {
            if isDownloadCancelled {
                return NSError(domain: "simpleRDP.clipboard", code: 5,
                               userInfo: [NSLocalizedDescriptionKey: "Download cancelled"])
            }
            let want = UInt32(min(maxChunk, size - offset))
            guard let data = requestFileContentsSync(listIndex: listIndex, offset: offset, count: want),
                  !data.isEmpty else {
                return NSError(domain: "simpleRDP.clipboard", code: 2,
                               userInfo: [NSLocalizedDescriptionKey: "Failed to fetch \(url.lastPathComponent) from the server"])
            }
            do {
                try handle.write(contentsOf: data)
            } catch { return error }
            offset += UInt64(data.count)
            updateDownloadStatus { $0.bytesDone &+= UInt64(data.count) }
        }
        return nil
    }
}


// MARK: - Request/response plumbing (ClipboardChannel)

extension ClipboardChannel {
    private func requestFileContentsSync(listIndex: UInt32, offset: UInt64, count: UInt32) -> Data? {
        final class Box: @unchecked Sendable { var data: Data? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        requestFileContents(listIndex: listIndex, offset: offset, count: count) { data in
            box.data = data
            sem.signal()
        }
        if sem.wait(timeout: .now() + 30) == .timedOut { return nil }
        return box.data
    }

    /// Sends a CB_FILECONTENTS_REQUEST (RANGE). The response arrives on the
    /// event-loop thread and is correlated back via streamId.
    func requestFileContents(listIndex: UInt32, offset: UInt64, count: UInt32,
                             completion: @escaping (Data?) -> Void) {
        guard let clip = clipSnapshot() else { completion(nil); return }

        lock.lock()
        let streamId = nextStreamId
        nextStreamId &+= 1
        pendingContents[streamId] = completion
        lock.unlock()

        var request = CLIPRDR_FILE_CONTENTS_REQUEST()
        request.streamId = streamId
        request.listIndex = listIndex
        request.dwFlags = UInt32(FILECONTENTS_RANGE)
        request.nPositionLow = UInt32(offset & 0xFFFF_FFFF)
        request.nPositionHigh = UInt32(offset >> 32)
        request.cbRequested = count
        let rc = clip.pointee.ClientFileContentsRequest?(clip, &request)
        if rc == nil || rc != 0 {
            lock.lock()
            let handler = pendingContents.removeValue(forKey: streamId)
            lock.unlock()
            handler?(nil)
        }
    }

    /// ServerFileContentsResponse (event-loop thread): completes the pending
    /// request matching the streamId. FAIL flag → nil; anything else is data.
    func onServerFileContentsResponse(_ response: CLIPRDR_FILE_CONTENTS_RESPONSE) {
        let failed = response.common.msgFlags & UInt16(CB_RESPONSE_FAIL) != 0
        var data: Data?
        if !failed {
            if response.cbRequested > 0, let ptr = response.requestedData {
                data = Data(bytes: ptr, count: Int(response.cbRequested))
            } else {
                data = Data()
            }
        }
        lock.lock()
        let handler = pendingContents.removeValue(forKey: response.streamId)
        lock.unlock()
        handler?(data)
    }
}



