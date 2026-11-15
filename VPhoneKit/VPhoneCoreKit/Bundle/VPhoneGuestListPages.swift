import Foundation

/// Collects a paged guest listing for consumers that need the complete list.
/// Older daemons omit paging metadata and finish after the first reply.
public struct VPhoneGuestListPages {
    public enum Failure: Error { case invalidPage, repeatedCursor, tooManyRows }
    private let key: String
    private var rows: [Any] = []
    private var cursors: Set<String> = []
    private var first: [String: Any]?
    public private(set) var result: [String: Any] = [:]

    public init(key: String) { self.key = key }

    /// Appends one reply and returns the next cursor, or nil at completion.
    public mutating func append(_ page: [String: Any]) throws -> String? {
        guard let batch = page[key] as? [Any] else { throw Failure.invalidPage }
        guard rows.count <= 100_000 - batch.count else { throw Failure.tooManyRows }
        if first == nil { first = page }
        rows += batch
        if page["truncated"] as? Bool == true {
            guard let cursor = page["next_cursor"] as? String, !cursor.isEmpty, !batch.isEmpty else {
                throw Failure.invalidPage
            }
            guard cursors.insert(cursor).inserted else { throw Failure.repeatedCursor }
            return cursor
        }
        result = first ?? page
        result[key] = rows
        if result["count"] != nil { result["count"] = rows.count }
        if result["total"] != nil { result["total"] = rows.count }
        if result["truncated"] != nil { result["truncated"] = false }
        result.removeValue(forKey: "next_cursor")
        return nil
    }
}
