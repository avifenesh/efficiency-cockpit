import Foundation

/// MCP Server for Efficiency Cockpit
/// Provides JSON-RPC interface over stdio for Claude Code integration

// MARK: - JSON-RPC Types

struct JSONRPCRequest: Codable {
    let jsonrpc: String
    let id: AnyCodable?  // Can be String, Int, or null per JSON-RPC spec
    let method: String
    let params: [String: AnyCodable]?
}

struct JSONRPCResponse: Codable {
    var jsonrpc: String = "2.0"
    let id: AnyCodable?  // Matches request id type
    let result: AnyCodable?
    let error: JSONRPCError?
}

struct JSONRPCError: Codable {
    let code: Int
    let message: String
    let data: AnyCodable?
}

// MARK: - MCP Types

struct MCPCapabilities: Codable {
    let resources: ResourcesCapability?
    let tools: ToolsCapability?
}

struct ResourcesCapability: Codable {
    let subscribe: Bool?
    let listChanged: Bool?
}

struct ToolsCapability: Codable {
    let listChanged: Bool?
}

struct MCPResource: Codable {
    let uri: String
    let name: String
    let description: String?
    let mimeType: String?
}

struct MCPTool: Codable {
    let name: String
    let description: String?
    let inputSchema: [String: AnyCodable]
}

// MARK: - AnyCodable Helper

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            self.value = dictionary.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Cannot encode value"))
        }
    }
}

// MARK: - MCP Server

class MCPServer {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let dataAccess = DataAccess()

    /// Cached ISO8601 date formatter (DateFormatter is expensive to create)
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()

    private let resources: [MCPResource] = [
        MCPResource(uri: "activity://current", name: "Current Activity", description: "The user's current activity", mimeType: "application/json"),
        MCPResource(uri: "activity://today", name: "Today's Activities", description: "All activities from today", mimeType: "application/json"),
        MCPResource(uri: "stats://daily", name: "Daily Statistics", description: "Aggregated daily statistics", mimeType: "application/json"),
        MCPResource(uri: "projects://list", name: "Projects", description: "Detected projects", mimeType: "application/json"),
        MCPResource(uri: "insights://recent", name: "Recent Insights", description: "Recent AI-generated insights", mimeType: "application/json")
    ]

