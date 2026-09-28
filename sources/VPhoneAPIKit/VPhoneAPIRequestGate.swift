import Foundation

/// Admission for the opt-in loopback TCP-to-VSOCK proxy. Exactly one
/// credential is accepted; it is stripped before forwarding to the guest.
public enum VPhoneAPIRequestGate {
    /// The largest request head the proxy buffers before refusing.
    public static let maximumHeadLength = 16 * 1024
    /// The CLI reads this variable only when its API proxy is explicitly enabled.
    public static let environmentKey = "VPHONE_API_TOKEN"
    public static let webSocketProtocolPrefix = "vphone-token."

    public enum Decision: Equatable, Sendable {
        /// The head is incomplete and still under the size limit.
        case needMore
        /// Forward these bytes to the guest, then relay the rest unchanged.
        case accept(Data)
        /// Reply with `unauthorizedResponse` and close.
        case reject
    }

    public static let unauthorizedResponse: Data = {
        let body = #"{"type":"response","id":null,"error":{"code":"unauthorized","message":"Missing or wrong API token"}}"#
        let head = "HTTP/1.1 401 Unauthorized\r\n" +
            "Content-Type: application/json; charset=utf-8\r\n" +
            "WWW-Authenticate: Bearer\r\n" +
            "Content-Length: \(body.utf8.count)\r\n" +
            "Connection: close\r\n\r\n"
        return Data((head + body).utf8)
    }()

    // MARK: - Token

