//
// ClipboardChannel.swift — CLIPRDR (clipboard virtual channel) bridge between
// NSPasteboard and the RDP server. Implements Milestone 4 of the plan:
//   - Mac → server: text AND file copy/paste (FileGroupDescriptorW +
//     FileContents streaming — the same PDUs xrdp's chansrv consumes when it
//     materializes files under ~/thinclient_drives/.clipboard/).
//   - Server → Mac: text (fetched eagerly when the server announces a format
//     list; server-side files are left for a later milestone).
//
// Threading: channel callbacks arrive on FreeRDP's event-loop thread.
// NSPasteboard is only touched on the main thread (callbacks hop via
// DispatchQueue.main). Channel *send* functions converge on transport_write,
// which is internally locked in FreeRDP 3.x — same story as RemoteInput.
//
// Discovery: the cliprdr channel add-in creates its CliprdrClientContext
// during freerdp_connect. We learn about it via the PubSub
// ChannelConnected event (installed by installClipboardChannelHooks, which
// must run AFTER freerdp_context_new and BEFORE freerdp_connect).
//

import Foundation
import AppKit
import CFreeRDP

final class ClipboardChannel: @unchecked Sendable {
    /// Named formats we advertise. IDs in 0xC000+ are client-assigned; the
    /// server matches on the NAME, per MS-RDPECLIP.
    static let fileGroupDescriptorFormatId: UInt32 = 0xC001 // "FileGroupDescriptorW"
    static let fileContentsFormatId: UInt32       = 0xC002 // "FileContents"

    let lock = NSLock()

    /// The channel's client context. Valid while the channel is connected.
    var clip: UnsafeMutablePointer<CliprdrClientContext>?

    /// Server general capability flags (from ServerCapabilities).
    var serverGeneralFlags: UInt32 = 0
    var sawServerCapabilities = false

    /// Files captured when we last announced a file list; streamId == index.
    var servedFiles: [ServedFile] = []

    // MARK: - Server → Mac receive state

    /// Server-assigned format ID for "FileGroupDescriptorW" in the most recent
    /// server format list (nil when the server clipboard holds no files).
    var remoteFileGroupFormatId: UInt32?

    /// Flattened file list from the server's last FileGroupDescriptorW.
    var remoteFiles: [RemoteClipboardFile] = []

    /// What our outstanding ClientFormatDataRequest asked for.
    var pendingDataRequest: ClipboardDataRequestKind?

    /// In-flight ClientFileContentsRequests, keyed by streamId.
    var pendingContents: [UInt32: (Data?) -> Void] = [:]
    var nextStreamId: UInt32 = 1

