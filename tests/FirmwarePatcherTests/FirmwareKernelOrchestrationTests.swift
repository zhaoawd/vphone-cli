import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct FirmwareKernelOrchestrationTests {
    @Test(arguments: [0, 1, 2]) func uniquePrebootTarget(_ count: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<count {
            let child = root.appendingPathComponent("volume-\(i)")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
            try Data([1]).write(to: child.appendingPathComponent("kernelcache"))
        }
        if count == 1 { #expect(try FirmwareKernelMount.uniqueKernel(in: root).lastPathComponent == "kernelcache") }
        else { #expect(throws: (any Error).self) { try FirmwareKernelMount.uniqueKernel(in: root) } }
    }

    @Test(arguments: ["directory", "link", "hardlink"]) func nonOrdinaryPrebootTargetRefused(_ kind: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("kernelcache"), other = root.appendingPathComponent("other")
        if kind == "directory" { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
        else {
            try Data([1]).write(to: other)
            if kind == "link" { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other) }
            else { try FileManager.default.linkItem(at: other, to: target) }
        }
        #expect(throws: (any Error).self) { try FirmwareKernelMount.uniqueKernel(in: root) }
    }

    @Test(arguments: [UInt64(6), UInt64(7)]) func sevenGiBDSCCannotEnterSixGiBKernel(_ capacity: UInt64) throws {
        let base: UInt64 = 0x180000000, size: UInt64 = 7 << 30
        var header = Data(repeating: 0, count: 0x100)
        func put(_ value: UInt64, _ offset: Int) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { header.replaceSubrange(offset..<offset+8, with: $0) }
        }
        put(base, 0xE0); put(size, 0xE8)
        let region = FirmwareKernelRegion.Region(base: base, size: capacity << 30)
        if capacity == 7 { try FirmwareKernelDSC.validate(header: header, lowest: base, highest: base + size, region: region) }
        else { #expect(throws: (any Error).self) { try FirmwareKernelDSC.validate(header: header, lowest: base, highest: base + size, region: region) } }
        put(UInt64.max, 0xF0)
        #expect(throws: (any Error).self) { try FirmwareKernelDSC.validate(header: header, lowest: base, highest: base + size, region: region) }
    }

    @Test(arguments: ["generation", "original"]) func changedPreviewInputRefused(_ change: String) throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        var generation = f.generation
        if change == "generation" {
            generation = .init(schemaVersion: generation.schemaVersion, id: String(repeating: "a", count: 64), content: generation.content)
        } else {
            let original = try FirmwareGeneration.originalURLs(in: f.vm, id: generation.id).first!
            if FileManager.default.fileExists(atPath: original.appendingPathComponent("kernelcache.research.vphone600").path) {
                try Data([9]).write(to: original.appendingPathComponent("kernelcache.research.vphone600"))
            } else { try FileManager.default.removeItem(at: original) }
        }
        #expect(throws: (any Error).self) { try FirmwareKernelUpdate.prepare(in: f.vm, plan: f.plan, generation: generation) }
    }

    @Test func readonlyDetachFailurePreventsReadbackSuccess() throws {
        let f = try FirmwareComponentReceiptTests.Fixture()
        let t = try FirmwareReceiptPublicationTests().begin(f)
        let image = f.generationFixture.disk
        var volumes: [String: FirmwareInstalledReadback.Volume] = [:]
        for (name, suffix) in ["system": "s1", "hardware": "s3", "preboot": "s5"] {
            let root = t.work.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            volumes[name] = .init(device: "disk998" + suffix, root: root)
        }
        let attachment = FirmwareInstalledReadback.Attachment(image: image, device: "/dev/disk999", volumes: volumes)
        var detachCount = 0
        let operations = FirmwareInstalledReadback.Operations(attach: { _, _ in attachment }, inspect: { _ in
            func plist(_ object: Any) throws -> Data { try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0) }
            return try .init(images: plist(["images": [["image-path": image.path, "system-entities": [["dev-entry": "/dev/disk999"]]]]]),
                containers: plist(["Containers": [["ContainerReference": "disk998", "PhysicalStores": [["DeviceIdentifier": "disk999s1"]],
                    "Volumes": volumes.values.map { ["DeviceIdentifier": $0.device, "MountPoint": $0.root.path] }]]]),
                volumes: volumes.mapValues { try plist(["DeviceIdentifier": $0.device, "MountPoint": $0.root.path, "ReadOnlyVolume": true]) })
        }, detach: { _ in detachCount += 1; throw POSIXError(.EIO) })
        #expect(throws: (any Error).self) {
            try FirmwareKernelMount.withVolumes(image: image, transaction: t, writable: false, operations: operations) { _ in }
        }
        #expect(detachCount == 1)
    }
}

