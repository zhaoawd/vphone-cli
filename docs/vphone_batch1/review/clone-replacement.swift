    // MARK: - Clone
    /// Copy a stopped VM's complete persistent boot state, retaining its device
    /// identity (NVRAM, machine identifier, SEP storage and tickets stay together).
    /// This is not a new independent device: use create/restore for that purpose.
    /// Prefer APFS CoW; omit only host runtime state and the control socket.
    public static func clone(
        bundleNamed name: String, to newName: String, in library: VPhoneLibrary
    ) throws -> VPhoneBundle {
        try clone(bundleNamed: name, to: newName, in: library, copyDirectory: {
            try VPhoneCloneCopy.copy(from: $0, to: $1, excludingRootNames: $2)
        })
    }

    /// Test seams for forced non-APFS copying, failed copies and a destination
    /// collision immediately before publication. No global mutable test hooks.
    static func clone(
        bundleNamed name: String, to newName: String, in library: VPhoneLibrary,
        copyDirectory: (URL, URL, Set<String>) throws -> Void,
        afterNameCheck: (() throws -> Void)? = nil
    ) throws -> VPhoneBundle {
        try requireValidName(newName)
        let src = try library.bundle(named: name).url
        // Keep the existing source lock for the full snapshot and publication.
        // Running VMs remain refused; there is no live-snapshot opt-out.
        return try VPhoneBundleGuard.withBundleLock(
            directory: src, operation: VPhoneVMOperation.clone
        ) { _ in
            let dst = library.url(forName: newName)
            let fm = FileManager.default
            if try VPhoneCloneCopy.exists(at: dst) {
                throw VPhoneLibraryError.alreadyExists(name: newName)
            }
            // Only an exclusively created private directory may be rolled back.
            // Never clean up the final name after a failed clone or EEXIST.
            let staging = library.root.appendingPathComponent(".clone-\(UUID().uuidString)")
            try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: staging) }
            let payload = staging.appendingPathComponent("payload")
            try copyDirectory(src, payload, [VPhoneVMRuntimeState.filename, "vphone.sock"])
            let staged = try VPhoneBundle.load(at: payload)
            // As in importArchive, copying happens privately, then name checking
            // and publication use the library lock. Slow copies do not monopolize it.
            return try VPhoneBundleGuard.withLibraryLock(root: library.root) { _ in
                if try VPhoneCloneCopy.exists(at: dst) {
                    throw VPhoneLibraryError.alreadyExists(name: newName)
                }
                try afterNameCheck?()
                do {
                    try fm.moveItem(at: payload, to: dst)
                } catch let error as NSError
                    where (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError)
                    || (error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST))
                {
                    throw VPhoneLibraryError.alreadyExists(name: newName)
                }
                return VPhoneBundle(url: dst, manifest: staged.manifest)
            }
        }
    }