    /// Serial queue for server→Mac file downloads. Serial so a multi-item
    /// copy doesn't interleave FileContents requests, and so downloads don't
    /// block the event-loop thread (which answers those requests).
    let fileDownloadQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "simpleRDP.clipboard-downloads"
        q.maxConcurrentOperationCount = 1
        return q
    }()

    /// The top-level cached items from the most recent server→Mac download
    /// (real file URLs inside `clipboardCacheDirectory`). Main-thread only.
    /// (Stored here, not in ClipboardFileReceive.swift's extension — Swift
    /// extensions cannot hold stored properties. Setter is internal because the
    /// writes live in ClipboardFileReceive.swift.)
    internal(set) var stagedURLs: [URL] = []

    /// Download progress snapshot for the UI. Guarded by `lock`; SessionView
    /// polls it on its existing refresh timer (no observation machinery).
    private var downloadStatus = ClipboardDownloadStatus()

    /// Cooperative-cancellation flag for in-flight downloads. Guarded by
    /// `lock`; checked between chunks in the download loop so a cancelled
    /// large copy stops promptly (cancelling the OperationQueue alone won't
    /// interrupt a blocking downloadToFile that's already running).
    private var downloadCancelled = false

    var isDownloadCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return downloadCancelled
    }

    /// Cancel any in-progress server→Mac download and clear the staged cache.
    /// Safe to call from the main thread (the Cancel button).
    func cancelDownloads() {
        lock.lock()
        downloadCancelled = true
        let pending = pendingContents
        pendingContents.removeAll()
        lock.unlock()
        // Interrupt any blocking requestFileContentsSync semaphores.
        for handler in pending.values { handler(nil) }
        fileDownloadQueue.cancelAllOperations()
        updateDownloadStatus { $0 = .idle }
        DispatchQueue.main.async {
            self.stagedURLs = []
            Self.cleanClipboardCache()
        }
        print("[Clipboard] download cancelled by user; cache cleared")
    }

    /// Reset the cancellation flag when a new download begins.
    func resetDownloadCancellation() {
        lock.lock()
        downloadCancelled = false
        lock.unlock()
    }

    func currentDownloadStatus() -> ClipboardDownloadStatus {
        lock.lock()
        defer { lock.unlock() }
        return downloadStatus
    }

    func updateDownloadStatus(_ mutate: (inout ClipboardDownloadStatus) -> Void) {
        lock.lock()
        mutate(&downloadStatus)
        lock.unlock()
    }

    // MARK: - Pasteboard monitoring (main thread)

    var monitorTimer: Timer?
    var lastChangeCount = 0

    var serverSupportsFileClip: Bool {
        sawServerCapabilities && (serverGeneralFlags & UInt32(CB_STREAM_FILECLIP_ENABLED)) != 0
    }

    // MARK: - Lifecycle

    /// Called from the PubSub ChannelConnected handler (event-loop thread).
    func attach(_ clip: UnsafeMutablePointer<CliprdrClientContext>) {
        lock.lock()
        self.clip = clip
        serverGeneralFlags = 0
        sawServerCapabilities = false
        servedFiles = []
        lock.unlock()

        clip.pointee.custom = Unmanaged.passUnretained(self).toOpaque()
        installClipboardCallbacks(on: clip)

        DispatchQueue.main.async { self.startMonitoring() }
    }

    /// Called on disconnect / channel teardown. Idempotent.
    func detach() {
        lock.lock()
        clip = nil
        servedFiles = []
        remoteFileGroupFormatId = nil
        remoteFiles = []
        pendingDataRequest = nil
        let pending = pendingContents
        pendingContents.removeAll()
        lock.unlock()
        // Fail any in-flight downloads so their semaphores release.
        fileDownloadQueue.cancelAllOperations()
        updateDownloadStatus { $0 = .idle }
        for handler in pending.values { handler(nil) }
        DispatchQueue.main.async { self.stopMonitoring() }
    }

    func clipSnapshot() -> UnsafeMutablePointer<CliprdrClientContext>? {
        lock.lock()
        defer { lock.unlock() }
        return clip
    }

    // MARK: - Pasteboard monitoring

    func startMonitoring() {
        lastChangeCount = NSPasteboard.general.changeCount
        guard monitorTimer == nil else { return }
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkLocalClipboard()
        }
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    func checkLocalClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        announceLocalFormats()
    }

    /// Swallow the next monitor tick: call after WE mutate the pasteboard
    /// from remote data, so the change doesn't echo back to the server.
    func swallowPasteboardChange() {
        lastChangeCount = NSPasteboard.general.changeCount
    }
}

// MARK: - Served file model

struct ServedFile {
    let url: URL
    let name: String
    let size: UInt64
    let isReadOnly: Bool
    let lastWriteTime: UInt64 // Windows FILETIME (100ns ticks since 1601)

    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey,
                                                             .fileSizeKey,
                                                             .contentModificationDateKey,
                                                             .isWritableKey]),
              values.isRegularFile == true
        else { return nil } // v1: directories are skipped
        self.url = url
        self.name = url.lastPathComponent
        self.size = UInt64(values.fileSize ?? 0)
        self.isReadOnly = !(values.isWritable ?? true)
        let modified = values.contentModificationDate ?? Date()
        self.lastWriteTime = UInt64((modified.timeIntervalSince1970 + 11_644_473_600) * 10_000_000)
    }
}

