import Foundation
import Testing
@testable import VPhoneLaunchpadKit

// MARK: - Stand-in vphone-cli for the B5 panels

/// A shell script in place of `vphone-cli`. It appends its arguments to
/// `arguments.log`, then prints `<name>.out` and exits with `<name>.status`,
/// where the name is `doctor`, `helper` or `verify-<version>`. Any other
/// command exits 99 without output.
struct LaunchpadStandInCLI {
    let directory: URL
    let script: URL
    let argumentLog: URL

    init(in directory: URL) throws {
        self.directory = directory
        script = directory.appendingPathComponent("vphone-cli")
        argumentLog = directory.appendingPathComponent("arguments.log")
        let d = directory.path
        try """
        #!/bin/sh
        echo "$*" >> '\(argumentLog.path)'
        case "$1 $2" in
          "doctor --json") name=doctor ;;
          "helper status") name=helper ;;
          "core-bundle verify") name="verify-$4" ;;
          *) exit 99 ;;
        esac
        [ -e '\(d)/'"$name.out" ] && cat '\(d)/'"$name.out"
        exit "$(cat '\(d)/'"$name.status" 2>/dev/null || echo 98)"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    func respond(_ name: String, output: String, status: Int32) throws {
        try output.write(to: directory.appendingPathComponent("\(name).out"), atomically: true, encoding: .utf8)
        try "\(status)\n".write(to: directory.appendingPathComponent("\(name).status"), atomically: true, encoding: .utf8)
    }

    /// Each recorded command line, in order; empty when nothing ran.
    var recorded: [String] {
        guard let text = try? String(contentsOf: argumentLog, encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n").map(String.init)
    }

    @MainActor
    func commandLine() -> VPhoneLaunchpadCommandLine {
        VPhoneLaunchpadCommandLine(executable: script, history: VPhoneLaunchpadCommandHistory())
    }
}

extension VPhoneLaunchpadCommandResult {
    /// A result as `VPhoneLaunchpadCommandLine.run` collects it: output split
    /// into lines.
    static func fixture(status: Int32, output: String) -> Self {
        var lines = output.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }
        return Self(status: status, lines: lines)
    }
}
