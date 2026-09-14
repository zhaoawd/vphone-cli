@testable import VPhoneCore
import Foundation
import Testing

struct ResourcesTests {
    @Test func bundledLayoutResolvesToContentsResources() {
        let exe = "/Applications/vphone-cli.app/Contents/MacOS/vphone-cli"
        let r = VPhoneResources.resolve(executablePath: exe)
        #expect(r.base.path == "/Applications/vphone-cli.app/Contents/Resources")
        #expect(r.fwPrepareScript.path == "/Applications/vphone-cli.app/Contents/Resources/scripts/fw_prepare.sh")
        #expect(r.cfwPy.path == "/Applications/vphone-cli.app/Contents/Resources/scripts/patchers/cfw.py")
    }

    @Test func symlinkLaunchResolvesBundleAndCertificate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("App.app/Contents/MacOS/vphone-cli")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: executable)
        let link = root.appendingPathComponent("launcher")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        let resources = VPhoneResources.resolve(executablePath: link.path)
        let expected = root.resolvingSymlinksInPath().appendingPathComponent("App.app/Contents/Resources")
        #expect(resources.base == expected)
        #expect(resources.signcert == expected.appendingPathComponent("scripts/vphoned/signcert.p12"))
    }

    @Test func devLayoutWalksUpToProjectRoot() throws {
        // Fake a dev tree: <root>/.build/release/vphone-cli with a <root>/scripts dir.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".build/release"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let exe = root.appendingPathComponent(".build/release/vphone-cli").path
        let r = VPhoneResources.resolve(executablePath: exe)
        #expect(r.base.path == root.resolvingSymlinksInPath().path)
        #expect(r.resourceArchivesDir.path == root.resolvingSymlinksInPath()
            .appendingPathComponent("scripts/resources").path)
    }

    @Test func cacheDirsAreHomeRelativeAndToolsBinIsBaseRelative() {
        let r = VPhoneResources(base: URL(fileURLWithPath: "/Applications/vphone-cli.app/Contents/Resources"), environment: [:])
        #expect(r.userCacheDir.path.hasSuffix("/.vphone"))
        #expect(r.toolsBinDir.path == r.base.appendingPathComponent(".tools/bin").path)
    }

    /// These all shell out; a missing interpreter must return false, not throw.
    @Test func venvProbesAreTotalForAMissingInterpreter() {
        let r = VPhoneResources(base: URL(fileURLWithPath: "/x"), environment: [:])
        let missing = URL(fileURLWithPath: "/nonexistent/bin/python3")
        #expect(r.pythonIsUsable(missing) == false)
    }

    @Test func explicitPythonMustPassFullLockedProbe() {
        let resources = VPhoneResources(base: URL(fileURLWithPath: "/missing-resources"),
                                        environment: ["VPHONE_PYTHON": "/usr/bin/false"])
        #expect(throws: VPhoneResourcesError.self) {
            try resources.pythonExecutable()
        }
    }

    @Test func managedVenvDefaultsUnderDotVphone() {
        let r = VPhoneResources(base: URL(fileURLWithPath: "/x"), environment: [:])
        #expect(r.managedVenvDir.path.hasSuffix("/.vphone/venv"))
    }

    @Test func userCacheDirHonorsVPHONERoot() {
        let r = VPhoneResources(base: URL(fileURLWithPath: "/x"),
                                environment: ["VPHONE_ROOT": "/tmp/vphone-test-root"])
        #expect(r.userCacheDir.path == "/tmp/vphone-test-root")
        #expect(r.ipswCacheDir.path == "/tmp/vphone-test-root/ipsws")
        #expect(r.sealVolumeCacheDir.path == "/tmp/vphone-test-root/tools")
        #expect(r.debsCacheDir.path == "/tmp/vphone-test-root/debs")
        #expect(r.managedVenvDir.path == "/tmp/vphone-test-root/venv")
    }

    @Test func managedVenvOverrideBeatsVPHONERoot() {
        let r = VPhoneResources(base: URL(fileURLWithPath: "/x"), environment: [
            "VPHONE_ROOT": "/tmp/vphone-test-root", "VPHONE_VENV_DIR": "/tmp/custom-venv",
        ])
        #expect(r.managedVenvDir.path == "/tmp/custom-venv")
    }

    @Test func pythonUsabilityProbeRejectsMissingAcceptsDevVenv() {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let r = VPhoneResources(base: cwd)
        // A non-existent interpreter is never usable.
        #expect(r.pythonIsUsable(URL(fileURLWithPath: "/does/not/exist/python3")) == false)
        // The dev .venv (when present) carries a modern ipsw_parser and must pass.
        let devVenv = cwd.appendingPathComponent(".venv/bin/python3")
        if FileManager.default.isExecutableFile(atPath: devVenv.path) {
            #expect(r.pythonIsUsable(devVenv) == true)
        }
    }
}