// MARK: - Instance → ClipboardChannel registry

/// Same problem as FramebufferRegistry: C callbacks can't capture Swift
/// context, so the PubSub handler finds the channel via the instance address.
enum ClipboardRegistry {
    private static let lock = NSLock()
    private static var map: [Int: ClipboardChannel] = [:]

    static func register(_ channel: ClipboardChannel, for instance: UnsafeMutablePointer<freerdp>) {
        lock.lock()
        map[Int(bitPattern: instance)] = channel
        lock.unlock()
    }

    static func unregister(for instance: UnsafeMutablePointer<freerdp>) {
        lock.lock()
        map.removeValue(forKey: Int(bitPattern: instance))
        lock.unlock()
    }

    static func channel(for instance: UnsafeMutablePointer<freerdp>) -> ClipboardChannel? {
        lock.lock()
        defer { lock.unlock() }
        return map[Int(bitPattern: instance)]
    }
}

// MARK: - Incoming channel events (called on the FreeRDP event-loop thread)

extension ClipboardChannel {
    /// Server advertised its capabilities; remember whether it speaks file clip.
    func onServerCapabilities(_ caps: CLIPRDR_CAPABILITIES) {
        guard caps.cCapabilitiesSets > 0, let sets = caps.capabilitySets,
              sets[0].capabilitySetType == UInt16(CB_CAPSTYPE_GENERAL) else { return }
        let general = UnsafeRawPointer(sets)!
            .assumingMemoryBound(to: CLIPRDR_GENERAL_CAPABILITY_SET.self)
        lock.lock()
        serverGeneralFlags = general.pointee.generalFlags
        sawServerCapabilities = true
        lock.unlock()
    }

    /// Clipboard channel is live: answer with our capabilities, then announce
    /// whatever is currently on the Mac pasteboard.
    func onMonitorReady() {
        sendCapabilities()
        DispatchQueue.main.async { self.announceLocalFormats() }
    }

    /// Server's clipboard changed. Acknowledge (mandatory — some servers stall
    /// without it), then eagerly fetch the payload descriptor: files win over
    /// text (a file copy usually also offers a path-list text form).
    func onServerFormatList(_ list: CLIPRDR_FORMAT_LIST) {
        if let clip = clipSnapshot() {
            var response = CLIPRDR_FORMAT_LIST_RESPONSE()
            response.common.msgFlags = UInt16(CB_RESPONSE_OK)
            _ = clip.pointee.ClientFormatListResponse?(clip, &response)
        }

        // Standard formats are matched by ID; FileGroupDescriptorW is a named
        // (registered) format whose ID the SERVER assigns — match by name.
        var offersUnicodeText = false
        var fileGroupId: UInt32?
        if let formats = list.formats, list.numFormats > 0 {
            for i in 0..<Int(list.numFormats) {
                let format = formats[i]
                if format.formatId == UInt32(CF_UNICODETEXT) {
                    offersUnicodeText = true
                }
                if let name = format.formatName,
                   String(cString: name) == "FileGroupDescriptorW" {
                    fileGroupId = format.formatId
                }
            }
        }

        lock.lock()
        remoteFileGroupFormatId = fileGroupId
        lock.unlock()

        guard let clip = clipSnapshot() else { return }
        var request = CLIPRDR_FORMAT_DATA_REQUEST()
        if let fileGroupId {
            lock.lock()
            pendingDataRequest = .fileGroup
            lock.unlock()
            request.requestedFormatId = fileGroupId
            _ = clip.pointee.ClientFormatDataRequest?(clip, &request)
        } else if offersUnicodeText {
            lock.lock()
            pendingDataRequest = .text
            lock.unlock()
            request.requestedFormatId = UInt32(CF_UNICODETEXT)
            _ = clip.pointee.ClientFormatDataRequest?(clip, &request)
        }
    }

