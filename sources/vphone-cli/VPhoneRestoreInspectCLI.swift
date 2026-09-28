import ArgumentParser
import Foundation
import VPhoneRestore

struct VPhoneRestoreInspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore-inspect",
        abstract: "Inspect a local restore directory and optional ticket without accessing a device",
        discussion: "Checks directory selection and plist structure only. Does not verify firmware completeness, Apple signatures, ticket/device association or restore readiness.")

    @Argument(help: "Directory containing one iPhone*_Restore tree") var directory: String
    @Option(help: "Optional hexadecimal ECID to parse; no device lookup") var ecid: String?
    @Option(help: "Optional UDID to normalize; no device lookup") var udid: String?
    @Option(help: "Explicit SHSH path; no automatic ticket selection") var ticket: String?
    @Flag(help: "Emit JSON") var json = false

    struct Report: Encodable {
        let restoreDirectory: String
        let ecidHex: String?
        let udid: String?
        let ticketPath: String?
        let ticketEncoding: String?
        let ticketPlistBytes: Int?
        let validationScope = "directory-selection-and-plist-structure"
        let deviceAccessPerformed = false
        let restorePerformed = false
    }

    func run() throws {
        let parsedECID = try VPhoneRestoreIdentity.parseECID(ecid)
        let tree = try VPhoneRestoreLayout.findRestoreDirectory(in: URL(fileURLWithPath: directory))
        var encoding: String?
        var count: Int?
        if let ticket {
            let path = URL(fileURLWithPath: ticket)
            let data = try VPhoneRestoreTicket.read(at: path)
            let plist = try VPhoneRestoreTicket.plistData(of: data, at: path)
            encoding = VPhoneRestoreTicket.isGzipped(data) ? "gzip-plist" : "plist"
            count = plist.count
        }
        let report = Report(
            restoreDirectory: tree.path, ecidHex: parsedECID.map(VPhoneRestoreIdentity.formatECID),
            udid: VPhoneRestoreIdentity.normalizeUDID(udid), ticketPath: ticket,
            ticketEncoding: encoding, ticketPlistBytes: count)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
            print("Restore directory: \(report.restoreDirectory)")
            if let value = report.ecidHex { print("Requested ECID: \(value)") }
            if let count { print("Ticket plist dictionary: \(count) bytes") }
            print("Offline structure check only; device access and restore were not performed.")
        }
    }
}
