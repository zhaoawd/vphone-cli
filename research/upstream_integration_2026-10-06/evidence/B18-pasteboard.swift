import AppKit
import Darwin
let args = CommandLine.arguments
let pb = NSPasteboard.general
let backup = URL(fileURLWithPath: "/private/tmp/vphone-b18-private-pasteboard.plist")
let text = "B18-MAC-paste-20261008"
switch args[1] {
case "backup":
    var bytes = 0
    let items: [[String: Data]] = try (pb.pasteboardItems ?? []).map { item in
        var record: [String: Data] = [:]
        for type in item.types {
            guard let data = item.data(forType: type) else { throw NSError(domain: "backup", code: 1) }
            bytes += data.count
            guard bytes <= 16 * 1024 * 1024 else { throw NSError(domain: "backup", code: 2) }
            record[type.rawValue] = data
        }
        return record
    }
    let data = try PropertyListSerialization.data(fromPropertyList: items, format: .binary, options: 0)
    let fd = open(backup.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { fatalError("private backup already exists or cannot be created") }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    try file.write(contentsOf: data); try file.synchronize(); try file.close()
    print("private original clipboard backup saved; values omitted")
case "set":
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    item.setData(Data("{\\rtf1\\ansi B18-MAC-paste-20261008}".utf8), forType: .rtf)
    pb.clearContents(); guard pb.writeObjects([item]) else { fatalError("write failed") }
    print("test plain text and RTF set; changeCount=\(pb.changeCount)")
case "assert":
    guard pb.string(forType: .string) == text else { fatalError("test text not present; private value omitted") }
    guard pb.data(forType: .rtf) == Data("{\\rtf1\\ansi B18-MAC-paste-20261008}".utf8) else { fatalError("test RTF not preserved") }
    print("test text and RTF preserved; changeCount=\(pb.changeCount)")
case "restore":
    guard pb.string(forType: .string) == text, pb.data(forType: .rtf) == Data("{\\rtf1\\ansi B18-MAC-paste-20261008}".utf8) else { fatalError("clipboard changed independently; refuse overwrite") }
    let records = try PropertyListSerialization.propertyList(from: Data(contentsOf: backup), options: [], format: nil) as! [[String: Data]]
    let items = records.map { record -> NSPasteboardItem in let item = NSPasteboardItem(); for (type,data) in record { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }; return item }
    pb.clearContents(); if !items.isEmpty { guard pb.writeObjects(items) else { fatalError("restore failed") } }
    let readback = (pb.pasteboardItems ?? []).map { item -> [String: Data] in var v: [String: Data] = [:]; for type in item.types { v[type.rawValue] = item.data(forType: type) }; return v }
    guard readback == records else { fatalError("clipboard restore readback differs") }
    print("original clipboard items/types/data restored; values omitted; original changeCount cannot be restored")
default: fatalError("unknown mode")
}
