import Foundation
import MobileRestoreCore
import Testing
@testable import VPhoneRestore

struct RestoreSafetyTests {
    func temporary(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func selectionRequiresUniqueECID() throws {
        try temporary { root in
            let dir = root.appendingPathComponent("shsh", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            let first = dir.appendingPathComponent("123-iPhone-1.shsh")
            try Data().write(to: first)
            let selected = try VPhoneRestoreService.locateWrittenSHSH(under: root, requestedECID: 123)
            #expect(selected.resolvingSymlinksInPath().path == first.resolvingSymlinksInPath().path)
            #expect(throws: VPhoneRestoreBackendError.shshSelectionAmbiguous(dir)) {
                try VPhoneRestoreService.locateWrittenSHSH(under: root, requestedECID: 456)
            }
            try Data().write(to: dir.appendingPathComponent("123-iPhone-2.shsh"))
            #expect(throws: VPhoneRestoreBackendError.shshSelectionAmbiguous(dir)) {
                try VPhoneRestoreService.locateWrittenSHSH(under: root, requestedECID: 123)
            }
            #expect(throws: VPhoneRestoreBackendError.shshSelectionAmbiguous(dir)) {
                try VPhoneRestoreService.locateWrittenSHSH(under: root, requestedECID: nil)
            }
        }
    }

    @Test func symbolicLinksAreNotRestoreTreesOrTickets() throws {
        try temporary { root in
            let target = root.appendingPathComponent("target")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("iPhone_test_Restore"), withDestinationURL: target)
            #expect(throws: VPhoneRestoreBackendError.noRestoreDirectory(root)) {
                try VPhoneRestoreLayout.findRestoreDirectory(in: root)
            }
            let ticket = root.appendingPathComponent("ticket.shsh")
            try Data("sample".utf8).write(to: ticket)
            let link = root.appendingPathComponent("link.shsh")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: ticket)
            #expect(throws: VPhoneRestoreBackendError.ticketUnreadable(link)) {
                try VPhoneRestoreTicket.read(at: link)
            }
        }
    }

    @Test func oversizedFilesAreRejectedBeforeRead() throws {
        try temporary { root in
            let path = root.appendingPathComponent("ticket.shsh")
            FileManager.default.createFile(atPath: path.path, contents: Data())
            let file = try FileHandle(forWritingTo: path)
            try file.truncate(atOffset: UInt64(VPhoneRestoreTicket.maximumBytes + 1))
            try file.close()
            #expect(throws: VPhoneRestoreBackendError.shshTooLarge(path)) {
                try VPhoneRestoreTicket.read(at: path)
            }
        }
    }

    @Test func filenamesRequireDecimalPrefixAndExtension() {
        for name in ["123junk.shsh", "123", "123-product.txt", "-product.shsh"] {
            #expect(VPhoneRestoreTicket.ecid(fromSHSHFilename: name) == nil)
        }
    }

    @Test func probeModeSelectionRejectsUnknownModes() {
        for selection: Bool? in [nil, true, false] {
            #expect(!VPhoneRecoveryProbe.matches(mode: .init(rawValue: 0x7777), isRecovery: selection))
        }
        #expect(VPhoneRecoveryProbe.matches(mode: .dfu, isRecovery: false))
        #expect(VPhoneRecoveryProbe.matches(mode: .portDFU, isRecovery: nil))
        #expect(!VPhoneRecoveryProbe.matches(mode: .dfu, isRecovery: true))
        #expect(VPhoneRecoveryProbe.matches(mode: .recovery2, isRecovery: true))
    }

    @Test func resultMappingDoesNotAccessDevice() throws {
        let options = VPhoneRestoreOptions(restoreDirectory: URL(fileURLWithPath: "/unused"))
        try VPhoneRestoreRunner.throwIfFailed(VPHONE_RESTORE_OK, options: options)
        #expect(throws: VPhoneRestoreBackendError.restoreAlreadyRunning) {
            try VPhoneRestoreRunner.throwIfFailed(VPHONE_RESTORE_E_BUSY, options: options)
        }
        #expect(throws: VPhoneRestoreBackendError.ticketUnreadable(options.restoreDirectory)) {
            try VPhoneRestoreRunner.throwIfFailed(VPHONE_RESTORE_E_TICKET, options: options)
        }
        do {
            try VPhoneRestoreRunner.throwIfFailed(-999, options: options)
            Issue.record("Expected unknown return code to fail")
        } catch VPhoneRestoreBackendError.restoreFailed(let code, _) {
            #expect(code == -999)
        }
    }
}
