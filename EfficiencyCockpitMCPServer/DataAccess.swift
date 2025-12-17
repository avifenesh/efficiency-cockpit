import Foundation
import SQLite3

// SQLITE_TRANSIENT tells SQLite to copy the string immediately, preventing memory corruption
// when Swift deallocates the temporary string before SQLite uses it
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Shared data access for MCP Server
/// Reads from the SwiftData SQLite database created by the main app
///
/// ## Thread Safety
/// WARNING: This class is NOT thread-safe. All database operations must be called
/// from the same thread/queue. The current implementation is safe because the MCP
/// server processes requests sequentially via readLine(). If concurrent access is
/// needed in the future, wrap all database operations in a serial queue.
final class DataAccess {
    private var db: OpaquePointer?
    private let dbPath: String

    /// Cache for Z_ENT values to avoid repeated lookups
    private var entityTypeCache: [String: Int32] = [:]

    /// Cached ISO8601 date formatter (DateFormatter is expensive to create)
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()

    /// Track whether FTS tables have been created
    private var ftsTablesCreated = false

    init() {
        // SwiftData stores in Application Support
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            print("[DataAccess] FATAL: Unable to locate Application Support directory")
            dbPath = ""
            return
        }
        let appFolder = appSupport.appendingPathComponent("EfficiencyCockpit")
        dbPath = appFolder.appendingPathComponent("default.store").path