    /// A usable token is 16 to 256 URL-unreserved characters, so it needs no
    /// escaping in a header, a query item or a WebSocket protocol name.
    public static func isValidToken(_ token: String) -> Bool {
        (16 ... 256).contains(token.utf8.count) && token.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "a") ... UInt8(ascii: "z"),
                 UInt8(ascii: "0") ... UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."),
                 UInt8(ascii: "_"), UInt8(ascii: "~"):
                true
            default:
                false
            }
        }
    }

    /// Lowercase hexadecimal for random token bytes.
    public static func hexToken(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Compares every byte regardless of where the first difference is.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = left.count ^ right.count
        for index in 0 ..< max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= Int(a ^ b)
        }
        return difference == 0
    }

    // MARK: - Admission

    /// Validates the initial HTTP head and preserves any already-read body.
    public static func evaluate(_ received: Data, token: String) -> Decision {
        let terminator = Data("\r\n\r\n".utf8)
        guard let end = received.range(of: terminator) else {
            return received.count >= maximumHeadLength ? .reject : .needMore
        }
        let headEnd = end.upperBound - received.startIndex
        guard headEnd <= maximumHeadLength, isValidToken(token),
              let request = Head(received[received.startIndex ..< end.lowerBound]),
              request.isLocalRequest, request.carries(token)
        else { return .reject }
        var forwarded = Data(request.rewritten(host: "vphoned").utf8)
        forwarded.append(received[end.lowerBound...])
        return .accept(forwarded)
    }

    // MARK: - Request Head

    struct Head {
        let requestLine: String
        let method: String
        let target: String
        let version: String
        /// Each header line as received, with its parsed name and value.
        var fields: [(line: String, name: String, value: String)]

        /// Parses a request head without its final blank line. Bare CR, bare
        /// LF, NUL, other control bytes, folded lines and malformed field
        /// names are refused, so the proxy and vphoned cannot read the same
        /// bytes as different headers.
        init?(_ bytes: Data) {
            guard bytes.allSatisfy({ $0 == 0x0D || $0 == 0x0A || $0 == 0x09 || (0x20 ..< 0x7F).contains($0) }),
                  let text = String(data: bytes, encoding: .ascii)
            else { return nil }
            let lines = text.components(separatedBy: "\r\n")
            guard lines.allSatisfy({ !$0.contains("\r") && !$0.contains("\n") }),
                  let requestLine = lines.first
            else { return nil }
            let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty,
                  parts[0].allSatisfy(Self.isTokenCharacter),
                  parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0"
            else { return nil }
            self.requestLine = requestLine
            method = String(parts[0])
            target = String(parts[1])
            version = String(parts[2])
            fields = []
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let name = line[..<colon]
                guard !name.isEmpty, name.allSatisfy(Self.isTokenCharacter) else { return nil }
                let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                fields.append((line, String(name), value))
            }
        }

        private static func isTokenCharacter(_ character: Character) -> Bool {
            guard let ascii = character.asciiValue, ascii > 0x20, ascii < 0x7F else { return false }
            return !"\"(),/:;<=>?@[\\]{}".contains(character)
        }

        func values(_ name: String) -> [String] {
            fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
        }

        /// The raw `name=value` items of the target's query, or nil without one.
        private var queryItems: [Substring]? {
            guard let question = target.firstIndex(of: "?") else { return nil }
            return target[target.index(after: question)...].split(separator: "&", omittingEmptySubsequences: false)
        }

        private static func isTokenItem(_ item: Substring) -> Bool {
            String(item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? "").removingPercentEncoding == "token"
        }

        var isLocalRequest: Bool {
            guard values("Origin").isEmpty, values("Proxy-Authorization").isEmpty,
                  target.hasPrefix("/"), !target.hasPrefix("//"), !target.contains("#"),
                  !target.contains("\t"), !target.contains("\\"),
                  values("Host").count == 1, let host = values("Host").first,
                  let url = URLComponents(string: "http://" + host),
                  ["localhost", "127.0.0.1", "[::1]", "::1"].contains(url.host?.lowercased() ?? ""),
                  url.user == nil, url.password == nil, url.path.isEmpty,
                  url.query == nil, url.fragment == nil,
                  url.port == nil || (1...65535).contains(url.port!)
            else { return false }
            let lengths = values("Content-Length")
            let encodings = values("Transfer-Encoding")
            guard lengths.count <= 1, encodings.count <= 1,
                  lengths.isEmpty || encodings.isEmpty else { return false }
            if let length = lengths.first {
                guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }), UInt64(length) != nil else { return false }
            }
            return encodings.isEmpty || encodings == ["chunked"]
        }

        func carries(_ token: String) -> Bool {
            var candidates: [String] = []
            for value in values("Authorization") {
                let parts = value.split(separator: " ", maxSplits: 1)
                guard parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame else { return false }
                candidates.append(String(parts[1]))
            }
            for item in queryItems ?? [] where Self.isTokenItem(item) {
                let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, let value = String(parts[1]).removingPercentEncoding else { return false }
                candidates.append(value)
            }
            for value in values("Sec-WebSocket-Protocol") {
                for name in value.split(separator: ",") {
                    let name = name.trimmingCharacters(in: .whitespaces)
                    if name.hasPrefix(VPhoneAPIRequestGate.webSocketProtocolPrefix) {
                        candidates.append(String(name.dropFirst(VPhoneAPIRequestGate.webSocketProtocolPrefix.count)))
                    }
                }
            }
            return candidates.count == 1 && VPhoneAPIRequestGate.constantTimeEquals(candidates[0], token)
        }

        /// The head to forward: the request line loses its `token` query
        /// items, `Authorization` is dropped, and `Host` is replaced only when
        /// asked. Token subprotocols are also removed; other lines are retained.
        func rewritten(host: String?) -> String {
            var lines = [requestLine]
            if let question = target.firstIndex(of: "?"), let items = queryItems,
               items.contains(where: Self.isTokenItem)
            {
                let kept = items.filter { !Self.isTokenItem($0) }
                let path = String(target[..<question]) + (kept.isEmpty ? "" : "?" + kept.joined(separator: "&"))
                lines[0] = "\(method) \(path) \(version)"
            }
            for field in fields {
                if field.name.caseInsensitiveCompare("Authorization") == .orderedSame {
                    continue
                }
                if field.name.caseInsensitiveCompare("Sec-WebSocket-Protocol") == .orderedSame {
                    let kept = field.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.hasPrefix(VPhoneAPIRequestGate.webSocketProtocolPrefix) }
                    if !kept.isEmpty { lines.append("Sec-WebSocket-Protocol: " + kept.joined(separator: ", ")) }
                    continue
                }
                if let host, field.name.caseInsensitiveCompare("Host") == .orderedSame {
                    lines.append("\(field.name): \(host)")
                } else {
                    lines.append(field.line)
                }
            }
            return lines.joined(separator: "\r\n")
        }
    }
}
