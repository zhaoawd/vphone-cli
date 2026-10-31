import ArgumentParser
import Foundation
import VPhoneAPIKit

struct VPhoneAPIProxyOptions {
    let port: UInt16
    let token: String

    static func port(_ listen: String) throws -> UInt16 {
        let prefix = "127.0.0.1:"
        guard listen.hasPrefix(prefix) else {
            throw ValidationError("--api-listen must be 127.0.0.1:PORT")
        }
        let digits = listen.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }), let port = UInt16(digits) else {
            throw ValidationError("--api-listen port must be 0...65535")
        }
        return port
    }

    static func validate(listen: String?, dfu: Bool, noVphoned: Bool) throws {
        guard let listen else { return }
        _ = try port(listen)
        guard !dfu, !noVphoned else {
            throw ValidationError("--api-listen is unavailable with --dfu or --no-vphoned")
        }
    }

    static func resolve(listen: String?, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self? {
        guard let listen else { return nil }
        let port = try port(listen)
        guard let token = environment[VPhoneAPIRequestGate.environmentKey], VPhoneAPIRequestGate.isValidToken(token) else {
            throw ValidationError("--api-listen requires VPHONE_API_TOKEN with 16...256 URL-unreserved characters")
        }
        return Self(port: port, token: token)
    }
}
