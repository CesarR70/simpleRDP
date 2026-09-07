import Foundation
import Darwin

struct ConnectionAddress: Equatable {
    let host: String
    let port: Int

    var display: String {
        let name = host.contains(":") ? "[\(host)]" : host
        return port == 3389 ? name : "\(name):\(port)"
    }

    init(_ raw: String, defaultPort: Int = 3389) throws {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = text
        var number = defaultPort
        func parsePort(_ value: Substring) throws -> Int {
            guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let port = Int(value), (1...65535).contains(port) else {
                throw ValidationError("Port must be a number between 1 and 65535.")
            }
            return port
        }
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else {
                throw ValidationError("Close the IPv6 address with ].")
            }
            name = String(text[text.index(after: text.startIndex)..<close])
            let tail = text[text.index(after: close)...]
            if !tail.isEmpty {
                guard tail.hasPrefix(":") else { throw ValidationError("Invalid server address.") }
                number = try parsePort(tail.dropFirst())
            }
            var address = in6_addr()
            guard inet_pton(AF_INET6, name, &address) == 1 else {
                throw ValidationError("Invalid IPv6 address.")
            }
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            name = String(text[..<colon])
            number = try parsePort(text[text.index(after: colon)...])
        } else if text.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, text, &address) == 1 else {
                throw ValidationError("Use [IPv6 address]:port for an IPv6 server with a port.")
            }
        }
        guard !name.isEmpty, !name.contains(where: { $0.isWhitespace || $0.isNewline }),
              !name.contains(where: { "/\\[]@".contains($0) }),
              (1...65535).contains(number) else {
            throw ValidationError("Enter a valid hostname or IP address and port.")
        }
        host = name
        port = number
    }
}

struct ValidationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}