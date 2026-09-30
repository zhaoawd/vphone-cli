import Virtualization
import VPhoneCore
func validateSyntax() throws {
        let auxStorage = try VPhoneNVRAMStorage.openOrCreate(
            at: options.nvramURL,
            openExisting: { VZMacAuxiliaryStorage(url: $0) },
            createNew: {
                try VZMacAuxiliaryStorage(
                    creatingStorageAt: $0, hardwareModel: hwModel, options: []
                )
            }
        )
}
