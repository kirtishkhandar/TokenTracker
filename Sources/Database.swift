import Foundation
import SQLite3

/// Read-only access to the usage SQLite database written by the proxy.
class UsageDB {
    private let path: String

    init(path: String) {
        self.path = path
    }

    // MARK: - Fetch Requests

    func fetchRequests(from start: Date, to end: Date,
                       limit: Int = 500) -> [UsageRecord] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT id, timestamp, model, endpoint,
                   input_tokens, output_tokens,
                   cache_creation_input_tokens, cache_read_input_tokens,
                   status_code, request_id, stop_reason, caller, error
            FROM requests
            WHERE timestamp >= ? AND timestamp <= ?
            ORDER BY timestamp DESC
            LIMIT ?
        """

        guard let stmt = prepare(db: db, sql: sql) else { return [] }
        defer { sqlite3_finalize(stmt) }

        let startISO = iso8601(start)
        let endISO = iso8601(end)

        sqlite3_bind_text(stmt, 1, (startISO as NSString).utf8String,
                          -1, nil)
        sqlite3_bind_text(stmt, 2, (endISO as NSString).utf8String,
                          -1, nil)
        sqlite3_bind_int(stmt, 3, Int32(limit))

        var records: [UsageRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            records.append(UsageRecord(
                id: Int(sqlite3_column_int(stmt, 0)),
                timestamp: parseDate(column(stmt, 1)),
                model: column(stmt, 2),
                endpoint: column(stmt, 3),
                inputTokens: Int(sqlite3_column_int(stmt, 4)),
                outputTokens: Int(sqlite3_column_int(stmt, 5)),
                cacheCreationInputTokens: Int(sqlite3_column_int(stmt, 6)),
                cacheReadInputTokens: Int(sqlite3_column_int(stmt, 7)),
                statusCode: Int(sqlite3_column_int(stmt, 8)),
                requestId: column(stmt, 9),
                stopReason: column(stmt, 10),
                caller: column(stmt, 11),
                error: column(stmt, 12)
            ))
        }
        return records
    }

    // MARK: - Summaries

    func modelSummaries(from start: Date, to end: Date) -> [ModelSummary] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT model,
                   COUNT(*) as cnt,
                   SUM(input_tokens),
                   SUM(output_tokens)
            FROM requests
            WHERE timestamp >= ? AND timestamp <= ?
              AND status_code = 200
            GROUP BY model
            ORDER BY SUM(input_tokens + output_tokens) DESC
        """

        guard let stmt = prepare(db: db, sql: sql) else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1,
                          (iso8601(start) as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2,
                          (iso8601(end) as NSString).utf8String, -1, nil)

        var results: [ModelSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let model = column(stmt, 0)
            let input = Int(sqlite3_column_int(stmt, 2))
            let output = Int(sqlite3_column_int(stmt, 3))
            results.append(ModelSummary(
                model: model,
                requestCount: Int(sqlite3_column_int(stmt, 1)),
                inputTokens: input,
                outputTokens: output,
                estimatedCost: TokenPricing.cost(
                    model: model, inputTokens: input, outputTokens: output)
            ))
        }
        return results
    }

    func dailySummaries(from start: Date, to end: Date) -> [DailySummary] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT DATE(timestamp) as day,
                   COUNT(*) as cnt,
                   SUM(input_tokens),
                   SUM(output_tokens)
            FROM requests
            WHERE timestamp >= ? AND timestamp <= ?
              AND status_code = 200
            GROUP BY DATE(timestamp)
            ORDER BY day DESC
        """

        guard let stmt = prepare(db: db, sql: sql) else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1,
                          (iso8601(start) as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2,
                          (iso8601(end) as NSString).utf8String, -1, nil)

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"

        var results: [DailySummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let dayStr = column(stmt, 0)
            let input = Int(sqlite3_column_int(stmt, 2))
            let output = Int(sqlite3_column_int(stmt, 3))
            let model = "claude-sonnet-4" // rough avg for daily summary
            results.append(DailySummary(
                date: dateFmt.date(from: dayStr) ?? Date(),
                requestCount: Int(sqlite3_column_int(stmt, 1)),
                inputTokens: input,
                outputTokens: output,
                estimatedCost: TokenPricing.cost(
                    model: model, inputTokens: input, outputTokens: output)
            ))
        }
        return results
    }

    // MARK: - Helpers

    private func open() -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            return nil
        }
        return db
    }

    private func prepare(db: OpaquePointer,
                         sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        return stmt
    }

    private func column(_ stmt: OpaquePointer, _ index: Int32) -> String {
        if let cStr = sqlite3_column_text(stmt, index) {
            return String(cString: cStr)
        }
        return ""
    }

    private func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func parseDate(_ str: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: str) ?? Date()
    }
}