    /// Server wants data we advertised (user pasted on the server side).
    func onServerFormatDataRequest(_ request: CLIPRDR_FORMAT_DATA_REQUEST) {
        switch request.requestedFormatId {
        case UInt32(CF_UNICODETEXT):
            DispatchQueue.main.async { self.respondTextData() }
        case Self.fileGroupDescriptorFormatId:
            respondFileGroupDescriptor()
        default:
            respondFormatDataFailure()
        }
    }

    /// Response to our eager fetch (text or file-group descriptor) → publish
    /// to the Mac pasteboard.
    func onServerFormatDataResponse(_ response: CLIPRDR_FORMAT_DATA_RESPONSE) {
        lock.lock()
        let kind = pendingDataRequest
        pendingDataRequest = nil
        lock.unlock()

        guard response.common.msgFlags & UInt16(CB_RESPONSE_OK) != 0,
              let bytes = response.requestedFormatData,
              response.common.dataLen > 0 else { return }
        // Copy now — the pointer is only valid for the duration of the callback.
        let data = Data(bytes: bytes, count: Int(response.common.dataLen))

        switch kind {
        case .fileGroup:
            let files = parseFileGroupDescriptor(data)
            lock.lock()
            remoteFiles = files
            lock.unlock()
            DispatchQueue.main.async { self.offerRemoteFiles(files) }

        case .text, nil:
            guard data.count > 1 else { return }
            var units = [UInt16]()
            units.reserveCapacity(data.count / 2)
            for i in stride(from: 0, to: data.count - 1, by: 2) {
                units.append(UInt16(data[i]) | UInt16(data[i + 1]) << 8)
            }
            if units.last == 0 { units.removeLast() } // trailing NUL
            let string = String(utf16CodeUnits: units, count: units.count)

            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(string, forType: .string)
                self.swallowPasteboardChange() // don't echo this back to the server
            }
        }
    }

    /// Server wants file metadata (SIZE) or content bytes (RANGE).
    func onServerFileContentsRequest(_ request: CLIPRDR_FILE_CONTENTS_REQUEST) {
        lock.lock()
        let index = Int(request.listIndex)
        let file = index >= 0 && index < servedFiles.count ? servedFiles[index] : nil
        lock.unlock()

        if request.dwFlags & UInt32(FILECONTENTS_SIZE) != 0 {
            var size = file?.size ?? 0
            let data = withUnsafeBytes(of: &size) { Data($0) }
            respondFileContents(streamId: request.streamId, data: data, ok: file != nil)
        } else if request.dwFlags & UInt32(FILECONTENTS_RANGE) != 0, let file {
            let offset = UInt64(request.nPositionHigh) << 32 | UInt64(request.nPositionLow)
            if let data = Self.readFileRange(url: file.url, offset: offset,
                                             count: Int(request.cbRequested)) {
                respondFileContents(streamId: request.streamId, data: data, ok: true)
            } else {
                respondFileContents(streamId: request.streamId, data: Data(), ok: false)
            }
        } else {
            respondFileContents(streamId: request.streamId, data: Data(), ok: false)
        }
    }

    private static func readFileRange(url: URL, offset: UInt64, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        return try? handle.read(upToCount: count)
    }
}


// MARK: - Outgoing channel messages

