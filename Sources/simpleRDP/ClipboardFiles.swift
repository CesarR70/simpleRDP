import Foundation
import Darwin

enum ClipboardDataRequestKind { case text, fileGroup }

struct RemoteClipboardFile {
    let listIndex: UInt32
    let relativePath: String
    let size: UInt64
    let isDirectory: Bool
    var topLevel: String { String(relativePath.split(separator: "/")[0]) }
}

struct ClipboardDownloadStatus: Equatable {
    var isActive = false
    var filesTotal = 0
    var filesDone = 0
    var bytesTotal: UInt64 = 0
    var bytesDone: UInt64 = 0
    var currentFile = ""
    var error: String?
    static let idle = ClipboardDownloadStatus()
}

/// Strictly validate the complete offer before touching the filesystem.
func parseFileGroupDescriptor(_ data: Data) throws -> [RemoteClipboardFile] {
    let data = [UInt8](data)
    func u32(_ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
    guard data.count >= 4 else { throw ValidationError("Truncated clipboard file list.") }
    let count = Int(u32(0))
    guard count > 0, count <= 10_000, data.count == 4 + count * 592 else {
        throw ValidationError("Invalid or oversized clipboard file list.")
    }
    var files: [RemoteClipboardFile] = []
    var paths: [String: Bool] = [:]
    var total: UInt64 = 0
    for index in 0..<count {
        let base = 4 + index * 592
        let flags = u32(base)
        let directory = u32(base + 36) & 0x10 != 0
        guard flags & 0x4 != 0, directory || flags & 0x40 != 0 else {
            throw ValidationError("Clipboard file metadata is missing attributes or size.")
        }
        var units: [UInt16] = []
        var terminated = false
        for offset in stride(from: base + 72, to: base + 592, by: 2) {
            let unit = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
            if unit == 0 { terminated = true; break }
            units.append(unit)
        }
        let name = String(decoding: units, as: UTF16.self)
        guard terminated, Array(name.utf16) == units else {
            throw ValidationError("Invalid clipboard filename encoding.")
        }
        let path = name.replacingOccurrences(of: "\\", with: "/")
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ component in
            !component.isEmpty && component != "." && component != ".."
                && !component.contains(":") && !component.hasSuffix(" ") && !component.hasSuffix(".")
                && component.utf8.count <= 255
                && !component.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }) else { throw ValidationError("Unsafe clipboard filename: \(name)") }
        let canonical = path.precomposedStringWithCanonicalMapping.lowercased()
        guard paths[canonical] == nil else { throw ValidationError("Conflicting clipboard filenames.") }
        paths[canonical] = directory
        let size = directory ? 0 : UInt64(u32(base + 64)) << 32 | UInt64(u32(base + 68))
        let sum = total.addingReportingOverflow(size)
        guard !sum.overflow, sum.partialValue <= UInt64(Int64.max) else {
            throw ValidationError("Clipboard download is too large.")
        }
        total = sum.partialValue
        files.append(RemoteClipboardFile(listIndex: UInt32(index), relativePath: path,
                                         size: size, isDirectory: directory))
    }
    for file in files {
        var components = file.relativePath.precomposedStringWithCanonicalMapping.lowercased().split(separator: "/")
        while components.count > 1 {
            components.removeLast()
            if paths[components.joined(separator: "/")] == false {
                throw ValidationError("Clipboard file conflicts with a directory.")
            }
        }
    }
    return files
}

/// A private directory per transfer. openat/mkdirat with O_NOFOLLOW prevent a
/// replaced symlink from redirecting writes outside it, including parent paths.
final class ClipboardStagingArea {
    let url: URL
    private let descriptor: Int32

    init(parent: URL) throws {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        url = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
    }

    deinit { close(descriptor) }

    func create(_ file: RemoteClipboardFile) throws -> FileHandle? {
        let components = file.relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ValidationError("Unsafe clipboard path.")
        }
        var parent = dup(descriptor)
        guard parent >= 0 else { throw POSIXError(.EIO) }
        defer { close(parent) }
        let directories = file.isDirectory ? components : Array(components.dropLast())
        for component in directories {
            if mkdirat(parent, component, 0o700) != 0 && errno != EEXIST { throw posixError() }
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw posixError() }
            close(parent)
            parent = next
        }
        if file.isDirectory { return nil }
        let fd = openat(parent, components.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

struct StagedMoveResult {
    var remaining: [URL] = []
    var destinations: [URL] = []
    var errors: [String] = []
}

/// FileManager implements cross-volume moves as copy-then-remove. Failed items
/// remain staged; never clear a whole cache after a partial failure.
func moveStagedFiles(_ sources: [URL], to directory: URL) -> StagedMoveResult {
    let fm = FileManager.default
    var result = StagedMoveResult()
    for source in sources where fm.fileExists(atPath: source.path) {
        let name = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var destination = directory.appendingPathComponent(source.lastPathComponent)
        var suffix = 2
        while fm.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(name) (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)"))
            suffix += 1
        }
        do {
            try fm.moveItem(at: source, to: destination)
            result.destinations.append(destination)
        } catch {
            result.remaining.append(source)
            result.errors.append("\(source.lastPathComponent): \(error.localizedDescription)")
        }
    }
    return result
}

final class ClipboardTransfer: @unchecked Sendable {
    let id = UUID()
    let generation: UUID
    let pasteboardChange: Int
    private let lock = NSLock()
    private var cancelled = false
    init(generation: UUID, pasteboardChange: Int) {
        self.generation = generation
        self.pasteboardChange = pasteboardChange
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}