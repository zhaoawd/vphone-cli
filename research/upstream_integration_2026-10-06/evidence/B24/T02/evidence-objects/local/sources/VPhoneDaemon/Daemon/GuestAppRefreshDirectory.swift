import Foundation

/// An explicit directory keeps its existing API meaning. A default refresh
/// requires a completed bootstrap; it must not fall back to system apps.
enum GuestAppRefreshDirectory {
    enum Refusal: Error { case missingBootstrap, invalidDirectory }
    static func resolve(requested: String?, installation: GuestBootstrapState.Installation?) throws -> String {
        if let requested {
            guard requested.hasPrefix("/"), !requested.contains("\0"),
                  requested == (requested as NSString).standardizingPath else { throw Refusal.invalidDirectory }
            return requested
        }
        guard let installation, GuestBootstrapState.validRoot(installation.root, layout: installation.layout) else { throw Refusal.missingBootstrap }
        return installation.root + "/Applications"
    }
}
