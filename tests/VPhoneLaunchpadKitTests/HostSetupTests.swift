import Foundation
import Testing
import VPhoneCore
@testable import VPhoneLaunchpadKit

// MARK: - doctor fixtures

/// `doctor --json` documents written by the CLI's own encoder
/// (`VPhoneDiagnosticReport.jsonData()`), with findings modelled on the
/// local host run recorded in research/t26_b5_launchpad_2026-10-01.md.
enum DoctorFixtures {
    static let findings: [VPhoneDiagnosticFinding] = [
        .init(.environment, .macosVersion, .ok, "macOS 27.0.0", evidence: ["macos": "27.0.0"]),
        .init(.environment, .sipStatus, .warning,
              "SIP is partially enabled; launching the signed binary depends on an AMFI bypass such as amfidont",
              evidence: ["status": "custom configuration", "csr_active_config": "0x00001004"],
              action: "make amfidont_allow_vphone (or disable SIP from Recovery OS)"),
        .init(.internal, .checkFailed, .unknown, "the occupancy check could not run", evidence: ["reason": "ps failed"]),
        .init(.environment, .hostArchitecture, .error, "host is not Apple silicon", evidence: ["hw.optional.arm64": "0"]),
        .init(.occupancy, .libraryLock, .ok, "library lock is free", evidence: ["held": "false"]),
    ]

    static func report(_ findings: [VPhoneDiagnosticFinding] = findings) -> VPhoneDiagnosticReport {
        VPhoneDiagnosticReport(
            vm: nil, libraryRoot: URL(fileURLWithPath: "/fixture/VMs"), toolCommit: "fixture", findings: findings,
            redactor: VPhoneDiagnosticRedactor(homePath: "/Users/fixture"),
            generatedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    static func json(_ findings: [VPhoneDiagnosticFinding] = findings) throws -> String {
        String(decoding: try report(findings).jsonData(), as: UTF8.self)
    }
}

// MARK: - Mapping

struct HostSetupMappingTests {
    @Test func severitiesMatchTheDoctorSchema() {
        #expect(VPhoneLaunchpadCheckSeverity.allCases.map(\.rawValue) == VPhoneDiagnosticSeverity.allCases.map(\.rawValue))
        #expect(VPhoneLaunchpadCheckSeverity(doctorValue: "fatal") == .unknown)
        #expect(VPhoneLaunchpadDiagnosticReport.schemaName == VPhoneDiagnosticReport.schema)
        #expect(VPhoneLaunchpadDiagnosticReport.schemaVersion == VPhoneDiagnosticReport.schemaVersion)
    }

    @Test func reportMapsToRowsWithEachSeverity() throws {
        let fixture = DoctorFixtures.report()
        let state = VPhoneLaunchpadHostSetup.doctorState(.fixture(status: fixture.exitCode, output: try DoctorFixtures.json()))
        guard case let .report(report, status) = state else {
            Issue.record("expected a report, got \(state)")
            return
        }
        #expect(status == 5)
        #expect(report.summary.exitCode == 5)
        #expect(report.worst == .error)
        #expect(report.scope.libraryRoot == "/fixture/VMs")
        #expect(report.toolCommit == "fixture")

        // doctor orders by category: environment, occupancy, internal.
        #expect(report.sections.map(\.category) == ["environment", "occupancy", "internal"])
        let rows = report.rows
        #expect(rows.map(\.code) == ["macos_version", "sip_status", "host_architecture", "library_lock", "check_failed"])
        #expect(rows.map(\.severity) == [.ok, .warning, .error, .ok, .unknown])
        #expect(rows.map(\.id) == [0, 1, 2, 3, 4])
        #expect(VPhoneLaunchpadCheckSeverity.allCases.map(report.count) == [2, 1, 1, 1])

        let sip = rows[1]
        #expect(sip.category == "environment")
        #expect(sip.suggestedAction == "make amfidont_allow_vphone (or disable SIP from Recovery OS)")
        #expect(sip.evidence.map(\.key) == ["csr_active_config", "status"])
        #expect(sip.vm == nil)
        #expect(rows[0].suggestedAction == nil)
    }

    @Test func allOkReportIsExitZero() throws {
        let ok = [DoctorFixtures.findings[0], DoctorFixtures.findings[4]]
        let state = VPhoneLaunchpadHostSetup.doctorState(.fixture(status: 0, output: try DoctorFixtures.json(ok)))
        guard case let .report(report, 0) = state else {
            Issue.record("expected a report with exit 0, got \(state)")
            return
        }
        #expect(report.worst == .ok)
        #expect(report.rows.allSatisfy { $0.severity == .ok })
    }

    @Test func warningAndUnknownExitStatusesCarryAReport() throws {
        for (findings, status, worst) in [
            ([DoctorFixtures.findings[1]], Int32(3), VPhoneLaunchpadCheckSeverity.warning),
            ([DoctorFixtures.findings[1], DoctorFixtures.findings[2]], 4, .unknown),
        ] {
            #expect(DoctorFixtures.report(findings).exitCode == status)
            let state = VPhoneLaunchpadHostSetup.doctorState(.fixture(status: status, output: try DoctorFixtures.json(findings)))
            guard case let .report(report, reported) = state else {
                Issue.record("expected a report for exit \(status), got \(state)")
                continue
            }
            #expect(reported == status)
            #expect(report.worst == worst)
        }
    }

    @Test func unknownSeverityFromANewerCLIIsShownAsUnknown() throws {
        let json = try DoctorFixtures.json([DoctorFixtures.findings[0]])
            .replacingOccurrences(of: "\"severity\" : \"ok\"", with: "\"severity\" : \"fatal\"")
        let state = VPhoneLaunchpadHostSetup.doctorState(.fixture(status: 5, output: json))
        guard case let .report(report, _) = state else {
            Issue.record("expected a report, got \(state)")
            return
        }
        #expect(report.rows.map(\.severity) == [.unknown])
    }

    @Test func failuresCarryTheCLIReason() throws {
        let usage = VPhoneLaunchpadHostSetup.doctorState(.fixture(status: 64, output: """
        Error: Unknown option '--bogus'
        Usage: vphone-cli doctor [--library-root <library-root>] [<name>] [--json]
        """))
        #expect(usage == .failed("Unknown option '--bogus'"))

        let silent = VPhoneLaunchpadHostSetup.doctorState(.fixture(status: 3, output: "no document here"))
        #expect(silent == .failed("doctor printed no JSON document (exit status 3)."))

        let otherSchema = try DoctorFixtures.json().replacingOccurrences(of: "\"schema_version\" : 1", with: "\"schema_version\" : 2")
        #expect(VPhoneLaunchpadHostSetup.doctorState(.fixture(status: 5, output: otherSchema))
            == .failed("Unsupported doctor schema vphone.diagnostics version 2."))

        let writable = try DoctorFixtures.json().replacingOccurrences(of: "\"read_only\" : true", with: "\"read_only\" : false")
        #expect(VPhoneLaunchpadHostSetup.doctorState(.fixture(status: 5, output: writable))
            == .failed("The doctor report is not marked read-only."))
    }

