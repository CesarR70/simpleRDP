//
// Models.swift — domain types shared by the SwiftUI views and the session layer.
//
// Mirrors the shapes sketched in RDP-Swift-Client-Plan.md §7 and §9.
//

import Foundation

/// How to interpret a connection target. Honors the `endpointKind` hint the
/// plan recommends for distinguishing Windows (often NLA-required) from
/// xrdp (typically TLS-only) endpoints.
enum EndpointKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case auto    // let FreeRDP negotiate
    case windows // hint: NLA-friendly
    case xrdp    // hint: TLS-first, no NLA by default

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:    return "Auto"
        case .windows: return "Windows"
        case .xrdp:    return "xrdp (Linux)"
        }
    }
}

/// A user-saved server entry. Passwords are deliberately NOT stored — a
/// favorite only pre-populates the connect form (host, username, trust flag,
/// share folder); the user types the password and clicks Connect each time.
struct ServerFavorite: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String            // custom label, e.g. "Lab box #3"
    var host: String            // IP or hostname (host or host:port)
    var port: Int = 3389
    var username: String?
    var endpointKind: EndpointKind = .auto
    var trustAllCertificates: Bool = false
    var sharePath: String?      // optional folder to share with the session

    /// Host display string, omitting the port when it's the RDP default.
    var displayHostPort: String {
        port == 3389 ? host : "\(host):\(port)"
    }

    // Memberwise init — the custom `init(from:)` below suppresses the
    // synthesized one, so it's declared explicitly for normal construction.
    init(id: UUID = UUID(), name: String, host: String, port: Int = 3389,
         username: String? = nil, endpointKind: EndpointKind = .auto,
         trustAllCertificates: Bool = false, sharePath: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.endpointKind = endpointKind
        self.trustAllCertificates = trustAllCertificates
        self.sharePath = sharePath
    }

    // Tolerant decoding: favorites saved by older builds lack
    // trustAllCertificates/sharePath; default them rather than failing the
    // whole file (which would silently drop every saved favorite).
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, endpointKind, trustAllCertificates, sharePath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 3389
        username = try c.decodeIfPresent(String.self, forKey: .username)
        endpointKind = try c.decodeIfPresent(EndpointKind.self, forKey: .endpointKind) ?? .auto
        trustAllCertificates = try c.decodeIfPresent(Bool.self, forKey: .trustAllCertificates) ?? false
        sharePath = try c.decodeIfPresent(String.self, forKey: .sharePath)
    }
}

/// Connection lifecycle state surfaced to the UI. Kept intentionally tiny so
/// it can back an `AsyncStream<ConnectionState>` without leaking FreeRDP types.
enum ConnectionState: Equatable {
    case idle
    case connecting(host: String)
    case handshaking
    case connected
    case disconnected(reason: String?)
    case failed(reason: String)

    var isActive: Bool {
        switch self {
        case .connecting, .handshaking, .connected: return true
        default: return false
        }
    }

    var displayLabel: String {
        switch self {
        case .idle:                            return "Idle"
        case .connecting(let host):            return "Connecting to \(host)…"
        case .handshaking:                     return "Handshaking…"
        case .connected:                       return "Connected"
        case .disconnected(let reason):        return "Disconnected" + (reason.map { " (\($0))" } ?? "")
        case .failed(let reason):              return "Failed: \(reason)"
        }
    }
}