extension ClipboardChannel {
    /// Announce the current Mac pasteboard contents to the server.
    /// Called on the main thread (pasteboard access).
    func announceLocalFormats() {
        let pb = NSPasteboard.general
        let urls = (pb.readObjects(forClasses: [NSURL.self],
                                   options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let files = urls.compactMap { ServedFile(url: $0) }

        lock.lock()
        if !files.isEmpty, serverSupportsFileClip {
            servedFiles = files
            lock.unlock()
            sendFormatList([(Self.fileGroupDescriptorFormatId, "FileGroupDescriptorW"),
                            (Self.fileContentsFormatId, "FileContents")])
        } else if pb.string(forType: .string) != nil {
            servedFiles = []
            lock.unlock()
            sendFormatList([(UInt32(CF_UNICODETEXT), nil)])
        } else {
            // Nothing we can serve (e.g. an image) — clear the remote side.
            servedFiles = []
            lock.unlock()
            sendFormatList([])
        }
    }

    private func sendCapabilities() {
        guard let clip = clipSnapshot() else { return }
        var general = CLIPRDR_GENERAL_CAPABILITY_SET()
        general.capabilitySetType = UInt16(CB_CAPSTYPE_GENERAL)
        general.capabilitySetLength = UInt16(CB_CAPSTYPE_GENERAL_LEN)
        general.version = UInt32(CB_CAPS_VERSION_2)
        general.generalFlags = UInt32(CB_USE_LONG_FORMAT_NAMES
                                      | CB_STREAM_FILECLIP_ENABLED
                                      | CB_FILECLIP_NO_FILE_PATHS
                                      | CB_HUGE_FILE_SUPPORT_ENABLED)
        withUnsafeMutablePointer(to: &general) { generalPtr in
            var caps = CLIPRDR_CAPABILITIES()
            caps.cCapabilitiesSets = 1
            caps.capabilitySets = UnsafeMutableRawPointer(generalPtr)
                .assumingMemoryBound(to: CLIPRDR_CAPABILITY_SET.self)
            _ = clip.pointee.ClientCapabilities?(clip, &caps)
        }
    }

    private func sendFormatList(_ entries: [(id: UInt32, name: String?)]) {
        guard let clip = clipSnapshot() else { return }
        // The channel marshals the PDU synchronously, so the strdup'd names
        // can be freed right after the call returns.
        var cFormats = entries.map { CLIPRDR_FORMAT(formatId: $0.id,
                                                    formatName: $0.name.flatMap { strdup($0) }) }
        defer { cFormats.forEach { free($0.formatName) } }
        cFormats.withUnsafeMutableBufferPointer { buffer in
            var list = CLIPRDR_FORMAT_LIST()
            list.numFormats = UInt32(entries.count)
            list.formats = buffer.baseAddress
            _ = clip.pointee.ClientFormatList?(clip, &list)
        }
    }

    // MARK: Data responses

    /// Serve the current pasteboard string as CF_UNICODETEXT (UTF-16LE,
    /// NUL-terminated). Called on the main thread.
    private func respondTextData() {
        guard let string = NSPasteboard.general.string(forType: .string) else {
            respondFormatDataFailure()
            return
        }
        var units = Array(string.utf16)
        units.append(0)
        // Host platforms we target are little-endian, so the UInt16 buffer's
        // raw bytes ARE UTF-16LE on the wire.
        let data = units.withUnsafeBufferPointer { Data(bytes: $0.baseAddress!, count: $0.count * 2) }
        respondFormatData(data)
    }

    private func respondFileGroupDescriptor() {
        lock.lock()
        let files = servedFiles
        lock.unlock()
        guard !files.isEmpty else {
            respondFormatDataFailure()
            return
        }
        respondFormatData(Self.makeFileGroupDescriptor(files))
    }

    private func respondFormatData(_ data: Data) {
        guard let clip = clipSnapshot() else { return }
        data.withUnsafeBytes { raw in
            var response = CLIPRDR_FORMAT_DATA_RESPONSE()
            response.common.msgFlags = UInt16(CB_RESPONSE_OK)
            response.common.dataLen = UInt32(data.count)
            response.requestedFormatData = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            _ = clip.pointee.ClientFormatDataResponse?(clip, &response)
        }
    }

    private func respondFormatDataFailure() {
        guard let clip = clipSnapshot() else { return }
        var response = CLIPRDR_FORMAT_DATA_RESPONSE()
        response.common.msgFlags = UInt16(CB_RESPONSE_FAIL)
        response.common.dataLen = 0
        _ = clip.pointee.ClientFormatDataResponse?(clip, &response)
    }

    private func respondFileContents(streamId: UInt32, data: Data, ok: Bool) {
        guard let clip = clipSnapshot() else { return }
        data.withUnsafeBytes { raw in
            var response = CLIPRDR_FILE_CONTENTS_RESPONSE()
            response.common.msgFlags = UInt16(ok ? CB_RESPONSE_OK : CB_RESPONSE_FAIL)
            response.streamId = streamId
            response.cbRequested = UInt32(data.count)
            response.requestedData = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            _ = clip.pointee.ClientFileContentsResponse?(clip, &response)
        }
    }
}


// MARK: - FILEDESCRIPTORW serialization (MS-RDPECLIP 2.2.5.2.3.1)

extension ClipboardChannel {
    /// FileGroupDescriptorW payload: cItems (UInt32) + one 592-byte
    /// FILEDESCRIPTORW per file. Built by hand — FreeRDP's public headers
    /// don't expose this struct.
    static func makeFileGroupDescriptor(_ files: [ServedFile]) -> Data {
        // flags: FD_ATTRIBUTES | FD_FILESIZE | FD_WRITESTIME | FD_UNICODE | FD_PROGRESSUI
        let descriptorFlags: UInt32 = 0x0000_0004 | 0x0000_0040 | 0x0000_0020
                                      | 0x0000_0200 | 0x0000_4000

        var bytes = [UInt8]()
        bytes.reserveCapacity(4 + files.count * 592)
        appendLE32(&bytes, UInt32(files.count))

        for file in files {
            var entry = [UInt8](repeating: 0, count: 592)
            putLE32(&entry, 0, descriptorFlags)
            // offset 36: fileAttributes — FILE_ATTRIBUTE_READONLY / _NORMAL
            putLE32(&entry, 36, file.isReadOnly ? 0x01 : 0x80)
            // offset 56: lastWriteTime (FILETIME)
            putLE64(&entry, 56, file.lastWriteTime)
            // offset 64/68: fileSizeHigh / fileSizeLow
            putLE32(&entry, 64, UInt32(file.size >> 32))
            putLE32(&entry, 68, UInt32(file.size & 0xFFFF_FFFF))
            // offset 72: WCHAR fileName[260], NUL-terminated, truncated
            for (i, unit) in file.name.utf16.prefix(259).enumerated() {
                entry[72 + i * 2] = UInt8(unit & 0xFF)
                entry[73 + i * 2] = UInt8(unit >> 8)
            }
            bytes.append(contentsOf: entry)
        }
        return Data(bytes)
    }
}

private func appendLE32(_ bytes: inout [UInt8], _ value: UInt32) {
    bytes.append(UInt8(value & 0xFF))
    bytes.append(UInt8((value >> 8) & 0xFF))
    bytes.append(UInt8((value >> 16) & 0xFF))
    bytes.append(UInt8((value >> 24) & 0xFF))
}

private func putLE32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
    bytes[offset]     = UInt8(value & 0xFF)
    bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
    bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
    bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
}

private func putLE64(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt64) {
    for i in 0..<8 {
        bytes[offset + i] = UInt8((value >> (8 * i)) & 0xFF)
    }
}


// MARK: - C callback surface (installed on CliprdrClientContext)

private func clipboardChannelFrom(_ context: UnsafeMutablePointer<CliprdrClientContext>?) -> ClipboardChannel? {
    guard let context, let raw = context.pointee.custom else { return nil }
    return Unmanaged<ClipboardChannel>.fromOpaque(raw).takeUnretainedValue()
}

private let serverCapabilitiesCb: pcCliprdrServerCapabilities = { context, caps in
    guard let caps, let channel = clipboardChannelFrom(context) else { return 0 }
    channel.onServerCapabilities(caps.pointee)
    return 0
}

private let monitorReadyCb: pcCliprdrMonitorReady = { context, _ in
    clipboardChannelFrom(context)?.onMonitorReady()
    return 0
}

private let serverFormatListCb: pcCliprdrServerFormatList = { context, list in
    guard let list, let channel = clipboardChannelFrom(context) else { return 0 }
    channel.onServerFormatList(list.pointee)
    return 0
}

private let serverFormatListResponseCb: pcCliprdrServerFormatListResponse = { _, _ in 0 }

private let serverFormatDataRequestCb: pcCliprdrServerFormatDataRequest = { context, request in
    guard let request, let channel = clipboardChannelFrom(context) else { return 0 }
    channel.onServerFormatDataRequest(request.pointee)
    return 0
}

private let serverFormatDataResponseCb: pcCliprdrServerFormatDataResponse = { context, response in
    guard let response, let channel = clipboardChannelFrom(context) else { return 0 }
    channel.onServerFormatDataResponse(response.pointee)
    return 0
}

private let serverFileContentsRequestCb: pcCliprdrServerFileContentsRequest = { context, request in
    guard let request, let channel = clipboardChannelFrom(context) else { return 0 }
    channel.onServerFileContentsRequest(request.pointee)
    return 0
}

private let serverFileContentsResponseCb: pcCliprdrServerFileContentsResponse = { context, response in
    guard let response, let channel = clipboardChannelFrom(context) else { return 0 }
    channel.onServerFileContentsResponse(response.pointee)
    return 0
}

/// Installs our delegate callbacks on the cliprdr client context.
/// Called by ClipboardChannel.attach().
func installClipboardCallbacks(on clip: UnsafeMutablePointer<CliprdrClientContext>) {
    clip.pointee.ServerCapabilities = serverCapabilitiesCb
    clip.pointee.MonitorReady = monitorReadyCb
    clip.pointee.ServerFormatList = serverFormatListCb
    clip.pointee.ServerFormatListResponse = serverFormatListResponseCb
    clip.pointee.ServerFormatDataRequest = serverFormatDataRequestCb
    clip.pointee.ServerFormatDataResponse = serverFormatDataResponseCb
    clip.pointee.ServerFileContentsRequest = serverFileContentsRequestCb
    clip.pointee.ServerFileContentsResponse = serverFileContentsResponseCb
}

// MARK: - PubSub channel discovery

/// PubSub event handlers receive the rdpContext as their `context` argument
/// (PubSub was created with it in freerdp_context_new).
private let channelConnectedHandler: pChannelConnectedEventHandler = { context, args in
    guard let args, let name = args.pointee.name,
          String(cString: name) == "cliprdr",
          let rawInterface = args.pointee.pInterface,
          let context else { return }
    let rdpCtx = context.assumingMemoryBound(to: rdpContext.self)
    guard let instance = rdpCtx.pointee.instance else { return }
    guard let channel = ClipboardRegistry.channel(for: instance) else { return }
    channel.attach(rawInterface.assumingMemoryBound(to: CliprdrClientContext.self))
}

private let channelDisconnectedHandler: pChannelDisconnectedEventHandler = { context, args in
    guard let args, let name = args.pointee.name,
          String(cString: name) == "cliprdr",
          let context else { return }
    let rdpCtx = context.assumingMemoryBound(to: rdpContext.self)
    guard let instance = rdpCtx.pointee.instance else { return }
    ClipboardRegistry.channel(for: instance)?.detach()
}

/// Registers the channel and subscribes to cliprdr lifecycle events.
/// Must be called AFTER freerdp_context_new() (pubSub exists) and BEFORE
/// freerdp_connect() (the ChannelConnected event fires during connect).
func installClipboardChannelHooks(on instance: UnsafeMutablePointer<freerdp>,
                                  channel: ClipboardChannel) {
    ClipboardRegistry.register(channel, for: instance)
    guard let pubSub = instance.pointee.context?.pointee.pubSub else { return }
    _ = PubSub_SubscribeChannelConnected(pubSub, channelConnectedHandler)
    _ = PubSub_SubscribeChannelDisconnected(pubSub, channelDisconnectedHandler)
}

/// Tears down the channel bridge. Safe to call multiple times.
func uninstallClipboardChannelHooks(for instance: UnsafeMutablePointer<freerdp>,
                                    channel: ClipboardChannel) {
    channel.detach()
    ClipboardRegistry.unregister(for: instance)
}