extension FirmwareKernelOrchestrationTests {
    @Test(arguments: ["success", "missing", "uuid", "extra", "offset"]) func dscRequiresEveryReferencedSubcache(_ fault: String) throws {
        let system = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = system.appendingPathComponent("System/Cryptexes/OS/System/Library/Caches/com.apple.dyld")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: system) }
        let base: UInt64 = 0x180000000
        func chunk(_ address: UInt64, uuid: UInt8) -> Data {
            var data = Data(repeating: 0, count: 0x1000)
            data.replaceSubrange(0..<7, with: Data("dyld_v1".utf8))
            data.replaceSubrange(0x58..<0x68, with: Data(repeating: uuid, count: 16))
            func put<T: FixedWidthInteger>(_ value: T, _ offset: Int) {
                var le = value.littleEndian
                withUnsafeBytes(of: &le) { data.replaceSubrange(offset..<offset + MemoryLayout<T>.size, with: $0) }
            }
            put(UInt32(0x200), 0x10); put(UInt32(1), 0x14)
            put(base, 0xE0); put(UInt64(0x2000), 0xE8)
            put(address, 0x200); put(UInt64(0x1000), 0x208)
            if uuid == 1 {
                put(UInt32(0x280), 0x188); put(UInt32(1), 0x18C)
                data.replaceSubrange(0x280..<0x290, with: Data(repeating: 2, count: 16))
                put(UInt64(fault == "offset" ? 0x2000 : 0x1000), 0x290)
                data.replaceSubrange(0x298..<0x29B, with: Data(".01".utf8))
            }
            return data
        }
        let name = "dyld_shared_cache_arm64e"
        try chunk(base, uuid: 1).write(to: directory.appendingPathComponent(name))
        if fault != "missing" { try chunk(base + 0x1000, uuid: fault == "uuid" ? 3 : 2).write(to: directory.appendingPathComponent(name + ".01")) }
        if fault == "extra" { try chunk(base + 0x2000, uuid: 4).write(to: directory.appendingPathComponent(name + ".02")) }
        let region = FirmwareKernelRegion.Region(base: base, size: 6 << 30)
        if fault == "success" { try FirmwareKernelDSC.validate(system: system, region: region) }
        else { #expect(throws: (any Error).self) { try FirmwareKernelDSC.validate(system: system, region: region) } }
    }
}


extension FirmwareKernelOrchestrationTests {
    @Test func unrelatedJBLinkDoesNotBecomeKernelCandidate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("kernelcache")
        try Data([1]).write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("procursus"), withDestinationURL: root)
        #expect(try FirmwareKernelMount.uniqueKernel(in: root) == target)
    }
}

extension FirmwareKernelOrchestrationTests {
    @Test func gptAttachmentUsesBackingDeviceRatherThanSynthesizedContainer() throws {
        // Shape observed with hdiutil attach -readonly -nomount on the separate
        // 64 MiB APFS probe. No VM disk is attached by this test.
        let entities: [[String: Any]] = [
            ["dev-entry": "/dev/disk6", "content-hint": "GUID_partition_scheme"],
            ["dev-entry": "/dev/disk6s1", "content-hint": "Apple_APFS"],
            ["dev-entry": "/dev/disk7", "content-hint": "EF57347C-0000-11AA-AA11-00306543ECAC"],
            ["dev-entry": "/dev/disk7s1", "content-hint": "41504653-0000-11AA-AA11-00306543ECAC"],
        ]
        #expect(try FirmwareTransaction.detachDevice(entries: entities) == "/dev/disk6")
    }
}

extension FirmwareKernelOrchestrationTests {
    @Test(arguments: ["released", "readonly", "unknown"]) func recoveryRequiresConfiguredDiskReleased(_ state: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let images: [[String: Any]] = state == "released" ? [] : state == "readonly"
            ? [["image-path": root.appendingPathComponent("Disk.img").path, "writeable": false]] : [[:]]
        let data = try PropertyListSerialization.data(fromPropertyList: ["images": images], format: .xml, options: 0)
        if state == "released" { try FirmwareKernelUpdate.requireReleasedDisk(in: root, observation: data) }
        else { #expect(throws: (any Error).self) { try FirmwareKernelUpdate.requireReleasedDisk(in: root, observation: data) } }
    }
}

extension FirmwareKernelOrchestrationTests {
    @Test func diskutilWritableVolumeFieldIsAnExplicitReadonlyProof() throws {
        // Actual macOS probe output contains WritableVolume:false rather than
        // ReadOnlyVolume. Both representations must agree when both are present.
        #expect(try FirmwareInstalledReadback.volumeReadOnly(["WritableVolume": false, "WritableMedia": false]))
        #expect(try !FirmwareInstalledReadback.volumeReadOnly(["WritableVolume": true]))
        #expect(try FirmwareInstalledReadback.volumeReadOnly(["ReadOnlyVolume": true, "WritableVolume": false]))
        #expect(throws: (any Error).self) { try FirmwareInstalledReadback.volumeReadOnly([:]) }
        #expect(throws: (any Error).self) { try FirmwareInstalledReadback.volumeReadOnly(["ReadOnlyVolume": true, "WritableVolume": true]) }
        #expect(throws: (any Error).self) { try FirmwareInstalledReadback.volumeReadOnly(["ReadOnlyVolume": "unknown", "WritableVolume": false]) }
    }
}
