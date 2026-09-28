import Foundation
import Virtualization
import VPhoneAPIKit

@MainActor
enum VPhoneAPIVSockConnector {
    /// Framework calls stay on MainActor. Only an owned descriptor and its
    /// lifetime holder cross to the proxy worker. Late results are discarded there.
    static func make(device: VZVirtioSocketDevice) -> VPhoneAPIProxy.Connector {
        let holder = DeviceHolder(device: device)
        return { completion in
            Task { @MainActor in
                holder.device.connect(toPort: 1339) { result in
                    switch result {
                    case let .success(connection):
                        completion(Result { try VPhoneAPISocket(duplicating: connection.fileDescriptor, owner: connection) })
                    case let .failure(error):
                        completion(.failure(error))
                    }
                }
            }
        }
    }
    @MainActor
    private final class DeviceHolder {
        let device: VZVirtioSocketDevice
        init(device: VZVirtioSocketDevice) { self.device = device }
    }
}
