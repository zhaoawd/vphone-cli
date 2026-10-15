import ArgumentParser
import Foundation
import Testing
@testable import vphone_cli

struct KernelUpdateCLITests {
    @Test func routesExplicitCommittedKernelRollback() throws {
        for options in [["--list"], ["--to-transaction", UUID().uuidString.lowercased(), "--preview"], ["--to-transaction", UUID().uuidString.lowercased()]] {
            let command = try VPhoneVMCommand.parseAsRoot(["rollback-kernel", "test"] + options)
            #expect(String(describing: type(of: command)) == "VPhoneVMRollbackKernelCommand")
        }
    }
    @Test func routesKernelUpdateAndExplicitRecovery() throws {
        let update = try VPhoneVMCommand.parseAsRoot(["update-kernel", "test", "--library-root", "/tmp/test-vms"])
        #expect(update is VPhoneVMUpdateKernelCommand)
        let recovery = try VPhoneVMUpdateKernelCommand.parse(["test", "--recover"])
        #expect(recovery.recover)
        #expect(recovery.name == "test")
        let hash = String(repeating: "a", count: 64)
        let launched = try VPhoneVMUpdateKernelCommand.parse(["test", "--expected-binding-sha256", hash, "--expected-core-bundle", "2.6.1"])
        #expect(launched.expectedBindingSha256 == hash)
        #expect(launched.expectedCoreBundle == "2.6.1")
        #expect(throws: (any Error).self) { try VPhoneVMUpdateKernelCommand.parse(["test", "--variant", "jb"]) }
    }
}

extension KernelUpdateCLITests {
    @Test(arguments: [[String](), ["--preview"], ["--list", "--preview"], ["--list", "--to-transaction", "invalid"], ["--to-transaction", "../target"], ["--to-transaction", "abc"], ["--list", "--recover"]])
    func rollbackRequiresOneExplicitSelection(_ options: [String]) throws {
        #expect(throws: (any Error).self) { try VPhoneVMRollbackKernelCommand.parse(["test"] + options) }
    }
}
