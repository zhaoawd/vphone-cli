import Darwin
import Foundation

let mode = CommandLine.arguments[1]
let output = URL(fileURLWithPath: CommandLine.arguments[2])
if mode.contains("ignored") { signal(SIGPIPE, SIG_IGN) }
var master: Int32 = -1
var slave: Int32 = -1
if mode != "pipe" {
    precondition(openpty(&master, &slave, nil, nil, nil) == 0)
    precondition(dup2(slave, STDERR_FILENO) == STDERR_FILENO)
    close(slave)
}
let bar = VPhoneProgressBar(label: "transferring")
if mode == "hangup" {
    close(master)
    master = -1
}
if mode.hasPrefix("broken") {
    var descriptors: [Int32] = [-1, -1]
    precondition(pipe(&descriptors) == 0)
    close(descriptors[0])
    precondition(dup2(descriptors[1], STDERR_FILENO) == STDERR_FILENO)
    close(descriptors[1])
}
try FileHandle.standardOutput.write(contentsOf: Data("ready\n".utf8))
_ = readLine()
let originalPipeFlag = fcntl(STDERR_FILENO, F_GETNOSIGPIPE)
// Drive the same nonthrowing callback used by VM import/export, between data writes.
let progress: (Int64, Int64) -> Void = { bar.update(done: $0, total: $1) }
if mode == "broken-tar" {
    let archive = URL(fileURLWithPath: CommandLine.arguments[3])
    let size = Int64(try Data(contentsOf: archive).count)
    let error = try VPhoneProcessRunner.runCountingTarPipe(
        producerArgs: nil, sourceFile: archive,
        consumerArgs: ["-xf", "-", "-C", output.deletingLastPathComponent().path],
        onBytes: { progress($0, size) })
    precondition(error == nil, error ?? "")
    bar.finish()
    print("completed")
    exit(0)
}
FileManager.default.createFile(atPath: output.path, contents: nil)
let data = try FileHandle(forWritingTo: output)
for index in 1...4 {
    try data.write(contentsOf: Data(repeating: UInt8(index), count: 1024))
    progress(Int64(index * 1024), 4096)
}
bar.finish()
precondition(fcntl(STDERR_FILENO, F_GETNOSIGPIPE) == originalPipeFlag)
try data.close()
if mode == "tty" {
    var buffer = [UInt8](repeating: 0, count: 8192)
    let count = read(master, &buffer, buffer.count)
    precondition(count > 0)
    try FileHandle.standardOutput.write(contentsOf: Data(buffer.prefix(count)))
}
if master >= 0 { close(master) }
print("completed")