    @Test func warningLinesBeforeTheDocumentAreSkipped() throws {
        let output = "warning: skipping broken: config.plist unreadable\n" + (try DoctorFixtures.json())
        guard case .report = VPhoneLaunchpadHostSetup.doctorState(.fixture(status: 5, output: output)) else {
            Issue.record("expected a report")
            return
        }
    }
}

// MARK: - Helper status

struct HelperStatusTests {
    @Test func reachableHelperReportsItsProtocol() {
        let status = VPhoneLaunchpadHelperStatus(.fixture(status: 0, output: "helper protocol: 1\n"))
        #expect(status.state == .reachable(protocolVersion: "1"))
        #expect(status.output == "helper protocol: 1")
        #expect(status.exitStatus == 0)
    }

    /// The output recorded on this host (no signing team configured).
    @Test func unconfiguredHelperIsUnavailableWithTheCLIReason() {
        let output = """
        Error: Helper signing team is not configured. Supply a valid 10-character Apple Team ID and matching signing identity.
        Usage: vphone-cli <subcommand>
          See 'vphone-cli --help' for more information.
        """
        let status = VPhoneLaunchpadHelperStatus(.fixture(status: 64, output: output))
        #expect(status.state == .unavailable(reason:
            "Helper signing team is not configured. Supply a valid 10-character Apple Team ID and matching signing identity."))
        #expect(status.output == output)
        #expect(status.exitStatus == 64)
    }

    @Test func exitZeroWithoutAProtocolLineIsUnavailable() {
        let status = VPhoneLaunchpadHelperStatus(.fixture(status: 0, output: "something else\n"))
        #expect(status.state == .unavailable(reason: "something else"))
    }
}

// MARK: - Model with a stand-in CLI

@MainActor
struct HostSetupModelTests {
    let temp: LaunchpadTemporaryDirectory
    let cli: LaunchpadStandInCLI

    init() throws {
        temp = try LaunchpadTemporaryDirectory()
        cli = try LaunchpadStandInCLI(in: temp.url)
    }

    @Test func refreshRunsDoctorThenHelperStatusOnly() async throws {
        let findings = [DoctorFixtures.findings[0], DoctorFixtures.findings[1]]
        try cli.respond("doctor", output: try DoctorFixtures.json(findings), status: 3)
        try cli.respond("helper", output: "Error: Helper signing team is not configured.\n", status: 64)

        let host = VPhoneLaunchpadHostSetup(commandLine: cli.commandLine(), libraryRoot: "/fixture/VMs")
        // Creating the model runs nothing; doctor waits for the panel.
        #expect(cli.recorded.isEmpty)
        #expect(host.doctor == .notRun)
        #expect(host.helper == nil)

        await host.refresh()
        #expect(cli.recorded == ["doctor --json --library-root /fixture/VMs", "helper status"])
        #expect(cli.recorded.allSatisfy { VPhoneLaunchpadReadOnlyCommand.isAllowed($0.split(separator: " ").map(String.init)) })
        guard case let .report(report, 3) = host.doctor else {
            Issue.record("expected a report with exit 3, got \(host.doctor)")
            return
        }
        #expect(report.rows.map(\.severity) == [.ok, .warning])
        #expect(host.sections.map(\.category) == ["environment"])
        #expect(host.helper?.state == .unavailable(reason: "Helper signing team is not configured."))
        #expect(host.isChecking == false)
        #expect(host.checkedAt != nil)
    }

    @Test func relativeLibraryRootRunsNoDoctor() async throws {
        try cli.respond("helper", output: "helper protocol: 1\n", status: 0)
        let host = VPhoneLaunchpadHostSetup(commandLine: cli.commandLine(), libraryRoot: "relative/VMs")
        await host.refresh()
        #expect(cli.recorded == ["helper status"])
        #expect(host.doctor == .failed("The library root is not an absolute path: relative/VMs"))
        #expect(host.helper?.state == .reachable(protocolVersion: "1"))
    }
}
