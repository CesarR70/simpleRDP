//
// FavoritesStore.swift — JSON-backed list of ServerFavorite entries.
//
// Persists to `~/Library/Application Support/simpleRDP/favorites.json`. Survives
// across app launches. The path is derived from FileManager's Application Support
// directory so it follows macOS conventions and respects sandbox container
// overrides should the app later be sandboxed.
//

import Foundation
import Combine

@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var favorites: [ServerFavorite] = []

    private let fileURL: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    init(fileURL: URL? = nil) {
        if let url = fileURL {
            self.fileURL = url
        } else {
            // ~/Library/Application Support/simpleRDP/favorites.json
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first!
            self.fileURL = appSupport
                .appendingPathComponent("simpleRDP", isDirectory: true)
                .appendingPathComponent("favorites.json")
        }
        load()
    }

    // MARK: - Public CRUD

    func add(_ fav: ServerFavorite) {
        favorites.append(fav)
        persist()
    }

    func update(_ fav: ServerFavorite) {
        guard let idx = favorites.firstIndex(where: { $0.id == fav.id }) else { return }
        favorites[idx] = fav
        persist()
    }

    func delete(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        persist()
    }

    func delete(_ fav: ServerFavorite) {
        favorites.removeAll { $0.id == fav.id }
        persist()
    }

    /// Returns the saved favorite whose `host` (or `host:port`) matches the given
    /// string. Useful for "save current as favorite" deduplication.
    func favorite(matchingHostPort hostPort: String) -> ServerFavorite? {
        let (host, port) = Self.splitHostPort(hostPort)
        return favorites.first { f in
            f.host == host && f.port == port
        }
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            self.favorites = try decoder.decode([ServerFavorite].self, from: data)
        } catch {
            // Don't crash on a malformed file; just start fresh and surface to console.
            print("[FavoritesStore] failed to decode \(fileURL.path): \(error)")
            self.favorites = []
        }
    }

    private func persist() {
        let dir = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true)
            let data = try encoder.encode(favorites)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[FavoritesStore] failed to persist favorites: \(error)")
        }
    }

    // MARK: - Host/port parsing

    /// Splits "host" or "host:port" into a (host, port) pair. Defaults port to 3389.
    /// Marked `nonisolated` because it's pure logic and called from non-MainActor
    /// contexts (e.g. `RDPSession` actor when starting a connect).
    nonisolated static func splitHostPort(_ raw: String) -> (host: String, port: Int) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // IPv6 literal in [..]:port
        if trimmed.hasPrefix("[") {
            if let close = trimmed.firstIndex(of: "]") {
                let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
                let tail = trimmed[trimmed.index(after: close)...]
                if tail.hasPrefix(":") {
                    let portStr = tail.dropFirst()
                    return (host, Int(portStr) ?? 3389)
                }
                return (host, 3389)
            }
        }
        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, let port = Int(parts[1]) {
            return (String(parts[0]), port)
        }
        return (trimmed, 3389)
    }
}