    private let tools: [MCPTool] = [
        MCPTool(
            name: "get_current_activity",
            description: "Get the user's current activity (app, window, file)",
            inputSchema: ["type": AnyCodable("object"), "properties": AnyCodable([String: Any]())]
        ),
        MCPTool(
            name: "get_today_activities",
            description: "Get all activities from today",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "limit": ["type": "integer", "description": "Maximum number of activities to return"],
                    "app_filter": ["type": "string", "description": "Filter by app name"]
                ])
            ]
        ),
        MCPTool(
            name: "get_time_on_project",
            description: "Get time spent on a specific project",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "project": ["type": "string", "description": "Project name or path"]
                ]),
                "required": AnyCodable(["project"])
            ]
        ),
        MCPTool(
            name: "search_activities",
            description: "Search activities by keyword, app, or project",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "query": ["type": "string", "description": "Search query"],
                    "from_date": ["type": "string", "description": "Start date (ISO 8601)"],
                    "to_date": ["type": "string", "description": "End date (ISO 8601)"]
                ])
            ]
        ),
        MCPTool(
            name: "get_productivity_score",
            description: "Calculate productivity score for a time period",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "period": ["type": "string", "enum": ["today", "week", "month"], "description": "Time period"]
                ])
            ]
        ),
        MCPTool(
            name: "store_insight",
            description: "Store an AI-generated insight about the user's productivity",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "title": ["type": "string", "description": "Insight title"],
                    "content": ["type": "string", "description": "Insight content"],
                    "type": ["type": "string", "enum": ["tip", "warning", "achievement", "pattern"], "description": "Insight type"]
                ]),
                "required": AnyCodable(["title", "content", "type"])
            ]
        ),
        // Context Snapshot tools
        MCPTool(
            name: "capture_context_snapshot",
            description: "Capture a context snapshot of the user's current work state",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "title": ["type": "string", "description": "Snapshot title"],
                    "what_i_was_doing": ["type": "string", "description": "Description of current work"],
                    "why_i_was_doing_it": ["type": "string", "description": "Reason for the work"],
                    "next_steps": ["type": "string", "description": "Planned next steps"],
                    "project_path": ["type": "string", "description": "Project path"],
                    "git_branch": ["type": "string", "description": "Current git branch"]
                ]),
                "required": AnyCodable(["title", "what_i_was_doing"])
            ]
        ),
        MCPTool(
            name: "get_recent_snapshots",
            description: "Get recent context snapshots",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "limit": ["type": "integer", "description": "Maximum number of snapshots to return"],
                    "project_filter": ["type": "string", "description": "Filter by project path"]
                ])
            ]
        ),
        MCPTool(
            name: "get_resume_context",
            description: "Get context for resuming work on a project or from a snapshot",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "snapshot_id": ["type": "string", "description": "Specific snapshot ID to resume from"],
                    "project_path": ["type": "string", "description": "Project path to find most recent snapshot"]
                ])
            ]
        ),
        // Decision tools
        MCPTool(
            name: "record_decision",
            description: "Record a technical decision for the Build/Buy gatekeeper",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "title": ["type": "string", "description": "Decision title"],
                    "problem": ["type": "string", "description": "Problem being solved"],
                    "decision_type": ["type": "string", "enum": ["buildVsBuy", "technicalApproach", "toolChoice", "architecture", "refactoring", "other"], "description": "Type of decision"],
                    "options": ["type": "string", "description": "JSON array of options considered"],
                    "chosen_option": ["type": "string", "description": "The chosen option"],
                    "rationale": ["type": "string", "description": "Reasoning for the choice"],
                    "project_path": ["type": "string", "description": "Related project path"],
                    "request_critique": ["type": "boolean", "description": "Whether to request AI critique"]
                ]),
                "required": AnyCodable(["title", "problem", "decision_type"])
            ]
        ),
        MCPTool(
            name: "list_decisions",
            description: "List recorded decisions",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "limit": ["type": "integer", "description": "Maximum number of decisions to return"],
                    "type_filter": ["type": "string", "description": "Filter by decision type"],
                    "pending_only": ["type": "boolean", "description": "Only show pending decisions"]
                ])
            ]
        ),
        MCPTool(
            name: "update_decision_outcome",
            description: "Update the outcome of a decision",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "decision_id": ["type": "string", "description": "Decision ID to update"],
                    "outcome": ["type": "string", "enum": ["successful", "partialSuccess", "failed", "abandoned", "pending"], "description": "Decision outcome"],
                    "outcome_notes": ["type": "string", "description": "Notes about the outcome"]
                ]),
                "required": AnyCodable(["decision_id", "outcome"])
            ]
        ),
        // Unified search
        MCPTool(
            name: "unified_search",
            description: "Search across activities, snapshots, decisions, and insights",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "query": ["type": "string", "description": "Search query"],
                    "types": ["type": "string", "description": "Comma-separated types to search: activity,snapshot,decision,insight"],
                    "from_date": ["type": "string", "description": "Start date (ISO 8601)"],
                    "to_date": ["type": "string", "description": "End date (ISO 8601)"],
                    "limit": ["type": "integer", "description": "Maximum results per type"]
                ]),
                "required": AnyCodable(["query"])
            ]
        ),
        // Digest
        MCPTool(
            name: "get_digest",
            description: "Generate a productivity digest for a time period",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "period": ["type": "string", "enum": ["today", "yesterday", "week"], "description": "Time period for digest"]
                ])
            ]
        ),
        // FTS Search
        MCPTool(
            name: "fts_search",
            description: "Fast full-text search with ranking across all indexed content (activities, snapshots, decisions, AI history, code)",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "query": ["type": "string", "description": "Search query (supports phrases in quotes and prefix matching)"],
                    "types": ["type": "string", "description": "Comma-separated types: activity,snapshot,decision,ai,content"],
                    "project_filter": ["type": "string", "description": "Filter to specific project path"],
                    "limit": ["type": "integer", "description": "Max results (default 50)"]
                ]),
                "required": AnyCodable(["query"])
            ]
        ),
        MCPTool(
            name: "get_ai_history",
            description: "Get past AI interactions for search and learning",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "limit": ["type": "integer", "description": "Max results (default 20)"],
                    "action_type": ["type": "string", "description": "Filter by action type: ask, summarize, nextSteps, debug, promptPack, critique"]
                ])
            ]
        ),
        MCPTool(
            name: "get_smart_digest",
            description: "Get smart digest with stale work, missing next steps, and unresolved decisions",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "stale_threshold_days": ["type": "integer", "description": "Days to consider work stale (default 7)"],
                    "unresolved_threshold_days": ["type": "integer", "description": "Days to consider decision unresolved (default 7)"]
                ])
            ]
        ),
        MCPTool(
            name: "rebuild_fts_index",
            description: "Rebuild full-text search indexes from current data",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([:])
            ]
        ),
        MCPTool(
            name: "store_ai_interaction",
            description: "Store an AI interaction for later search and analysis",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "prompt_summary": ["type": "string", "description": "Brief summary of the prompt"],
                    "full_prompt": ["type": "string", "description": "Full prompt text"],
                    "action_type": ["type": "string", "description": "Type of action: ask, summarize, nextSteps, debug, promptPack, critique"],
                    "response": ["type": "string", "description": "AI response text"],
                    "context_type": ["type": "string", "description": "Context type: activities, snapshot, decision, freeform"],
                    "project_path": ["type": "string", "description": "Related project path"]
                ]),
                "required": AnyCodable(["prompt_summary", "action_type", "response"])
            ]
        )
    ]

    func run() {
        while let line = readLine() {
            guard !line.isEmpty else { continue }

            do {
                let request = try decoder.decode(JSONRPCRequest.self, from: Data(line.utf8))

                // JSON-RPC notifications (id is nil or NSNull) don't get responses
                if request.id == nil || request.id?.value is NSNull {
                    handleNotification(request)
                    continue
                }

                let response = handleRequest(request)
                let responseData = try encoder.encode(response)
                if let responseString = String(data: responseData, encoding: .utf8) {
                    print(responseString)
                    fflush(stdout)
                }
            } catch {
                let errorResponse = JSONRPCResponse(
                    id: nil,
                    result: nil,
                    error: JSONRPCError(code: -32700, message: "Parse error: \(error.localizedDescription)", data: nil)
                )
                if let data = try? encoder.encode(errorResponse),
                   let str = String(data: data, encoding: .utf8) {
                    print(str)
                    fflush(stdout)
                }
            }
        }
    }

    /// Handle JSON-RPC notifications (no response required)
    private func handleNotification(_ request: JSONRPCRequest) {
        switch request.method {
        case "notifications/initialized", "initialized":
            // MCP initialized notification - server is ready
            break
        case "notifications/cancelled":
            // Request cancellation notification
            break
        default:
            // Unknown notification - ignore per JSON-RPC spec
            break
        }
    }

    private func handleRequest(_ request: JSONRPCRequest) -> JSONRPCResponse {
        switch request.method {
        case "initialize":
            return handleInitialize(request)
        case "resources/list":
            return handleListResources(request)
        case "resources/read":
            return handleReadResource(request)
        case "tools/list":
            return handleListTools(request)
        case "tools/call":
            return handleCallTool(request)
        default:
            return JSONRPCResponse(
                id: request.id,
                result: nil,
                error: JSONRPCError(code: -32601, message: "Method not found: \(request.method)", data: nil)
            )
        }
    }

    private func handleInitialize(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let result: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "resources": ["subscribe": false, "listChanged": false],
                "tools": ["listChanged": false]
            ],
            "serverInfo": [
                "name": "EfficiencyCockpit",
                "version": "1.0.0"
            ]
        ]
        return JSONRPCResponse(id: request.id, result: AnyCodable(result), error: nil)
    }

    private func handleListResources(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let resourceDicts = resources.map { resource -> [String: Any] in
            var dict: [String: Any] = [
                "uri": resource.uri,
                "name": resource.name
            ]
            if let desc = resource.description {
                dict["description"] = desc
            }
            if let mime = resource.mimeType {
                dict["mimeType"] = mime
            }
            return dict
        }
        return JSONRPCResponse(id: request.id, result: AnyCodable(["resources": resourceDicts]), error: nil)
    }

    private func handleReadResource(_ request: JSONRPCRequest) -> JSONRPCResponse {
        guard let params = request.params,
              let uri = params["uri"]?.value as? String else {
            return JSONRPCResponse(
                id: request.id,
                result: nil,
                error: JSONRPCError(code: -32602, message: "Invalid params: missing uri", data: nil)
            )
        }

        // Read from shared SwiftData database
        let content: [String: Any]
        switch uri {
        case "activity://current":
            content = dataAccess.getCurrentActivity() ?? ["error": "No current activity"]
        case "activity://today":
            let activities = dataAccess.getTodayActivities()
            content = ["activities": activities, "count": activities.count]
        case "stats://daily":
            content = dataAccess.getDailyStats()
        case "projects://list":
            content = ["projects": dataAccess.getProjects()]
        case "insights://recent":
            content = ["insights": dataAccess.getRecentInsights()]
        default:
            return JSONRPCResponse(
                id: request.id,
                result: nil,
                error: JSONRPCError(code: -32602, message: "Unknown resource: \(uri)", data: nil)
            )
        }

        let result: [String: Any] = [
            "contents": [
                [
                    "uri": uri,
                    "mimeType": "application/json",
                    "text": try? String(data: JSONSerialization.data(withJSONObject: content), encoding: .utf8) ?? "{}"
                ]
            ]
        ]
        return JSONRPCResponse(id: request.id, result: AnyCodable(result), error: nil)
    }

    private func handleListTools(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let toolDicts = tools.map { tool -> [String: Any] in
            var dict: [String: Any] = [
                "name": tool.name,
                "inputSchema": tool.inputSchema.mapValues { $0.value }
            ]
            if let desc = tool.description {
                dict["description"] = desc
            }
            return dict
        }
        return JSONRPCResponse(id: request.id, result: AnyCodable(["tools": toolDicts]), error: nil)
    }

    private func handleCallTool(_ request: JSONRPCRequest) -> JSONRPCResponse {
        guard let params = request.params,
              let name = params["name"]?.value as? String else {
            return JSONRPCResponse(
                id: request.id,
                result: nil,
                error: JSONRPCError(code: -32602, message: "Invalid params: missing tool name", data: nil)
            )
        }

        let arguments = params["arguments"]?.value as? [String: Any] ?? [:]

        // Execute tool with actual data
        let content: [String: Any]
        switch name {
        case "get_current_activity":
            content = dataAccess.getCurrentActivity() ?? ["error": "No current activity"]

        case "get_today_activities":
            // Validate and sanitize limit parameter
            var limit = 100
            if let limitArg = arguments["limit"] {
                if let limitInt = limitArg as? Int {
                    limit = max(1, min(limitInt, 1000)) // Enforce bounds
                } else if let limitDouble = limitArg as? Double {
                    limit = max(1, min(Int(limitDouble), 1000))
                }
                // Otherwise use default
            }
            let appFilter = arguments["app_filter"] as? String
            let activities = dataAccess.getTodayActivities(limit: limit, appFilter: appFilter)
            content = ["activities": activities, "count": activities.count]

        case "get_time_on_project":
            let project = arguments["project"] as? String ?? ""
            content = dataAccess.getTimeOnProject(project)

        case "search_activities":
            let query = arguments["query"] as? String ?? ""

            // Require non-empty query to prevent returning all activities
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                content = ["error": "Search query is required", "results": [], "count": 0]
                break
            }

            var fromDate: Date?
            var toDate: Date?

            if let fromStr = arguments["from_date"] as? String {
                fromDate = Self.iso8601Formatter.date(from: fromStr)
            }
            if let toStr = arguments["to_date"] as? String {
                toDate = Self.iso8601Formatter.date(from: toStr)
            }

            let results = dataAccess.searchActivities(query: query, fromDate: fromDate, toDate: toDate)
            content = ["results": results, "count": results.count]

        case "get_productivity_score":
            let period = arguments["period"] as? String ?? "today"
            content = dataAccess.getProductivityScore(period: period)

        case "store_insight":
            let title = arguments["title"] as? String ?? ""
            let insightContent = arguments["content"] as? String ?? ""
            let type = arguments["type"] as? String ?? "tip"

            if let id = dataAccess.storeInsight(title: title, content: insightContent, type: type) {
                content = ["stored": true, "id": id]
            } else {
                content = ["stored": false, "error": "Failed to store insight"]
            }

        // Context Snapshot tools
        case "capture_context_snapshot":
            let title = arguments["title"] as? String ?? ""
            let whatIWasDoing = arguments["what_i_was_doing"] as? String ?? ""
            let whyIWasDoingIt = arguments["why_i_was_doing_it"] as? String
            let nextSteps = arguments["next_steps"] as? String
            let projectPath = arguments["project_path"] as? String
            let gitBranch = arguments["git_branch"] as? String

            let snapshot: [String: Any] = [
                "title": title,
                "whatIWasDoing": whatIWasDoing,
                "whyIWasDoingIt": whyIWasDoingIt as Any,
                "nextSteps": nextSteps as Any,
                "projectPath": projectPath as Any,
                "gitBranch": gitBranch as Any,
                "source": "mcp"
            ]

            if let id = dataAccess.insertSnapshot(snapshot) {
                content = ["stored": true, "id": id]
            } else {
                content = ["stored": false, "error": "Failed to store snapshot"]
            }

        case "get_recent_snapshots":
            var limit = 10
            if let limitArg = arguments["limit"] as? Int {
                limit = max(1, min(limitArg, 100))
            }
            let projectFilter = arguments["project_filter"] as? String
            let snapshots = dataAccess.getRecentSnapshots(limit: limit, projectFilter: projectFilter)
            content = ["snapshots": snapshots, "count": snapshots.count]

        case "get_resume_context":
            if let snapshotId = arguments["snapshot_id"] as? String {
                if let snapshot = dataAccess.getSnapshot(id: snapshotId) {
                    content = ["snapshot": snapshot, "found": true]
                } else {
                    content = ["found": false, "error": "Snapshot not found"]
                }
            } else if let projectPath = arguments["project_path"] as? String {
                let snapshots = dataAccess.getRecentSnapshots(limit: 1, projectFilter: projectPath)
                if let snapshot = snapshots.first {
                    content = ["snapshot": snapshot, "found": true]
                } else {
                    content = ["found": false, "error": "No snapshots found for project"]
                }
            } else {
                // Get most recent snapshot
                let snapshots = dataAccess.getRecentSnapshots(limit: 1, projectFilter: nil)
                if let snapshot = snapshots.first {
                    content = ["snapshot": snapshot, "found": true]
                } else {
                    content = ["found": false, "error": "No snapshots available"]
                }
            }

        // Decision tools
        case "record_decision":
            let title = arguments["title"] as? String ?? ""
            let problem = arguments["problem"] as? String ?? ""
            let decisionType = arguments["decision_type"] as? String ?? "other"
            let options = arguments["options"] as? String
            let chosenOption = arguments["chosen_option"] as? String
            let rationale = arguments["rationale"] as? String
            let projectPath = arguments["project_path"] as? String
            let requestCritique = arguments["request_critique"] as? Bool ?? false

            let decision: [String: Any] = [
                "title": title,
                "problem": problem,
                "decisionType": decisionType,
                "options": options as Any,
                "chosenOption": chosenOption as Any,
                "rationale": rationale as Any,
                "projectPath": projectPath as Any,
                "critiqueRequested": requestCritique
            ]

            if let id = dataAccess.insertDecision(decision) {
                content = ["stored": true, "id": id]
            } else {
                content = ["stored": false, "error": "Failed to store decision"]
            }

        case "list_decisions":
            var limit = 20
            if let limitArg = arguments["limit"] as? Int {
                limit = max(1, min(limitArg, 100))
            }
            let typeFilter = arguments["type_filter"] as? String
            let pendingOnly = arguments["pending_only"] as? Bool ?? false
            let decisions = dataAccess.getRecentDecisions(limit: limit, typeFilter: typeFilter, pendingOnly: pendingOnly)
            content = ["decisions": decisions, "count": decisions.count]

        case "update_decision_outcome":
            guard let decisionId = arguments["decision_id"] as? String else {
                content = ["error": "decision_id is required"]
                break
            }
            let outcome = arguments["outcome"] as? String ?? "pending"
            let outcomeNotes = arguments["outcome_notes"] as? String

            let fields: [String: Any] = [
                "outcome": outcome,
                "outcomeNotes": outcomeNotes as Any
            ]

            if dataAccess.updateDecision(id: decisionId, fields: fields) {
                content = ["updated": true, "id": decisionId]
            } else {
                content = ["updated": false, "error": "Failed to update decision"]
            }

        // Unified search
        case "unified_search":
            let query = arguments["query"] as? String ?? ""
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                content = ["error": "Search query is required", "results": [:], "total": 0]
                break
            }

            let typesStr = arguments["types"] as? String ?? "activity,snapshot,decision,insight"
            let types = Set(typesStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })

            var fromDate: Date?
            var toDate: Date?
            if let fromStr = arguments["from_date"] as? String {
                fromDate = Self.iso8601Formatter.date(from: fromStr)
            }
            if let toStr = arguments["to_date"] as? String {
                toDate = Self.iso8601Formatter.date(from: toStr)
            }

            var limit = 20
            if let limitArg = arguments["limit"] as? Int {
                limit = max(1, min(limitArg, 50))
            }

            let results = dataAccess.unifiedSearch(query: query, types: types, fromDate: fromDate, toDate: toDate, limit: limit)
            var totalCount = 0
            for (_, items) in results {
                if let arr = items as? [[String: Any]] {
                    totalCount += arr.count
                }
            }
            content = ["results": results, "total": totalCount]

        // Digest
        case "get_digest":
            let period = arguments["period"] as? String ?? "today"
            content = dataAccess.getDigest(period: period)

        // FTS Search
        case "fts_search":
            let query = arguments["query"] as? String ?? ""
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                content = ["error": "Search query is required", "results": [], "count": 0]
                break
            }

            let typesStr = arguments["types"] as? String ?? "activity,snapshot,decision,ai,content"
            let types = Set(typesStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            let projectFilter = arguments["project_filter"] as? String

            var limit = 50
            if let limitArg = arguments["limit"] as? Int {
                limit = max(1, min(limitArg, 100))
            }

            let results = dataAccess.ftsSearch(query: query, types: types, limit: limit, projectFilter: projectFilter)
            content = ["results": results, "count": results.count, "query": query]

        // AI History
        case "get_ai_history":
            var limit = 20
            if let limitArg = arguments["limit"] as? Int {
                limit = max(1, min(limitArg, 100))
            }
            let actionType = arguments["action_type"] as? String
            let interactions = dataAccess.getRecentAIInteractions(limit: limit, actionType: actionType)
            content = ["interactions": interactions, "count": interactions.count]

        // Smart Digest
        case "get_smart_digest":
            var staleThreshold = 7
            if let staleArg = arguments["stale_threshold_days"] as? Int {
                staleThreshold = max(1, min(staleArg, 90))
            }
            var unresolvedThreshold = 7
            if let unresolvedArg = arguments["unresolved_threshold_days"] as? Int {
                unresolvedThreshold = max(1, min(unresolvedArg, 90))
            }
            content = dataAccess.getSmartDigest(staleThresholdDays: staleThreshold, unresolvedThresholdDays: unresolvedThreshold)

        // Rebuild FTS Index
        case "rebuild_fts_index":
            dataAccess.rebuildFTSIndexes()
            content = ["success": true, "message": "FTS indexes rebuilt successfully"]

        // Store AI Interaction
        case "store_ai_interaction":
            let promptSummary = arguments["prompt_summary"] as? String ?? ""
            let fullPrompt = arguments["full_prompt"] as? String
            let actionType = arguments["action_type"] as? String ?? "ask"
            let response = arguments["response"] as? String ?? ""
            let contextType = arguments["context_type"] as? String ?? "freeform"
            let projectPath = arguments["project_path"] as? String

            let interaction: [String: Any] = [
                "promptSummary": promptSummary,
                "fullPrompt": fullPrompt as Any,
                "actionType": actionType,
                "response": response,
                "contextType": contextType,
                "projectPath": projectPath as Any
            ]

            if let id = dataAccess.insertAIInteraction(interaction) {
                content = ["stored": true, "id": id]
            } else {
                content = ["stored": false, "error": "Failed to store AI interaction"]
            }

        default:
            return JSONRPCResponse(
                id: request.id,
                result: nil,
                error: JSONRPCError(code: -32602, message: "Unknown tool: \(name)", data: nil)
            )
        }

        let result: [String: Any] = [
            "content": [
                [
                    "type": "text",
                    "text": (try? String(data: JSONSerialization.data(withJSONObject: content), encoding: .utf8)) ?? "{}"
                ]
            ]
        ]
        return JSONRPCResponse(id: request.id, result: AnyCodable(result), error: nil)
    }
}

// MARK: - Main

let server = MCPServer()
server.run()
