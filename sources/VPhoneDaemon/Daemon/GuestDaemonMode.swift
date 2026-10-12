import Foundation

/// 独立 API 保留启动恢复；相机由匹配的发布端拥有。
struct GuestDaemonMode {
    let apiOnly: Bool
    let cameraEnabled: Bool

    init(environment: [String: String]) {
        apiOnly = environment["VPHONE_API_ONLY"] == "1"
        cameraEnabled = !apiOnly && environment["VPHONE_DISABLE_CAMERA"] != "1"
            && environment["VPHONED_VCAM"] != "off"
    }
}
