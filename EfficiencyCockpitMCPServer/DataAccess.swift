import Foundation
import SQLite3

/// Shared data access for MCP Server
/// Reads from the SwiftData SQLite database created by the main app
final class DataAccess {
    private var db: OpaquePointer?
    private let dbPath: String

    init() {
        // SwiftData stores in Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("EfficiencyCockpit")
        dbPath = appFolder.appendingPathComponent("default.store").path

        openDatabase()
    }

    deinit {
        closeDatabase()
    }

    private func openDatabase() {
        // Open in read-only mode
        if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            print("Failed to open database at \(dbPath)")
            db = nil
        }
    }

    private func closeDatabase() {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Activity Queries

    func getCurrentActivity() -> [String: Any]? {
        guard let db = db else { return nil }

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
        guard let db = db else { return [] }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let timestamp = startOfDay.timeIntervalSinceReferenceDate

        var query = """
            SELECT * FROM ZACTIVITY
            WHERE ZTIMESTAMP >= ?
        """

        if appFilter != nil {
            query += " AND ZAPPNAME LIKE ?"
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
            sqlite3_bind_text(statement, paramIndex, "%\(filter)%", -1, nil)
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
        guard let db = db else { return [] }

        var query = """
            SELECT * FROM ZACTIVITY
            WHERE (ZAPPNAME LIKE ? OR ZWINDOWTITLE LIKE ? OR ZPROJECTPATH LIKE ?)
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

        let searchPattern = "%\(searchQuery)%"
        sqlite3_bind_text(statement, 1, searchPattern, -1, nil)
        sqlite3_bind_text(statement, 2, searchPattern, -1, nil)
        sqlite3_bind_text(statement, 3, searchPattern, -1, nil)

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
        guard let db = db else {
            return ["project": projectName, "totalTime": 0, "sessions": []]
        }

        let query = """
            SELECT SUM(ZDURATION) as total_time, COUNT(*) as session_count
            FROM ZACTIVITY
            WHERE ZPROJECTPATH LIKE ?
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return ["project": projectName, "totalTime": 0, "sessions": []]
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, "%\(projectName)%", -1, nil)

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
        guard let db = db else {
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
            "date": ISO8601DateFormatter().string(from: Date()),
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

        guard let db = db else {
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

        // Productive time
        let productiveQuery = """
            SELECT SUM(ZDURATION) FROM ZACTIVITY
            WHERE ZTIMESTAMP >= ?
            AND (ZAPPNAME IN ('\(productiveApps.joined(separator: "','"))')
                 OR ZTYPE = 'aiToolUse'
                 OR ZTYPE = 'fileOpen')
        """

        var productiveTime: Double = 0
        if sqlite3_prepare_v2(db, productiveQuery, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, timestamp)
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
        guard let db = db else { return [] }

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
        guard let db = db else { return [] }

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

            if let title = sqlite3_column_text(statement, columnIndex(for: "ZTITLE", in: statement)) {
                insight["title"] = String(cString: title)
            }
            if let content = sqlite3_column_text(statement, columnIndex(for: "ZCONTENT", in: statement)) {
                insight["content"] = String(cString: content)
            }
            if let type = sqlite3_column_text(statement, columnIndex(for: "ZTYPE", in: statement)) {
                insight["type"] = String(cString: type)
            }

            let timestamp = sqlite3_column_double(statement, columnIndex(for: "ZGENERATEDAT", in: statement))
            insight["generatedAt"] = Date(timeIntervalSinceReferenceDate: timestamp).ISO8601Format()

            insights.append(insight)
        }

        return insights
    }

    func storeInsight(title: String, content: String, type: String) -> String? {
        // Note: Writing requires opening DB in read-write mode
        // For now, return a placeholder - in production, use XPC or a write-enabled connection
        return UUID().uuidString
    }

    // MARK: - Helpers

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

    private func columnIndex(for name: String, in statement: OpaquePointer?) -> Int32 {
        guard let statement = statement else { return -1 }

        let columnCount = sqlite3_column_count(statement)
        for i in 0..<columnCount {
            if let columnName = sqlite3_column_name(statement, i) {
                if String(cString: columnName) == name {
                    return i
                }
            }
        }
        return -1
    }

    private func formatDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
