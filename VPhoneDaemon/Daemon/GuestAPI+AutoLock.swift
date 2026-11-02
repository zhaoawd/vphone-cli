import CoreFoundation
import Foundation

extension GuestAPI {
    /// The display.auto_lock.set handler, shared with the guest-free tests.
    static func setAutoLock(_ params: [String: Any]) throws -> [String: Any] {
        let seconds: Int
        if let value = params["seconds"] {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue,
                  (0 ... Double(Int32.max)).contains(number.doubleValue)
            else { throw GuestAPIError.invalidRequest("seconds must be an integer between 0 and Int32.max") }
            seconds = number.intValue
        } else if let flag = params["never"] as? NSNumber,
                  CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue {
            seconds = Int(Int32.max)
        } else {
            throw GuestAPIError.invalidRequest("seconds must be an integer, or never must be true")
        }
        return try GuestLockScreenIdle.setAutoLockSeconds(seconds)
    }
}