        openDatabase()
        createFTSTables()
    }

    deinit {
        closeDatabase()
    }

    private func openDatabase() {
        // Open with read-write mode and WAL for concurrent access with main app
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        if sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK {
            // Enable WAL mode for better concurrent access (allows readers while writing)
            sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
            // Set busy timeout to wait for locks instead of failing immediately (5 seconds)
            sqlite3_busy_timeout(db, 5000)
        } else {
            print("[DataAccess] Failed to open database at \(dbPath)")
            db = nil
        }
    }

    private func closeDatabase() {
        if let db = db {
            sqlite3_close(db)
        }
        db = nil
    }

    /// Ensure database is connected, attempting reconnection if needed
    private func ensureConnection() -> Bool {
        // If already connected, verify connection is still valid
        if let db = db {
            // Simple check: try to prepare a trivial statement
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT 1", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_finalize(stmt)
                return true
            }
            // Connection seems broken, close and retry
            closeDatabase()
            // Clear entity type cache as schema may have changed
            entityTypeCache.removeAll()
        }

        // Attempt to open/reopen
        openDatabase()
        return db != nil
    }

    // MARK: - Activity Queries

    func getCurrentActivity() -> [String: Any]? {
        guard ensureConnection(), let db = db else { return nil }

        let query = """
            SELECT * FROM ZACTIVITY
            ORDER BY ZTIMESTAMP DESC
            LIMIT 1
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        if sqlite3_step(statement) == SQLITE_ROW {
            return activityFromStatement(statement)
        }

        return nil
    }

    func getTodayActivities(limit: Int = 100, appFilter: String? = nil) -> [[String: Any]] {
        guard ensureConnection(), let db = db else { return [] }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let timestamp = startOfDay.timeIntervalSinceReferenceDate

        var query = """
            SELECT * FROM ZACTIVITY
            WHERE ZTIMESTAMP >= ?
        """

        if appFilter != nil {
            query += " AND ZAPPNAME LIKE ? ESCAPE '\\'"
        }

        query += " ORDER BY ZTIMESTAMP DESC LIMIT ?"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, timestamp)

        var paramIndex: Int32 = 2
        if let filter = appFilter {
            // Escape SQL wildcard characters to prevent injection
            let escapedFilter = escapeSQLWildcards(filter)
            sqlite3_bind_text(statement, paramIndex, "%\(escapedFilter)%", -1, SQLITE_TRANSIENT)
            paramIndex += 1
        }
        sqlite3_bind_int(statement, paramIndex, Int32(limit))

        var activities: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let activity = activityFromStatement(statement) {
                activities.append(activity)
            }
        }

        return activities
    }

    func searchActivities(query searchQuery: String, fromDate: Date? = nil, toDate: Date? = nil) -> [[String: Any]] {
        guard ensureConnection(), let db = db else { return [] }

        var query = """
            SELECT * FROM ZACTIVITY
            WHERE (ZAPPNAME LIKE ? ESCAPE '\\' OR ZWINDOWTITLE LIKE ? ESCAPE '\\' OR ZPROJECTPATH LIKE ? ESCAPE '\\')
        """

        if fromDate != nil {
            query += " AND ZTIMESTAMP >= ?"
        }
        if toDate != nil {
            query += " AND ZTIMESTAMP <= ?"
        }

        query += " ORDER BY ZTIMESTAMP DESC LIMIT 100"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        // Escape SQL wildcard characters to prevent injection
        let escapedQuery = escapeSQLWildcards(searchQuery)
        let searchPattern = "%\(escapedQuery)%"
        sqlite3_bind_text(statement, 1, searchPattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, searchPattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, searchPattern, -1, SQLITE_TRANSIENT)

        var paramIndex: Int32 = 4
        if let from = fromDate {
            sqlite3_bind_double(statement, paramIndex, from.timeIntervalSinceReferenceDate)
            paramIndex += 1
        }
        if let to = toDate {
            sqlite3_bind_double(statement, paramIndex, to.timeIntervalSinceReferenceDate)
        }

        var activities: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let activity = activityFromStatement(statement) {
                activities.append(activity)
            }
        }

        return activities
    }

    func getTimeOnProject(_ projectName: String) -> [String: Any] {
        guard ensureConnection(), let db = db else {
            return ["project": projectName, "totalTime": 0, "sessions": []]
        }

        let query = """
            SELECT SUM(ZDURATION) as total_time, COUNT(*) as session_count
            FROM ZACTIVITY
            WHERE ZPROJECTPATH LIKE ? ESCAPE '\\'
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return ["project": projectName, "totalTime": 0, "sessions": []]
        }
        defer { sqlite3_finalize(statement) }

        // Escape SQL wildcard characters to prevent injection
        let escapedProject = escapeSQLWildcards(projectName)
        sqlite3_bind_text(statement, 1, "%\(escapedProject)%", -1, SQLITE_TRANSIENT)

        var totalTime: Double = 0
        var sessionCount: Int = 0

        if sqlite3_step(statement) == SQLITE_ROW {
            totalTime = sqlite3_column_double(statement, 0)
            sessionCount = Int(sqlite3_column_int(statement, 1))
        }

        return [
            "project": projectName,
            "totalTime": totalTime,
            "totalTimeFormatted": formatDuration(totalTime),
            "sessionCount": sessionCount
        ]
    }

    // MARK: - Statistics

    func getDailyStats() -> [String: Any] {
        guard ensureConnection(), let db = db else {
            return [
                "totalActiveTime": 0,
                "focusSessions": 0,
                "contextSwitches": 0,
                "topApps": [],
                "topProjects": []
            ]
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let timestamp = startOfDay.timeIntervalSinceReferenceDate

        // Total active time
        let totalTimeQuery = """
            SELECT SUM(ZDURATION) FROM ZACTIVITY
            WHERE ZTIMESTAMP >= ?
        """

        var statement: OpaquePointer?
        var totalTime: Double = 0

        if sqlite3_prepare_v2(db, totalTimeQuery, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, timestamp)
            if sqlite3_step(statement) == SQLITE_ROW {
                totalTime = sqlite3_column_double(statement, 0)
            }
            sqlite3_finalize(statement)
        }

        // Top apps by time
        let topAppsQuery = """
            SELECT ZAPPNAME, SUM(ZDURATION) as total
            FROM ZACTIVITY
            WHERE ZTIMESTAMP >= ? AND ZAPPNAME IS NOT NULL
            GROUP BY ZAPPNAME
            ORDER BY total DESC
            LIMIT 5
        """

        var topApps: [[String: Any]] = []
        if sqlite3_prepare_v2(db, topAppsQuery, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, timestamp)
            while sqlite3_step(statement) == SQLITE_ROW {
                if let appName = sqlite3_column_text(statement, 0) {
                    topApps.append([
                        "app": String(cString: appName),
                        "time": sqlite3_column_double(statement, 1)
                    ])
                }
            }
            sqlite3_finalize(statement)
        }

        // Top projects
        let topProjectsQuery = """
            SELECT ZPROJECTPATH, SUM(ZDURATION) as total
            FROM ZACTIVITY
            WHERE ZTIMESTAMP >= ? AND ZPROJECTPATH IS NOT NULL
            GROUP BY ZPROJECTPATH
            ORDER BY total DESC
            LIMIT 5
        """

        var topProjects: [[String: Any]] = []
        if sqlite3_prepare_v2(db, topProjectsQuery, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, timestamp)
            while sqlite3_step(statement) == SQLITE_ROW {
                if let project = sqlite3_column_text(statement, 0) {
                    topProjects.append([
                        "project": String(cString: project),
                        "time": sqlite3_column_double(statement, 1)
                    ])
                }
            }
            sqlite3_finalize(statement)
        }

        // Activity count for context switches estimate
        let countQuery = """
            SELECT COUNT(*) FROM ZACTIVITY
            WHERE ZTIMESTAMP >= ?
        """

        var activityCount: Int = 0
        if sqlite3_prepare_v2(db, countQuery, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, timestamp)
            if sqlite3_step(statement) == SQLITE_ROW {
                activityCount = Int(sqlite3_column_int(statement, 0))
            }
            sqlite3_finalize(statement)
        }

        return [
            "date": Self.iso8601Formatter.string(from: Date()),
            "totalActiveTime": totalTime,
            "totalActiveTimeFormatted": formatDuration(totalTime),
            "activityCount": activityCount,
            "contextSwitches": max(0, activityCount - 1),
            "topApps": topApps,
            "topProjects": topProjects
        ]
    }

    func getProductivityScore(period: String) -> [String: Any] {
        // Calculate a simple productivity score based on time in productive apps
        let productiveApps = ["Xcode", "Visual Studio Code", "Cursor", "Terminal", "iTerm"]

        guard ensureConnection(), let db = db else {
            return ["score": 0.0, "period": period]
        }

        let calendar = Calendar.current
        let startDate: Date

        switch period {
        case "week":
            startDate = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        case "month":
            startDate = calendar.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        default: // today
            startDate = calendar.startOfDay(for: Date())
        }

        let timestamp = startDate.timeIntervalSinceReferenceDate

        // Total time
        let totalQuery = "SELECT SUM(ZDURATION) FROM ZACTIVITY WHERE ZTIMESTAMP >= ?"
        var statement: OpaquePointer?
        var totalTime: Double = 0

        if sqlite3_prepare_v2(db, totalQuery, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, timestamp)
            if sqlite3_step(statement) == SQLITE_ROW {
                totalTime = sqlite3_column_double(statement, 0)
            }
            sqlite3_finalize(statement)
        }

        // Productive time - use parameterized query to avoid SQL injection patterns
        // Build placeholders for the IN clause
        let placeholders = productiveApps.map { _ in "?" }.joined(separator: ",")
        let productiveQuery = """
            SELECT SUM(ZDURATION) FROM ZACTIVITY
            WHERE ZTIMESTAMP >= ?
            AND (ZAPPNAME IN (\(placeholders))
                 OR ZTYPE = ?
                 OR ZTYPE = ?)
        """

        var productiveTime: Double = 0
        if sqlite3_prepare_v2(db, productiveQuery, -1, &statement, nil) == SQLITE_OK {
            // Bind timestamp as first parameter
            sqlite3_bind_double(statement, 1, timestamp)

            // Bind each app name individually (parameterized, not string interpolation)
            var paramIndex: Int32 = 2
            for app in productiveApps {
                sqlite3_bind_text(statement, paramIndex, app, -1, SQLITE_TRANSIENT)
                paramIndex += 1
            }

            // Bind the activity types
            sqlite3_bind_text(statement, paramIndex, "aiToolUse", -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, paramIndex + 1, "fileOpen", -1, SQLITE_TRANSIENT)

            if sqlite3_step(statement) == SQLITE_ROW {
                productiveTime = sqlite3_column_double(statement, 0)
            }
            sqlite3_finalize(statement)
        }

        let score = totalTime > 0 ? (productiveTime / totalTime) : 0.0

        return [
            "score": score,
            "scorePercentage": score * 100,
            "period": period,
            "totalTime": totalTime,
            "productiveTime": productiveTime
        ]
    }

    // MARK: - Projects

    func getProjects() -> [[String: Any]] {
        guard ensureConnection(), let db = db else { return [] }

        let query = """
            SELECT ZPROJECTPATH, COUNT(*) as activity_count, SUM(ZDURATION) as total_time
            FROM ZACTIVITY
            WHERE ZPROJECTPATH IS NOT NULL
            GROUP BY ZPROJECTPATH
            ORDER BY total_time DESC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var projects: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let project = sqlite3_column_text(statement, 0) {
                projects.append([
                    "path": String(cString: project),
                    "name": URL(fileURLWithPath: String(cString: project)).lastPathComponent,
                    "activityCount": sqlite3_column_int(statement, 1),
                    "totalTime": sqlite3_column_double(statement, 2)
                ])
            }
        }

        return projects
    }

    // MARK: - Insights

    func getRecentInsights() -> [[String: Any]] {
        guard ensureConnection(), let db = db else { return [] }

        let query = """
            SELECT * FROM ZPRODUCTIVITYINSIGHT
            ORDER BY ZGENERATEDAT DESC
            LIMIT 10
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var insights: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var insight: [String: Any] = [:]

            if let idx = columnIndex(for: "ZTITLE", in: statement),
               let title = sqlite3_column_text(statement, idx) {
                insight["title"] = String(cString: title)
            }
            if let idx = columnIndex(for: "ZCONTENT", in: statement),
               let content = sqlite3_column_text(statement, idx) {
                insight["content"] = String(cString: content)
            }
            if let idx = columnIndex(for: "ZTYPE", in: statement),
               let type = sqlite3_column_text(statement, idx) {
                insight["type"] = String(cString: type)
            }

            if let idx = columnIndex(for: "ZGENERATEDAT", in: statement) {
                let timestamp = sqlite3_column_double(statement, idx)
                insight["generatedAt"] = Date(timeIntervalSinceReferenceDate: timestamp).ISO8601Format()
            }

            insights.append(insight)
        }

        return insights
    }

    func storeInsight(title: String, content: String, type: String) -> String? {
        guard ensureConnection(), let db = db else { return nil }

        // Look up Z_ENT dynamically
        guard let entityType = getEntityType(for: "ProductivityInsight") else {
            print("[DataAccess] Failed to determine entity type for ProductivityInsight")
            return nil
        }

        let id = UUID()
        let timestamp = Date().timeIntervalSinceReferenceDate

        // SwiftData uses Core Data naming conventions with Z prefix
        let query = """
            INSERT INTO ZPRODUCTIVITYINSIGHT (Z_PK, Z_ENT, Z_OPT, ZID, ZTITLE, ZCONTENT, ZTYPE, ZGENERATEDAT, ZISREAD, ZISDISMISSED)
            VALUES ((SELECT COALESCE(MAX(Z_PK), 0) + 1 FROM ZPRODUCTIVITYINSIGHT), \(entityType), 1, ?, ?, ?, ?, ?, 0, 0)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let idString = id.uuidString
        sqlite3_bind_text(statement, 1, idString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, content, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 4, type, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 5, timestamp)

        if sqlite3_step(statement) == SQLITE_DONE {
            return id.uuidString
        }
        return nil
    }

    // MARK: - Context Snapshots

    func insertSnapshot(_ snapshot: [String: Any]) -> String? {
        guard ensureConnection(), let db = db else { return nil }

        // Look up Z_ENT dynamically
        guard let entityType = getEntityType(for: "ContextSnapshot") else {
            print("[DataAccess] Failed to determine entity type for ContextSnapshot")
            return nil
        }

        let id = UUID()
        let timestamp = Date().timeIntervalSinceReferenceDate

        let query = """
            INSERT INTO ZCONTEXTSNAPSHOT (
                Z_PK, Z_ENT, Z_OPT, ZID, ZTIMESTAMP, ZTITLE, ZPROJECTPATH, ZGITBRANCH, ZGITCOMMITHASH,
                ZGITDIRTYFILES, ZWHATIWASWORKINGON, ZWHYIWASWORKINGONIT, ZNEXTSTEPS,
                ZACTIVEFILES, ZACTIVEAPPS, ZRECENTACTIVITYIDS, ZISAUTOMATIC, ZSOURCE, ZTAGS
            ) VALUES (
                (SELECT COALESCE(MAX(Z_PK), 0) + 1 FROM ZCONTEXTSNAPSHOT), \(entityType), 1, ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?
            )
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            print("[DataAccess] Failed to prepare snapshot insert: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var paramIndex: Int32 = 1

        // ID and timestamp
        sqlite3_bind_text(statement, paramIndex, id.uuidString, -1, SQLITE_TRANSIENT)
        paramIndex += 1
        sqlite3_bind_double(statement, paramIndex, timestamp)
        paramIndex += 1

        // Title
        bindOptionalText(statement, paramIndex, snapshot["title"] as? String)
        paramIndex += 1

        // Git context
        bindOptionalText(statement, paramIndex, snapshot["projectPath"] as? String)
        paramIndex += 1
        bindOptionalText(statement, paramIndex, snapshot["gitBranch"] as? String)
        paramIndex += 1
        bindOptionalText(statement, paramIndex, snapshot["gitCommitHash"] as? String)
        paramIndex += 1
        bindOptionalData(statement, paramIndex, encodeJSONArray(snapshot["gitDirtyFiles"] as? [String]))
        paramIndex += 1

        // Core context
        bindOptionalText(statement, paramIndex, snapshot["whatIWasDoing"] as? String)
        paramIndex += 1
        bindOptionalText(statement, paramIndex, snapshot["whyIWasDoingIt"] as? String)
        paramIndex += 1
        bindOptionalText(statement, paramIndex, snapshot["nextSteps"] as? String)
        paramIndex += 1

        // Related data
        bindOptionalData(statement, paramIndex, encodeJSONArray(snapshot["activeFiles"] as? [String]))
        paramIndex += 1
        bindOptionalData(statement, paramIndex, encodeJSONArray(snapshot["activeApps"] as? [String]))
        paramIndex += 1
        bindOptionalData(statement, paramIndex, encodeJSONArray(snapshot["recentActivityIds"] as? [String]))
        paramIndex += 1

        // Metadata
        sqlite3_bind_int(statement, paramIndex, (snapshot["isAutomatic"] as? Bool ?? false) ? 1 : 0)
        paramIndex += 1
        bindOptionalText(statement, paramIndex, snapshot["source"] as? String ?? "manual")
        paramIndex += 1
        bindOptionalData(statement, paramIndex, encodeJSONArray(snapshot["tags"] as? [String]))

        if sqlite3_step(statement) == SQLITE_DONE {
            let idString = id.uuidString
            // Sync to FTS index
            syncSnapshotToFTS(
                id: idString,
                title: snapshot["title"] as? String,
                whatIWasDoing: snapshot["whatIWasDoing"] as? String,
                whyIWasDoingIt: snapshot["whyIWasDoingIt"] as? String,
                nextSteps: snapshot["nextSteps"] as? String,
                projectPath: snapshot["projectPath"] as? String
            )
            return idString
        }
        print("[DataAccess] Failed to insert snapshot: \(String(cString: sqlite3_errmsg(db)))")
        return nil
    }

    func getRecentSnapshots(limit: Int = 20, projectFilter: String? = nil) -> [[String: Any]] {
        guard ensureConnection(), let db = db else { return [] }

        var query = "SELECT * FROM ZCONTEXTSNAPSHOT"
        if projectFilter != nil {
            query += " WHERE ZPROJECTPATH LIKE ? ESCAPE '\\'"
        }
        query += " ORDER BY ZTIMESTAMP DESC LIMIT ?"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var paramIndex: Int32 = 1
        if let path = projectFilter {
            let escapedPath = escapeSQLWildcards(path)
            sqlite3_bind_text(statement, paramIndex, "%\(escapedPath)%", -1, SQLITE_TRANSIENT)
            paramIndex += 1
        }
        sqlite3_bind_int(statement, paramIndex, Int32(limit))

        var snapshots: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let snapshot = snapshotFromStatement(statement) {
                snapshots.append(snapshot)
            }
        }

        return snapshots
    }

    func getSnapshot(id: String) -> [String: Any]? {
        guard ensureConnection(), let db = db else { return nil }

        let query = "SELECT * FROM ZCONTEXTSNAPSHOT WHERE ZID = ? LIMIT 1"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)

        if sqlite3_step(statement) == SQLITE_ROW {
            return snapshotFromStatement(statement)
        }

        return nil
    }

    private func snapshotFromStatement(_ statement: OpaquePointer?) -> [String: Any]? {
        guard let statement = statement else { return nil }

        var snapshot: [String: Any] = [:]
        let columnCount = sqlite3_column_count(statement)

        for i in 0..<columnCount {
            guard let columnName = sqlite3_column_name(statement, i) else { continue }
            let name = String(cString: columnName)
            let cleanName = name.lowercased().replacingOccurrences(of: "z", with: "", options: .anchored)

            switch sqlite3_column_type(statement, i) {
            case SQLITE_TEXT:
                if let text = sqlite3_column_text(statement, i) {
                    snapshot[cleanName] = String(cString: text)
                }
            case SQLITE_INTEGER:
                snapshot[cleanName] = sqlite3_column_int64(statement, i)
            case SQLITE_FLOAT:
                let value = sqlite3_column_double(statement, i)
                if cleanName == "timestamp" {
                    snapshot[cleanName] = Date(timeIntervalSinceReferenceDate: value).ISO8601Format()
                } else {
                    snapshot[cleanName] = value
                }
            case SQLITE_BLOB:
                if let bytes = sqlite3_column_blob(statement, i) {
                    let length = sqlite3_column_bytes(statement, i)
                    let data = Data(bytes: bytes, count: Int(length))
                    // Try to decode as JSON array
                    if let array = try? JSONSerialization.jsonObject(with: data) as? [String] {
                        snapshot[cleanName] = array
                    }
                }
            default:
                break
            }
        }

        return snapshot.isEmpty ? nil : snapshot
    }

    // MARK: - Decisions

    func insertDecision(_ decision: [String: Any]) -> String? {
        guard ensureConnection(), let db = db else { return nil }

        // Look up Z_ENT dynamically
        guard let entityType = getEntityType(for: "Decision") else {
            print("[DataAccess] Failed to determine entity type for Decision")
            return nil
        }

        let id = UUID()
        let timestamp = Date().timeIntervalSinceReferenceDate

        let query = """
            INSERT INTO ZDECISION (
                Z_PK, Z_ENT, Z_OPT, ZID, ZTIMESTAMP, ZTITLE, ZPROBLEM, ZDECISIONTYPE,
                ZOPTIONS, ZCHOSENOPTION, ZRATIONALE, ZPROJECTPATH, ZRELATEDSNAPSHOTID,
                ZFREQUENCY, ZMINIMALPROOF, ZTIMEESTIMATE, ZAICRITIQUE, ZCRITIQUEREQUESTED, ZOUTCOME, ZOUTCOMENOTES
            ) VALUES (
                (SELECT COALESCE(MAX(Z_PK), 0) + 1 FROM ZDECISION), \(entityType), 1, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?, ?
            )
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            print("[DataAccess] Failed to prepare decision insert: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var paramIndex: Int32 = 1

        sqlite3_bind_text(statement, paramIndex, id.uuidString, -1, SQLITE_TRANSIENT)
        paramIndex += 1
        sqlite3_bind_double(statement, paramIndex, timestamp)
        paramIndex += 1
        bindOptionalText(statement, paramIndex, decision["title"] as? String)
        paramIndex += 1
        bindOptionalText(statement, paramIndex, decision["problem"] as? String)
        paramIndex += 1
        bindOptionalText(statement, paramIndex, decision["decisionType"] as? String ?? "other")
        paramIndex += 1

        // Options as JSON blob
        if let options = decision["options"] {
            if let data = try? JSONSerialization.data(withJSONObject: options) {
                sqlite3_bind_blob(statement, paramIndex, (data as NSData).bytes, Int32(data.count), SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, paramIndex)
            }
        } else {
            sqlite3_bind_null(statement, paramIndex)
        }
        paramIndex += 1

        bindOptionalText(statement, paramIndex, decision["chosenOption"] as? String)
        paramIndex += 1
        bindOptionalText(statement, paramIndex, decision["rationale"] as? String)
        paramIndex += 1
        bindOptionalText(statement, paramIndex, decision["projectPath"] as? String)
        paramIndex += 1
        bindOptionalText(statement, paramIndex, decision["relatedSnapshotId"] as? String)
        paramIndex += 1

        // Frequency - default to "oneTime" if not provided
        bindOptionalText(statement, paramIndex, decision["frequency"] as? String ?? "oneTime")
        paramIndex += 1

        // Minimal proof
        bindOptionalText(statement, paramIndex, decision["minimalProof"] as? String)
        paramIndex += 1

        if let estimate = decision["timeEstimate"] as? Double {
            sqlite3_bind_double(statement, paramIndex, estimate)
        } else {
            sqlite3_bind_null(statement, paramIndex)
        }
        paramIndex += 1

        bindOptionalText(statement, paramIndex, decision["aiCritique"] as? String)
        paramIndex += 1
        sqlite3_bind_int(statement, paramIndex, (decision["critiqueRequested"] as? Bool ?? false) ? 1 : 0)
        paramIndex += 1
        bindOptionalText(statement, paramIndex, decision["outcome"] as? String)
        paramIndex += 1
        bindOptionalText(statement, paramIndex, decision["outcomeNotes"] as? String)

        if sqlite3_step(statement) == SQLITE_DONE {
            let idString = id.uuidString
            // Sync to FTS index
            syncDecisionToFTS(
                id: idString,
                title: decision["title"] as? String,
                problem: decision["problem"] as? String,
                rationale: decision["rationale"] as? String,
                chosenOption: decision["chosenOption"] as? String,
                minimalProof: decision["minimalProof"] as? String,
                projectPath: decision["projectPath"] as? String
            )
            return idString
        }
        print("[DataAccess] Failed to insert decision: \(String(cString: sqlite3_errmsg(db)))")
        return nil
    }

    func updateDecision(id: String, fields: [String: Any]) -> Bool {
        guard ensureConnection(), let db = db else { return false }

        var setClauses: [String] = []
        var values: [Any] = []

        // Build dynamic SET clause
        if let critique = fields["aiCritique"] as? String {
            setClauses.append("ZAICRITIQUE = ?")
            values.append(critique)
        }
        if let outcome = fields["outcome"] as? String {
            setClauses.append("ZOUTCOME = ?")
            values.append(outcome)
        }
        if let notes = fields["outcomeNotes"] as? String {
            setClauses.append("ZOUTCOMENOTES = ?")
            values.append(notes)
        }
        if let chosenOption = fields["chosenOption"] as? String {
            setClauses.append("ZCHOSENOPTION = ?")
            values.append(chosenOption)
        }
        if let rationale = fields["rationale"] as? String {
            setClauses.append("ZRATIONALE = ?")
            values.append(rationale)
        }

        guard !setClauses.isEmpty else { return false }

        let query = "UPDATE ZDECISION SET \(setClauses.joined(separator: ", ")) WHERE ZID = ?"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        var paramIndex: Int32 = 1
        for value in values {
            if let str = value as? String {
                sqlite3_bind_text(statement, paramIndex, str, -1, SQLITE_TRANSIENT)
            }
            paramIndex += 1
        }
        sqlite3_bind_text(statement, paramIndex, id, -1, SQLITE_TRANSIENT)

        return sqlite3_step(statement) == SQLITE_DONE
    }

    func getRecentDecisions(limit: Int = 20, typeFilter: String? = nil, pendingOnly: Bool = false) -> [[String: Any]] {
        guard ensureConnection(), let db = db else { return [] }

        var query = "SELECT * FROM ZDECISION WHERE 1=1"
        if typeFilter != nil {
            query += " AND ZDECISIONTYPE = ?"
        }
        if pendingOnly {
            query += " AND (ZOUTCOME IS NULL OR ZOUTCOME = 'pending')"
        }
        query += " ORDER BY ZTIMESTAMP DESC LIMIT ?"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var paramIndex: Int32 = 1
        if let type = typeFilter {
            sqlite3_bind_text(statement, paramIndex, type, -1, SQLITE_TRANSIENT)
            paramIndex += 1
        }
        sqlite3_bind_int(statement, paramIndex, Int32(limit))

        var decisions: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let decision = decisionFromStatement(statement) {
                decisions.append(decision)
            }
        }

        return decisions
    }

    private func decisionFromStatement(_ statement: OpaquePointer?) -> [String: Any]? {
        guard let statement = statement else { return nil }

        var decision: [String: Any] = [:]
        let columnCount = sqlite3_column_count(statement)

        for i in 0..<columnCount {
            guard let columnName = sqlite3_column_name(statement, i) else { continue }
            let name = String(cString: columnName)
            let cleanName = name.lowercased().replacingOccurrences(of: "z", with: "", options: .anchored)

            switch sqlite3_column_type(statement, i) {
            case SQLITE_TEXT:
                if let text = sqlite3_column_text(statement, i) {
                    decision[cleanName] = String(cString: text)
                }
            case SQLITE_INTEGER:
                decision[cleanName] = sqlite3_column_int64(statement, i)
            case SQLITE_FLOAT:
                let value = sqlite3_column_double(statement, i)
                if cleanName == "timestamp" {
                    decision[cleanName] = Date(timeIntervalSinceReferenceDate: value).ISO8601Format()
                } else {
                    decision[cleanName] = value
                }
            case SQLITE_BLOB:
                if let bytes = sqlite3_column_blob(statement, i) {
                    let length = sqlite3_column_bytes(statement, i)
                    let data = Data(bytes: bytes, count: Int(length))
                    if let json = try? JSONSerialization.jsonObject(with: data) {
                        decision[cleanName] = json
                    }
                }
            default:
                break
            }
        }

        return decision.isEmpty ? nil : decision
    }

    // MARK: - Unified Search

    func unifiedSearch(query searchQuery: String, types: Set<String>? = nil, fromDate: Date? = nil, toDate: Date? = nil, limit: Int = 50) -> [String: Any] {
        let typesToSearch = types ?? Set(["activity", "snapshot", "decision", "insight"])
        var results: [String: Any] = [:]

        if typesToSearch.contains("activity") {
            let activities = searchActivities(query: searchQuery, fromDate: fromDate, toDate: toDate)
            results["activities"] = Array(activities.prefix(limit))
        }

        if typesToSearch.contains("snapshot") {
            let snapshots = searchSnapshots(query: searchQuery, fromDate: fromDate, toDate: toDate)
            results["snapshots"] = Array(snapshots.prefix(limit))
        }

        if typesToSearch.contains("decision") {
            let decisions = searchDecisions(query: searchQuery, fromDate: fromDate, toDate: toDate)
            results["decisions"] = Array(decisions.prefix(limit))
        }

        if typesToSearch.contains("insight") {
            let insights = searchInsights(query: searchQuery)
            results["insights"] = Array(insights.prefix(limit))
        }

        return results
    }

    // MARK: - Digest Generation

    func getDigest(period: String) -> [String: Any] {
        let now = Date()
        let periodName: String

        switch period {
        case "yesterday":
            periodName = "Yesterday"
        case "week":
            periodName = "Past Week"
        default: // today
            periodName = "Today"
        }

        // Get stats
        let stats = getDailyStats()

        // Get recent snapshots
        let snapshots = getRecentSnapshots(limit: 5, projectFilter: nil)

        // Get pending decisions
        let pendingDecisions = getRecentDecisions(limit: 5, typeFilter: nil, pendingOnly: true)

        // Get recent insights
        let insights = getRecentInsights()

        return [
            "period": periodName,
            "generatedAt": Self.iso8601Formatter.string(from: now),
            "stats": stats,
            "recentSnapshots": snapshots,
            "pendingDecisions": pendingDecisions,
            "recentInsights": Array(insights.prefix(3)),
            "summary": generateDigestSummary(stats: stats, snapshots: snapshots, pendingDecisions: pendingDecisions)
        ]
    }

    private func generateDigestSummary(stats: [String: Any], snapshots: [[String: Any]], pendingDecisions: [[String: Any]]) -> String {
        var lines: [String] = []

        if let totalTime = stats["totalActiveTimeFormatted"] as? String {
            lines.append("Total active time: \(totalTime)")
        }

        if let activityCount = stats["activityCount"] as? Int {
            lines.append("Activities tracked: \(activityCount)")
        }

        if let topApps = stats["topApps"] as? [[String: Any]], !topApps.isEmpty {
            let appNames = topApps.prefix(3).compactMap { $0["app"] as? String }
            lines.append("Top apps: \(appNames.joined(separator: ", "))")
        }

        if !snapshots.isEmpty {
            lines.append("Context snapshots saved: \(snapshots.count)")
        }

        if !pendingDecisions.isEmpty {
            lines.append("Pending decisions to review: \(pendingDecisions.count)")
        }

        return lines.joined(separator: "\n")
    }

    private func searchSnapshots(query searchQuery: String, fromDate: Date? = nil, toDate: Date? = nil) -> [[String: Any]] {
        guard ensureConnection(), let db = db else { return [] }

        var sql = """
            SELECT * FROM ZCONTEXTSNAPSHOT
            WHERE (ZTITLE LIKE ? ESCAPE '\\' OR ZWHATIWASWORKINGON LIKE ? ESCAPE '\\' OR ZPROJECTPATH LIKE ? ESCAPE '\\' OR ZNEXTSTEPS LIKE ? ESCAPE '\\')
        """

        if fromDate != nil { sql += " AND ZTIMESTAMP >= ?" }
        if toDate != nil { sql += " AND ZTIMESTAMP <= ?" }
        sql += " ORDER BY ZTIMESTAMP DESC LIMIT 50"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        let pattern = "%\(escapeSQLWildcards(searchQuery))%"
        sqlite3_bind_text(statement, 1, pattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, pattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, pattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 4, pattern, -1, SQLITE_TRANSIENT)

        var paramIndex: Int32 = 5
        if let from = fromDate {
            sqlite3_bind_double(statement, paramIndex, from.timeIntervalSinceReferenceDate)
            paramIndex += 1
        }
        if let to = toDate {
            sqlite3_bind_double(statement, paramIndex, to.timeIntervalSinceReferenceDate)
        }

        var results: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let snapshot = snapshotFromStatement(statement) {
                results.append(snapshot)
            }
        }
        return results
    }

    private func searchDecisions(query searchQuery: String, fromDate: Date? = nil, toDate: Date? = nil) -> [[String: Any]] {
        guard ensureConnection(), let db = db else { return [] }

        var sql = """
            SELECT * FROM ZDECISION
            WHERE (ZTITLE LIKE ? ESCAPE '\\' OR ZPROBLEM LIKE ? ESCAPE '\\' OR ZRATIONALE LIKE ? ESCAPE '\\' OR ZPROJECTPATH LIKE ? ESCAPE '\\')
        """

        if fromDate != nil { sql += " AND ZTIMESTAMP >= ?" }
        if toDate != nil { sql += " AND ZTIMESTAMP <= ?" }
        sql += " ORDER BY ZTIMESTAMP DESC LIMIT 50"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        let pattern = "%\(escapeSQLWildcards(searchQuery))%"
        sqlite3_bind_text(statement, 1, pattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, pattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, pattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 4, pattern, -1, SQLITE_TRANSIENT)

        var paramIndex: Int32 = 5
        if let from = fromDate {
            sqlite3_bind_double(statement, paramIndex, from.timeIntervalSinceReferenceDate)
            paramIndex += 1
        }
        if let to = toDate {
            sqlite3_bind_double(statement, paramIndex, to.timeIntervalSinceReferenceDate)
        }

        var results: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let decision = decisionFromStatement(statement) {
                results.append(decision)
            }
        }
        return results
    }

    private func searchInsights(query searchQuery: String) -> [[String: Any]] {
        guard ensureConnection(), let db = db else { return [] }

        let sql = """
            SELECT * FROM ZPRODUCTIVITYINSIGHT
            WHERE (ZTITLE LIKE ? ESCAPE '\\' OR ZCONTENT LIKE ? ESCAPE '\\')
            ORDER BY ZGENERATEDAT DESC LIMIT 50
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        let pattern = "%\(escapeSQLWildcards(searchQuery))%"
        sqlite3_bind_text(statement, 1, pattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, pattern, -1, SQLITE_TRANSIENT)

        var results: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var insight: [String: Any] = [:]
            if let idx = columnIndex(for: "ZID", in: statement), let idText = sqlite3_column_text(statement, idx) {
                insight["id"] = String(cString: idText)
            }
            if let idx = columnIndex(for: "ZTITLE", in: statement), let title = sqlite3_column_text(statement, idx) {
                insight["title"] = String(cString: title)
            }
            if let idx = columnIndex(for: "ZCONTENT", in: statement), let content = sqlite3_column_text(statement, idx) {
                insight["content"] = String(cString: content)
            }
            if let idx = columnIndex(for: "ZTYPE", in: statement), let type = sqlite3_column_text(statement, idx) {
                insight["type"] = String(cString: type)
            }
            if let idx = columnIndex(for: "ZGENERATEDAT", in: statement) {
                let ts = sqlite3_column_double(statement, idx)
                insight["timestamp"] = Date(timeIntervalSinceReferenceDate: ts).ISO8601Format()
            }
            if !insight.isEmpty {
                results.append(insight)
            }
        }
        return results
    }

    // MARK: - Helper Methods for Binding

    private func bindOptionalText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value = value {
            sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bindOptionalData(_ statement: OpaquePointer?, _ index: Int32, _ value: Data?) {
        if let data = value {
            sqlite3_bind_blob(statement, index, (data as NSData).bytes, Int32(data.count), SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func encodeJSONArray(_ array: [String]?) -> Data? {
        guard let array = array else { return nil }
        return try? JSONSerialization.data(withJSONObject: array)
    }

    // MARK: - Helpers

    /// Escape SQL LIKE wildcard characters (% and _) to prevent injection
    private func escapeSQLWildcards(_ input: String) -> String {
        return input
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func activityFromStatement(_ statement: OpaquePointer?) -> [String: Any]? {
        guard let statement = statement else { return nil }

        var activity: [String: Any] = [:]

        // Get column indices dynamically
        let columnCount = sqlite3_column_count(statement)
        for i in 0..<columnCount {
            if let columnName = sqlite3_column_name(statement, i) {
                let name = String(cString: columnName)

                switch sqlite3_column_type(statement, i) {
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, i) {
                        activity[name.lowercased().replacingOccurrences(of: "z", with: "", options: .anchored)] = String(cString: text)
                    }
                case SQLITE_INTEGER:
                    activity[name.lowercased().replacingOccurrences(of: "z", with: "", options: .anchored)] = sqlite3_column_int64(statement, i)
                case SQLITE_FLOAT:
                    let value = sqlite3_column_double(statement, i)
                    let cleanName = name.lowercased().replacingOccurrences(of: "z", with: "", options: .anchored)
                    if cleanName == "timestamp" {
                        activity[cleanName] = Date(timeIntervalSinceReferenceDate: value).ISO8601Format()
                    } else {
                        activity[cleanName] = value
                    }
                default:
                    break
                }
            }
        }

        return activity.isEmpty ? nil : activity
    }

    private func columnIndex(for name: String, in statement: OpaquePointer?) -> Int32? {
        guard let statement = statement else { return nil }

        let columnCount = sqlite3_column_count(statement)
        for i in 0..<columnCount {
            if let columnName = sqlite3_column_name(statement, i) {
                if String(cString: columnName) == name {
                    return i
                }
            }
        }
        return nil
    }

    private func formatDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    /// Look up Z_ENT value for a given entity name from the Z_PRIMARYKEY table.
    /// SwiftData/Core Data stores entity type mappings here.
    /// Falls back to scanning existing records if Z_PRIMARYKEY lookup fails.
    private func getEntityType(for entityName: String) -> Int32? {
        // Check cache first
        if let cached = entityTypeCache[entityName] {
            return cached
        }

        guard let db = db else { return nil }

        // Try Z_PRIMARYKEY table (standard Core Data metadata table)
        let primaryKeyQuery = "SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = ?"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, primaryKeyQuery, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, entityName, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) == SQLITE_ROW {
                let entValue = sqlite3_column_int(statement, 0)
                sqlite3_finalize(statement)
                entityTypeCache[entityName] = entValue
                return entValue
            }
            sqlite3_finalize(statement)
        }

        // Fallback: scan an existing record in the target table
        let tableName = "Z\(entityName.uppercased())"
        let fallbackQuery = "SELECT Z_ENT FROM \(tableName) LIMIT 1"
        if sqlite3_prepare_v2(db, fallbackQuery, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                let entValue = sqlite3_column_int(statement, 0)
                sqlite3_finalize(statement)
                entityTypeCache[entityName] = entValue
                return entValue
            }
            sqlite3_finalize(statement)
        }

        return nil
    }

    // MARK: - FTS5 Full-Text Search

    /// Create FTS5 virtual tables for fast full-text search
    private func createFTSTables() {
        guard let db = db, !ftsTablesCreated else { return }

        // FTS table for activities (searchable metadata)
        let createActivitiesFTS = """
            CREATE VIRTUAL TABLE IF NOT EXISTS fts_activities USING fts5(
                id UNINDEXED,
                appname,
                windowtitle,
                projectpath,
                filepath,
                tokenize='porter unicode61'
            )
        """

        // FTS table for snapshots
        let createSnapshotsFTS = """
            CREATE VIRTUAL TABLE IF NOT EXISTS fts_snapshots USING fts5(
                id UNINDEXED,
                title,
                whatiwasworkingon,
                whyiwasworkingonit,
                nextsteps,
                projectpath,
                tokenize='porter unicode61'
            )
        """

        // FTS table for decisions
        let createDecisionsFTS = """
            CREATE VIRTUAL TABLE IF NOT EXISTS fts_decisions USING fts5(
                id UNINDEXED,
                title,
                problem,
                rationale,
                chosenoption,
                minimalproof,
                projectpath,
                tokenize='porter unicode61'
            )
        """

        // FTS table for AI interactions
        let createAIFTS = """
            CREATE VIRTUAL TABLE IF NOT EXISTS fts_ai_interactions USING fts5(
                id UNINDEXED,
                promptsummary,
                response,
                actiontype,
                projectpath,
                tokenize='porter unicode61'
            )
        """

        // FTS table for content index (code, docs)
        let createContentFTS = """
            CREATE VIRTUAL TABLE IF NOT EXISTS fts_content USING fts5(
                id UNINDEXED,
                filepath,
                filename,
                content,
                language,
                projectpath,
                tokenize='porter unicode61'
            )
        """

        // Execute all FTS table creations
        sqlite3_exec(db, createActivitiesFTS, nil, nil, nil)
        sqlite3_exec(db, createSnapshotsFTS, nil, nil, nil)
        sqlite3_exec(db, createDecisionsFTS, nil, nil, nil)
        sqlite3_exec(db, createAIFTS, nil, nil, nil)
        sqlite3_exec(db, createContentFTS, nil, nil, nil)

        ftsTablesCreated = true
    }

    /// Rebuild all FTS indexes from main SwiftData tables
    /// - Returns: Number of successful rebuilds (0-5)
    @discardableResult
    func rebuildFTSIndexes() -> Int {
        guard let db = db else { return 0 }

        var successCount = 0

        // Helper to execute and log errors
        func execSQL(_ sql: String, description: String) -> Bool {
            var errMsg: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(db, sql, nil, nil, &errMsg)
            if result != SQLITE_OK {
                if let errMsg = errMsg {
                    print("[DataAccess] FTS rebuild failed for \(description): \(String(cString: errMsg))")
                    sqlite3_free(errMsg)
                }
                return false
            }
            return true
        }

        // Clear existing FTS data (ignore errors - tables might not exist)
        sqlite3_exec(db, "DELETE FROM fts_activities", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM fts_snapshots", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM fts_decisions", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM fts_ai_interactions", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM fts_content", nil, nil, nil)

        // Rebuild activities FTS
        let rebuildActivities = """
            INSERT INTO fts_activities(id, appname, windowtitle, projectpath, filepath)
            SELECT ZID, ZAPPNAME, ZWINDOWTITLE, ZPROJECTPATH, ZFILEPATH
            FROM ZACTIVITY
            WHERE ZAPPNAME IS NOT NULL OR ZWINDOWTITLE IS NOT NULL
        """
        if execSQL(rebuildActivities, description: "activities") { successCount += 1 }

        // Rebuild snapshots FTS
        let rebuildSnapshots = """
            INSERT INTO fts_snapshots(id, title, whatiwasworkingon, whyiwasworkingonit, nextsteps, projectpath)
            SELECT ZID, ZTITLE, ZWHATIWASWORKINGON, ZWHYIWASWORKINGONIT, ZNEXTSTEPS, ZPROJECTPATH
            FROM ZCONTEXTSNAPSHOT
        """
        if execSQL(rebuildSnapshots, description: "snapshots") { successCount += 1 }

        // Rebuild decisions FTS
        let rebuildDecisions = """
            INSERT INTO fts_decisions(id, title, problem, rationale, chosenoption, minimalproof, projectpath)
            SELECT ZID, ZTITLE, ZPROBLEM, ZRATIONALE, ZCHOSENOPTION, ZMINIMALPROOF, ZPROJECTPATH
            FROM ZDECISION
        """
        if execSQL(rebuildDecisions, description: "decisions") { successCount += 1 }

        // Rebuild AI interactions FTS (if table exists)
        let rebuildAI = """
            INSERT INTO fts_ai_interactions(id, promptsummary, response, actiontype, projectpath)
            SELECT ZID, ZPROMPTSUMMARY, ZRESPONSE, ZACTIONTYPE, ZPROJECTPATH
            FROM ZAIINTERACTION
        """
        if execSQL(rebuildAI, description: "ai_interactions") { successCount += 1 }

        // Rebuild content FTS (if table exists)
        let rebuildContent = """
            INSERT INTO fts_content(id, filepath, filename, content, language, projectpath)
            SELECT ZID, ZFILEPATH, ZFILENAME, ZCONTENT, ZLANGUAGE, ZPROJECTPATH
            FROM ZCONTENTINDEX
            WHERE ZINDEXINGFAILED = 0
        """
        if execSQL(rebuildContent, description: "content") { successCount += 1 }

        return successCount
    }

    // MARK: - FTS Auto-Sync Helpers

    /// Sync a snapshot to the FTS index
    private func syncSnapshotToFTS(id: String, title: String?, whatIWasDoing: String?, whyIWasDoingIt: String?, nextSteps: String?, projectPath: String?) {
        guard let db = db else { return }

        let sql = """
            INSERT OR REPLACE INTO fts_snapshots(id, title, whatiwasworkingon, whyiwasworkingonit, nextsteps, projectpath)
            VALUES (?, ?, ?, ?, ?, ?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        bindOptionalText(stmt, 2, title)
        bindOptionalText(stmt, 3, whatIWasDoing)
        bindOptionalText(stmt, 4, whyIWasDoingIt)
        bindOptionalText(stmt, 5, nextSteps)
        bindOptionalText(stmt, 6, projectPath)

        sqlite3_step(stmt)
    }

    /// Sync a decision to the FTS index
    private func syncDecisionToFTS(id: String, title: String?, problem: String?, rationale: String?, chosenOption: String?, minimalProof: String?, projectPath: String?) {
        guard let db = db else { return }

        let sql = """
            INSERT OR REPLACE INTO fts_decisions(id, title, problem, rationale, chosenoption, minimalproof, projectpath)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        bindOptionalText(stmt, 2, title)
        bindOptionalText(stmt, 3, problem)
        bindOptionalText(stmt, 4, rationale)
        bindOptionalText(stmt, 5, chosenOption)
        bindOptionalText(stmt, 6, minimalProof)
        bindOptionalText(stmt, 7, projectPath)

        sqlite3_step(stmt)
    }

    /// Sync an AI interaction to the FTS index
    private func syncAIInteractionToFTS(id: String, promptSummary: String?, response: String?, actionType: String?, projectPath: String?) {
        guard let db = db else { return }

        let sql = """
            INSERT OR REPLACE INTO fts_ai_interactions(id, promptsummary, response, actiontype, projectpath)
            VALUES (?, ?, ?, ?, ?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        bindOptionalText(stmt, 2, promptSummary)
        bindOptionalText(stmt, 3, response)
        bindOptionalText(stmt, 4, actionType)
        bindOptionalText(stmt, 5, projectPath)

        sqlite3_step(stmt)
    }

    /// FTS search result structure
    struct FTSSearchResult {
        let id: String
        let type: String
        let snippet: String
        let rank: Double
    }

    /// Full-text search with ranking across all indexed content
    func ftsSearch(
        query: String,
        types: Set<String> = Set(["activity", "snapshot", "decision", "ai", "content"]),
        limit: Int = 50,
        projectFilter: String? = nil
    ) -> [[String: Any]] {
        guard let db = db, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return []
        }

        var results: [FTSSearchResult] = []
        let escapedQuery = escapeFTSQuery(query)

        // Search each type
        if types.contains("activity") {
            results.append(contentsOf: searchFTSTable(
                db: db,
                table: "fts_activities",
                query: escapedQuery,
                type: "activity",
                projectFilter: projectFilter,
                limit: limit
            ))
        }

        if types.contains("snapshot") {
            results.append(contentsOf: searchFTSTable(
                db: db,
                table: "fts_snapshots",
                query: escapedQuery,
                type: "snapshot",
                projectFilter: projectFilter,
                limit: limit
            ))
        }

        if types.contains("decision") {
            results.append(contentsOf: searchFTSTable(
                db: db,
                table: "fts_decisions",
                query: escapedQuery,
                type: "decision",
                projectFilter: projectFilter,
                limit: limit
            ))
        }

        if types.contains("ai") {
            results.append(contentsOf: searchFTSTable(
                db: db,
                table: "fts_ai_interactions",
                query: escapedQuery,
                type: "ai",
                projectFilter: projectFilter,
                limit: limit
            ))
        }

        if types.contains("content") {
            results.append(contentsOf: searchFTSTable(
                db: db,
                table: "fts_content",
                query: escapedQuery,
                type: "content",
                projectFilter: projectFilter,
                limit: limit
            ))
        }

        // Sort by rank (BM25 score - more negative is better match)
        let sorted = results.sorted { $0.rank < $1.rank }.prefix(limit)

        return sorted.map { result in
            [
                "id": result.id,
                "type": result.type,
                "snippet": result.snippet,
                "rank": result.rank
            ]
        }
    }

    private func searchFTSTable(
        db: OpaquePointer,
        table: String,
        query: String,
        type: String,
        projectFilter: String?,
        limit: Int
    ) -> [FTSSearchResult] {
        // Determine snippet column based on table
        let snippetColumn: Int32
        switch table {
        case "fts_activities": snippetColumn = 2 // windowtitle
        case "fts_snapshots": snippetColumn = 2  // whatiwasworkingon
        case "fts_decisions": snippetColumn = 2  // problem
        case "fts_ai_interactions": snippetColumn = 2 // response
        case "fts_content": snippetColumn = 3    // content
        default: snippetColumn = 1
        }

        var sql = """
            SELECT id, snippet(\(table), \(snippetColumn), '<mark>', '</mark>', '...', 32) as snippet,
                   bm25(\(table)) as rank
            FROM \(table)
            WHERE \(table) MATCH ?
        """

        if projectFilter != nil {
            sql += " AND projectpath LIKE ? ESCAPE '\\'"
        }

        sql += " ORDER BY rank LIMIT ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var paramIndex: Int32 = 1
        sqlite3_bind_text(stmt, paramIndex, query, -1, SQLITE_TRANSIENT)
        paramIndex += 1

        if let filter = projectFilter {
            // Escape SQL wildcards in project filter
            let escapedFilter = escapeSQLWildcards(filter)
            sqlite3_bind_text(stmt, paramIndex, "%\(escapedFilter)%", -1, SQLITE_TRANSIENT)
            paramIndex += 1
        }

        sqlite3_bind_int(stmt, paramIndex, Int32(limit))

        var results: [FTSSearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let snippet = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let rank = sqlite3_column_double(stmt, 2)

            results.append(FTSSearchResult(
                id: id,
                type: type,
                snippet: snippet,
                rank: rank
            ))
        }

        return results
    }

    /// Escape special FTS5 characters for safe query
    /// FTS5 special characters: " * - + : ^ ( ) ~ AND OR NOT NEAR
    private func escapeFTSQuery(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }

        // If user included quotes, they want phrase matching - validate balanced quotes
        if trimmed.contains("\"") {
            let quoteCount = trimmed.filter { $0 == "\"" }.count
            if quoteCount % 2 == 0 {
                // Balanced quotes - user knows what they're doing
                return trimmed
            }
            // Unbalanced quotes - escape them
        }

        // Escape each word and do prefix search for fuzzy matching
        let words = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        return words.map { word in
            // Escape special FTS5 characters within words
            let escaped = word
                .replacingOccurrences(of: "\"", with: "\"\"")
                .replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "+", with: "")
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "^", with: "")
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
                .replacingOccurrences(of: "~", with: "")
            // Skip if word became empty after escaping
            guard !escaped.isEmpty else { return nil }
            // Quote the term and add prefix wildcard
            return "\"\(escaped)\"*"
        }.compactMap { $0 }.joined(separator: " ")
    }

    // MARK: - AI Interaction Queries

    func insertAIInteraction(_ interaction: [String: Any]) -> String? {
        guard ensureConnection(), let db = db else { return nil }

        guard let entityType = getEntityType(for: "AIInteraction") else {
            print("[DataAccess] Failed to determine entity type for AIInteraction")
            return nil
        }

        let id = UUID()
        let timestamp = Date().timeIntervalSinceReferenceDate

        let query = """
            INSERT INTO ZAIINTERACTION (
                Z_PK, Z_ENT, Z_OPT, ZID, ZTIMESTAMP, ZPROMPTSUMMARY, ZFULLPROMPT,
                ZACTIONTYPE, ZRESPONSE, ZRESPONSELENGTH, ZWASSUCCESSFUL,
                ZCONTEXTTYPE, ZRELATEDSNAPSHOTID, ZRELATEDDECISIONID, ZPROJECTPATH
            ) VALUES (
                (SELECT COALESCE(MAX(Z_PK), 0) + 1 FROM ZAIINTERACTION), \(entityType), 1, ?, ?, ?, ?,
                ?, ?, ?, ?,
                ?, ?, ?, ?
            )
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            print("[DataAccess] Failed to prepare AI interaction insert: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var paramIndex: Int32 = 1

        sqlite3_bind_text(statement, paramIndex, id.uuidString, -1, SQLITE_TRANSIENT)
        paramIndex += 1
        sqlite3_bind_double(statement, paramIndex, timestamp)
        paramIndex += 1
        bindOptionalText(statement, paramIndex, interaction["promptSummary"] as? String)
        paramIndex += 1

        // Full prompt as blob
        if let prompt = interaction["fullPrompt"] as? String, let data = prompt.data(using: .utf8) {
            sqlite3_bind_blob(statement, paramIndex, (data as NSData).bytes, Int32(data.count), SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, paramIndex)
        }
        paramIndex += 1

        bindOptionalText(statement, paramIndex, interaction["actionType"] as? String)
        paramIndex += 1
        bindOptionalText(statement, paramIndex, interaction["response"] as? String)
        paramIndex += 1

        let responseLength = (interaction["response"] as? String)?.count ?? 0
        sqlite3_bind_int(statement, paramIndex, Int32(responseLength))
        paramIndex += 1

        sqlite3_bind_int(statement, paramIndex, (interaction["wasSuccessful"] as? Bool ?? true) ? 1 : 0)
        paramIndex += 1

        bindOptionalText(statement, paramIndex, interaction["contextType"] as? String ?? "freeform")
        paramIndex += 1
        bindOptionalText(statement, paramIndex, interaction["relatedSnapshotId"] as? String)
        paramIndex += 1
        bindOptionalText(statement, paramIndex, interaction["relatedDecisionId"] as? String)
        paramIndex += 1
        bindOptionalText(statement, paramIndex, interaction["projectPath"] as? String)

        if sqlite3_step(statement) == SQLITE_DONE {
            let idString = id.uuidString
            // Sync to FTS index
            syncAIInteractionToFTS(
                id: idString,
                promptSummary: interaction["promptSummary"] as? String,
                response: interaction["response"] as? String,
                actionType: interaction["actionType"] as? String,
                projectPath: interaction["projectPath"] as? String
            )
            return idString
        }
        print("[DataAccess] Failed to insert AI interaction: \(String(cString: sqlite3_errmsg(db)))")
        return nil
    }

    func getRecentAIInteractions(limit: Int = 20, actionType: String? = nil) -> [[String: Any]] {
        guard ensureConnection(), let db = db else { return [] }

        var query = "SELECT * FROM ZAIINTERACTION"
        if actionType != nil {
            query += " WHERE ZACTIONTYPE = ?"
        }
        query += " ORDER BY ZTIMESTAMP DESC LIMIT ?"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var paramIndex: Int32 = 1
        if let type = actionType {
            sqlite3_bind_text(statement, paramIndex, type, -1, SQLITE_TRANSIENT)
            paramIndex += 1
        }
        sqlite3_bind_int(statement, paramIndex, Int32(limit))

        var interactions: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let interaction = aiInteractionFromStatement(statement) {
                interactions.append(interaction)
            }
        }

        return interactions
    }

    private func aiInteractionFromStatement(_ statement: OpaquePointer?) -> [String: Any]? {
        guard let statement = statement else { return nil }

        var interaction: [String: Any] = [:]
        let columnCount = sqlite3_column_count(statement)

        for i in 0..<columnCount {
            guard let columnName = sqlite3_column_name(statement, i) else { continue }
            let name = String(cString: columnName)
            let cleanName = name.lowercased().replacingOccurrences(of: "z", with: "", options: .anchored)

            switch sqlite3_column_type(statement, i) {
            case SQLITE_TEXT:
                if let text = sqlite3_column_text(statement, i) {
                    interaction[cleanName] = String(cString: text)
                }
            case SQLITE_INTEGER:
                interaction[cleanName] = sqlite3_column_int64(statement, i)
            case SQLITE_FLOAT:
                let value = sqlite3_column_double(statement, i)
                if cleanName == "timestamp" {
                    interaction[cleanName] = Date(timeIntervalSinceReferenceDate: value).ISO8601Format()
                } else {
                    interaction[cleanName] = value
                }
            default:
                break
            }
        }

        return interaction.isEmpty ? nil : interaction
    }

    // MARK: - Smart Digest

    func getSmartDigest(staleThresholdDays: Int = 7, unresolvedThresholdDays: Int = 7) -> [String: Any] {
        let now = Date()
        let staleThreshold = Calendar.current.date(byAdding: .day, value: -staleThresholdDays, to: now) ?? now
        let unresolvedThreshold = Calendar.current.date(byAdding: .day, value: -unresolvedThresholdDays, to: now) ?? now

        // Get stale work (projects with old snapshots but no recent activity)
        let staleWork = detectStaleWork(threshold: staleThreshold)

        // Get snapshots missing next steps
        let missingNext = findSnapshotsMissingNextSteps(sinceDays: 3)

        // Get unresolved decisions
        let unresolvedDecisions = findUnresolvedDecisions(threshold: unresolvedThreshold)

        // Get decisions awaiting critique
        let awaitingCritique = findDecisionsAwaitingCritique()

        // Calculate urgency
        let totalItems = staleWork.count + missingNext.count + unresolvedDecisions.count + awaitingCritique.count
        let urgency: String
        if totalItems == 0 {
            urgency = "clear"
        } else if totalItems <= 2 {
            urgency = "low"
        } else if totalItems <= 5 {
            urgency = "medium"
        } else {
            urgency = "high"
        }

        // Generate summary
        var summaryLines: [String] = []
        if !staleWork.isEmpty {
            let projectNames = staleWork.prefix(3).compactMap { $0["projectName"] as? String }
            summaryLines.append("\(staleWork.count) stale project(s): \(projectNames.joined(separator: ", "))")
        }
        if !missingNext.isEmpty {
            summaryLines.append("\(missingNext.count) snapshot(s) missing next steps")
        }
        if !unresolvedDecisions.isEmpty {
            summaryLines.append("\(unresolvedDecisions.count) decision(s) awaiting resolution")
        }
        if !awaitingCritique.isEmpty {
            summaryLines.append("\(awaitingCritique.count) decision(s) awaiting critique")
        }
        if summaryLines.isEmpty {
            summaryLines.append("All clear! No pending items.")
        }

        return [
            "generatedAt": Self.iso8601Formatter.string(from: now),
            "urgency": urgency,
            "totalActionItems": totalItems,
            "staleWork": staleWork,
            "snapshotsMissingNext": missingNext,
            "unresolvedDecisions": unresolvedDecisions,
            "decisionsAwaitingCritique": awaitingCritique,
            "summary": summaryLines.joined(separator: "\n")
        ]
    }

    private func detectStaleWork(threshold: Date) -> [[String: Any]] {
        guard ensureConnection(), let db = db else { return [] }

        // Find projects with no recent activity and get their most recent snapshot
        // Uses subquery to ensure we get the actual most recent snapshot per project
        let query = """
            SELECT s.ZPROJECTPATH, s.ZTITLE, s.ZTIMESTAMP, s.ZID
            FROM ZCONTEXTSNAPSHOT s
            WHERE s.ZPROJECTPATH IS NOT NULL
            AND NOT EXISTS (
                SELECT 1 FROM ZACTIVITY a
                WHERE a.ZPROJECTPATH = s.ZPROJECTPATH
                AND a.ZTIMESTAMP >= ?
            )
            AND s.ZTIMESTAMP = (
                SELECT MAX(s2.ZTIMESTAMP)
                FROM ZCONTEXTSNAPSHOT s2
                WHERE s2.ZPROJECTPATH = s.ZPROJECTPATH
            )
            ORDER BY s.ZTIMESTAMP DESC
            LIMIT 10
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, threshold.timeIntervalSinceReferenceDate)

        var results: [[String: Any]] = []
        let now = Date()

        while sqlite3_step(statement) == SQLITE_ROW {
            if let projectPath = sqlite3_column_text(statement, 0) {
                let path = String(cString: projectPath)
                let timestamp = sqlite3_column_double(statement, 2)
                let snapshotDate = Date(timeIntervalSinceReferenceDate: timestamp)
                let daysSince = Calendar.current.dateComponents([.day], from: snapshotDate, to: now).day ?? 0

                results.append([
                    "projectPath": path,
                    "projectName": URL(fileURLWithPath: path).lastPathComponent,
                    "lastSnapshotTitle": sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "",
                    "lastSnapshotId": sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "",
                    "lastSnapshotDate": snapshotDate.ISO8601Format(),
                    "daysSinceActivity": daysSince
                ])
            }
        }

        return results
    }

    private func findSnapshotsMissingNextSteps(sinceDays: Int) -> [[String: Any]] {
        guard ensureConnection(), let db = db else { return [] }

        let threshold = Calendar.current.date(byAdding: .day, value: -sinceDays, to: Date()) ?? Date()

        let query = """
            SELECT ZID, ZTITLE, ZPROJECTPATH, ZTIMESTAMP
            FROM ZCONTEXTSNAPSHOT
            WHERE ZTIMESTAMP >= ?
            AND (ZNEXTSTEPS IS NULL OR ZNEXTSTEPS = '')
            ORDER BY ZTIMESTAMP DESC
            LIMIT 10
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, threshold.timeIntervalSinceReferenceDate)

        var results: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = sqlite3_column_double(statement, 3)
            results.append([
                "id": sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "",
                "title": sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "",
                "projectPath": sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "",
                "timestamp": Date(timeIntervalSinceReferenceDate: timestamp).ISO8601Format()
            ])
        }

        return results
    }

    private func findUnresolvedDecisions(threshold: Date) -> [[String: Any]] {
        guard ensureConnection(), let db = db else { return [] }

        let query = """
            SELECT ZID, ZTITLE, ZPROBLEM, ZPROJECTPATH, ZTIMESTAMP
            FROM ZDECISION
            WHERE ZTIMESTAMP < ?
            AND (ZOUTCOME IS NULL OR ZOUTCOME = 'pending')
            ORDER BY ZTIMESTAMP ASC
            LIMIT 10
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, threshold.timeIntervalSinceReferenceDate)

        var results: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = sqlite3_column_double(statement, 4)
            results.append([
                "id": sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "",
                "title": sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "",
                "problem": sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "",
                "projectPath": sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "",
                "timestamp": Date(timeIntervalSinceReferenceDate: timestamp).ISO8601Format()
            ])
        }

        return results
    }

    private func findDecisionsAwaitingCritique() -> [[String: Any]] {
        guard ensureConnection(), let db = db else { return [] }

        let query = """
            SELECT ZID, ZTITLE, ZPROBLEM, ZPROJECTPATH, ZTIMESTAMP
            FROM ZDECISION
            WHERE ZCRITIQUEREQUESTED = 1
            AND ZAICRITIQUE IS NULL
            ORDER BY ZTIMESTAMP ASC
            LIMIT 10
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var results: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = sqlite3_column_double(statement, 4)
            results.append([
                "id": sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "",
                "title": sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "",
                "problem": sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "",
                "projectPath": sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "",
                "timestamp": Date(timeIntervalSinceReferenceDate: timestamp).ISO8601Format()
            ])
        }

        return results
    }
}
