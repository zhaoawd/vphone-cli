import Foundation
import Testing
@testable import VPhoneCoreKit

struct GuestListPagesTests {
    @Test func legacyReply() throws {
        var pages = VPhoneGuestListPages(key: "entries")
        let reply: [String: Any] = ["entries": ["a", "b"], "path": "/tmp"]
        #expect(try pages.append(reply) == nil)
        #expect(NSDictionary(dictionary: pages.result).isEqual(to: reply))
    }

    @Test func multiplePages() throws {
        var pages = VPhoneGuestListPages(key: "processes")
        #expect(try pages.append(["processes": [1, 2], "count": 2, "total": 3, "truncated": true, "next_cursor": "2"]) == "2")
        #expect(try pages.append(["processes": [3], "count": 1, "total": 3, "truncated": false]) == nil)
        #expect(pages.result["processes"] as? [Int] == [1, 2, 3])
        #expect(pages.result["count"] as? Int == 3)
        #expect(pages.result["truncated"] as? Bool == false)
        #expect(pages.result["next_cursor"] == nil)
    }

    @Test func rejectsBrokenProgress() throws {
        var pages = VPhoneGuestListPages(key: "entries")
        #expect(throws: (any Error).self) { try pages.append(["entries": [], "truncated": true, "next_cursor": "2"]) }
        _ = try pages.append(["entries": [1], "truncated": true, "next_cursor": "2"])
        #expect(throws: (any Error).self) { try pages.append(["entries": [2], "truncated": true, "next_cursor": "2"]) }
        #expect(throws: (any Error).self) { try pages.append(["entries": [3], "truncated": true]) }
    }
}
